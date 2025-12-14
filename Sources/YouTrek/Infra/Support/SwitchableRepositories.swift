import Foundation

@MainActor
final class SwitchableAuthRepository: AuthRepository {
    private var current: AuthRepository

    init(initial: AuthRepository) {
        self.current = initial
    }

    func replace(with repository: AuthRepository) {
        current = repository
    }

    var currentAccount: Account? {
        current.currentAccount
    }

    func signIn() async throws {
        try await current.signIn()
    }

    func signOut() async throws {
        try await current.signOut()
    }

    func currentAccessToken() async throws -> String {
        try await current.currentAccessToken()
    }
}

actor SwitchableIssueRepository: IssueRepository {
    private var current: IssueRepository

    init(initial: IssueRepository) {
        self.current = initial
    }

    func replace(with repository: IssueRepository) {
        current = repository
    }

    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        try await current.fetchIssues(query: query)
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        try await current.createIssue(draft: draft)
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        try await current.updateIssue(id: id, patch: patch)
    }
}
