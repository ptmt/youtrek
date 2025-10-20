import Foundation

final class IssueLocalStore {
    func loadCachedIssues() async throws -> [IssueSummary] {
        // TODO: Replace with SwiftData/SQLite-backed persistence.
        return AppStatePlaceholder.sampleIssues()
    }

    func save(issues: [IssueSummary]) async throws {
        // TODO: Persist issues locally.
    }
}
