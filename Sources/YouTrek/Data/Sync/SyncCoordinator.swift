import Foundation

actor SyncCoordinator {
    struct IssueSyncResult: Sendable {
        let issues: [IssueSummary]
        let didSyncRemote: Bool
    }

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
        let result = await refreshIssuesWithStatus(
            using: query,
            currentUserID: nil,
            currentUserLogin: nil,
            currentUserDisplayName: nil
        )
        return result.issues
    }

    func refreshIssuesWithStatus(
        using query: IssueQuery,
        currentUserID: String?,
        currentUserLogin: String?,
        currentUserDisplayName: String?
    ) async -> IssueSyncResult {
        if AppDebugSettings.disableSyncing {
            let cached = await localStore.loadIssues(for: query)
            LoggingService.sync.info("Issue sync: syncing disabled, loaded \(cached.count, privacy: .public) cached issues.")
            return IssueSyncResult(issues: cached, didSyncRemote: false)
        }
        do {
            LoggingService.sync.info("Issue sync: fetching remote issues.")
            let issues = try await enqueue(label: "Sync issues") {
                let remote = try await self.issueRepository.fetchIssues(query: query)
                await self.localStore.saveRemoteIssues(
                    remote,
                    for: query,
                    currentUserID: currentUserID,
                    currentUserLogin: currentUserLogin,
                    currentUserDisplayName: currentUserDisplayName
                )
                return await self.localStore.loadIssues(for: query)
            }
            LoggingService.sync.info("Issue sync: remote issues fetched (\(issues.count, privacy: .public)).")
            return IssueSyncResult(issues: issues, didSyncRemote: true)
        } catch {
            // On failure fall back to local cache.
            let cached = await localStore.loadIssues(for: query)
            LoggingService.sync.error("Issue sync: failed (\(error.localizedDescription, privacy: .public)), loaded \(cached.count, privacy: .public) cached issues.")
            return IssueSyncResult(issues: cached, didSyncRemote: false)
        }
    }

    func loadCachedIssues(for query: IssueQuery) async -> [IssueSummary] {
        await localStore.loadIssues(for: query)
    }

    func fetchIssueDetail(for issue: IssueSummary) async throws -> IssueDetail {
        if AppDebugSettings.disableSyncing {
            throw YouTrackAPIError.http(statusCode: 503, body: "Syncing disabled")
        }
        return try await enqueue(label: "Sync issue details") {
            try await self.issueRepository.fetchIssueDetail(issue: issue)
        }
    }

    func clearCachedIssues() async {
        await localStore.clearCache()
    }

    func loadIssueSeenUpdates(for issueIDs: [IssueSummary.ID]) async -> [IssueSummary.ID: Date] {
        await localStore.loadIssueSeenUpdates(for: issueIDs)
    }

    func markIssueSeen(_ issue: IssueSummary) async {
        await localStore.markIssueSeen(issue)
    }

    func markIssuesSeen(_ issues: [IssueSummary]) async {
        await localStore.markIssuesSeen(issues)
    }

    func hasSeenUpdates() async -> Bool {
        await localStore.hasSeenUpdates()
    }

    func applyOptimisticUpdate(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        guard let updated = await localStore.applyPatch(id: id, patch: patch) else {
            throw YouTrackAPIError.http(statusCode: 404, body: "Issue not found in local store")
        }
        _ = await localStore.enqueueUpdate(issueID: id, patch: patch)
        Task { [weak self] in
            await self?.flushPendingMutations()
        }
        return updated
    }

    func flushPendingMutations() async {
        if AppDebugSettings.disableSyncing {
            return
        }
        let mutations = await localStore.pendingMutations()
        guard !mutations.isEmpty else { return }

        for mutation in mutations {
            await localStore.markMutationAttempted(id: mutation.id, errorDescription: nil)
            switch mutation.kind {
            case .update:
                do {
                    let updated = try await enqueue(
                        label: "Sync issue update",
                        localChanges: mutation.localChanges
                    ) {
                        try await self.issueRepository.updateIssue(id: mutation.issueID, patch: mutation.patch)
                    }
                    await localStore.markMutationApplied(mutation, updatedIssue: updated)
                } catch {
                    await localStore.markMutationAttempted(id: mutation.id, errorDescription: error.localizedDescription)
                }
            }
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
