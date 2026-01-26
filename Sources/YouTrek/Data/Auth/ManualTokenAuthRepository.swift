import Foundation

@MainActor
final class ManualTokenAuthRepository: AuthRepository {
    private let configurationStore: AppConfigurationStore
    private(set) var currentAccount: Account?
    private var sessionToken: String?

    init(configurationStore: AppConfigurationStore) {
        self.configurationStore = configurationStore
        if configurationStore.loadToken() != nil {
            let displayName = configurationStore.loadUserDisplayName() ?? "YouTrack Token"
            currentAccount = Account(id: UUID(), displayName: displayName, avatarURL: nil)
        }
    }

    func apply(token: String, displayName: String?) throws {
        sessionToken = token
        if let displayName, !displayName.isEmpty {
            configurationStore.saveUserDisplayName(displayName)
        }
        let resolvedName = configurationStore.loadUserDisplayName() ?? "YouTrack Token"
        currentAccount = Account(id: UUID(), displayName: resolvedName, avatarURL: nil)
        try configurationStore.save(token: token)
    }

    func signIn() async throws {
        // Manual token flow does not perform interactive sign-in.
        guard configurationStore.loadToken() != nil else {
            throw AuthError.notSignedIn
        }
    }

    func signOut() async throws {
        try configurationStore.clearToken()
        sessionToken = nil
        configurationStore.clearUserDisplayName()
        currentAccount = nil
    }

    func currentAccessToken() async throws -> String {
        if let sessionToken, !sessionToken.isEmpty {
            return sessionToken
        }
        guard let token = configurationStore.loadToken(), !token.isEmpty else {
            throw AuthError.notSignedIn
        }
        return token
    }
}
