import Foundation

actor SyncCoordinator {
    let issueRepository: IssueRepository
    let localStore: IssueLocalStore

    init(issueRepository: IssueRepository = YouTrackIssueRepository(), localStore: IssueLocalStore = IssueLocalStore()) {
        self.issueRepository = issueRepository
        self.localStore = localStore
    }

    func refreshIssues(using query: IssueQuery) async throws -> [IssueSummary] {
        do {
            let remote = try await issueRepository.fetchIssues(query: query)
            try await localStore.save(issues: remote)
            return remote
        } catch {
            // On failure fall back to local cache.
            return (try? await localStore.loadCachedIssues()) ?? []
        }
    }
}
