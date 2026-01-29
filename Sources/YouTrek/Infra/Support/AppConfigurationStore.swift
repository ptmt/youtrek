import Foundation

struct AppConfigurationStore {
    private enum Keys {
        static let baseURL = "com.potomushto.youtrek.config.base-url"
        static let tokenAccount = "com.potomushto.youtrek.config.token"
        static let lastSidebarSelectionID = "com.potomushto.youtrek.config.last-sidebar-selection"
        static let userDisplayName = "com.potomushto.youtrek.config.user-display-name"
        static let userLogin = "com.potomushto.youtrek.config.user-login"
        static let userID = "com.potomushto.youtrek.config.user-id"
    }

    private static let sharedSuiteName = "com.potomushto.youtrek.shared"
    private static let sharedKeychainGroupSuffix = "com.potomushto.youtrek.shared"
    private static let legacyKeychainGroupSuffixes = [
        "com.potomushto.youtrek.macos",
        "com.potomushto.youtrek"
    ]

    private let defaults: UserDefaults
    private let keychain: KeychainStorage

    init(
        defaults: UserDefaults = AppConfigurationStore.defaultDefaults(),
        keychain: KeychainStorage = KeychainStorage(
            service: "com.potomushto.youtrek.config",
            accessGroup: KeychainAccessGroupResolver.resolve(
                matchingSuffixes: [AppConfigurationStore.sharedKeychainGroupSuffix]
                    + AppConfigurationStore.legacyKeychainGroupSuffixes
            )
        )
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private static func defaultDefaults() -> UserDefaults {
        guard let sharedDefaults = UserDefaults(suiteName: sharedSuiteName) else {
            return .standard
        }
        migrateDefaultsIfNeeded(from: .standard, to: sharedDefaults)
        return sharedDefaults
    }

    private static func migrateDefaultsIfNeeded(from source: UserDefaults, to target: UserDefaults) {
        if target.string(forKey: Keys.baseURL) == nil,
           let baseURL = source.string(forKey: Keys.baseURL),
           !baseURL.isEmpty {
            target.set(baseURL, forKey: Keys.baseURL)
        }
        if target.string(forKey: Keys.userDisplayName) == nil,
           let name = source.string(forKey: Keys.userDisplayName),
           !name.isEmpty {
            target.set(name, forKey: Keys.userDisplayName)
        }
        if target.string(forKey: Keys.userLogin) == nil,
           let login = source.string(forKey: Keys.userLogin),
           !login.isEmpty {
            target.set(login, forKey: Keys.userLogin)
        }
        if target.string(forKey: Keys.userID) == nil,
           let id = source.string(forKey: Keys.userID),
           !id.isEmpty {
            target.set(id, forKey: Keys.userID)
        }
        if target.string(forKey: Keys.lastSidebarSelectionID) == nil,
           let selection = source.string(forKey: Keys.lastSidebarSelectionID),
           !selection.isEmpty {
            target.set(selection, forKey: Keys.lastSidebarSelectionID)
        }
    }

    func loadBaseURL() -> URL? {
        guard let stored = defaults.string(forKey: Keys.baseURL), !stored.isEmpty else {
            return nil
        }
        return URL(string: stored)
    }

    func save(baseURL: URL) {
        defaults.set(baseURL.absoluteString, forKey: Keys.baseURL)
    }

    func clearBaseURL() {
        defaults.removeObject(forKey: Keys.baseURL)
    }

    func loadToken(allowInteraction: Bool = false) -> String? {
        loadTokenResult(allowInteraction: allowInteraction).token
    }

    func loadTokenResult(allowInteraction: Bool = false) -> (token: String?, error: String?) {
        let tokenData: Data?
        do {
            tokenData = try keychain.load(account: Keys.tokenAccount, allowInteraction: allowInteraction)
        } catch {
            let message = error.localizedDescription
            LoggingService.sync.error("Keychain: failed to load token (\(message, privacy: .public)).")
            return (nil, message)
        }
        if let unwrapped = tokenData {
            return (String(data: unwrapped, encoding: .utf8), nil)
        }
        guard keychain.accessGroup != nil else { return (nil, nil) }
        do {
            let legacyKeychain = KeychainStorage(service: "com.potomushto.youtrek.config")
            if let legacyData = try legacyKeychain.load(
                account: Keys.tokenAccount,
                allowInteraction: allowInteraction
            ) {
                try? keychain.save(data: legacyData, account: Keys.tokenAccount)
                return (String(data: legacyData, encoding: .utf8), nil)
            }
        } catch {
            let message = error.localizedDescription
            LoggingService.sync.error("Keychain: failed to load legacy token (\(message, privacy: .public)).")
            return (nil, message)
        }
        return (nil, nil)
    }

    func save(token: String) throws {
        let data = Data(token.utf8)
        try keychain.save(data: data, account: Keys.tokenAccount)
        if keychain.accessGroup != nil {
            try? KeychainStorage(service: "com.potomushto.youtrek.config")
                .save(data: data, account: Keys.tokenAccount)
        }
    }

    func clearToken() throws {
        try keychain.delete(account: Keys.tokenAccount)
        if keychain.accessGroup != nil {
            try? KeychainStorage(service: "com.potomushto.youtrek.config")
                .delete(account: Keys.tokenAccount)
        }
    }

    func loadUserDisplayName() -> String? {
        defaults.string(forKey: Keys.userDisplayName)
    }

    func saveUserDisplayName(_ name: String) {
        defaults.set(name, forKey: Keys.userDisplayName)
    }

    func clearUserDisplayName() {
        defaults.removeObject(forKey: Keys.userDisplayName)
    }

    func loadUserLogin() -> String? {
        defaults.string(forKey: Keys.userLogin)
    }

    func saveUserLogin(_ login: String) {
        defaults.set(login, forKey: Keys.userLogin)
    }

    func clearUserLogin() {
        defaults.removeObject(forKey: Keys.userLogin)
    }

    func loadUserID() -> String? {
        defaults.string(forKey: Keys.userID)
    }

    func saveUserID(_ id: String) {
        defaults.set(id, forKey: Keys.userID)
    }

    func clearUserID() {
        defaults.removeObject(forKey: Keys.userID)
    }

    func loadLastSidebarSelectionID() -> String? {
        defaults.string(forKey: Keys.lastSidebarSelectionID)
    }

    func saveLastSidebarSelectionID(_ id: String) {
        defaults.set(id, forKey: Keys.lastSidebarSelectionID)
    }

    func clearLastSidebarSelectionID() {
        defaults.removeObject(forKey: Keys.lastSidebarSelectionID)
    }
}

enum AppDebugSettings {
    enum Keys {
        static let simulateSlowResponses = "com.potomushto.youtrek.debug.simulate-slow-responses"
        static let showNetworkFooter = "com.potomushto.youtrek.debug.show-network-footer"
        static let disableSyncing = "com.potomushto.youtrek.debug.disable-syncing"
        static let showBoardDiagnostics = "com.potomushto.youtrek.debug.show-board-diagnostics"
    }

    static var simulateSlowResponses: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.simulateSlowResponses)
        #else
        return false
        #endif
    }

    static var showNetworkFooter: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showNetworkFooter)
        #else
        return false
        #endif
    }

    static var disableSyncing: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.disableSyncing)
        #else
        return false
        #endif
    }

    static var showBoardDiagnostics: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showBoardDiagnostics)
        #else
        return false
        #endif
    }

    static func setSimulateSlowResponses(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.simulateSlowResponses)
        #endif
    }

    static func setShowNetworkFooter(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.showNetworkFooter)
        #endif
    }

    static func setDisableSyncing(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.disableSyncing)
        #endif
    }

    static func setShowBoardDiagnostics(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.showBoardDiagnostics)
        #endif
    }

    static let slowResponseDelay: TimeInterval = 5
    static let syncStartDelay: TimeInterval = 2.0 // we postpone syncing to make sure we fetch first from offline

    static func applySlowResponseIfNeeded() async throws {
        guard simulateSlowResponses else { return }
        let nanoseconds = UInt64(slowResponseDelay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
