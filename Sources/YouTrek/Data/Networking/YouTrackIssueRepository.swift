import Foundation

final class YouTrackIssueRepository: IssueRepository, Sendable {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        // TODO: Integrate with YouTrack REST API using Swift OpenAPI Generator or Apollo.
        try await Task.sleep(nanoseconds: 50_000_000)
        return AppStatePlaceholder.sampleIssues()
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        try await Task.sleep(nanoseconds: 50_000_000)
        return IssueSummary(
            readableID: "TEMP-\(Int.random(in: 100...999))",
            title: draft.title,
            projectName: "Sample",
            priority: draft.priority,
            status: .open
        )
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        try await Task.sleep(nanoseconds: 50_000_000)
        return AppStatePlaceholder.sampleIssues().first ?? IssueSummary(
            readableID: "TEMP-001",
            title: patch.title ?? "Updated",
            projectName: "Sample",
            priority: patch.priority ?? .normal,
            status: patch.status ?? .open
        )
    }
}
