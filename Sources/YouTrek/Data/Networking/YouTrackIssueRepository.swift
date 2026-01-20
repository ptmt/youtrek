import Foundation

final class YouTrackIssueRepository: IssueRepository, Sendable {
    private let client: YouTrackAPIClient
    private let decoder: JSONDecoder

    init(client: YouTrackAPIClient, decoder: JSONDecoder = YouTrackIssueRepository.makeDecoder()) {
        self.client = client
        self.decoder = decoder
    }

    convenience init(
        configuration: YouTrackAPIConfiguration,
        session: URLSession = .shared,
        monitor: NetworkRequestMonitor? = nil
    ) {
        self.init(client: YouTrackAPIClient(configuration: configuration, session: session, monitor: monitor))
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
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = draft.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedProject.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing required issue fields.")
        }

        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = IssueCreatePayload.ProjectReference.from(identifier: trimmedProject)

        var customFields: [IssueCreatePayload.CustomField] = []
        customFields.append(.priority(draft.priority))

        let moduleValue = draft.module?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let moduleValue, !moduleValue.isEmpty {
            customFields.append(.module(moduleValue))
        }

        let assigneeValue = draft.assigneeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assigneeValue, !assigneeValue.isEmpty {
            customFields.append(.assignee(assigneeValue))
        }

        let payload = IssueCreatePayload(
            summary: trimmedTitle,
            description: description.isEmpty ? nil : description,
            project: project,
            customFields: customFields.isEmpty ? nil : customFields
        )

        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)
        let response = try await client.post(
            path: "issues",
            queryItems: [URLQueryItem(name: "fields", value: Self.issueListFields)],
            body: body
        )
        let issue = try decoder.decode(YouTrackIssue.self, from: response)
        return mapIssue(issue)
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
        let customFieldValues = extractCustomFieldValues(from: customFields)

        return IssueSummary(
            id: makeStableIdentifier(for: issue.idReadable),
            readableID: issue.idReadable,
            title: issue.summary,
            projectName: projectName,
            updatedAt: updatedDate,
            assignee: assignee,
            priority: priority,
            status: status,
            tags: tags,
            customFieldValues: customFieldValues
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
        if let raw = query.rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }

        var parts: [String] = []

        let trimmedSearch = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            parts.append(trimmedSearch)
        }

        let filterParts = query.filters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        parts.append(contentsOf: filterParts)

        if let sort = query.sort {
            switch sort {
            case .updated(let descending):
                parts.append("sort by: updated \(descending ? "desc" : "asc")")
            case .priority(let descending):
                parts.append("sort by: priority \(descending ? "desc" : "asc")")
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    func extractCustomFieldValues(from fields: [YouTrackIssue.CustomField]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        result.reserveCapacity(fields.count)
        for field in fields {
            let key = field.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            let values = field.value.displayNames
            if !values.isEmpty {
                result[key] = values
            }
        }
        return result
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

                var resolvedName: String? {
                    displayName ?? login ?? id
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

            var displayNames: [String] {
                let values: [Value]
                switch self {
                case .none:
                    values = []
                case .object(let value):
                    values = [value]
                case .array(let array):
                    values = array
                }
                return values.compactMap { $0.resolvedName }
            }
        }
    }
}

private struct IssueCreatePayload: Encodable {
    let summary: String
    let description: String?
    let project: ProjectReference
    let customFields: [CustomField]?

    struct ProjectReference: Encodable {
        let id: String?
        let shortName: String?

        static func from(identifier: String) -> ProjectReference {
            if identifier.isLikelyYouTrackID {
                return ProjectReference(id: identifier, shortName: nil)
            }
            return ProjectReference(id: nil, shortName: identifier)
        }
    }

    struct CustomField: Encodable {
        let typeName: String
        let name: String
        let value: CustomFieldValue

        enum CodingKeys: String, CodingKey {
            case typeName = "$type"
            case name
            case value
        }

        static func priority(_ priority: IssuePriority) -> CustomField {
            CustomField(
                typeName: "SingleEnumIssueCustomField",
                name: "Priority",
                value: CustomFieldValue(name: priority.displayName)
            )
        }

        static func assignee(_ identifier: String) -> CustomField {
            CustomField(
                typeName: "SingleUserIssueCustomField",
                name: "Assignee",
                value: CustomFieldValue(userIdentifier: identifier)
            )
        }

        static func module(_ module: String) -> CustomField {
            CustomField(
                typeName: "SingleOwnedIssueCustomField",
                name: "Subsystem",
                value: CustomFieldValue(name: module)
            )
        }
    }

    struct CustomFieldValue: Encodable {
        let id: String?
        let name: String?
        let login: String?

        init(id: String? = nil, name: String? = nil, login: String? = nil) {
            self.id = id
            self.name = name
            self.login = login
        }

        init(userIdentifier: String) {
            if userIdentifier.isLikelyYouTrackID {
                self.init(id: userIdentifier)
            } else {
                self.init(login: userIdentifier)
            }
        }
    }
}

private extension String {
    var isLikelyYouTrackID: Bool {
        let parts = split(separator: "-")
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
