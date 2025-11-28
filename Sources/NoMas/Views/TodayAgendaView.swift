import SwiftUI
import EventKit

/// A compact timeline view showing availability for a given day
struct TodayAgendaView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var selectedDate: Date = Date()
    @State private var events: [EKEvent] = []
    @AppStorage("hideAllDayEvents") private var hideAllDayEvents: Bool = false
    
    // Timeline configuration - full day
    private let startHour: Int = 0
    private let endHour: Int = 24
    private let hourHeight: CGFloat = 40
    private let timelineWidth: CGFloat = 30
    
    private var totalHeight: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }
    
    // Filtered events (excluding all-day if toggle is on)
    private var filteredEvents: [EKEvent] {
        if hideAllDayEvents {
            return events.filter { !$0.isAllDay }
        }
        return events
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with date navigation
            dateNavigationHeader
            
            Divider()
            
            // Timeline
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    timelineView
                        .id("timeline")
                }
                .onAppear {
                    loadEvents()
                    // Scroll to current time if viewing today
                    if Calendar.current.isDateInToday(selectedDate) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo("nowIndicator", anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 240, height: 380)
        .onChange(of: selectedDate) { _ in
            loadEvents()
        }
    }
    
    // MARK: - Date Navigation Header
    
    private var dateNavigationHeader: some View {
        HStack(spacing: 6) {
            Button(action: previousDay) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(dateDisplayText)
                    .font(.system(size: 13, weight: .semibold))
                
                if !Calendar.current.isDateInToday(selectedDate) {
                    Text(formattedDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: nextDay) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            
            // Toggle all-day events visibility
            Button(action: { hideAllDayEvents.toggle() }) {
                Image(systemName: hideAllDayEvents ? "sun.max" : "sun.max.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(hideAllDayEvents ? .secondary : .orange)
            .help(hideAllDayEvents ? "Show all-day events" : "Hide all-day events")
            
            Button(action: goToToday) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("Go to today")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    // MARK: - Timeline View
    
    private var timelineView: some View {
        ZStack(alignment: .topLeading) {
            // Hour grid lines and labels
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { hour in
                    ZStack(alignment: .topLeading) {
                        // Hour line - positioned at top
                        HStack(spacing: 0) {
                            Spacer()
                                .frame(width: timelineWidth + 6)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                        }
                        
                        // Hour label - centered vertically on the line
                        Text(String(format: "%02d", hour))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.6))
                            .frame(width: timelineWidth, alignment: .trailing)
                            .offset(y: -6) // Center the label on the line
                    }
                    .frame(height: hourHeight)
                }
            }
            
            // Event blocks
            eventsOverlay
            
            // Now indicator (only for today)
            if Calendar.current.isDateInToday(selectedDate) {
                nowIndicator
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    // MARK: - Events Overlay
    
    private var eventsOverlay: some View {
        GeometryReader { geometry in
            let displayEvents = filteredEvents
            let eventColumns = calculateEventColumns(for: displayEvents)
            let availableWidth = geometry.size.width - timelineWidth - 8
            
            ForEach(Array(displayEvents.enumerated()), id: \.element.eventIdentifier) { index, event in
                if let column = eventColumns[index] {
                    eventBlock(for: event, column: column, totalColumns: column.total, availableWidth: availableWidth)
                }
            }
        }
    }
    
    private func eventBlock(for event: EKEvent, column: EventColumn, totalColumns: Int, availableWidth: CGFloat) -> some View {
        let yPosition = positionForTime(event.startDate)
        let height = max(heightForEvent(event), 8) // Minimum height
        let columnWidth = availableWidth / CGFloat(totalColumns)
        let xOffset = timelineWidth + 8 + (CGFloat(column.index) * columnWidth)
        
        let calendarColor = Color(nsColor: event.calendar.color ?? .gray)
        let isTentative = event.status == .tentative
        let displayLocation = normalizeLocation(event.location)
        
        // Build tooltip text
        var tooltipParts: [String] = []
        if let title = event.title, !title.isEmpty {
            tooltipParts.append(title)
        }
        if let location = displayLocation {
            tooltipParts.append("📍 \(location)")
        }
        let tooltip = tooltipParts.joined(separator: "\n")
        
        return ZStack {
            if isTentative {
                // Striped pattern for tentative events
                TentativeEventBlock(color: calendarColor)
            } else {
                // Solid block for accepted events
                RoundedRectangle(cornerRadius: 3)
                    .fill(calendarColor.opacity(0.85))
            }
            
            // Text overlay (only if there's enough space)
            if height >= 16 {
                eventTextOverlay(title: event.title, location: displayLocation, height: height, width: columnWidth - 4)
            }
        }
        .frame(width: columnWidth - 2, height: height)
        .position(x: xOffset + columnWidth / 2, y: yPosition + height / 2)
        .help(tooltip)
    }
    
    @ViewBuilder
    private func eventTextOverlay(title: String?, location: String?, height: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Title
            if let title = title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(height >= 32 ? 2 : 1)
                    .truncationMode(.tail)
            }
            
            // Location (only if enough height and location exists)
            if height >= 32, let location = location {
                Text(location)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .frame(maxWidth: width, maxHeight: height, alignment: .topLeading)
    }
    
    /// Normalizes location strings, converting virtual meeting URLs/names to "Online"
    private func normalizeLocation(_ location: String?) -> String? {
        guard let location = location, !location.isEmpty else {
            return nil
        }
        
        let lowercased = location.lowercased()
        
        // Check for virtual meeting patterns
        let onlinePatterns = [
            "microsoft teams",
            "teams meeting",
            "teams.microsoft.com",
            "zoom",
            "zoom.us",
            "google meet",
            "meet.google.com",
            "webex",
            "webex.com",
            "skype",
            "gotomeeting",
            "goto.com",
            "bluejeans",
            "whereby",
            "discord",
            "slack huddle"
        ]
        
        for pattern in onlinePatterns {
            if lowercased.contains(pattern) {
                return "Online"
            }
        }
        
        // Check for URL patterns (likely meeting links)
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return "Online"
        }
        
        // Return original location (truncated if very long)
        if location.count > 25 {
            return String(location.prefix(22)) + "..."
        }
        
        return location
    }
    
    // MARK: - Now Indicator
    
    private var nowIndicator: some View {
        let yPosition = positionForTime(Date())
        
        return HStack(spacing: 4) {
            // Time label (no background, just red text)
            Text(currentTimeString)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.red)
                .frame(width: timelineWidth, alignment: .trailing)
            
            // Small red dot at line start
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            
            // Line - thicker for visibility
            Rectangle()
                .fill(Color.red)
                .frame(height: 2)
        }
        .offset(y: yPosition - 4)
        .id("nowIndicator")
    }
    
    // MARK: - Helper Methods
    
    private var dateDisplayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return "Today"
        } else if calendar.isDateInYesterday(selectedDate) {
            return "Yesterday"
        } else if calendar.isDateInTomorrow(selectedDate) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: selectedDate)
        }
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: selectedDate)
    }
    
    private var currentTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
    
    private func positionForTime(_ date: Date) -> CGFloat {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        
        let hourOffset = CGFloat(hour - startHour)
        let minuteOffset = CGFloat(minute) / 60.0
        
        return (hourOffset + minuteOffset) * hourHeight
    }
    
    private func heightForEvent(_ event: EKEvent) -> CGFloat {
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let hours = duration / 3600
        return CGFloat(hours) * hourHeight
    }
    
    private func previousDay() {
        selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    }
    
    private func nextDay() {
        selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    }
    
    private func goToToday() {
        selectedDate = Date()
    }
    
    private func loadEvents() {
        events = syncEngine.fetchEvents(for: selectedDate, startHour: startHour, endHour: endHour)
    }
    
    // MARK: - Event Column Calculation
    
    struct EventColumn {
        let index: Int
        let total: Int
    }
    
    private func calculateEventColumns(for eventList: [EKEvent]) -> [Int: EventColumn] {
        var columns: [Int: EventColumn] = [:]
        var groups: [[Int]] = []
        
        // Sort events by start time, then by duration (longer first)
        let sortedIndices = eventList.indices.sorted { i, j in
            let a = eventList[i]
            let b = eventList[j]
            if a.startDate == b.startDate {
                let durationA = a.endDate.timeIntervalSince(a.startDate)
                let durationB = b.endDate.timeIntervalSince(b.startDate)
                return durationA > durationB
            }
            return a.startDate < b.startDate
        }
        
        for eventIndex in sortedIndices {
            let event = eventList[eventIndex]
            var placed = false
            
            // Try to add to an existing group
            for groupIndex in groups.indices {
                let group = groups[groupIndex]
                var overlapsWithGroup = false
                
                for existingIndex in group {
                    let existing = eventList[existingIndex]
                    if eventsOverlap(event, existing) {
                        overlapsWithGroup = true
                        break
                    }
                }
                
                if overlapsWithGroup {
                    // Find a column within this group
                    var columnIndex = 0
                    for existingIndex in group {
                        let existing = eventList[existingIndex]
                        if eventsOverlap(event, existing) {
                            columnIndex += 1
                        }
                    }
                    groups[groupIndex].append(eventIndex)
                    columns[eventIndex] = EventColumn(index: columnIndex, total: 0) // Total updated later
                    placed = true
                    break
                }
            }
            
            if !placed {
                // Start a new group
                groups.append([eventIndex])
                columns[eventIndex] = EventColumn(index: 0, total: 0)
            }
        }
        
        // Update total columns for each group
        for group in groups {
            let maxColumn = group.compactMap { columns[$0]?.index }.max() ?? 0
            let totalColumns = maxColumn + 1
            for eventIndex in group {
                if let col = columns[eventIndex] {
                    columns[eventIndex] = EventColumn(index: col.index, total: totalColumns)
                }
            }
        }
        
        return columns
    }
    
    private func eventsOverlap(_ a: EKEvent, _ b: EKEvent) -> Bool {
        return a.startDate < b.endDate && b.startDate < a.endDate
    }
}

// MARK: - Tentative Event Block with Stripes

struct TentativeEventBlock: View {
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.3))
                
                // Diagonal stripes
                Canvas { context, size in
                    let stripeWidth: CGFloat = 4
                    let spacing: CGFloat = 6
                    
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height + stripeWidth, y: 0))
                        path.addLine(to: CGPoint(x: x + stripeWidth, y: size.height))
                        path.closeSubpath()
                        
                        context.fill(path, with: .color(color.opacity(0.5)))
                        x += spacing + stripeWidth
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}
