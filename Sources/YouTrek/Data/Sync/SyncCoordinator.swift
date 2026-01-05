import Foundation

actor SyncCoordinator {
    private let issueRepository: IssueRepository
    private let localStore: IssueLocalStore
    private let operationQueue: SyncOperationQueue
    private let conflictHandler: (@Sendable (ConflictNotice) async -> Void)?

    init(
        issueRepository: IssueRepository,
        localStore: IssueLocalStore = IssueLocalStore(),
        operationQueue: SyncOperationQueue = SyncOperationQueue(),
        conflictHandler: (@Sendable (ConflictNotice) async -> Void)? = nil
    ) {
        self.issueRepository = issueRepository
        self.localStore = localStore
        self.operationQueue = operationQueue
        self.conflictHandler = conflictHandler
    }

    func refreshIssues(using query: IssueQuery) async throws -> [IssueSummary] {
        do {
            return try await enqueue(label: "Sync issues") {
                let remote = try await self.issueRepository.fetchIssues(query: query)
                try await self.localStore.save(issues: remote)
                return remote
            }
        } catch {
            // On failure fall back to local cache.
            return (try? await localStore.loadCachedIssues()) ?? []
        }
    }

    func enqueue<T: Sendable>(
        label: String,
        localChanges: String? = nil,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await operationQueue.enqueue(label: label, operation: operation)
        } catch {
            if let conflict = conflictNotice(for: error, label: label, localChanges: localChanges) {
                await conflictHandler?(conflict)
            }
            throw error
        }
    }

    private func conflictNotice(for error: Error, label: String, localChanges: String?) -> ConflictNotice? {
        guard case let YouTrackAPIError.http(statusCode, _) = error else { return nil }
        guard statusCode == 409 || statusCode == 412 else { return nil }

        let fallbackChanges = localChanges?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (fallbackChanges?.isEmpty == false) ? fallbackChanges! : "No local changes captured."

        return ConflictNotice(
            title: "Sync Conflict",
            message: "Your local changes could not be synced because the remote item changed. Copy your changes below before retrying.",
            localChanges: text
        )
    }
}
