import Foundation
import CalSyncCore

// MARK: - Simple Test Framework

/// Simple test result tracking
var testsPassed = 0
var testsFailed = 0
var currentTestName = ""

func test(_ name: String, _ block: () -> Void) {
    currentTestName = name
    block()
}

func expect(_ condition: Bool, _ message: String = "") {
    if condition {
        testsPassed += 1
        print("  ✅ \(currentTestName)")
    } else {
        testsFailed += 1
        print("  ❌ \(currentTestName): \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    if actual == expected {
        testsPassed += 1
        print("  ✅ \(currentTestName)")
    } else {
        testsFailed += 1
        print("  ❌ \(currentTestName): Expected '\(expected)' but got '\(actual)'. \(message)")
    }
}

func expectNil<T>(_ value: T?, _ message: String = "") {
    if value == nil {
        testsPassed += 1
        print("  ✅ \(currentTestName)")
    } else {
        testsFailed += 1
        print("  ❌ \(currentTestName): Expected nil but got '\(value!)'. \(message)")
    }
}

func expectNotNil<T>(_ value: T?, _ message: String = "") {
    if value != nil {
        testsPassed += 1
        print("  ✅ \(currentTestName)")
    } else {
        testsFailed += 1
        print("  ❌ \(currentTestName): Expected non-nil value. \(message)")
    }
}

// MARK: - Block Marker Tests

func runBlockMarkerTests() {
    print("\n📋 Block Marker Tests")
    print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))
    
    // LOOP-001: Valid marker detection
    test("LOOP-001: Valid marker is recognized") {
        let notes = "<!-- CALSYNC:BLOCK:source=calendar123:id=event456 -->"
        expect(BlockMarker.containsMarker(notes) == true)
    }
    
    test("LOOP-001: Marker among other content") {
        let notes = "Notes\n<!-- CALSYNC:BLOCK:source=cal1:id=evt1 -->\nMore"
        expect(BlockMarker.containsMarker(notes) == true)
    }
    
    test("LOOP-001: Notes without marker") {
        let notes = "Team standup meeting"
        expect(BlockMarker.containsMarker(notes) == false)
    }
    
    test("LOOP-001: Nil notes") {
        let notes: String? = nil
        expect(BlockMarker.containsMarker(notes) == false)
    }
    
    test("LOOP-001: Empty notes") {
        expect(BlockMarker.containsMarker("") == false)
    }
    
    // LOOP-002: Marker parsing
    test("LOOP-002: Parse valid marker") {
        let notes = "<!-- CALSYNC:BLOCK:source=calendar-abc:id=event-xyz -->"
        expectEqual(BlockMarker.parseBlockId(from: notes), "calendar-abc:event-xyz")
    }
    
    test("LOOP-002: Parse reversed order") {
        let notes = "<!-- CALSYNC:BLOCK:id=event123:source=calendar456 -->"
        expectEqual(BlockMarker.parseBlockId(from: notes), "calendar456:event123")
    }
    
    test("LOOP-002: Generate block ID consistency") {
        let id = BlockMarker.generateBlockId(sourceCalendarId: "cal-123", sourceEventId: "evt-456")
        expectEqual(id, "cal-123:evt-456")
    }
    
    test("LOOP-002: Round-trip through marker") {
        let blockId = BlockMarker.generateBlockId(sourceCalendarId: "my-cal", sourceEventId: "my-evt")
        let marker = BlockMarker.createMarker(sourceCalendarId: "my-cal", sourceEventId: "my-evt")
        let parsed = BlockMarker.parseBlockId(from: marker)
        expectEqual(parsed, blockId)
    }
    
    // LOOP-003: Corrupted markers
    test("LOOP-003: Partial marker - missing prefix") {
        let notes = "source=calendar123:id=event456 -->"
        expect(BlockMarker.containsMarker(notes) == false)
    }
    
    test("LOOP-003: Partial marker - missing suffix") {
        let notes = "<!-- CALSYNC:BLOCK:source=calendar123:id=event456"
        // Contains prefix but parsing should fail
        expect(BlockMarker.containsMarker(notes) == true)
        expectNil(BlockMarker.parseBlockId(from: notes))
    }
    
    test("LOOP-003: Missing source") {
        let notes = "<!-- CALSYNC:BLOCK:id=event456 -->"
        expectNil(BlockMarker.parseBlockId(from: notes))
    }
    
    test("LOOP-003: Missing id") {
        let notes = "<!-- CALSYNC:BLOCK:source=calendar123 -->"
        expectNil(BlockMarker.parseBlockId(from: notes))
    }
    
    test("LOOP-003: Non-CalSync marker") {
        let notes = "<!-- SOME:OTHER:MARKER -->"
        expectNil(BlockMarker.parseBlockId(from: notes))
    }
    
    // Marker creation
    test("Marker creation contains all parts") {
        let marker = BlockMarker.createMarker(sourceCalendarId: "test-cal", sourceEventId: "test-evt")
        expect(marker.contains(BlockMarker.prefix))
        expect(marker.contains(BlockMarker.suffix))
        expect(marker.contains("source=test-cal"))
        expect(marker.contains("id=test-evt"))
    }
}

