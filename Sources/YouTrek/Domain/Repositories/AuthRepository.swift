import Foundation

protocol AuthRepository {
    func signIn() async throws
    func signOut() async throws
    var currentAccount: Account? { get }
}

struct Account: Equatable {
    var id: UUID
    var displayName: String
    var avatarURL: URL?
}
