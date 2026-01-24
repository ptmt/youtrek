import Foundation

protocol IssueRepository: Sendable {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary]
    func fetchSprintIssueIDs(agileID: String, sprintID: String) async throws -> [String]
    func fetchIssueDetail(issue: IssueSummary) async throws -> IssueDetail
    func createIssue(draft: IssueDraft) async throws -> IssueSummary
    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary
    func addComment(issueReadableID: String, text: String) async throws -> IssueComment
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
    static func boardQuery(boardName: String, sprintName: String?, sprintFieldName: String? = nil) -> String {
        let trimmedBoard = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedBoard = escapeQueryValue(trimmedBoard)
        guard let sprintName else {
            return "has: {Board \(escapedBoard)}"
        }

        let trimmedSprint = sprintName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSprint.isEmpty else {
            return "has: {Board \(escapedBoard)}"
        }

        let escapedSprint = escapeQueryValue(trimmedSprint)
        let boardClause = "has: {Board \(escapedBoard)}"
        let fieldCandidate = sprintFieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !fieldCandidate.isEmpty {
            let fieldName = escapeQueryValue(fieldCandidate)
            return "\(boardClause) \(fieldName): {\(escapedSprint)}"
        }

        let boardAttributeName = trimmedBoard.isEmpty ? "Board" : "Board \(escapedBoard)"
        return "\(boardAttributeName): {\(escapedSprint)}"
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
    var customFields: [IssueDraftField] = []
}

struct IssuePatch: Equatable, Codable {
    var title: String?
    var description: String?
    var projectID: String? = nil
    var projectName: String? = nil
    var status: IssueStatus?
    var statusOption: IssueFieldOption? = nil
    var priority: IssuePriority?
    var priorityOption: IssueFieldOption? = nil
    var assignee: AssigneeChange? = nil
    var issueReadableID: String? = nil
}

enum AssigneeChange: Equatable, Codable {
    case clear
    case set(IssueFieldOption)

    private enum CodingKeys: String, CodingKey {
        case type
        case option
    }

    private enum ChangeType: String, Codable {
        case clear
        case set
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ChangeType.self, forKey: .type)
        switch type {
        case .clear:
            self = .clear
        case .set:
            let option = try container.decode(IssueFieldOption.self, forKey: .option)
            self = .set(option)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clear:
            try container.encode(ChangeType.clear, forKey: .type)
        case .set(let option):
            try container.encode(ChangeType.set, forKey: .type)
            try container.encode(option, forKey: .option)
        }
    }
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
        if let projectName {
            parts.append("Project: \(projectName)")
        } else if let projectID {
            parts.append("Project ID: \(projectID)")
        }
        if let statusOption {
            parts.append("Status: \(statusOption.displayName)")
        } else if let status {
            parts.append("Status: \(status.displayName)")
        }
        if let priorityOption {
            parts.append("Priority: \(priorityOption.displayName)")
        } else if let priority {
            parts.append("Priority: \(priority.displayName)")
        }
        if let assignee {
            switch assignee {
            case .clear:
                parts.append("Assignee: Unassigned")
            case .set(let option):
                parts.append("Assignee: \(option.displayName)")
            }
        }
        return parts.isEmpty ? "No local changes captured." : parts.joined(separator: "\n")
    }
}
