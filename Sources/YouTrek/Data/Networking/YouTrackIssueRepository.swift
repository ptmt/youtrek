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
        var lastError: Error?
        for fields in Self.issueListFieldCandidates {
            do {
                return try await fetchIssues(query: query, queryString: queryString, fields: fields)
            } catch let error as YouTrackAPIError {
                if case .http(let statusCode, _) = error, statusCode == 400 {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? YouTrackAPIError.invalidResponse
    }

    private func fetchIssues(query: IssueQuery, queryString: String?, fields: String) async throws -> [IssueSummary] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: fields),
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

    func fetchSprintIssueIDs(agileID: String, sprintID: String) async throws -> [String] {
        let trimmedAgileID = agileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSprintID = sprintID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgileID.isEmpty, !trimmedSprintID.isEmpty else {
            return []
        }

        let queryItems = [
            URLQueryItem(name: "fields", value: "issues(idReadable)")
        ]
        let data = try await client.get(path: "agiles/\(trimmedAgileID)/sprints/\(trimmedSprintID)", queryItems: queryItems)
        let sprint = try decoder.decode(YouTrackSprintIssues.self, from: data)
        let ids = sprint.issues?.compactMap { $0.idReadable?.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        return ids.filter { !$0.isEmpty }
    }

    func fetchIssueDetail(issue: IssueSummary) async throws -> IssueDetail {
        let identifier = issue.readableID
        let data = try await client.get(
            path: "issues/\(identifier)",
            queryItems: [URLQueryItem(name: "fields", value: Self.issueDetailFields)]
        )
        let detail = try decoder.decode(YouTrackIssue.self, from: data)
        return mapIssueDetail(detail, fallback: issue)
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
        let draftFields = draft.customFields
        let draftFieldNames = Set(draftFields.map { $0.normalizedName })
        customFields.append(contentsOf: draftFields.compactMap { IssueCreatePayload.CustomField.from(draftField: $0) })

        if !draftFieldNames.contains("priority") {
            customFields.append(.priority(draft.priority))
        }

        let moduleValue = draft.module?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let moduleValue, !moduleValue.isEmpty, !draftFieldNames.contains("subsystem"), !draftFieldNames.contains("module") {
            customFields.append(.module(moduleValue))
        }

        let assigneeValue = draft.assigneeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assigneeValue, !assigneeValue.isEmpty, !draftFieldNames.contains("assignee") {
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
            queryItems: [URLQueryItem(name: "fields", value: Self.issueListFieldsBase)],
            body: body
        )
        let issue = try decoder.decode(YouTrackIssue.self, from: response)
        return mapIssue(issue)
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        let readableID = patch.issueReadableID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !readableID.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing issue identifier for update")
        }

        var customFields: [IssueUpdatePayload.CustomField] = []
        if let status = patch.status {
            customFields.append(.status(status))
        }
        if let priority = patch.priority {
            customFields.append(.priority(priority))
        }
        if let assignee = patch.assignee {
            switch assignee {
            case .clear:
                customFields.append(.clearAssignee())
            case .set(let option):
                customFields.append(.assignee(option))
            }
        }

        let trimmedTitle = patch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = patch.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = IssueUpdatePayload(
            summary: trimmedTitle?.isEmpty == false ? trimmedTitle : nil,
            description: trimmedDescription?.isEmpty == false ? trimmedDescription : nil,
            customFields: customFields.isEmpty ? nil : customFields
        )
        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)
        let response = try await client.post(
            path: "issues/\(readableID)",
            queryItems: [URLQueryItem(name: "fields", value: Self.issueListFieldsBase)],
            body: body
        )
        let issue = try decoder.decode(YouTrackIssue.self, from: response)
        return mapIssue(issue)
    }

    func addComment(issueReadableID: String, text: String) async throws -> IssueComment {
        let readableID = issueReadableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readableID.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing issue identifier for comment")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing comment text")
        }

        let payload = IssueCommentPayload(text: trimmedText)
        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)
        let response = try await client.post(
            path: "issues/\(readableID)/comments",
            queryItems: [URLQueryItem(name: "fields", value: Self.issueCommentFields)],
            body: body
        )
        let comment = try decoder.decode(YouTrackComment.self, from: response)
        return mapComment(comment, fallbackText: trimmedText)
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
            guard let displayName = value.displayName ?? value.fullName ?? value.login ?? value.id else { return nil }
            let avatarURL = value.avatarUrl.flatMap(URL.init(string:))
            let identifier = value.compositeIdentifier.isEmpty ? displayName : value.compositeIdentifier
            return Person(
                id: Person.stableID(for: identifier),
                displayName: displayName,
                avatarURL: avatarURL,
                login: value.login,
                remoteID: value.id
            )
        }

        let reporter = issue.reporter.flatMap { user -> Person? in
            guard let displayName = user.displayName else { return nil }
            let avatarURL = user.avatarUrl.flatMap(URL.init(string:))
            let identifier = user.compositeIdentifier.isEmpty ? displayName : user.compositeIdentifier
            return Person(
                id: Person.stableID(for: identifier),
                displayName: displayName,
                avatarURL: avatarURL,
                login: user.login,
                remoteID: user.id
            )
        }

        let statusName = statusField?.value.firstValue?.name
            ?? statusField?.value.firstValue?.localizedName
            ?? statusField?.value.firstValue?.resolvedName
        let status = IssueStatus.from(apiName: statusName)
        let priority = priorityField?.value.firstValue?.name.flatMap(IssuePriority.init(apiName:)) ?? .normal
        let tags = issue.tags?.compactMap { $0.name } ?? []
        var customFieldValues = extractCustomFieldValues(from: customFields)
        if let sprintValues = issue.sprints?
            .compactMap({ $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }),
           !sprintValues.isEmpty {
            addCustomFieldValues(&customFieldValues, key: "sprint", values: sprintValues)
            addCustomFieldValues(&customFieldValues, key: "sprints", values: sprintValues)
        }

        return IssueSummary(
            id: Person.stableID(for: issue.idReadable),
            readableID: issue.idReadable,
            title: issue.summary,
            projectName: projectName,
            updatedAt: updatedDate,
            assignee: assignee,
            reporter: reporter,
            priority: priority,
            status: status,
            tags: tags,
            customFieldValues: customFieldValues
        )
    }

    private func addCustomFieldValues(
        _ values: inout [String: [String]],
        key: String,
        values newValues: [String]
    ) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKey.isEmpty else { return }
        let existing = values[normalizedKey] ?? []
        var merged = existing
        for value in newValues {
            if !merged.contains(value) {
                merged.append(value)
            }
        }
        values[normalizedKey] = merged
    }

    private func mapIssueDetail(_ issue: YouTrackIssue, fallback: IssueSummary) -> IssueDetail {
        let updatedDate = issue.updated.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? fallback.updatedAt
        let createdDate = issue.created.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        let reporter = issue.reporter.flatMap { user -> Person? in
            guard let displayName = user.displayName else { return nil }
            let avatarURL = user.avatarUrl.flatMap(URL.init(string:))
            let identifier = user.compositeIdentifier.isEmpty ? displayName : user.compositeIdentifier
            return Person(
                id: Person.stableID(for: identifier),
                displayName: displayName,
                avatarURL: avatarURL,
                login: user.login,
                remoteID: user.id
            )
        }
        let comments = issue.comments?.compactMap { comment -> IssueComment? in
            guard let id = comment.id else { return nil }
            let createdAt = comment.created.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? updatedDate
            let author = comment.author.flatMap { user -> Person? in
                guard let displayName = user.displayName else { return nil }
                let avatarURL = user.avatarUrl.flatMap(URL.init(string:))
                let identifier = user.compositeIdentifier.isEmpty ? displayName : user.compositeIdentifier
                return Person(
                    id: Person.stableID(for: identifier),
                    displayName: displayName,
                    avatarURL: avatarURL,
                    login: user.login,
                    remoteID: user.id
                )
            }
            return IssueComment(
                id: id,
                author: author,
                createdAt: createdAt,
                text: comment.text ?? ""
            )
        } ?? []

        return IssueDetail(
            id: fallback.id,
            readableID: issue.idReadable,
            title: issue.summary,
            description: issue.description,
            reporter: reporter ?? fallback.reporter,
            createdAt: createdDate,
            updatedAt: updatedDate,
            comments: comments
        )
    }

    private func mapComment(_ comment: YouTrackComment, fallbackText: String) -> IssueComment {
        let createdAt = comment.created.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? Date()
        let author = comment.author.flatMap { user -> Person? in
            guard let displayName = user.displayName else { return nil }
            let avatarURL = user.avatarUrl.flatMap(URL.init(string:))
            let identifier = user.compositeIdentifier.isEmpty ? displayName : user.compositeIdentifier
            return Person(
                id: Person.stableID(for: identifier),
                displayName: displayName,
                avatarURL: avatarURL,
                login: user.login,
                remoteID: user.id
            )
        }
        let resolvedID = comment.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (resolvedID?.isEmpty == false) ? resolvedID! : UUID().uuidString
        let text = comment.text ?? fallbackText
        return IssueComment(
            id: id,
            author: author,
            createdAt: createdAt,
            text: text
        )
    }

}

