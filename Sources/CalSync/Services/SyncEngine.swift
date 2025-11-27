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
            // Clear pending changes after sync
            pendingChanges = PendingSyncChanges()
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
        // Parse: source=XXX:id=YYY
        let components = markerContent.split(separator: ":")
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
        let marker = "\(Self.blockMarkerPrefix)source=\(sourceCalendarId):id=\(syncable.seriesId):recurring=\(syncable.isRecurring)\(Self.blockMarkerSuffix)"
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
            case .exchange:
                return source.title
            case .calDAV:
                return source.title
            default:
                return calendar.title
            }
        }
        return calendar.title
    }
    
    // MARK: - Purge All Blocks
    
    /// Removes ALL CalSync-created blocks from ALL calendars
    /// Use this to clean up after bugs or when you want to start fresh
    @MainActor
    func purgeAllBlocks() async -> Int {
        Logger.shared.log("Starting purge of all CalSync blocks...")
        
        var totalDeleted = 0
        
        // Get ALL calendars, not just enabled ones
        let allCalendars = eventStore.calendars(for: .event)
        
        // Search a wide date range (1 year back, 1 year forward)
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let endDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
        
        for calendar in allCalendars {
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: [calendar]
            )
            
            let events = eventStore.events(matching: predicate)
            var calendarDeleteCount = 0
            
            for event in events {
                if isBlockEvent(event) {
                    do {
                        try eventStore.remove(event, span: .thisEvent)
                        calendarDeleteCount += 1
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
    
    // MARK: - Notifications
    
    private func sendNotification(created: Int, updated: Int, deleted: Int) {
        guard settings.showNotifications else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "CalSync"
        
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
