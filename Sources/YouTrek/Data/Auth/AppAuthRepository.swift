import Foundation

final class AppAuthRepository: AuthRepository {
    private(set) var currentAccount: Account?

    func signIn() async throws {
        // TODO: Wire into AppAuth + ASWebAuthenticationSession
        try await Task.sleep(nanoseconds: 100_000_000)
        currentAccount = Account(id: UUID(), displayName: "YouTrek Pilot", avatarURL: nil)
    }

    func signOut() async throws {
        currentAccount = nil
    }
}