private extension YouTrackIssueRepository {
    static let issueListFieldsBase = [
        "id",
        "idReadable",
        "summary",
        "project(shortName,name)",
        "updated",
        "customFields($type,name,value(id,name,localizedName,fullName,login,avatarUrl))",
        "reporter(id,login,fullName,avatarUrl)",
        "tags(name)"
    ].joined(separator: ",")

    static let issueListFieldsWithSprints = [
        issueListFieldsBase,
        "sprints(id,name)"
    ].joined(separator: ",")

    static let issueListFieldCandidates = [
        issueListFieldsWithSprints,
        issueListFieldsBase
    ]

    static let issueDetailFields = [
        "id",
        "idReadable",
        "summary",
        "description",
        "created",
        "updated",
        "reporter(id,login,fullName,avatarUrl)",
        "comments(id,text,created,author(id,login,fullName,avatarUrl))"
    ].joined(separator: ",")

    static let issueCommentFields = [
        "id",
        "text",
        "created",
        "author(id,login,fullName,avatarUrl)"
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

// MARK: - API DTOs

private struct YouTrackIssue: Decodable {
    let id: String
    let idReadable: String
    let summary: String
    let project: Project?
    let description: String?
    let created: Int?
    let updated: Int?
    let reporter: User?
    let comments: [Comment]?
    let customFields: [CustomField]?
    let tags: [Tag]?
    let sprints: [Sprint]?

    struct Project: Decodable {
        let name: String?
        let shortName: String?
    }

    struct Tag: Decodable {
        let name: String?
    }

    struct Sprint: Decodable {
        let id: String?
        let name: String?
    }

    struct Comment: Decodable {
        let id: String?
        let text: String?
        let created: Int?
        let author: User?
    }

    struct User: Decodable {
        let id: String?
        let login: String?
        let fullName: String?
        let avatarUrl: String?

        var displayName: String? {
            fullName ?? login ?? id
        }

        var compositeIdentifier: String {
            [id, login, fullName].compactMap { $0 }.joined(separator: "|")
        }
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

private struct YouTrackSprintIssues: Decodable {
    let issues: [IssueRef]?

    struct IssueRef: Decodable {
        let idReadable: String?
    }
}

private struct YouTrackComment: Decodable {
    let id: String?
    let text: String?
    let created: Int?
    let author: User?

    struct User: Decodable {
        let id: String?
        let login: String?
        let fullName: String?
        let avatarUrl: String?

        var displayName: String? {
            fullName ?? login ?? id
        }

        var compositeIdentifier: String {
            [id, login, fullName].compactMap { $0 }.joined(separator: "|")
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
                value: .option(OptionPayload(name: priority.displayName))
            )
        }

        static func assignee(_ identifier: String) -> CustomField {
            CustomField(
                typeName: "SingleUserIssueCustomField",
                name: "Assignee",
                value: .option(OptionPayload(identifier: identifier))
            )
        }

        static func module(_ module: String) -> CustomField {
            CustomField(
                typeName: "SingleOwnedIssueCustomField",
                name: "Subsystem",
                value: .option(OptionPayload(name: module))
            )
        }

        static func from(draftField: IssueDraftField) -> CustomField? {
            guard let value = CustomFieldValue.from(draftField: draftField) else { return nil }
            return CustomField(
                typeName: draftField.kind.issueCustomFieldTypeName(allowsMultiple: draftField.allowsMultiple),
                name: draftField.name,
                value: value
            )
        }
    }

    enum CustomFieldValue: Encodable {
        case option(OptionPayload)
        case options([OptionPayload])
        case string(String)
        case text(String)
        case integer(Int)
        case float(Double)
        case bool(Bool)
        case date(Date)
        case period(minutes: Int)

        static func from(draftField: IssueDraftField) -> CustomFieldValue? {
            let value = draftField.value
            guard !value.isEmpty else { return nil }

            switch draftField.kind {
            case .enumeration, .state, .version, .build, .ownedField:
                if draftField.allowsMultiple {
                    let options = value.optionValues.map(OptionPayload.init(option:))
                    return options.isEmpty ? nil : .options(options)
                } else if let option = value.optionValue {
                    return .option(OptionPayload(option: option))
                } else if let string = value.stringValue {
                    return .option(OptionPayload(name: string))
                }
                return nil
            case .user:
                if draftField.allowsMultiple {
                    let options = value.optionValues.map(OptionPayload.init(option:))
                    return options.isEmpty ? nil : .options(options)
                } else if let option = value.optionValue {
                    return .option(OptionPayload(option: option))
                } else if let string = value.stringValue {
                    return .option(OptionPayload(identifier: string))
                }
                return nil
            case .string:
                guard let string = value.stringValue else { return nil }
                return .string(string)
            case .text:
                guard let string = value.stringValue else { return nil }
                return .text(string)
            case .integer:
                guard let number = value.intValue else { return nil }
                return .integer(number)
            case .float:
                guard let number = value.doubleValue else { return nil }
                return .float(number)
            case .boolean:
                guard let flag = value.boolValue else { return nil }
                return .bool(flag)
            case .date, .dateTime:
                guard let date = value.dateValue else { return nil }
                return .date(date)
            case .period:
                guard let minutes = value.intValue else { return nil }
                return .period(minutes: minutes)
            case .unknown:
                guard let string = value.stringValue else { return nil }
                return .string(string)
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .option(let payload):
                try payload.encode(to: encoder)
            case .options(let payloads):
                try payloads.encode(to: encoder)
            case .string(let value), .text(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .integer(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .float(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .bool(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .date(let value):
                var container = encoder.singleValueContainer()
                let milliseconds = Int64(value.timeIntervalSince1970 * 1000.0)
                try container.encode(milliseconds)
            case .period(let minutes):
                try PeriodPayload(minutes: minutes).encode(to: encoder)
            }
        }
    }

    struct OptionPayload: Encodable {
        let id: String?
        let name: String?
        let login: String?

        init(id: String? = nil, name: String? = nil, login: String? = nil) {
            self.id = id
            self.name = name
            self.login = login
        }

        init(name: String) {
            self.init(id: nil, name: name, login: nil)
        }

        init(identifier: String) {
            if identifier.isLikelyYouTrackID {
                self.init(id: identifier, name: nil, login: nil)
            } else {
                self.init(id: nil, name: nil, login: identifier)
            }
        }

        init(option: IssueFieldOption) {
            let trimmedName = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                id: option.id.isEmpty ? nil : option.id,
                name: trimmedName.isEmpty ? option.displayName : trimmedName,
                login: option.login
            )
        }
    }

    struct PeriodPayload: Encodable {
        let minutes: Int
    }
}

private struct IssueCommentPayload: Encodable {
    let text: String
}

private struct IssueUpdatePayload: Encodable {
    let summary: String?
    let description: String?
    let customFields: [CustomField]?

    struct CustomField: Encodable {
        let typeName: String
        let name: String
        let value: CustomFieldValue

        enum CodingKeys: String, CodingKey {
            case typeName = "$type"
            case name
            case value
        }

        static func status(_ status: IssueStatus) -> CustomField {
            CustomField(
                typeName: "StateIssueCustomField",
                name: "State",
                value: .option(OptionPayload(name: status.displayName))
            )
        }

        static func priority(_ priority: IssuePriority) -> CustomField {
            CustomField(
                typeName: "SingleEnumIssueCustomField",
                name: "Priority",
                value: .option(OptionPayload(name: priority.displayName))
            )
        }

        static func assignee(_ option: IssueFieldOption) -> CustomField {
            CustomField(
                typeName: "SingleUserIssueCustomField",
                name: "Assignee",
                value: .option(OptionPayload(option: option))
            )
        }

        static func clearAssignee() -> CustomField {
            CustomField(
                typeName: "SingleUserIssueCustomField",
                name: "Assignee",
                value: .clear
            )
        }
    }

    enum CustomFieldValue: Encodable {
        case option(OptionPayload)
        case clear

        func encode(to encoder: Encoder) throws {
            switch self {
            case .option(let payload):
                try payload.encode(to: encoder)
            case .clear:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }

    struct OptionPayload: Encodable {
        let id: String?
        let name: String?
        let login: String?

        init(id: String? = nil, name: String? = nil, login: String? = nil) {
            self.id = id
            self.name = name
            self.login = login
        }

        init(name: String) {
            self.init(id: nil, name: name, login: nil)
        }

        init(identifier: String) {
            if identifier.isLikelyYouTrackID {
                self.init(id: identifier, name: nil, login: nil)
            } else {
                self.init(id: nil, name: nil, login: identifier)
            }
        }

        init(option: IssueFieldOption) {
            let trimmedName = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                id: option.id.isEmpty ? nil : option.id,
                name: trimmedName.isEmpty ? option.displayName : trimmedName,
                login: option.login
            )
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
