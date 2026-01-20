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

extension IssueQuery {
    static func boardQuery(boardName: String, sprintName: String?) -> String {
        let trimmedBoard = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedBoard = escapeQueryValue(trimmedBoard)
        var query = "board: {\(escapedBoard)}"
        if let sprintName {
            let trimmedSprint = sprintName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSprint.isEmpty {
                let escapedSprint = escapeQueryValue(trimmedSprint)
                query += " Sprint: {\(escapedSprint)}"
            }
        }
        return query
    }

    private static func escapeQueryValue(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "{", with: "\\{")
        escaped = escaped.replacingOccurrences(of: "}", with: "\\}")
        return escaped
    }
}

enum IssueSort: Equatable, Hashable, Sendable {
    case updated(descending: Bool)
    case priority(descending: Bool)
}

struct IssueDraft: Equatable, Codable {
    var title: String
    var description: String
    var projectID: String
    var module: String?
    var priority: IssuePriority
    var assigneeID: String?
}

struct IssuePatch: Equatable, Codable {
    var title: String?
    var description: String?
    var status: IssueStatus?
    var priority: IssuePriority?
}

extension IssuePatch {
    var localChangesDescription: String {
        var parts: [String] = []
        if let title {
            parts.append("Title: \(title)")
        }
        if let description {
            parts.append("Description: \(description)")
        }
        if let status {
            parts.append("Status: \(status.displayName)")
        }
        if let priority {
            parts.append("Priority: \(priority.displayName)")
        }
        return parts.isEmpty ? "No local changes captured." : parts.joined(separator: "\n")
    }
}
