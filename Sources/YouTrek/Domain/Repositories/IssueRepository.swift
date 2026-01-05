import Foundation

protocol IssueRepository: Sendable {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary]
    func createIssue(draft: IssueDraft) async throws -> IssueSummary
    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary
}

struct IssueQuery: Equatable, Hashable, Sendable {
    var rawQuery: String?
    var search: String
    var filters: [String]
    var sort: IssueSort?
    var page: Page

    struct Page: Equatable, Hashable, Sendable {
        var size: Int
        var offset: Int
    }

    static func saved(_ query: String, page: Page) -> IssueQuery {
        IssueQuery(
            rawQuery: query,
            search: "",
            filters: [],
            sort: nil,
            page: page
        )
    }
}

enum IssueSort: Equatable, Hashable, Sendable {
    case updated(descending: Bool)
    case priority(descending: Bool)
}

struct IssueDraft: Equatable {
    var title: String
    var description: String
    var projectID: String
    var priority: IssuePriority
    var assigneeID: String?
}

struct IssuePatch: Equatable {
    var title: String?
    var description: String?
    var status: IssueStatus?
    var priority: IssuePriority?
}
