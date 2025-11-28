import Foundation
import EventKit
import Combine
import UserNotifications

/// Represents pending sync changes before they are committed
struct PendingSyncChanges: Equatable {
    var toCreate: Int = 0
    var toUpdate: Int = 0
    var toDelete: Int = 0
    
    var total: Int { toCreate + toUpdate + toDelete }
    var isEmpty: Bool { total == 0 }
    
    var description: String {
        var parts: [String] = []
        if toCreate > 0 { parts.append("\(toCreate) to create") }
        if toUpdate > 0 { parts.append("\(toUpdate) to update") }
        if toDelete > 0 { parts.append("\(toDelete) to delete") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

/// Represents an event or recurring series to be synced
struct SyncableEvent {
    let event: EKEvent
    let seriesId: String  // Unique ID for the series (same for all occurrences)
    let isRecurring: Bool
    let recurrenceRules: [EKRecurrenceRule]?
    
    /// Creates a SyncableEvent from an EKEvent
    static func from(_ event: EKEvent, useSeriesTracking: Bool) -> SyncableEvent {
        let isRecurring = event.hasRecurrenceRules
        
        // For recurring events, use calendarItemExternalIdentifier if available
        // This ID is stable across all occurrences of a recurring event
        let seriesId: String
        if useSeriesTracking && isRecurring, let externalId = event.calendarItemExternalIdentifier {
            seriesId = externalId
        } else {
            seriesId = event.eventIdentifier ?? UUID().uuidString
        }
        
        return SyncableEvent(
            event: event,
            seriesId: seriesId,
            isRecurring: isRecurring,
            recurrenceRules: isRecurring ? event.recurrenceRules : nil
        )
    }
}

/// The core sync engine that manages calendar synchronization
class SyncEngine: ObservableObject {
    let eventStore = EKEventStore()
    
    @Published var calendars: [EKCalendar] = []
    @Published var lastSyncTime: Date?
    @Published var isSyncing = false
    @Published var isSyncEnabled = true
    @Published var pendingChanges = PendingSyncChanges()
    
    private var syncTimer: Timer?
    private var lastSyncCompletedTime: Date?
    private let syncCooldownSeconds: TimeInterval = 10 // Minimum time between syncs
    private var enabledCalendarIds: Set<String> = []
    private let settings = Settings.shared
    
    /// Marker prefix to identify synced blocks
    static let blockMarkerPrefix = "<!-- CALSYNC:BLOCK:"
    static let blockMarkerSuffix = " -->"
    
    init() {
        loadEnabledCalendars()
    }
    
    // MARK: - Calendar Management
    
    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
        
        Logger.shared.log("Loaded \(calendars.count) calendars")
        
        // Don't auto-enable calendars - user should manually select which ones to sync
        // This prevents syncing birthday calendars, holidays, etc. by default
        // Only keep calendars that still exist
        let validCalendarIds = Set(calendars.map { $0.calendarIdentifier })
        enabledCalendarIds = enabledCalendarIds.intersection(validCalendarIds)
        saveEnabledCalendars()
    }
    
    func isCalendarEnabled(_ calendarId: String) -> Bool {
        enabledCalendarIds.contains(calendarId)
    }
    
    func toggleCalendar(_ calendarId: String) {
        if enabledCalendarIds.contains(calendarId) {
            enabledCalendarIds.remove(calendarId)
        } else {
            enabledCalendarIds.insert(calendarId)
        }
        saveEnabledCalendars()
    }
    
    private func loadEnabledCalendars() {
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledCalendarIds") {
            enabledCalendarIds = Set(saved)
        }
    }
    
    private func saveEnabledCalendars() {
        UserDefaults.standard.set(Array(enabledCalendarIds), forKey: "enabledCalendarIds")
    }
    
    // MARK: - Sync Timer
    
    func startSyncTimer() {
        stopSyncTimer()
        let interval = TimeInterval(settings.syncIntervalMinutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.performSync()
            }
        }
        Logger.shared.log("Sync timer started (interval: \(settings.syncIntervalMinutes) min)")
    }
    
