import Foundation

final class YouTrackIssueRepository: IssueRepository, Sendable {
    private let client: YouTrackAPIClient
    private let decoder: JSONDecoder

    init(client: YouTrackAPIClient, decoder: JSONDecoder = YouTrackIssueRepository.makeDecoder()) {
        self.client = client
        self.decoder = decoder
    }

    convenience init(configuration: YouTrackAPIConfiguration, session: URLSession = .shared) {
        self.init(client: YouTrackAPIClient(configuration: configuration, session: session))
    }

    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        let queryString = buildQueryString(from: query)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: Self.issueListFields),
            URLQueryItem(name: "\u{24}top", value: String(query.page.size)),
            URLQueryItem(name: "\u{24}skip", value: String(query.page.offset))
        ]
        if let queryString {
            queryItems.append(URLQueryItem(name: "query", value: queryString))
        }

        let data = try await client.get(path: "issues", queryItems: queryItems)
        let issues = try decoder.decode([YouTrackIssue].self, from: data)
        return issues.map(mapIssue(_:))
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Issue creation not yet implemented")
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Issue update not yet implemented")
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func mapIssue(_ issue: YouTrackIssue) -> IssueSummary {
        let projectName = issue.project?.shortName ?? issue.project?.name ?? "Unknown"
        let updatedDate = issue.updated.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? .now
        let customFields = issue.customFields ?? []

        let assigneeField = customFields.first { $0.name.caseInsensitiveCompare("Assignee") == .orderedSame }
        let statusField = customFields.first { field in
            field.name.caseInsensitiveCompare("State") == .orderedSame || field.name.caseInsensitiveCompare("Status") == .orderedSame
        }
        let priorityField = customFields.first { $0.name.caseInsensitiveCompare("Priority") == .orderedSame }

        let assignee = assigneeField?.value.firstValue.flatMap { value -> Person? in
            guard let displayName = value.displayName else { return nil }
            let avatarURL = value.avatarUrl.flatMap(URL.init(string:))
            let identifier = value.compositeIdentifier.isEmpty ? displayName : value.compositeIdentifier
            return Person(id: makeStableIdentifier(for: identifier), displayName: displayName, avatarURL: avatarURL)
        }

        let status = statusField?.value.firstValue?.name.flatMap(IssueStatus.init(apiName:)) ?? .open
        let priority = priorityField?.value.firstValue?.name.flatMap(IssuePriority.init(apiName:)) ?? .normal
        let tags = issue.tags?.compactMap { $0.name } ?? []

        return IssueSummary(
            id: makeStableIdentifier(for: issue.idReadable),
            readableID: issue.idReadable,
            title: issue.summary,
            projectName: projectName,
            updatedAt: updatedDate,
            assignee: assignee,
            priority: priority,
            status: status,
            tags: tags
        )
    }

    private func makeStableIdentifier(for source: String) -> UUID {
        var hashBytes = [UInt8](repeating: 0, count: 16)
        let data = Array(source.utf8)
        for (index, byte) in data.enumerated() {
            hashBytes[index % 16] = hashBytes[index % 16] &+ byte &+ UInt8(index % 7)
        }
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }
}

private extension YouTrackIssueRepository {
    static let issueListFields = [
        "id",
        "idReadable",
        "summary",
        "project(shortName,name)",
        "updated",
        "customFields($type,name,value(id,name,localizedName,fullName,login,avatarUrl))",
        "tags(name)"
    ].joined(separator: ",")

    func buildQueryString(from query: IssueQuery) -> String? {
        var parts: [String] = []

        let trimmedSearch = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            parts.append(trimmedSearch)
        }

        let filterParts = query.filters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        parts.append(contentsOf: filterParts)

        switch query.sort {
        case .updated(let descending):
            parts.append("sort by: updated \(descending ? "desc" : "asc")")
        case .priority(let descending):
            parts.append("sort by: priority \(descending ? "desc" : "asc")")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
}

private extension IssuePriority {
    init?(apiName: String) {
        let normalized = apiName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "show-stopper", "showstopper", "critical", "blocker": self = .critical
        case "major", "high", "important": self = .high
        case "normal", "medium", "default": self = .normal
        case "minor", "low", "trivial": self = .low
        default:
            return nil
        }
    }
}

private extension IssueStatus {
    init?(apiName: String) {
        let normalized = apiName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "open", "new", "to do": self = .open
        case "in progress", "doing", "implementation": self = .inProgress
        case "in review", "code review", "qa", "testing": self = .inReview
        case "blocked", "on hold", "stuck": self = .blocked
        case "done", "fixed", "resolved", "closed", "completed": self = .done
        default:
            return nil
        }
    }
}

// MARK: - API DTOs

private struct YouTrackIssue: Decodable {
    let id: String
    let idReadable: String
    let summary: String
    let project: Project?
    let updated: Int?
    let customFields: [CustomField]?
    let tags: [Tag]?

    struct Project: Decodable {
        let name: String?
        let shortName: String?
    }

    struct Tag: Decodable {
        let name: String?
    }

    struct CustomField: Decodable {
        let typeName: String?
        let name: String
        let value: FieldValue

        enum CodingKeys: String, CodingKey {
            case typeName = "$type"
            case name
            case value
        }

        enum FieldValue: Decodable {
            case none
            case object(Value)
            case array([Value])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() {
                    self = .none
                } else if let array = try? container.decode([Value].self) {
                    self = .array(array)
                } else if let object = try? container.decode(Value.self) {
                    self = .object(object)
                } else {
                    self = .none
                }
            }

            struct Value: Decodable {
                let id: String?
                let name: String?
                let localizedName: String?
                let fullName: String?
                let login: String?
                let avatarUrl: String?

                var displayName: String? {
                    name ?? localizedName ?? fullName
                }

                var compositeIdentifier: String {
                    [id, login, name, fullName].compactMap { $0 }.joined(separator: "|")
                }
            }

            var firstValue: Value? {
                switch self {
                case .none:
                    return nil
                case .object(let value):
                    return value
                case .array(let values):
                    return values.first
                }
            }
        }
    }
}
