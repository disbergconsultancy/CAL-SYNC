import SwiftUI
import AppKit
import EventKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var settingsWindow: NSWindow?
    let syncEngine = SyncEngine()
    private var pendingCheckTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - this is a menu bar only app
        NSApp.setActivationPolicy(.accessory)
        
        // Request calendar permissions
        requestCalendarAccess()
        
        // Request notification permissions
        requestNotificationPermissions()
        
        // Setup menu bar
        setupMenuBar()
        
        // Start sync timer
        syncEngine.startSyncTimer()
        
        // Start pending changes check timer
        startPendingCheckTimer()
        
        // Listen for calendar changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: syncEngine.eventStore
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        syncEngine.stopSyncTimer()
        pendingCheckTimer?.invalidate()
    }
    
    // MARK: - Pending Changes Timer
    
    private func startPendingCheckTimer() {
        pendingCheckTimer?.invalidate()
        // Check for pending changes every 30 seconds
        pendingCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task {
                await self?.syncEngine.calculatePendingChanges()
            }
        }
        // Also run immediately
        Task {
            await syncEngine.calculatePendingChanges()
        }
    }
    
    private func updateMenuBarBadge() {
        guard let button = statusItem?.button else { return }
        
        let pendingCount = syncEngine.pendingChanges.total
        
        if pendingCount > 0 {
            // Create badge image with count
            let badgeImage = createBadgedIcon(count: pendingCount)
            button.image = badgeImage
        } else {
            // Reset to normal icon
            button.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "CalSync")
        }
    }
    
    private func createBadgedIcon(count: Int) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // Draw base calendar icon
        if let baseIcon = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let configuredIcon = baseIcon.withSymbolConfiguration(config) {
                configuredIcon.draw(in: NSRect(x: 0, y: 2, width: 16, height: 16))
            }
        }
        
        // Draw badge circle
        let badgeSize: CGFloat = 12
        let badgeRect = NSRect(x: size.width - badgeSize, y: size.height - badgeSize, width: badgeSize, height: badgeSize)
        
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        
        // Draw count text
        let displayCount = count > 9 ? "9+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = displayCount.size(withAttributes: attributes)
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        displayCount.draw(in: textRect, withAttributes: attributes)
        
        image.unlockFocus()
        image.isTemplate = false
        
        return image
    }
    
    private func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            syncEngine.eventStore.requestFullAccessToEvents { [weak self] granted, error in
                self?.handleCalendarAccessResult(granted: granted, error: error)
            }
        } else {
            // Fallback for older macOS versions
            syncEngine.eventStore.requestAccess(to: .event) { [weak self] granted, error in
                self?.handleCalendarAccessResult(granted: granted, error: error)
            }
        }
    }
    
    private func handleCalendarAccessResult(granted: Bool, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if granted {
                print("✅ Calendar access granted")
                self?.syncEngine.loadCalendars()
                // Perform initial sync
                Task {
                    await self?.syncEngine.performSync()
                }
            } else {
                print("❌ Calendar access denied: \(error?.localizedDescription ?? "Unknown error")")
                self?.showCalendarAccessAlert()
            }
        }
    }
    
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            }
        }
    }
    
    private func showCalendarAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Calendar Access Required"
        alert.informativeText = "CalSync needs access to your calendars to sync busy blocks. Please grant access in System Settings > Privacy & Security > Calendars."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private var pendingSyncWorkItem: DispatchWorkItem?
    
    @objc private func calendarChanged() {
        // Don't trigger sync if sync is disabled
        guard syncEngine.isSyncEnabled else {
            Logger.shared.log("📅 Calendar changed but sync disabled, ignoring")
            return
        }
        
        // Don't trigger sync if we're already syncing (to prevent loops)
        guard !syncEngine.isSyncing else {
            Logger.shared.log("📅 Calendar changed but sync in progress, ignoring")
            return
        }
        
        Logger.shared.log("📅 Calendar changed, scheduling sync...")
        
        // Cancel any pending sync
        pendingSyncWorkItem?.cancel()
        
        // Debounce - wait before syncing to batch multiple changes
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Double check we're not syncing
            guard !self.syncEngine.isSyncing else { return }
            Task {
                await self.syncEngine.performSync()
            }
        }
        pendingSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "CalSync")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Create menu
        let menu = NSMenu()
        
        // Status header
        let statusItem = NSMenuItem(title: "CalSync", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Sync status
        let syncStatusItem = NSMenuItem(title: "Last sync: Never", action: nil, keyEquivalent: "")
        syncStatusItem.tag = 100 // Tag for updating later
        syncStatusItem.isEnabled = false
        menu.addItem(syncStatusItem)
        
        // Pending changes status
        let pendingStatusItem = NSMenuItem(title: "Pending: No changes", action: nil, keyEquivalent: "")
        pendingStatusItem.tag = 102 // Tag for updating later
        pendingStatusItem.isEnabled = false
        menu.addItem(pendingStatusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Sync toggle
        let syncToggle = NSMenuItem(title: "Sync Enabled", action: #selector(toggleSync), keyEquivalent: "")
        syncToggle.tag = 101
        syncToggle.state = .on
        syncToggle.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        menu.addItem(syncToggle)
        
        // Sync now
        let syncNowItem = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "s")
        syncNowItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(syncNowItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Calendars submenu
        let calendarsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        let calendarsSubmenu = NSMenu()
        calendarsItem.submenu = calendarsSubmenu
        calendarsItem.tag = 200
        calendarsItem.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        menu.addItem(calendarsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        
        // View logs
        let viewLogsItem = NSMenuItem(title: "View Logs...", action: #selector(viewLogs), keyEquivalent: "")
        viewLogsItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        menu.addItem(viewLogsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Purge all blocks
        let purgeItem = NSMenuItem(title: "Purge All Blocks...", action: #selector(purgeAllBlocks), keyEquivalent: "")
        purgeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(purgeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit CalSync", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
        
        self.statusItem?.menu = menu
        
        // Update menu when sync state changes
        syncEngine.$lastSyncTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] date in
                self?.updateSyncStatus()
            }
            .store(in: &cancellables)
        
        syncEngine.$calendars
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateCalendarsMenu()
            }
            .store(in: &cancellables)
        
        // Update pending changes display
        syncEngine.$pendingChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePendingStatus()
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private func updatePendingStatus() {
        // Update menu item
        if let menu = statusItem?.menu,
           let pendingStatusItem = menu.item(withTag: 102) {
            let changes = syncEngine.pendingChanges
            if changes.isEmpty {
                pendingStatusItem.title = "Pending: No changes"
            } else {
                pendingStatusItem.title = "Pending: \(changes.description)"
            }
        }
        
        // Update menu bar badge
        updateMenuBarBadge()
    }
    
    private func updateSyncStatus() {
        guard let menu = statusItem?.menu,
              let syncStatusItem = menu.item(withTag: 100) else { return }
        
        if let lastSync = syncEngine.lastSyncTime {
            let formatter = DateFormatter()
            let calendar = Calendar.current
            
            // Check if the sync was today
            if calendar.isDateInToday(lastSync) {
                formatter.dateFormat = "HH:mm"
                syncStatusItem.title = "Last sync: Today at \(formatter.string(from: lastSync))"
            } else if calendar.isDateInYesterday(lastSync) {
                formatter.dateFormat = "HH:mm"
                syncStatusItem.title = "Last sync: Yesterday at \(formatter.string(from: lastSync))"
            } else {
                formatter.dateFormat = "MMM d 'at' HH:mm"
                syncStatusItem.title = "Last sync: \(formatter.string(from: lastSync))"
            }
        } else {
            syncStatusItem.title = "Last sync: Never"
        }
    }
    
    private func updateCalendarsMenu() {
        guard let menu = statusItem?.menu,
              let calendarsItem = menu.item(withTag: 200),
              let submenu = calendarsItem.submenu else { return }
        
        submenu.removeAllItems()
        
        for calendar in syncEngine.calendars {
            let item = NSMenuItem(
                title: calendar.title,
                action: #selector(toggleCalendar(_:)),
                keyEquivalent: ""
            )
            item.representedObject = calendar.calendarIdentifier
            item.state = syncEngine.isCalendarEnabled(calendar.calendarIdentifier) ? .on : .off
            
            // Add colored circle indicator
            if let color = calendar.color {
                let colorImage = createColorCircle(color: color)
                item.image = colorImage
            }
            
            submenu.addItem(item)
        }
        
        if syncEngine.calendars.isEmpty {
            let noCalendarsItem = NSMenuItem(title: "No calendars found", action: nil, keyEquivalent: "")
            noCalendarsItem.isEnabled = false
            submenu.addItem(noCalendarsItem)
        }
    }
    
    private func createColorCircle(color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        path.fill()
        image.unlockFocus()
        return image
    }
    
    @objc private func togglePopover() {
        // Currently using menu instead of popover
    }
    
    @objc private func toggleSync(_ sender: NSMenuItem) {
        syncEngine.isSyncEnabled.toggle()
        sender.state = syncEngine.isSyncEnabled ? .on : .off
        
        if syncEngine.isSyncEnabled {
            syncEngine.startSyncTimer()
        } else {
            syncEngine.stopSyncTimer()
        }
    }
    
    @objc private func syncNow() {
        Task {
            await syncEngine.performSync()
        }
    }
    
    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let calendarId = sender.representedObject as? String else { return }
        syncEngine.toggleCalendar(calendarId)
        sender.state = syncEngine.isCalendarEnabled(calendarId) ? .on : .off
    }
    
    @objc private func openSettings() {
        // If window already exists, just bring it to front
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create the settings window
        let settingsView = SettingsView()
            .environmentObject(syncEngine)
        
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CalSync Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 350))
        window.center()
        window.isReleasedWhenClosed = false
        
        // Store reference
        settingsWindow = window
        
        // Show window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func viewLogs() {
        Logger.shared.openLogFile()
    }
    
    @objc private func purgeAllBlocks() {
        let alert = NSAlert()
        alert.messageText = "Purge All Blocks?"
        alert.informativeText = "This will delete ALL CalSync-created busy blocks from ALL your calendars. This action cannot be undone.\n\nUse this to clean up after a sync issue or to start fresh."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Purge All Blocks")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                // Temporarily disable sync to prevent re-creating blocks
                let wasEnabled = syncEngine.isSyncEnabled
                syncEngine.isSyncEnabled = false
                
                let deletedCount = await syncEngine.purgeAllBlocks()
                
                // Show result
                DispatchQueue.main.async {
                    let resultAlert = NSAlert()
                    resultAlert.messageText = "Purge Complete"
                    resultAlert.informativeText = "Deleted \(deletedCount) CalSync blocks from your calendars."
                    resultAlert.alertStyle = .informational
                    resultAlert.addButton(withTitle: "OK")
                    resultAlert.runModal()
                }
                
                // Re-enable sync if it was enabled
                syncEngine.isSyncEnabled = wasEnabled
            }
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

import Combine
