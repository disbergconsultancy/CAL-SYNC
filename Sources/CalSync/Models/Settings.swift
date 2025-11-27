import Foundation

/// App settings stored in UserDefaults
class Settings: ObservableObject {
    static let shared = Settings()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Keys
    private enum Keys {
        static let syncIntervalMinutes = "syncIntervalMinutes"
        static let syncWindowDays = "syncWindowDays"
        static let blockTitleFormat = "blockTitleFormat"
        static let syncAllDayEvents = "syncAllDayEvents"
        static let showNotifications = "showNotifications"
        static let launchAtLogin = "launchAtLogin"
        static let syncRecurringAsSeries = "syncRecurringAsSeries"
    }
    
    // MARK: - Settings Properties
    
    @Published var syncIntervalMinutes: Int {
        didSet {
            defaults.set(syncIntervalMinutes, forKey: Keys.syncIntervalMinutes)
        }
    }
    
    @Published var syncWindowDays: Int {
        didSet {
            defaults.set(syncWindowDays, forKey: Keys.syncWindowDays)
        }
    }
    
    @Published var blockTitleFormat: String {
        didSet {
            defaults.set(blockTitleFormat, forKey: Keys.blockTitleFormat)
        }
    }
    
    @Published var syncAllDayEvents: Bool {
        didSet {
            defaults.set(syncAllDayEvents, forKey: Keys.syncAllDayEvents)
        }
    }
    
    @Published var showNotifications: Bool {
        didSet {
            defaults.set(showNotifications, forKey: Keys.showNotifications)
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        }
    }
    
    @Published var syncRecurringAsSeries: Bool {
        didSet {
            defaults.set(syncRecurringAsSeries, forKey: Keys.syncRecurringAsSeries)
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Register defaults
        defaults.register(defaults: [
            Keys.syncIntervalMinutes: 5,
            Keys.syncWindowDays: 14,
            Keys.blockTitleFormat: "Busy - {source_name}",
            Keys.syncAllDayEvents: false,
            Keys.showNotifications: true,
            Keys.launchAtLogin: false,
            Keys.syncRecurringAsSeries: true
        ])
        
        // Load values
        self.syncIntervalMinutes = defaults.integer(forKey: Keys.syncIntervalMinutes)
        self.syncWindowDays = defaults.integer(forKey: Keys.syncWindowDays)
        self.blockTitleFormat = defaults.string(forKey: Keys.blockTitleFormat) ?? "Busy - {source_name}"
        self.syncAllDayEvents = defaults.bool(forKey: Keys.syncAllDayEvents)
        self.showNotifications = defaults.bool(forKey: Keys.showNotifications)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.syncRecurringAsSeries = defaults.bool(forKey: Keys.syncRecurringAsSeries)
    }
    
    // MARK: - Reset
    
    func resetToDefaults() {
        syncIntervalMinutes = 5
        syncWindowDays = 14
        blockTitleFormat = "Busy - {source_name}"
        syncAllDayEvents = false
        showNotifications = true
        launchAtLogin = false
        syncRecurringAsSeries = true
    }
}
