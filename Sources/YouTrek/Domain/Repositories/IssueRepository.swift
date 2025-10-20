import Foundation

protocol IssueRepository {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary]
    func createIssue(draft: IssueDraft) async throws -> IssueSummary
    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary
}

struct IssueQuery: Equatable {
    var search: String
    var filters: [String]
    var sort: IssueSort
    var page: Page

    struct Page: Equatable {
        var size: Int
        var offset: Int
    }
}

enum IssueSort: Equatable {
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