// MARK: - Sync Logic Tests

func runSyncLogicTests() {
    print("\n📋 Sync Logic Tests")
    print("=".padding(toLength: 50, withPad: "=", startingAt: 0))
    
    // Calendar count preconditions
    test("SYNC-001: Zero calendars - skip") {
        expect(SyncLogic.shouldSyncForCalendarCount(0) == false)
    }
    
    test("SYNC-002: One calendar - skip") {
        expect(SyncLogic.shouldSyncForCalendarCount(1) == false)
    }
    
    test("SYNC-003: Two calendars - proceed") {
        expect(SyncLogic.shouldSyncForCalendarCount(2) == true)
    }
    
    test("SYNC-003: Three calendars - proceed") {
        expect(SyncLogic.shouldSyncForCalendarCount(3) == true)
    }
    
    // Cooldown
    test("SYNC-008: Cooldown active") {
        let lastSync = Date().addingTimeInterval(-5)
        expect(SyncLogic.isCooldownActive(lastSyncTime: lastSync, cooldownSeconds: 10) == true)
    }
    
    test("SYNC-008: Cooldown expired") {
        let lastSync = Date().addingTimeInterval(-15)
        expect(SyncLogic.isCooldownActive(lastSyncTime: lastSync, cooldownSeconds: 10) == false)
    }
    
    test("SYNC-008: No previous sync (nil)") {
        expect(SyncLogic.isCooldownActive(lastSyncTime: nil, cooldownSeconds: 10) == false)
    }
    
    // All-day events
    test("EVT-002: All-day event - sync disabled") {
        expect(SyncLogic.shouldSyncEvent(isAllDay: true, syncAllDayEvents: false) == false)
    }
    
    test("EVT-003: All-day event - sync enabled") {
        expect(SyncLogic.shouldSyncEvent(isAllDay: true, syncAllDayEvents: true) == true)
    }
    
    test("Regular event - always synced") {
        expect(SyncLogic.shouldSyncEvent(isAllDay: false, syncAllDayEvents: false) == true)
        expect(SyncLogic.shouldSyncEvent(isAllDay: false, syncAllDayEvents: true) == true)
    }
    
    // Sync window
    test("Sync window - event within") {
        let now = Date()
        let window = SyncLogic.calculateSyncWindow(fromDate: now, windowDays: 14)
        let eventDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        expect(SyncLogic.isEventInSyncWindow(eventDate: eventDate, windowStart: window.start, windowEnd: window.end) == true)
    }
    
    test("Sync window - event outside") {
        let now = Date()
        let window = SyncLogic.calculateSyncWindow(fromDate: now, windowDays: 14)
        let eventDate = Calendar.current.date(byAdding: .day, value: 20, to: now)!
        expect(SyncLogic.isEventInSyncWindow(eventDate: eventDate, windowStart: window.start, windowEnd: window.end) == false)
    }
    
    // Bidirectional sync
    test("SYNC-004: Event in A creates block in B") {
        let targets = SyncLogic.targetCalendarsForEvent(sourceCalendarId: "cal-A", allEnabledCalendarIds: ["cal-A", "cal-B"])
        expectEqual(targets.count, 1)
        expectEqual(targets.first, "cal-B")
    }
    
    test("SYNC-004: Three calendars - blocks in both others") {
        let targets = SyncLogic.targetCalendarsForEvent(sourceCalendarId: "cal-A", allEnabledCalendarIds: ["cal-A", "cal-B", "cal-C"])
        expectEqual(targets.count, 2)
        expect(targets.contains("cal-B"))
        expect(targets.contains("cal-C"))
        expect(!targets.contains("cal-A"))
    }
    
    // Orphan detection
    test("UPD-002: Not orphan when source exists") {
        let expected = Set(["cal-A:evt-1", "cal-A:evt-2"])
        expect(SyncLogic.isBlockOrphaned(blockId: "cal-A:evt-1", expectedBlockIds: expected) == false)
    }
    
    test("UPD-002: Orphan when source deleted") {
        let expected = Set(["cal-A:evt-1", "cal-A:evt-2"])
        expect(SyncLogic.isBlockOrphaned(blockId: "cal-A:evt-deleted", expectedBlockIds: expected) == true)
    }
    
    // Block update detection
    test("UPD-001: No update when times match") {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        expect(SyncLogic.blockNeedsUpdate(blockStart: start, blockEnd: end, eventStart: start, eventEnd: end) == false)
    }
    
    test("UPD-001: Update when start changed") {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let newStart = start.addingTimeInterval(1800)
        expect(SyncLogic.blockNeedsUpdate(blockStart: start, blockEnd: end, eventStart: newStart, eventEnd: end) == true)
    }
    
    test("UPD-001: Update when end changed") {
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let newEnd = start.addingTimeInterval(7200)
        expect(SyncLogic.blockNeedsUpdate(blockStart: start, blockEnd: end, eventStart: start, eventEnd: newEnd) == true)
    }
    
    // Calendar filtering
    test("SEL-005: Filter deleted calendars") {
        let enabled = Set(["cal-exists", "cal-deleted", "cal-also-exists"])
        let valid = Set(["cal-exists", "cal-also-exists", "cal-new"])
        let filtered = SyncLogic.filterValidCalendarIds(enabledIds: enabled, validIds: valid)
        expect(filtered.contains("cal-exists"))
        expect(filtered.contains("cal-also-exists"))
        expect(!filtered.contains("cal-deleted"))
        expect(!filtered.contains("cal-new"))
    }
    
    // Toggle calendar
    test("Toggle calendar - enable") {
        var enabled = Set<String>()
        let newState = SyncLogic.toggleCalendar("cal-1", in: &enabled)
        expect(newState == true)
        expect(enabled.contains("cal-1"))
    }
    
    test("Toggle calendar - disable") {
        var enabled = Set(["cal-1"])
        let newState = SyncLogic.toggleCalendar("cal-1", in: &enabled)
        expect(newState == false)
        expect(!enabled.contains("cal-1"))
    }
    
    // Block title format
    test("SYNC-006: Placeholder replacement") {
        let result = SyncLogic.formatBlockTitle(format: "Busy - {source_name}", sourceName: "Work")
        expectEqual(result, "Busy - Work")
    }
    
    test("SYNC-006: No placeholder") {
        let result = SyncLogic.formatBlockTitle(format: "Blocked", sourceName: "Work")
        expectEqual(result, "Blocked")
    }
    
    // Purge window
    test("PURGE-003: Purge window spans ~2 years") {
        let now = Date()
        let window = SyncLogic.calculatePurgeWindow(fromDate: now)
        let days = Calendar.current.dateComponents([.day], from: window.start, to: window.end).day ?? 0
        expect(days > 729)
    }
    
    // Edge case - overlapping events
    test("EDGE-009: Overlapping events get unique IDs") {
        let id1 = BlockMarker.generateBlockId(sourceCalendarId: "cal-A", sourceEventId: "evt-1")
        let id2 = BlockMarker.generateBlockId(sourceCalendarId: "cal-A", sourceEventId: "evt-2")
        expect(id1 != id2)
    }
}

