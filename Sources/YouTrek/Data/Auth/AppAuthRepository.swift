import AppAuth
import AppKit
import Foundation

@MainActor
final class AppAuthRepository: NSObject, AuthRepository {
    private enum Constants {
        static let keychainAccount = "youtrack.oauth.state"
    }

    private let configuration: YouTrackOAuthConfiguration
    private let keychain: KeychainStorage
    private var currentFlow: OIDExternalUserAgentSession?

    private var authState: OIDAuthState? {
        didSet {
            authState?.stateChangeDelegate = self
            authState?.errorDelegate = self
            persistAuthState()
            updateCurrentAccount()
        }
    }

    private(set) var currentAccount: Account?

    init(configuration: YouTrackOAuthConfiguration, keychain: KeychainStorage) {
        self.configuration = configuration
        self.keychain = keychain
        super.init()
        if let restored = Self.restoreAuthState(from: keychain) {
            self.authState = restored
            self.authState?.stateChangeDelegate = self
            self.authState?.errorDelegate = self
            updateCurrentAccount()
        }
    }

    func signIn() async throws {
        let serviceConfiguration = OIDServiceConfiguration(
            authorizationEndpoint: configuration.authorizationEndpoint,
            tokenEndpoint: configuration.tokenEndpoint
        )

        let request = OIDAuthorizationRequest(
            configuration: serviceConfiguration,
            clientId: configuration.clientID,
            clientSecret: nil,
            scopes: configuration.scopes,
            redirectURL: configuration.redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )

        try await withCheckedThrowingContinuation { continuation in
            let callback: OIDAuthStateAuthorizationCallback = { [weak self] state, error in
                guard let self else { return }
                defer { self.currentFlow = nil }

                if let state {
                    self.authState = state
                    continuation.resume(returning: ())
                } else if let error {
                    let nsError = error as NSError
                    if nsError.domain == OIDGeneralErrorDomain,
                       nsError.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                        continuation.resume(throwing: AuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: AuthError.tokenUnavailable)
                }
            }

            if let window = Self.activeWindow {
                self.currentFlow = OIDAuthState.authState(byPresenting: request, presenting: window, callback: callback)
            } else {
                self.currentFlow = OIDAuthState.authState(byPresenting: request, callback: callback)
            }
        }
    }

    func signOut() async throws {
        authState = nil
        currentAccount = nil
        try keychain.delete(account: Constants.keychainAccount)
    }

    func currentAccessToken() async throws -> String {
        guard let authState else {
            throw AuthError.notSignedIn
        }

        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { accessToken, _, error in
                if let accessToken {
                    continuation.resume(returning: accessToken)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthError.tokenUnavailable)
                }
            }
        }
    }

    private func persistAuthState() {
        guard let authState else {
            try? keychain.delete(account: Constants.keychainAccount)
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            try keychain.save(data: data, account: Constants.keychainAccount)
        } catch {
            print("Failed to persist auth state: \(error.localizedDescription)")
        }
    }

    private func updateCurrentAccount() {
        guard let authState else {
            currentAccount = nil
            return
        }

        let idTokenString = authState.lastTokenResponse?.idToken ?? authState.lastAuthorizationResponse.idToken
        guard let idTokenString, let idToken = OIDIDToken(idTokenString: idTokenString) else {
            currentAccount = nil
            return
        }

        let claims = idToken.claims
        let displayName = claims["name"] as? String ??
            claims["fullName"] as? String ??
            claims["preferred_username"] as? String ??
            claims["login"] as? String ??
            "YouTrack User"
        let subject = claims["sub"] as? String ?? UUID().uuidString
        let identifier = UUID(uuidString: subject) ?? UUID()
        let avatarURL = (claims["picture"] as? String).flatMap(URL.init(string:))
        currentAccount = Account(id: identifier, displayName: displayName, avatarURL: avatarURL)
    }

    private static func restoreAuthState(from keychain: KeychainStorage) -> OIDAuthState? {
        do {
            guard let data = try keychain.load(account: Constants.keychainAccount) else { return nil }
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        } catch {
            print("Failed to restore auth state: \(error.localizedDescription)")
            return nil
        }
    }

    private static var activeWindow: NSWindow? {
        NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first
    }
}

@MainActor
extension AppAuthRepository: @preconcurrency OIDAuthStateChangeDelegate, @preconcurrency OIDAuthStateErrorDelegate {
    func didChange(_ state: OIDAuthState) {
        authState = state
    }

    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        print("Authorization error encountered: \(error.localizedDescription)")
    }
}
