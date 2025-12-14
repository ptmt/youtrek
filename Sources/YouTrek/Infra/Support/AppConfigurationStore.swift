import Foundation

struct AppConfigurationStore {
    private enum Keys {
        static let baseURL = "com.youtrek.config.base-url"
        static let tokenAccount = "com.youtrek.config.token"
    }

    private let ubiquitousStore: NSUbiquitousKeyValueStore
    private let keychain: KeychainStorage

    init(
        ubiquitousStore: NSUbiquitousKeyValueStore = .default,
        keychain: KeychainStorage = KeychainStorage(service: "com.youtrek.config")
    ) {
        self.ubiquitousStore = ubiquitousStore
        self.keychain = keychain
    }

    func loadBaseURL() -> URL? {
        guard let stored = ubiquitousStore.string(forKey: Keys.baseURL), !stored.isEmpty else {
            return nil
        }
        return URL(string: stored)
    }

    func save(baseURL: URL) {
        ubiquitousStore.set(baseURL.absoluteString, forKey: Keys.baseURL)
        ubiquitousStore.synchronize()
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