// MARK: - Pending Sync Changes Tests

func runPendingSyncChangesTests() {
    print("\n📋 Pending Sync Changes Tests")
    print("=".padding(toLength: 50, withPad: "=", startingAt: 0))
    
    // Total calculation
    test("PEND-001: Total is sum of all changes") {
        let changes = PendingSyncChanges(toCreate: 5, toUpdate: 3, toDelete: 2)
        expectEqual(changes.total, 10)
    }
    
    test("PEND-001: Total is zero for empty changes") {
        let changes = PendingSyncChanges()
        expectEqual(changes.total, 0)
    }
    
    // isEmpty property
    test("PEND-002: isEmpty true when all zero") {
        let changes = PendingSyncChanges(toCreate: 0, toUpdate: 0, toDelete: 0)
        expect(changes.isEmpty == true)
    }
    
    test("PEND-002: isEmpty false with creates") {
        let changes = PendingSyncChanges(toCreate: 1, toUpdate: 0, toDelete: 0)
        expect(changes.isEmpty == false)
    }
    
    test("PEND-002: isEmpty false with updates") {
        let changes = PendingSyncChanges(toCreate: 0, toUpdate: 1, toDelete: 0)
        expect(changes.isEmpty == false)
    }
    
    test("PEND-002: isEmpty false with deletes") {
        let changes = PendingSyncChanges(toCreate: 0, toUpdate: 0, toDelete: 1)
        expect(changes.isEmpty == false)
    }
    
    // Description formatting
    test("PEND-003: Description for empty changes") {
        let changes = PendingSyncChanges()
        expectEqual(changes.description, "No changes")
    }
    
    test("PEND-003: Description with only creates") {
        let changes = PendingSyncChanges(toCreate: 3, toUpdate: 0, toDelete: 0)
        expectEqual(changes.description, "3 to create")
    }
    
    test("PEND-003: Description with only updates") {
        let changes = PendingSyncChanges(toCreate: 0, toUpdate: 2, toDelete: 0)
        expectEqual(changes.description, "2 to update")
    }
    
    test("PEND-003: Description with only deletes") {
        let changes = PendingSyncChanges(toCreate: 0, toUpdate: 0, toDelete: 5)
        expectEqual(changes.description, "5 to delete")
    }
    
    test("PEND-003: Description with all types") {
        let changes = PendingSyncChanges(toCreate: 2, toUpdate: 3, toDelete: 1)
        expectEqual(changes.description, "2 to create, 3 to update, 1 to delete")
    }
    
    // Equatable
    test("PEND-004: Equal changes are equal") {
        let changes1 = PendingSyncChanges(toCreate: 1, toUpdate: 2, toDelete: 3)
        let changes2 = PendingSyncChanges(toCreate: 1, toUpdate: 2, toDelete: 3)
        expect(changes1 == changes2)
    }
    
    test("PEND-004: Different changes are not equal") {
        let changes1 = PendingSyncChanges(toCreate: 1, toUpdate: 2, toDelete: 3)
        let changes2 = PendingSyncChanges(toCreate: 1, toUpdate: 2, toDelete: 4)
        expect(changes1 != changes2)
    }
}

