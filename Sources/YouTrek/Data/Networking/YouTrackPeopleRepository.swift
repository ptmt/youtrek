import Foundation

final class YouTrackPeopleRepository: PeopleRepository, Sendable {
    private let client: YouTrackAPIClient
    private let decoder: JSONDecoder

    init(client: YouTrackAPIClient, decoder: JSONDecoder = JSONDecoder()) {
        self.client = client
        self.decoder = decoder
    }

    convenience init(
        configuration: YouTrackAPIConfiguration,
        session: URLSession = .shared,
        monitor: NetworkRequestMonitor? = nil
    ) {
        let client = YouTrackAPIClient(configuration: configuration, session: session, monitor: monitor)
        self.init(client: client)
    }

    func fetchPeople(query: String?, projectID: String?) async throws -> [IssueFieldOption] {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedProjectID.isEmpty {
            if let projectAssignees = try await fetchProjectAssignees(projectID: trimmedProjectID) {
                return filterPeople(sortedPeople(projectAssignees), matching: trimmedQuery)
            }
            return []
        }

        let data = try await client.get(path: "users", queryItems: peopleQueryItems(query: trimmedQuery))
        let users = try decoder.decode([YouTrackUser].self, from: data)
        return sortedPeople(users.compactMap(Self.option(from:)))
    }
}

private extension YouTrackPeopleRepository {
    func fetchProjectAssignees(projectID: String) async throws -> [IssueFieldOption]? {
        let data = try await client.get(
            path: "admin/projects/\(projectID)/customFields",
            queryItems: [URLQueryItem(name: "fields", value: Self.projectFieldFields)]
        )
        let fields = try decoder.decode([YouTrackProjectCustomField].self, from: data)
        guard let bundleID = Self.assigneeBundleID(in: fields) else {
            return nil
        }

        let bundleData = try await client.get(
            path: "admin/customFieldSettings/bundles/user/\(bundleID)",
            queryItems: [URLQueryItem(name: "fields", value: Self.userBundleFields)]
        )
        let bundle = try decoder.decode(YouTrackUserBundle.self, from: bundleData)
        return (bundle.values ?? []).compactMap(Self.option(from:))
    }

    func peopleQueryItems(query: String) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: "id,login,name,fullName,avatarUrl"),
            URLQueryItem(name: "\u{24}top", value: "100"),
            URLQueryItem(name: "\u{24}skip", value: "0")
        ]
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        return queryItems
    }

    func sortedPeople(_ options: [IssueFieldOption]) -> [IssueFieldOption] {
        options.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func filterPeople(_ options: [IssueFieldOption], matching query: String) -> [IssueFieldOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return options }

        return options.filter { option in
            [option.displayName, option.name, option.login ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    static func assigneeBundleID(in fields: [YouTrackProjectCustomField]) -> String? {
        let candidates = fields.compactMap { field -> AssigneeFieldCandidate? in
            let kind = IssueFieldKind.from(
                kind: field.field?.fieldType?.kind,
                valueType: field.field?.fieldType?.valueType,
                fieldTypeID: field.field?.fieldType?.id
            )
            guard kind.usesPeople else { return nil }

            let bundleID = field.bundle?.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !bundleID.isEmpty else { return nil }

            let names = [field.field?.name, field.field?.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let isMultiValue = field.isMultiValue ?? field.field?.fieldType?.collection ?? false
            return AssigneeFieldCandidate(bundleID: bundleID, names: names, isMultiValue: isMultiValue)
        }

        if let assigneeField = candidates.first(where: { $0.names.contains("assignee") && !$0.isMultiValue }) {
            return assigneeField.bundleID
        }
        return candidates.first(where: { $0.names.contains("assignee") })?.bundleID
    }

    static func option(from user: YouTrackUser) -> IssueFieldOption? {
        let displayName = user.fullName ?? user.name ?? user.login ?? ""
        guard !displayName.isEmpty else { return nil }
        return IssueFieldOption(
            id: user.id ?? user.login ?? displayName,
            name: user.login ?? displayName,
            displayName: displayName,
            login: user.login,
            avatarURL: user.avatarUrl.flatMap(URL.init(string:)),
            ordinal: nil
        )
    }

    static let projectFieldFields = [
        "isMultiValue",
        "bundle(id)",
        "field(name,localizedName,fieldType(id,kind,valueType,collection))"
    ].joined(separator: ",")

    static let userBundleFields = [
        "values(id,login,name,fullName,avatarUrl)"
    ].joined(separator: ",")
}

private struct YouTrackUser: Decodable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?
    let avatarUrl: String?
}

private struct YouTrackProjectCustomField: Decodable {
    let isMultiValue: Bool?
    let bundle: YouTrackFieldBundle?
    let field: YouTrackCustomField?
}

private struct YouTrackFieldBundle: Decodable {
    let id: String?
}

private struct YouTrackCustomField: Decodable {
    let name: String?
    let localizedName: String?
    let fieldType: YouTrackFieldType?
}

private struct YouTrackFieldType: Decodable {
    let id: String?
    let kind: String?
    let valueType: String?
    let collection: Bool?
}

private struct YouTrackUserBundle: Decodable {
    let values: [YouTrackUser]?
}

private struct AssigneeFieldCandidate {
    let bundleID: String
    let names: [String]
    let isMultiValue: Bool
}
