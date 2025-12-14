import Foundation

@MainActor
final class ManualTokenAuthRepository: AuthRepository {
    private let configurationStore: AppConfigurationStore
    private(set) var currentAccount: Account?

    init(configurationStore: AppConfigurationStore) {
        self.configurationStore = configurationStore
        if configurationStore.loadToken() != nil {
            currentAccount = Account(id: UUID(), displayName: "YouTrack Token", avatarURL: nil)
        }
    }

    func apply(token: String) throws {
        try configurationStore.save(token: token)
        currentAccount = Account(id: UUID(), displayName: "YouTrack Token", avatarURL: nil)
    }

    func signIn() async throws {
        // Manual token flow does not perform interactive sign-in.
        guard configurationStore.loadToken() != nil else {
            throw AuthError.notSignedIn
        }
    }

    func signOut() async throws {
        try configurationStore.clearToken()
        currentAccount = nil
    }

    func currentAccessToken() async throws -> String {
        guard let token = configurationStore.loadToken(), !token.isEmpty else {
            throw AuthError.notSignedIn
        }
        return token
    }
}
