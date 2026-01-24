import Foundation

struct AppConfigurationStore {
    private enum Keys {
        static let baseURL = "com.potomushto.youtrek.config.base-url"
        static let tokenAccount = "com.potomushto.youtrek.config.token"
        static let lastSidebarSelectionID = "com.potomushto.youtrek.config.last-sidebar-selection"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStorage

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStorage = KeychainStorage(service: "com.potomushto.youtrek.config")
    ) {
        self.defaults = defaults
        self.keychain = keychain
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

    func loadToken() -> String? {
        let tokenData: Data?
        do {
            tokenData = try keychain.load(account: Keys.tokenAccount)
        } catch {
            return nil
        }
        guard let unwrapped = tokenData else { return nil }
        return String(data: unwrapped, encoding: .utf8)
    }

    func save(token: String) throws {
        let data = Data(token.utf8)
        try keychain.save(data: data, account: Keys.tokenAccount)
    }

    func clearToken() throws {
        try keychain.delete(account: Keys.tokenAccount)
    }

    func loadLastSidebarSelectionID() -> String? {
        defaults.string(forKey: Keys.lastSidebarSelectionID)
    }

    func saveLastSidebarSelectionID(_ id: String) {
        defaults.set(id, forKey: Keys.lastSidebarSelectionID)
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
