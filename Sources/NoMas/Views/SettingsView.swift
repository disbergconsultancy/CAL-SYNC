import SwiftUI
import LaunchAtLogin

struct SettingsView: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @ObservedObject private var settings = Settings.shared
    
    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            CalendarsSettingsView(syncEngine: syncEngine)
                .tabItem {
                    Label("Calendars", systemImage: "calendar")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 350)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
        Form {
            Section {
                Picker("Sync interval:", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                
                Picker("Sync window:", selection: $settings.syncWindowDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                }
            } header: {
                Text("Sync Settings")
            }
            
            Section {
                TextField("Block title format:", text: $settings.blockTitleFormat)
                    .help("Use {source_name} for the source calendar name")
                
                Text("Preview: \(settings.blockTitleFormat.replacingOccurrences(of: "{source_name}", with: "Work Calendar"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Block Appearance")
            }
            
            Section {
                Toggle("Sync all-day events", isOn: $settings.syncAllDayEvents)
                Toggle("Sync recurring events as series", isOn: $settings.syncRecurringAsSeries)
                    .help("When enabled, recurring events create a single recurring block instead of individual blocks for each occurrence")
                Toggle("Show notifications", isOn: $settings.showNotifications)
                LaunchAtLogin.Toggle("Launch at login")
            } header: {
                Text("Behavior")
            }
            
            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Calendars Settings

struct CalendarsSettingsView: View {
    @ObservedObject var syncEngine: SyncEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select which calendars to sync:")
                .font(.headline)
            
            Text("Events from enabled calendars will be blocked on all other enabled calendars.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if syncEngine.calendars.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No calendars found")
                        .font(.headline)
                    Text("Make sure you have calendars added in the macOS Calendar app and have granted calendar access to No Mas!.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(syncEngine.calendars, id: \.calendarIdentifier) { calendar in
                        CalendarRowView(
                            calendar: calendar,
                            isEnabled: syncEngine.isCalendarEnabled(calendar.calendarIdentifier),
                            onToggle: {
                                syncEngine.toggleCalendar(calendar.calendarIdentifier)
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
            
            HStack {
                Button("Select All") {
                    for calendar in syncEngine.calendars {
                        if !syncEngine.isCalendarEnabled(calendar.calendarIdentifier) {
                            syncEngine.toggleCalendar(calendar.calendarIdentifier)
                        }
                    }
                }
                
                Button("Deselect All") {
                    for calendar in syncEngine.calendars {
                        if syncEngine.isCalendarEnabled(calendar.calendarIdentifier) {
                            syncEngine.toggleCalendar(calendar.calendarIdentifier)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct CalendarRowView: View {
    let calendar: EKCalendar
    let isEnabled: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Circle()
                .fill(Color(nsColor: calendar.color ?? .gray))
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading) {
                Text(calendar.title)
                    .font(.body)
                
                if let source = calendar.source {
                    Text(source.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("No Mas!")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version 1.0.0")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
                .frame(width: 200)
            
            Text("Sync busy time blocks across multiple calendars without sharing event details.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(width: 300)
            
            Spacer()
            
            VStack(spacing: 4) {
                Text("Made with ❤️ for calendar sanity")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("View on GitHub", destination: URL(string: "https://github.com")!)
                    .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import EventKit
