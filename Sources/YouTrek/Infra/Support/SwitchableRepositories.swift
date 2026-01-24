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

    func fetchSprintIssueIDs(agileID: String, sprintID: String) async throws -> [String] {
        try await current.fetchSprintIssueIDs(agileID: agileID, sprintID: sprintID)
    }

    func fetchIssueDetail(issue: IssueSummary) async throws -> IssueDetail {
        try await current.fetchIssueDetail(issue: issue)
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        try await current.createIssue(draft: draft)
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        try await current.updateIssue(id: id, patch: patch)
    }

    func addComment(issueReadableID: String, text: String) async throws -> IssueComment {
        try await current.addComment(issueReadableID: issueReadableID, text: text)
    }
}

actor SwitchableSavedQueryRepository: SavedQueryRepository {
    private var current: SavedQueryRepository

    init(initial: SavedQueryRepository) {
        self.current = initial
    }

    func replace(with repository: SavedQueryRepository) {
        current = repository
    }

    func fetchSavedQueries() async throws -> [SavedQuery] {
        try await current.fetchSavedQueries()
    }

    func deleteSavedQuery(id: String) async throws {
        try await current.deleteSavedQuery(id: id)
    }
}

actor SwitchableIssueBoardRepository: IssueBoardRepository {
    private var current: IssueBoardRepository

    init(initial: IssueBoardRepository) {
        self.current = initial
    }

    func replace(with repository: IssueBoardRepository) {
        current = repository
    }

    func fetchBoards() async throws -> [IssueBoard] {
        try await current.fetchBoards()
    }

    func fetchBoard(id: String) async throws -> IssueBoard {
        try await current.fetchBoard(id: id)
    }
}

actor SwitchableProjectRepository: ProjectRepository {
    private var current: ProjectRepository

    init(initial: ProjectRepository) {
        self.current = initial
    }

    func replace(with repository: ProjectRepository) {
        current = repository
    }

    func fetchProjects() async throws -> [IssueProject] {
        try await current.fetchProjects()
    }
}

actor SwitchableIssueFieldRepository: IssueFieldRepository {
    private var current: IssueFieldRepository

    init(initial: IssueFieldRepository) {
        self.current = initial
    }

    func replace(with repository: IssueFieldRepository) {
        current = repository
    }

    func fetchFields(projectID: String) async throws -> [IssueField] {
        try await current.fetchFields(projectID: projectID)
    }

    func fetchBundleOptions(bundleID: String, kind: IssueFieldKind) async throws -> [IssueFieldOption] {
        try await current.fetchBundleOptions(bundleID: bundleID, kind: kind)
    }
}

actor SwitchablePeopleRepository: PeopleRepository {
    private var current: PeopleRepository

    init(initial: PeopleRepository) {
        self.current = initial
    }

    func replace(with repository: PeopleRepository) {
        current = repository
    }

    func fetchPeople(query: String?, projectID: String?) async throws -> [IssueFieldOption] {
        try await current.fetchPeople(query: query, projectID: projectID)
    }
}