// MARK: - Recurring Event Handling Tests

func runRecurringEventTests() {
    print("\n📋 Recurring Event Handling Tests")
    print("=".padding(toLength: 50, withPad: "=", startingAt: 0))
    
    // Series ID generation
    test("REC-001: Recurring event uses externalId with series tracking") {
        let seriesId = SyncLogic.getSeriesId(
            isRecurring: true,
            externalId: "external-abc",
            eventId: "event-123",
            useSeriesTracking: true
        )
        expectEqual(seriesId, "external-abc")
    }
    
    test("REC-001: Recurring event uses eventId without series tracking") {
        let seriesId = SyncLogic.getSeriesId(
            isRecurring: true,
            externalId: "external-abc",
            eventId: "event-123",
            useSeriesTracking: false
        )
        expectEqual(seriesId, "event-123")
    }
    
    test("REC-001: Non-recurring event uses eventId") {
        let seriesId = SyncLogic.getSeriesId(
            isRecurring: false,
            externalId: "external-abc",
            eventId: "event-123",
            useSeriesTracking: true
        )
        expectEqual(seriesId, "event-123")
    }
    
    test("REC-001: Recurring without externalId uses eventId") {
        let seriesId = SyncLogic.getSeriesId(
            isRecurring: true,
            externalId: nil,
            eventId: "event-123",
            useSeriesTracking: true
        )
        expectEqual(seriesId, "event-123")
    }
    
    test("REC-001: No IDs generates UUID") {
        let seriesId = SyncLogic.getSeriesId(
            isRecurring: true,
            externalId: nil,
            eventId: nil,
            useSeriesTracking: true
        )
        // UUID should be 36 characters
        expect(seriesId.count == 36)
    }
    
    // Duplicate occurrence detection
    test("REC-002: First occurrence is not duplicate") {
        let seenIds = Set<String>()
        expect(SyncLogic.isDuplicateOccurrence(seriesId: "series-1", seenSeriesIds: seenIds) == false)
    }
    
    test("REC-002: Second occurrence is duplicate") {
        let seenIds = Set(["series-1", "series-2"])
        expect(SyncLogic.isDuplicateOccurrence(seriesId: "series-1", seenSeriesIds: seenIds) == true)
    }
    
    test("REC-002: Different series is not duplicate") {
        let seenIds = Set(["series-1"])
        expect(SyncLogic.isDuplicateOccurrence(seriesId: "series-2", seenSeriesIds: seenIds) == false)
    }
    
    // Save span determination
    test("REC-003: Recurring with series sync uses futureEvents") {
        let span = SyncLogic.getSaveSpan(isRecurring: true, syncRecurringAsSeries: true)
        expectEqual(span, "futureEvents")
    }
    
    test("REC-003: Recurring without series sync uses thisEvent") {
        let span = SyncLogic.getSaveSpan(isRecurring: true, syncRecurringAsSeries: false)
        expectEqual(span, "thisEvent")
    }
    
    test("REC-003: Non-recurring event uses thisEvent") {
        let span = SyncLogic.getSaveSpan(isRecurring: false, syncRecurringAsSeries: true)
        expectEqual(span, "thisEvent")
    }
    
    test("REC-003: Non-recurring without series sync uses thisEvent") {
        let span = SyncLogic.getSaveSpan(isRecurring: false, syncRecurringAsSeries: false)
        expectEqual(span, "thisEvent")
    }
}

