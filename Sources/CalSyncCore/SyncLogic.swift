import Foundation

/// Core sync logic utilities that can be tested without EventKit dependencies
public struct SyncLogic {
    
    // MARK: - Sync Preconditions
    
    /// Check if sync should proceed based on number of enabled calendars
    /// - Parameter enabledCalendarCount: The number of enabled calendars
    /// - Returns: True if there are at least 2 calendars to sync between
    public static func shouldSyncForCalendarCount(_ enabledCalendarCount: Int) -> Bool {
        return enabledCalendarCount >= 2
    }
    
    /// Check if sync should be skipped due to cooldown period
    /// - Parameters:
    ///   - lastSyncTime: The time of the last completed sync
    ///   - cooldownSeconds: The minimum seconds between syncs
    /// - Returns: True if cooldown is still active and sync should be skipped
    public static func isCooldownActive(lastSyncTime: Date?, cooldownSeconds: TimeInterval) -> Bool {
        guard let lastSyncTime = lastSyncTime else { return false }
        let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
        return timeSinceLastSync < cooldownSeconds
    }
    
    // MARK: - Event Filtering
    
    /// Check if an all-day event should be synced based on settings
    /// - Parameters:
    ///   - isAllDay: Whether the event is an all-day event
    ///   - syncAllDayEvents: The user's setting for syncing all-day events
    /// - Returns: True if the event should be synced
    public static func shouldSyncEvent(isAllDay: Bool, syncAllDayEvents: Bool) -> Bool {
        return !isAllDay || syncAllDayEvents
    }
    
    /// Check if an event falls within the sync window
    /// - Parameters:
    ///   - eventDate: The date of the event
    ///   - windowStart: The start of the sync window
    ///   - windowEnd: The end of the sync window
    /// - Returns: True if the event is within the window
    public static func isEventInSyncWindow(eventDate: Date, windowStart: Date, windowEnd: Date) -> Bool {
        return eventDate >= windowStart && eventDate <= windowEnd
    }
    
    /// Calculate the sync window dates
    /// - Parameters:
    ///   - fromDate: The starting date (usually now)
    ///   - windowDays: The number of days to look ahead
    /// - Returns: A tuple of (start, end) dates
    public static func calculateSyncWindow(fromDate: Date, windowDays: Int) -> (start: Date, end: Date) {
        let start = fromDate
        let end = Calendar.current.date(byAdding: .day, value: windowDays, to: start)!
        return (start, end)
    }
    
    /// Calculate the purge window dates (1 year back and forward)
    /// - Parameter fromDate: The center date (usually now)
    /// - Returns: A tuple of (start, end) dates
    public static func calculatePurgeWindow(fromDate: Date) -> (start: Date, end: Date) {
        let start = Calendar.current.date(byAdding: .year, value: -1, to: fromDate)!
        let end = Calendar.current.date(byAdding: .year, value: 1, to: fromDate)!
        return (start, end)
    }
    
    // MARK: - Block Management
    
    /// Determine which calendars should receive blocks for an event
    /// - Parameters:
    ///   - sourceCalendarId: The ID of the calendar containing the source event
    ///   - allEnabledCalendarIds: All enabled calendar IDs
    /// - Returns: Array of calendar IDs that should receive blocks
    public static func targetCalendarsForEvent(
        sourceCalendarId: String,
        allEnabledCalendarIds: [String]
    ) -> [String] {
        return allEnabledCalendarIds.filter { $0 != sourceCalendarId }
    }
    
    /// Check if an existing block needs to be updated based on time changes
    /// - Parameters:
    ///   - blockStart: The block's current start time
    ///   - blockEnd: The block's current end time
    ///   - eventStart: The source event's start time
    ///   - eventEnd: The source event's end time
    /// - Returns: True if the block needs to be updated
    public static func blockNeedsUpdate(
        blockStart: Date,
        blockEnd: Date,
        eventStart: Date,
        eventEnd: Date
    ) -> Bool {
        return blockStart != eventStart || blockEnd != eventEnd
    }
    
