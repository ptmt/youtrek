import Foundation

struct AppConfigurationStore {
    private enum Keys {
        static let baseURL = "com.potomushto.youtrek.config.base-url"
        static let tokenAccount = "com.potomushto.youtrek.config.token"
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
}