// MARK: - Settings Tests

func runSettingsTests() {
    print("\n📋 Settings Tests")
    print("=".padding(toLength: 50, withPad: "=", startingAt: 0))
    
    let testSuiteName = "CalSyncTestSettings"
    guard let testDefaults = UserDefaults(suiteName: testSuiteName) else {
        print("  ❌ Could not create test UserDefaults")
        return
    }
    
    // Clean up before tests
    testDefaults.removePersistentDomain(forName: testSuiteName)
    
    // SET-001: Default values
    test("SET-001: Default sync interval") {
        testDefaults.register(defaults: ["syncIntervalMinutes": 5])
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 5)
    }
    
    test("SET-001: Default sync window") {
        testDefaults.register(defaults: ["syncWindowDays": 14])
        expectEqual(testDefaults.integer(forKey: "syncWindowDays"), 14)
    }
    
    test("SET-001: Default block title format") {
        testDefaults.register(defaults: ["blockTitleFormat": "Busy - {source_name}"])
        expectEqual(testDefaults.string(forKey: "blockTitleFormat"), "Busy - {source_name}")
    }
    
    test("SET-001: Default syncAllDayEvents") {
        testDefaults.register(defaults: ["syncAllDayEvents": false])
        expect(testDefaults.bool(forKey: "syncAllDayEvents") == false)
    }
    
    test("SET-001: Default showNotifications") {
        testDefaults.register(defaults: ["showNotifications": true])
        expect(testDefaults.bool(forKey: "showNotifications") == true)
    }
    
    // SET-002: Persistence
    test("SET-002: Sync interval persists") {
        testDefaults.set(10, forKey: "syncIntervalMinutes")
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 10)
    }
    
    test("SET-002: Value overrides default") {
        testDefaults.register(defaults: ["syncIntervalMinutes": 5])
        testDefaults.set(15, forKey: "syncIntervalMinutes")
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 15)
    }
    
    // SET-004: Block title format
    test("SET-004: Custom format persists") {
        testDefaults.set("[{source_name}] Blocked", forKey: "blockTitleFormat")
        expectEqual(testDefaults.string(forKey: "blockTitleFormat"), "[{source_name}] Blocked")
    }
    
    test("SET-004: Emoji characters preserved") {
        testDefaults.set("🚫 {source_name}", forKey: "blockTitleFormat")
        expectEqual(testDefaults.string(forKey: "blockTitleFormat"), "🚫 {source_name}")
    }
    
    // SET-007: Reset to defaults
    test("SET-007: Reset restores defaults") {
        // Set custom values
        testDefaults.set(30, forKey: "syncIntervalMinutes")
        testDefaults.set(true, forKey: "syncAllDayEvents")
        
        // Remove and re-register defaults
        testDefaults.removeObject(forKey: "syncIntervalMinutes")
        testDefaults.removeObject(forKey: "syncAllDayEvents")
        testDefaults.register(defaults: [
            "syncIntervalMinutes": 5,
            "syncAllDayEvents": false
        ])
        
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 5)
        expect(testDefaults.bool(forKey: "syncAllDayEvents") == false)
    }
    
    // Boundary tests
    test("Boundary: Minimum sync interval (1 min)") {
        testDefaults.set(1, forKey: "syncIntervalMinutes")
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 1)
    }
    
    test("Boundary: Maximum sync interval (30 min)") {
        testDefaults.set(30, forKey: "syncIntervalMinutes")
        expectEqual(testDefaults.integer(forKey: "syncIntervalMinutes"), 30)
    }
    
    // Clean up after tests
    testDefaults.removePersistentDomain(forName: testSuiteName)
}

// MARK: - Main Entry Point

@main
struct TestRunner {
    static func main() {
        print("🧪 CalSync Test Suite")
        print("=".padding(toLength: 50, withPad: "=", startingAt: 0))
        
        runBlockMarkerTests()
        runSyncLogicTests()
        runPendingSyncChangesTests()
        runRecurringEventTests()
        runSettingsTests()
        
        print("\n" + "=".padding(toLength: 50, withPad: "=", startingAt: 0))
        print("📊 Results: \(testsPassed) passed, \(testsFailed) failed")
        
        if testsFailed > 0 {
            print("❌ Some tests failed!")
            exit(1)
        } else {
            print("✅ All tests passed!")
            exit(0)
        }
    }
}
