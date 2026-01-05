import Foundation

final class IssueLocalStore: Sendable {
    func loadCachedIssues() async throws -> [IssueSummary] {
        // TODO: Replace with SwiftData/SQLite-backed persistence.
        return []
    }

    func save(issues: [IssueSummary]) async throws {
        // TODO: Persist issues locally.
    }
}
