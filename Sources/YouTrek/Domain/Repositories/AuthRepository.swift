import Foundation

@MainActor
protocol AuthRepository: AnyObject {
    func signIn() async throws
    func signOut() async throws
    var currentAccount: Account? { get }
    func currentAccessToken() async throws -> String
}

struct Account: Equatable, Sendable {
    var id: UUID
    var displayName: String
    var avatarURL: URL?
}

enum AuthError: Error, LocalizedError {
    case notSignedIn
    case configurationMissing(String)
    case userCancelled
    case tokenUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in yet."
        case .configurationMissing(let detail):
            return "OAuth configuration is incomplete: \(detail)."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .tokenUnavailable:
            return "Unable to obtain an access token from Hub."
        }
    }
}
