import Foundation

final class YouTrackIssueBoardRepository: IssueBoardRepository, Sendable {
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
        self.init(client: YouTrackAPIClient(configuration: configuration, session: session, monitor: monitor))
    }

    func fetchBoards() async throws -> [IssueBoard] {
        let baseFields = Self.agileFieldsBase
        let fieldCandidates = [
            "\(baseFields),favorite"
        ]

        var lastError: Error?

        for fields in fieldCandidates {
            do {
                return try await fetchBoards(fields: fields)
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

    private func fetchBoards(fields: String) async throws -> [IssueBoard] {
        let pageSize = 42
        var skip = 0
        var allBoards: [YouTrackAgileBoard] = []

        while true {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "fields", value: fields),
                URLQueryItem(name: "\u{24}top", value: String(pageSize)),
                URLQueryItem(name: "\u{24}skip", value: String(skip))
            ]

            let data = try await client.get(path: "agiles", queryItems: queryItems)
            let page = try decoder.decode([YouTrackAgileBoard].self, from: data)
            allBoards.append(contentsOf: page)

            if page.count < pageSize {
                break
            }
            skip += pageSize
        }

        return mapBoards(allBoards)
    }

    private func mapBoards(_ boards: [YouTrackAgileBoard]) -> [IssueBoard] {
        boards
            .map { board in
                let isFavorite = board.favorite ?? board.isFavorite ?? board.isStarred ?? false
                let projectNames = board.projects?.compactMap { $0.shortName ?? $0.name } ?? []
                let columnFieldName = board.columnSettings?.field?.resolvedName
                let columns = mapColumns(from: board.columnSettings)
                let swimlaneSettings = mapSwimlaneSettings(from: board.swimlaneSettings)
                return IssueBoard(
                    id: board.id,
                    name: board.name,
                    isFavorite: isFavorite,
                    projectNames: projectNames,
                    columnFieldName: columnFieldName,
                    columns: columns,
                    swimlaneSettings: swimlaneSettings,
                    orphansAtTheTop: board.orphansAtTheTop ?? false,
                    hideOrphansSwimlane: board.hideOrphansSwimlane ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func mapColumns(from settings: YouTrackAgileBoard.ColumnSettings?) -> [IssueBoardColumn] {
        guard let columns = settings?.columns else { return [] }
        return columns
            .sorted { (left, right) in
                let leftOrdinal = left.ordinal ?? Int.max
                let rightOrdinal = right.ordinal ?? Int.max
                if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
                return (left.presentation ?? "").localizedCaseInsensitiveCompare(right.presentation ?? "") == .orderedAscending
            }
            .compactMap { column in
                let valueNames = column.fieldValues?.compactMap { $0.resolvedName } ?? []
                let presentation = column.presentation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = presentation.isEmpty ? valueNames.joined(separator: ", ") : presentation
                guard !title.isEmpty else { return nil }
                return IssueBoardColumn(
                    id: column.id ?? UUID().uuidString,
                    title: title,
                    valueNames: valueNames,
                    isResolved: column.isResolved ?? false,
                    ordinal: column.ordinal,
                    parentID: column.parent?.id
                )
            }
    }

    private func mapSwimlaneSettings(from settings: YouTrackAgileBoard.SwimlaneSettings?) -> IssueBoardSwimlaneSettings {
        guard let settings, settings.enabled == true else { return .disabled }
        let fieldName = settings.field?.resolvedName
        let values = settings.values?.compactMap { $0.resolvedName } ?? []
        let kind = IssueBoardSwimlaneSettings.Kind(from: settings.typeName)
        return IssueBoardSwimlaneSettings(
            kind: kind,
            isEnabled: settings.enabled ?? false,
            fieldName: fieldName,
            values: values
        )
    }
}

private struct YouTrackAgileBoard: Decodable {
    let id: String
    let name: String
    let favorite: Bool?
    let isFavorite: Bool?
    let isStarred: Bool?
    let projects: [Project]?
    let orphansAtTheTop: Bool?
    let hideOrphansSwimlane: Bool?
    let columnSettings: ColumnSettings?
    let swimlaneSettings: SwimlaneSettings?

    struct Project: Decodable {
        let name: String?
        let shortName: String?
    }

    struct Field: Decodable {
        let name: String?
        let localizedName: String?

        var resolvedName: String? {
            name ?? localizedName
        }
    }

    struct FieldValue: Decodable {
        let id: String?
        let name: String?
        let localizedName: String?
        let isResolved: Bool?

        var resolvedName: String? {
            name ?? localizedName
        }
    }

    struct ColumnSettings: Decodable {
        let field: Field?
        let columns: [Column]?
    }

    struct Column: Decodable {
        let id: String?
        let presentation: String?
        let isResolved: Bool?
        let ordinal: Int?
        let parent: ColumnParent?
        let fieldValues: [FieldValue]?
    }

    struct ColumnParent: Decodable {
        let id: String?
    }

    struct SwimlaneSettings: Decodable {
        let typeName: String?
        let enabled: Bool?
        let field: Field?
        let values: [FieldValue]?

        enum CodingKeys: String, CodingKey {
            case typeName = "$type"
            case enabled
            case field
            case values
        }
    }
}

private extension YouTrackIssueBoardRepository {
    static let agileFieldsBase: String = [
        "id",
        "name",
        "owner(id,login,fullName,avatarUrl)",
        "visibleFor(id,name)",
        "visibleForProjectBased",
        "updateableBy(id,name)",
        "updateableByProjectBased",
        "readSharingSettings(id,permittedGroups(id,name),permittedUsers(id,login,fullName,avatarUrl))",
        "updateSharingSettings(id,permittedGroups(id,name),permittedUsers(id,login,fullName,avatarUrl))",
        "orphansAtTheTop",
        "hideOrphansSwimlane",
        "estimationField(id,name,localizedName)",
        "originalEstimationField(id,name,localizedName)",
        "projects(id,name,shortName,archived)",
        "sprints(id,name,goal,start,finish,archived,isDefault,unresolvedIssuesCount)",
        "currentSprint(id,name,goal,start,finish,archived,isDefault,unresolvedIssuesCount)",
        "columnSettings(id,field(id,name,localizedName),columns(id,presentation,isResolved,ordinal,wipLimit(id,min,max),parent(id),fieldValues(id,name,localizedName,isResolved)))",
        "swimlaneSettings($type,id,enabled,field(id,name,localizedName),values(id,name,localizedName))",
        "sprintsSettings(id,isExplicit,cardOnSeveralSprints,defaultSprint(id,name),disableSprints,explicitQuery,sprintSyncField(id,name,localizedName),hideSubtasksOfCards)",
        "colorCoding(id)",
        "status(id,valid,hasJobs,errors,warnings)"
    ].joined(separator: ",")
}