    func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        Logger.shared.log("Sync timer stopped")
    }
    
    // MARK: - Sync Logic
    
    /// Gathers calendar data for sync analysis
    private func gatherCalendarData() -> (syncableEvents: [String: [SyncableEvent]], existingBlocks: [String: [EKEvent]], enabledCalendars: [EKCalendar])? {
        let enabledCalendars = calendars.filter { enabledCalendarIds.contains($0.calendarIdentifier) }
        
        guard enabledCalendars.count >= 2 else {
            return nil
        }
        
        let syncWindow = settings.syncWindowDays
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: syncWindow, to: startDate)!
        let useSeriesTracking = settings.syncRecurringAsSeries
        
        var syncableEventsByCalendar: [String: [SyncableEvent]] = [:]
        var existingBlocksByCalendar: [String: [EKEvent]] = [:]
        
        for calendar in enabledCalendars {
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: [calendar]
            )
            
            let events = eventStore.events(matching: predicate)
            
            var realEvents: [SyncableEvent] = []
            var blocks: [EKEvent] = []
            
            // Track series we've already seen (for deduplication)
            var seenSeriesIds = Set<String>()
            
            for event in events {
                if isBlockEvent(event) {
                    blocks.append(event)
                } else {
                    let syncable = SyncableEvent.from(event, useSeriesTracking: useSeriesTracking)
                    
                    // If tracking recurring series, only keep first occurrence
                    if useSeriesTracking && syncable.isRecurring {
                        if seenSeriesIds.contains(syncable.seriesId) {
                            continue  // Skip duplicate occurrence
                        }
                        seenSeriesIds.insert(syncable.seriesId)
                    }
                    
                    realEvents.append(syncable)
                }
            }
            
            syncableEventsByCalendar[calendar.calendarIdentifier] = realEvents
            existingBlocksByCalendar[calendar.calendarIdentifier] = blocks
        }
        
        return (syncableEventsByCalendar, existingBlocksByCalendar, enabledCalendars)
    }
    
    /// Calculates what changes would be made without actually making them
    @MainActor
    func calculatePendingChanges() async {
        guard !isSyncing else { return }
        
        guard let data = gatherCalendarData() else {
            pendingChanges = PendingSyncChanges()
            return
        }
        
        let (syncableEventsByCalendar, existingBlocksByCalendar, enabledCalendars) = data
        
        var toCreate = 0
        var toUpdate = 0
        var toDelete = 0
        
        for targetCalendar in enabledCalendars {
            let targetId = targetCalendar.calendarIdentifier
            let existingBlocks = existingBlocksByCalendar[targetId] ?? []
            
            var expectedBlockIds = Set<String>()
            
            for sourceCalendar in enabledCalendars {
                let sourceId = sourceCalendar.calendarIdentifier
                guard sourceId != targetId else { continue }
                
                let sourceSyncables = syncableEventsByCalendar[sourceId] ?? []
                
                for syncable in sourceSyncables {
                    let sourceEvent = syncable.event
                    
                    if sourceEvent.isAllDay && !settings.syncAllDayEvents {
                        continue
                    }
                    
                    // Use seriesId for recurring events, eventIdentifier for regular events
                    let blockId = generateBlockId(sourceCalendarId: sourceId, sourceEventId: syncable.seriesId)
                    expectedBlockIds.insert(blockId)
                    
                    let existingBlock = existingBlocks.first { event in
                        getBlockId(from: event) == blockId
                    }
                    
                    if let existing = existingBlock {
                        // For recurring events, we compare the first occurrence
                        if existing.startDate != sourceEvent.startDate ||
                           existing.endDate != sourceEvent.endDate {
                            toUpdate += 1
                        }
                    } else {
                        toCreate += 1
                    }
                }
            }
            
            for existingBlock in existingBlocks {
                if let blockId = getBlockId(from: existingBlock),
                   !expectedBlockIds.contains(blockId) {
                    toDelete += 1
                }
            }
        }
        
        pendingChanges = PendingSyncChanges(toCreate: toCreate, toUpdate: toUpdate, toDelete: toDelete)
        
        if !pendingChanges.isEmpty {
            Logger.shared.log("Pending changes: \(pendingChanges.description)")
        }
    }
    
    @MainActor
    func performSync() async {
        guard isSyncEnabled else {
            Logger.shared.log("Sync skipped - disabled")
            return
        }
        
        guard !isSyncing else {
            Logger.shared.log("Sync skipped - already in progress")
            return
        }
        
        // Check cooldown to prevent rapid re-syncs
        if let lastCompleted = lastSyncCompletedTime {
            let timeSinceLastSync = Date().timeIntervalSince(lastCompleted)
            if timeSinceLastSync < syncCooldownSeconds {
                Logger.shared.log("Sync skipped - cooldown active (\(Int(syncCooldownSeconds - timeSinceLastSync))s remaining)")
                return
            }
        }
        
        isSyncing = true
        defer { 
            isSyncing = false
            lastSyncCompletedTime = Date()
        }
        
        Logger.shared.log("Starting sync...")
        
        guard let data = gatherCalendarData() else {
            Logger.shared.log("Sync skipped - need at least 2 enabled calendars")
            return
        }
        
        let (syncableEventsByCalendar, existingBlocksByCalendar, enabledCalendars) = data
        
        for calendar in enabledCalendars {
            let syncables = syncableEventsByCalendar[calendar.calendarIdentifier] ?? []
            let blocks = existingBlocksByCalendar[calendar.calendarIdentifier] ?? []
            let recurringCount = syncables.filter { $0.isRecurring }.count
            Logger.shared.log("Calendar '\(calendar.title)': \(syncables.count) events (\(recurringCount) recurring series), \(blocks.count) existing blocks")
        }
        
        // Step 2: For each calendar, create/update blocks for events from other calendars
        var blocksCreated = 0
        var blocksUpdated = 0
        var blocksDeleted = 0
        
        for targetCalendar in enabledCalendars {
            let targetId = targetCalendar.calendarIdentifier
            let existingBlocks = existingBlocksByCalendar[targetId] ?? []
            
            // Build a set of expected block identifiers
            var expectedBlockIds = Set<String>()
            
            // Iterate through all other calendars' events
            for sourceCalendar in enabledCalendars {
                let sourceId = sourceCalendar.calendarIdentifier
                
                // Skip own calendar
                guard sourceId != targetId else { continue }
                
                let sourceSyncables = syncableEventsByCalendar[sourceId] ?? []
                
                for syncable in sourceSyncables {
                    let sourceEvent = syncable.event
                    
                    // Skip all-day events if configured
                    if sourceEvent.isAllDay && !settings.syncAllDayEvents {
                        continue
                    }
                    
                    // Use seriesId for recurring events (stable across occurrences)
                    let blockId = generateBlockId(sourceCalendarId: sourceId, sourceEventId: syncable.seriesId)
                    expectedBlockIds.insert(blockId)
                    
                    // Check if block already exists
                    let existingBlock = existingBlocks.first { event in
                        getBlockId(from: event) == blockId
                    }
                    
                    if let existing = existingBlock {
                        // Update if changed (for recurring, this updates the first occurrence time)
                        if existing.startDate != sourceEvent.startDate ||
                           existing.endDate != sourceEvent.endDate {
                            existing.startDate = sourceEvent.startDate
                            existing.endDate = sourceEvent.endDate
                            
                            // For recurring events, also update recurrence rules
                            if syncable.isRecurring && settings.syncRecurringAsSeries {
                                existing.recurrenceRules = syncable.recurrenceRules
                                try? eventStore.save(existing, span: .futureEvents)
                            } else {
                                try? eventStore.save(existing, span: .thisEvent)
                            }
                            blocksUpdated += 1
                        }
                    } else {
                        // Create new block
                        let accountName = getAccountName(for: sourceCalendar)
                        createBlock(
                            in: targetCalendar,
                            for: syncable,
                            sourceCalendarId: sourceId,
                            accountName: accountName
                        )
                        blocksCreated += 1
                    }
                }
            }
            
            // Step 3: Delete orphaned blocks (source event was deleted or changed)
            for existingBlock in existingBlocks {
                if let blockId = getBlockId(from: existingBlock),
                   !expectedBlockIds.contains(blockId) {
                    // For recurring blocks, delete the entire series
                    let span: EKSpan = existingBlock.hasRecurrenceRules ? .futureEvents : .thisEvent
                    try? eventStore.remove(existingBlock, span: span)
                    blocksDeleted += 1
                }
            }
        }
        
        lastSyncTime = Date()
        
        Logger.shared.log("Sync complete: \(blocksCreated) created, \(blocksUpdated) updated, \(blocksDeleted) deleted")
        
        // Show notification if there were changes
        if blocksCreated > 0 || blocksDeleted > 0 {
            sendNotification(created: blocksCreated, updated: blocksUpdated, deleted: blocksDeleted)
        }
        
        // Recalculate pending changes after sync to verify everything is in sync
        // This also ensures the UI shows accurate pending count immediately
        // Note: We need to set isSyncing = false first to allow the calculation
        isSyncing = false
        await calculatePendingChanges()
    }
    
    // MARK: - Block Management
    
    private func isBlockEvent(_ event: EKEvent) -> Bool {
        guard let notes = event.notes else { return false }
        return notes.contains(Self.blockMarkerPrefix)
    }
    
    private func generateBlockId(sourceCalendarId: String, sourceEventId: String) -> String {
        // Create a stable identifier for the block
        return "\(sourceCalendarId):\(sourceEventId)"
    }
    
    private func getBlockId(from event: EKEvent) -> String? {
        guard let notes = event.notes,
              let startRange = notes.range(of: Self.blockMarkerPrefix),
              let endRange = notes.range(of: Self.blockMarkerSuffix, range: startRange.upperBound..<notes.endIndex) else {
            return nil
        }
        
        let markerContent = String(notes[startRange.upperBound..<endRange.lowerBound])
        // Parse: source=XXX|id=YYY|recurring=ZZZ (using | as delimiter to avoid conflicts with IDs containing colons)
        let components = markerContent.split(separator: "|")
        var sourceId: String?
        var eventId: String?
        
        for component in components {
            if component.hasPrefix("source=") {
                sourceId = String(component.dropFirst(7))
            } else if component.hasPrefix("id=") {
                eventId = String(component.dropFirst(3))
            }
        }
        
        if let sourceId = sourceId, let eventId = eventId {
            return generateBlockId(sourceCalendarId: sourceId, sourceEventId: eventId)
        }
        return nil
    }
    
    private func createBlock(in calendar: EKCalendar, for syncable: SyncableEvent, sourceCalendarId: String, accountName: String) {
        let block = EKEvent(eventStore: eventStore)
        let sourceEvent = syncable.event
        
        // Set title based on format preference
        let titleFormat = settings.blockTitleFormat
        block.title = titleFormat.replacingOccurrences(of: "{source_name}", with: accountName)
        
        block.startDate = sourceEvent.startDate
        block.endDate = sourceEvent.endDate
        block.isAllDay = sourceEvent.isAllDay
        block.calendar = calendar
        
        // For recurring events, copy the recurrence rules if setting is enabled
        if syncable.isRecurring && settings.syncRecurringAsSeries {
            block.recurrenceRules = syncable.recurrenceRules
        }
        
        // Add marker in notes for identification (use seriesId for recurring events)
        // Using | as delimiter to avoid conflicts with IDs that may contain colons
        let marker = "\(Self.blockMarkerPrefix)source=\(sourceCalendarId)|id=\(syncable.seriesId)|recurring=\(syncable.isRecurring)\(Self.blockMarkerSuffix)"
        block.notes = marker
        
        // Set as busy
        block.availability = .busy
        
        do {
            // For recurring events with series tracking, save future events too
            let span: EKSpan = (syncable.isRecurring && settings.syncRecurringAsSeries) ? .futureEvents : .thisEvent
            try eventStore.save(block, span: span)
            
            if syncable.isRecurring {
                Logger.shared.log("Created recurring block series for '\(accountName)'")
            }
        } catch {
            Logger.shared.log("Error creating block: \(error.localizedDescription)")
        }
    }
    
    private func getAccountName(for calendar: EKCalendar) -> String {
        // Try to get a friendly account name
        if let source = calendar.source {
            switch source.sourceType {
            case .birthdays:
                // Don't use source.title for birthday sources - use calendar title instead
                return calendar.title
            case .exchange, .calDAV:
                // For work accounts, use the account/source title
                return source.title
            default:
                return calendar.title
            }
        }
        return calendar.title
    }
    
    // MARK: - Purge All Blocks
    
    /// Removes ALL NoMas-created blocks from ALL calendars
    /// Use this to clean up after bugs or when you want to start fresh
    @MainActor
    func purgeAllBlocks() async -> Int {
        Logger.shared.log("Starting purge of all NoMas blocks...")
        
        var totalDeleted = 0
        
        // Get ALL calendars, not just enabled ones
        let allCalendars = eventStore.calendars(for: .event)
        
        // Search a wide date range (1 year back, 1 year forward)
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let endDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
        
        // Track deleted event identifiers to avoid trying to delete the same recurring series multiple times
        var deletedEventIds = Set<String>()
        
        for calendar in allCalendars {
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: [calendar]
            )
            
            let events = eventStore.events(matching: predicate)
            var calendarDeleteCount = 0
            
            for event in events {
                // Skip if we already deleted this event (or its series)
                if let eventId = event.eventIdentifier, deletedEventIds.contains(eventId) {
                    continue
                }
                // Also check the external identifier for recurring events
                if let externalId = event.calendarItemExternalIdentifier, deletedEventIds.contains(externalId) {
                    continue
                }
                
                if isBlockEvent(event) {
                    do {
                        // Use .futureEvents for recurring blocks to delete the entire series
                        let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
                        try eventStore.remove(event, span: span)
                        calendarDeleteCount += 1
                        
                        // Track both identifiers to avoid duplicate deletion attempts
                        if let eventId = event.eventIdentifier {
                            deletedEventIds.insert(eventId)
                        }
                        if let externalId = event.calendarItemExternalIdentifier {
                            deletedEventIds.insert(externalId)
                        }
                    } catch {
                        Logger.shared.log("Error deleting block: \(error.localizedDescription)")
                    }
                }
            }
            
            if calendarDeleteCount > 0 {
                Logger.shared.log("Purged \(calendarDeleteCount) blocks from '\(calendar.title)'")
                totalDeleted += calendarDeleteCount
            }
        }
        
        Logger.shared.log("Purge complete: \(totalDeleted) blocks deleted")
        return totalDeleted
    }
    
    // MARK: - Event Fetching for Agenda View
    
    /// Fetches events for a specific day within the given hour range
    /// Returns events from ENABLED calendars only for display in the agenda view
    func fetchEvents(for date: Date, startHour: Int, endHour: Int) -> [EKEvent] {
        let calendar = Calendar.current
        
        // Get start of the day
        let startOfDay = calendar.startOfDay(for: date)
        
        // Handle 24-hour case (endHour of 24 means end of day)
        let actualEndHour = endHour == 24 ? 23 : endHour
        let endMinute = endHour == 24 ? 59 : 0
        
        // Set start time to startHour
        guard let dayStart = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: startOfDay),
              let dayEnd = calendar.date(bySettingHour: actualEndHour, minute: endMinute, second: 59, of: startOfDay) else {
            return []
        }
        
        // Get ENABLED calendars only for display
        let enabledCalendars = calendars.filter { enabledCalendarIds.contains($0.calendarIdentifier) }
        
        // If no calendars are enabled, return empty
        guard !enabledCalendars.isEmpty else {
            return []
        }
        
        let predicate = eventStore.predicateForEvents(
            withStart: dayStart,
            end: dayEnd,
            calendars: enabledCalendars
        )
        
        var events = eventStore.events(matching: predicate)
        
        // Filter out:
        // 1. NoMas-created blocks (we only show real events)
        // 2. Canceled events
        events = events.filter { event in
            // Skip NoMas blocks
            if isBlockEvent(event) {
                return false
            }
            // Skip canceled events
            if event.status == .canceled {
                return false
            }
            return true
        }
        
        // Also include events that overlap with this time range but start earlier
        // or end later (they should still be visible)
        let extendedStart = calendar.date(byAdding: .hour, value: -12, to: dayStart)!
        let extendedEnd = calendar.date(byAdding: .hour, value: 12, to: dayEnd)!
        
        let extendedPredicate = eventStore.predicateForEvents(
            withStart: extendedStart,
            end: extendedEnd,
            calendars: enabledCalendars
        )
        
        let extendedEvents = eventStore.events(matching: extendedPredicate)
        
        // Add events that overlap with our time range but weren't in the original query
        for event in extendedEvents {
            // Skip if already included
            if events.contains(where: { $0.eventIdentifier == event.eventIdentifier }) {
                continue
            }
            // Skip NoMas blocks
            if isBlockEvent(event) {
                continue
            }
            // Skip canceled events
            if event.status == .canceled {
                continue
            }
            // Check if event overlaps with our display range
            if event.startDate < dayEnd && event.endDate > dayStart {
                events.append(event)
            }
        }
        
        // Sort by start time
        events.sort { $0.startDate < $1.startDate }
        
        return events
    }
    
    // MARK: - Meeting Time Calculation
    
    /// Calculates total meeting time for a specific date (union of all event times, no double-counting overlaps)
    func calculateMeetingTime(for date: Date) -> TimeInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }
        
        return calculateMeetingTime(from: startOfDay, to: endOfDay)
    }
    
    /// Calculates total meeting time for the current week (Monday to today, union calculation)
    func calculateMeetingTimeThisWeek() -> TimeInterval {
        let calendar = Calendar.current
        let today = Date()
        
        // Find Monday of current week (ISO 8601: Monday = 2)
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        components.weekday = 2 // Monday
        
        guard let mondayOfWeek = calendar.date(from: components) else {
            return 0
        }
        
        // Calculate from Monday 00:00 to end of today
        let startOfMonday = calendar.startOfDay(for: mondayOfWeek)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) else {
            return 0
        }
        
        return calculateMeetingTime(from: startOfMonday, to: endOfToday)
    }
    
    /// Calculates total meeting time for a date range (union of all event times)
    private func calculateMeetingTime(from startDate: Date, to endDate: Date) -> TimeInterval {
        // Get enabled calendars only
        let enabledCalendars = calendars.filter { enabledCalendarIds.contains($0.calendarIdentifier) }
        
        guard !enabledCalendars.isEmpty else {
            return 0
        }
        
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: enabledCalendars
        )
        
        var events = eventStore.events(matching: predicate)
        
        // Filter out NoMas blocks and canceled events
        events = events.filter { event in
            // Skip NoMas blocks
            if isBlockEvent(event) {
                return false
            }
            // Skip canceled events
            if event.status == .canceled {
                return false
            }
            // Skip all-day events if setting is enabled
            if event.isAllDay && !settings.syncAllDayEvents {
                return false
            }
            return true
        }
        
        // Convert events to time intervals
        let intervals = events.map { event -> (start: Date, end: Date) in
            // Clamp event times to the date range
            let clampedStart = max(event.startDate, startDate)
            let clampedEnd = min(event.endDate, endDate)
            return (clampedStart, clampedEnd)
        }.filter { $0.start < $0.end } // Only valid intervals
        
        // Calculate union of intervals (no double-counting overlaps)
        return calculateUnionDuration(of: intervals)
    }
    
    /// Calculates the total duration of the union of time intervals
    /// This handles overlapping events by merging them
    private func calculateUnionDuration(of intervals: [(start: Date, end: Date)]) -> TimeInterval {
        guard !intervals.isEmpty else { return 0 }
        
        // Sort intervals by start time
        let sorted = intervals.sorted { $0.start < $1.start }
        
        // Merge overlapping intervals
        var merged: [(start: Date, end: Date)] = []
        var current = sorted[0]
        
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                // Overlapping or adjacent - extend current interval
                current.end = max(current.end, interval.end)
            } else {
                // No overlap - save current and start new
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        
        // Sum up durations
        return merged.reduce(0) { total, interval in
            total + interval.end.timeIntervalSince(interval.start)
        }
    }
    
    // MARK: - Notifications
    
    private func sendNotification(created: Int, updated: Int, deleted: Int) {
        guard settings.showNotifications else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "No Mas!"
        
        var changes: [String] = []
        if created > 0 { changes.append("\(created) created") }
        if updated > 0 { changes.append("\(updated) updated") }
        if deleted > 0 { changes.append("\(deleted) deleted") }
        
        content.body = "Sync complete: \(changes.joined(separator: ", "))"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