    /// Check if a block is orphaned (its source event no longer exists)
    /// - Parameters:
    ///   - blockId: The ID of the block to check
    ///   - expectedBlockIds: Set of block IDs for current events
    /// - Returns: True if the block is orphaned and should be deleted
    public static func isBlockOrphaned(blockId: String, expectedBlockIds: Set<String>) -> Bool {
        return !expectedBlockIds.contains(blockId)
    }
    
    // MARK: - Calendar Selection
    
    /// Filter enabled calendar IDs to only include those that still exist
    /// - Parameters:
    ///   - enabledIds: The currently enabled calendar IDs
    ///   - validIds: The set of valid (existing) calendar IDs
    /// - Returns: The intersection of enabled and valid IDs
    public static func filterValidCalendarIds(
        enabledIds: Set<String>,
        validIds: Set<String>
    ) -> Set<String> {
        return enabledIds.intersection(validIds)
    }
    
    /// Toggle a calendar ID in an enabled set
    /// - Parameters:
    ///   - calendarId: The calendar ID to toggle
    ///   - enabledIds: The current set of enabled IDs (modified in place)
    /// - Returns: The new state (true if enabled, false if disabled)
    @discardableResult
    public static func toggleCalendar(
        _ calendarId: String,
        in enabledIds: inout Set<String>
    ) -> Bool {
        if enabledIds.contains(calendarId) {
            enabledIds.remove(calendarId)
            return false
        } else {
            enabledIds.insert(calendarId)
            return true
        }
    }
    
    // MARK: - Block Title Formatting
    
    /// Format a block title by replacing the {source_name} placeholder
    /// - Parameters:
    ///   - format: The title format string
    ///   - sourceName: The name of the source calendar/account
    /// - Returns: The formatted title
    public static func formatBlockTitle(format: String, sourceName: String) -> String {
        return format.replacingOccurrences(of: "{source_name}", with: sourceName)
    }
    
    // MARK: - Recurring Event Handling
    
    /// Determines the series ID for an event
    /// - Parameters:
    ///   - isRecurring: Whether the event is recurring
    ///   - externalId: The calendarItemExternalIdentifier (stable across occurrences)
    ///   - eventId: The eventIdentifier (unique per occurrence)
    ///   - useSeriesTracking: Whether to use series tracking
    /// - Returns: The appropriate ID to use for tracking
    public static func getSeriesId(
        isRecurring: Bool,
        externalId: String?,
        eventId: String?,
        useSeriesTracking: Bool
    ) -> String {
        if useSeriesTracking && isRecurring, let externalId = externalId {
            return externalId
        }
        return eventId ?? UUID().uuidString
    }
    
    /// Checks if a recurring event occurrence has already been seen
    /// - Parameters:
    ///   - seriesId: The series ID of the event
    ///   - seenSeriesIds: Set of already seen series IDs
    /// - Returns: True if this is a duplicate occurrence
    public static func isDuplicateOccurrence(
        seriesId: String,
        seenSeriesIds: Set<String>
    ) -> Bool {
        return seenSeriesIds.contains(seriesId)
    }
    
    /// Determines the appropriate save span for an event
    /// - Parameters:
    ///   - isRecurring: Whether the event is recurring
    ///   - syncRecurringAsSeries: Whether recurring events should sync as series
    /// - Returns: "futureEvents" for recurring series, "thisEvent" otherwise
    public static func getSaveSpan(
        isRecurring: Bool,
        syncRecurringAsSeries: Bool
    ) -> String {
        return (isRecurring && syncRecurringAsSeries) ? "futureEvents" : "thisEvent"
    }
}

// MARK: - PendingSyncChanges

/// Represents pending sync changes before they are committed
public struct PendingSyncChanges: Equatable {
    public var toCreate: Int
    public var toUpdate: Int
    public var toDelete: Int
    
    public init(toCreate: Int = 0, toUpdate: Int = 0, toDelete: Int = 0) {
        self.toCreate = toCreate
        self.toUpdate = toUpdate
        self.toDelete = toDelete
    }
    
    public var total: Int { toCreate + toUpdate + toDelete }
    public var isEmpty: Bool { total == 0 }
    
    public var description: String {
        var parts: [String] = []
        if toCreate > 0 { parts.append("\(toCreate) to create") }
        if toUpdate > 0 { parts.append("\(toUpdate) to update") }
        if toDelete > 0 { parts.append("\(toDelete) to delete") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}
