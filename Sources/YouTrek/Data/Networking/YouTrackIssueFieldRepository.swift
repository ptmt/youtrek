import Foundation

final class YouTrackIssueFieldRepository: IssueFieldRepository, Sendable {
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

    func fetchFields(projectID: String) async throws -> [IssueField] {
        let path = "admin/projects/\(projectID)/customFields"
        let queryItems = [
            URLQueryItem(name: "fields", value: Self.projectFieldFields)
        ]

        let data = try await client.get(path: path, queryItems: queryItems)
        let fields = try decoder.decode([YouTrackProjectCustomField].self, from: data)
        return fields.compactMap { field in
            guard let fieldName = field.field?.name, !fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let kind = IssueFieldKind.from(
                kind: field.field?.fieldType?.kind,
                valueType: field.field?.fieldType?.valueType,
                fieldTypeID: field.field?.fieldType?.id
            )
            let options: [IssueFieldOption] = []
            return IssueField(
                id: field.id,
                name: fieldName,
                localizedName: field.field?.localizedName,
                kind: kind,
                isRequired: (field.canBeEmpty == false),
                allowsMultiple: field.isMultiValue ?? field.field?.fieldType?.collection ?? false,
                bundleID: field.bundle?.id,
                options: options,
                ordinal: field.ordinal
            )
        }
    }

    func fetchBundleOptions(bundleID: String, kind: IssueFieldKind) async throws -> [IssueFieldOption] {
        guard let path = kind.bundleEndpoint(bundleID: bundleID) else { return [] }
        let queryItems = [
            URLQueryItem(name: "fields", value: "id,name,values(id,name,localizedName,fullName,login,avatarUrl,ordinal,color(background,foreground))")
        ]

        let data = try await client.get(path: path, queryItems: queryItems)
        let bundle = try decoder.decode(YouTrackBundle.self, from: data)
        let values = bundle.values ?? []
        return values.map { value in
            IssueFieldOption(
                id: value.id,
                name: value.name ?? value.localizedName ?? value.fullName ?? value.login ?? "",
                displayName: value.localizedName ?? value.name ?? value.fullName ?? value.login ?? "",
                login: value.login,
                avatarURL: value.avatarUrl.flatMap(URL.init(string:)),
                ordinal: value.ordinal,
                color: IssueFieldColor(
                    backgroundHex: value.color?.background,
                    foregroundHex: value.color?.foreground
                )
            )
        }
    }
}

private extension IssueFieldKind {
    func bundleEndpoint(bundleID: String) -> String? {
        switch self {
        case .enumeration:
            return "admin/customFieldSettings/bundles/enum/\(bundleID)"
        case .state:
            return "admin/customFieldSettings/bundles/state/\(bundleID)"
        case .version:
            return "admin/customFieldSettings/bundles/version/\(bundleID)"
        case .build:
            return "admin/customFieldSettings/bundles/build/\(bundleID)"
        case .ownedField:
            return "admin/customFieldSettings/bundles/ownedField/\(bundleID)"
        case .user:
            return "admin/customFieldSettings/bundles/user/\(bundleID)"
        default:
            return nil
        }
    }
}

private struct YouTrackProjectCustomField: Decodable {
    let id: String
    let canBeEmpty: Bool?
    let isMultiValue: Bool?
    let ordinal: Int?
    let bundle: YouTrackBundle?
    let field: YouTrackCustomField?
}

private struct YouTrackCustomField: Decodable {
    let name: String?
    let localizedName: String?
    let fieldType: YouTrackCustomFieldType?
}

private struct YouTrackCustomFieldType: Decodable {
    let id: String?
    let kind: String?
    let valueType: String?
    let collection: Bool?
}

private struct YouTrackBundle: Decodable {
    let id: String
    let name: String?
    let values: [YouTrackBundleValue]?
}

private struct YouTrackBundleValue: Decodable {
    let id: String
    let name: String?
    let localizedName: String?
    let fullName: String?
    let login: String?
    let avatarUrl: String?
    let ordinal: Int?
    let color: YouTrackFieldStyle?
}

private struct YouTrackFieldStyle: Decodable {
    let background: String?
    let foreground: String?
}

private extension YouTrackIssueFieldRepository {
    static let projectFieldFields = [
        "id",
        "canBeEmpty",
        "isMultiValue",
        "ordinal",
        "bundle(id,name)",
        "field(name,localizedName,fieldType(id,kind,valueType,collection))"
    ].joined(separator: ",")
}
