import AppAuth
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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

    init(
        configuration: YouTrackOAuthConfiguration,
        keychain: KeychainStorage = AppAuthRepository.defaultKeychain()
    ) {
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

    nonisolated static func defaultKeychain() -> KeychainStorage {
        AppConfigurationStore.defaultKeychain(service: "com.potomushto.youtrek.auth")
    }

    static func hasSavedAuthState(
        keychain: KeychainStorage = AppAuthRepository.defaultKeychain()
    ) -> Bool {
        restoreAuthState(from: keychain) != nil
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

            do {
                self.currentFlow = try Self.presentAuthorizationRequest(request, callback: callback)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func signOut() async throws {
        authState = nil
        currentAccount = nil
        try keychain.delete(account: Constants.keychainAccount)
        for legacyKeychain in Self.legacyFallbackKeychains(for: keychain) {
            try? legacyKeychain.delete(account: Constants.keychainAccount)
        }
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

    func resumeExternalUserAgentFlow(with url: URL) -> Bool {
        currentFlow?.resumeExternalUserAgentFlow(with: url) ?? false
    }

    private func persistAuthState() {
        guard let authState else {
            try? keychain.delete(account: Constants.keychainAccount)
            for legacyKeychain in Self.legacyFallbackKeychains(for: keychain) {
                try? legacyKeychain.delete(account: Constants.keychainAccount)
            }
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            try keychain.save(data: data, account: Constants.keychainAccount)
            for legacyKeychain in Self.legacyFallbackKeychains(for: keychain) {
                try? legacyKeychain.save(data: data, account: Constants.keychainAccount)
            }
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
        let identifier = UUID(uuidString: subject) ?? Self.stableIdentifier(for: subject)
        let avatarURL = (claims["picture"] as? String).flatMap(URL.init(string:))
        currentAccount = Account(id: identifier, displayName: displayName, avatarURL: avatarURL)
    }

    private static func restoreAuthState(from keychain: KeychainStorage) -> OIDAuthState? {
        do {
            if let data = try keychain.load(account: Constants.keychainAccount) {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
            }
            for legacyKeychain in legacyFallbackKeychains(for: keychain) {
                guard let data = try legacyKeychain.load(account: Constants.keychainAccount) else { continue }
                try? keychain.save(data: data, account: Constants.keychainAccount)
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
            }
            return nil
        } catch {
            print("Failed to restore auth state: \(error.localizedDescription)")
            return nil
        }
    }

    private static func stableIdentifier(for subject: String) -> UUID {
        let bytes = Array(subject.utf8)
        guard !bytes.isEmpty else { return UUID() }
        var hashBytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            hashBytes[index % hashBytes.count] = hashBytes[index % hashBytes.count] &+ byte &+ UInt8(index % 13)
        }
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }

    private static func legacyFallbackKeychains(for keychain: KeychainStorage) -> [KeychainStorage] {
        var candidates: [KeychainStorage] = [
            KeychainStorage(
                service: keychain.service,
                synchronizable: false,
                prefersDataProtectionKeychain: false
            )
        ]

        if let currentGroup = keychain.accessGroup {
            let alternateGroups = KeychainAccessGroupResolver.availableGroups()
                .filter { $0 != currentGroup }
                .sorted()
            for group in alternateGroups {
                candidates.append(
                    KeychainStorage(
                        service: keychain.service,
                        accessGroup: group,
                        synchronizable: keychain.synchronizable,
                        prefersDataProtectionKeychain: false
                    )
                )
            }
        }

        var seen: Set<String> = []
        return candidates.filter { storage in
            let signature = [storage.service, storage.accessGroup ?? "-", storage.synchronizable ? "1" : "0"]
                .joined(separator: "|")
            return seen.insert(signature).inserted
        }
    }

    private static func presentAuthorizationRequest(
        _ request: OIDAuthorizationRequest,
        callback: @escaping OIDAuthStateAuthorizationCallback
    ) throws -> OIDExternalUserAgentSession {
        #if canImport(UIKit)
        guard let presentingViewController = activeViewController else {
            throw AuthError.presentationUnavailable
        }
        return OIDAuthState.authState(
            byPresenting: request,
            presenting: presentingViewController,
            callback: callback
        )
        #elseif canImport(AppKit)
        guard let presentingWindow = activeWindow else {
            throw AuthError.presentationUnavailable
        }
        return OIDAuthState.authState(
            byPresenting: request,
            presenting: presentingWindow,
            callback: callback
        )
        #else
        throw AuthError.presentationUnavailable
        #endif
    }

    #if canImport(AppKit)
    private static var activeWindow: NSWindow? {
        NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first
    }
    #elseif canImport(UIKit)
    private static var activeViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
            .first?
            .rootViewController
            .flatMap(topViewController(from:))
            ?? connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { !$0.isHidden })?
            .rootViewController
            .flatMap(topViewController(from:))
    }

    private static var connectedScenes: Set<UIScene> {
        UIApplication.shared.connectedScenes
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        if let navigationController = root as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return topViewController(from: visibleViewController)
        }
        if let tabBarController = root as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return topViewController(from: selectedViewController)
        }
        if let presentedViewController = root.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        return root
    }
    #endif
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
