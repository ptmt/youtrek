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
        let summaries = try await fetchBoardSummaries()
        let favorites = summaries.filter(\.isFavorite)
        guard !favorites.isEmpty else { return summaries }

        let detailedByID = await fetchFavoriteBoardDetails(for: favorites)
        guard !detailedByID.isEmpty else { return summaries }

        return summaries.map { board in
            guard let detail = detailedByID[board.id] else { return board }
            return applyingFavorite(board.isFavorite, to: detail)
        }
    }

    func fetchBoardSummaries() async throws -> [IssueBoard] {
        var lastError: Error?
        for fields in Self.agileSummaryFieldCandidates {
            do {
                let boards = try await fetchBoards(fields: fields, pageSize: 100)
                return mapBoards(boards)
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

    func fetchBoard(id: String) async throws -> IssueBoard {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw YouTrackAPIError.invalidResponse
        }

        var lastError: Error?
        for fields in Self.agileDetailFieldCandidates {
            do {
                let detail = try await fetchBoardDetails(id: trimmedID, fields: fields)
                guard let mapped = mapBoards([detail]).first else {
                    throw YouTrackAPIError.invalidResponse
                }
                return mapped
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

    private func fetchBoards(fields: String, pageSize: Int = 10) async throws -> [YouTrackAgileBoard] {
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

        return allBoards
    }

    private func mapBoards(_ boards: [YouTrackAgileBoard]) -> [IssueBoard] {
        boards
            .map { board in
                let isFavorite = board.favorite ?? board.isFavorite ?? board.isStarred ?? false
                let projectNames = board.projects?.compactMap { $0.shortName ?? $0.name } ?? []
                let mappedSprints = mapSprints(board.sprints, current: board.currentSprint)
                let currentSprintID = board.currentSprint?.id
                let sprintFieldName = board.sprintsSettings?.sprintSyncField?.resolvedName
                let columnFieldName = board.columnSettings?.field?.resolvedName
                let columns = mapColumns(from: board.columnSettings)
                let swimlaneSettings = mapSwimlaneSettings(from: board.swimlaneSettings)
                return IssueBoard(
                    id: board.id,
                    name: board.name,
                    isFavorite: isFavorite,
                    projectNames: projectNames,
                    sprints: mappedSprints,
                    currentSprintID: currentSprintID,
                    sprintFieldName: sprintFieldName,
                    columnFieldName: columnFieldName,
                    columns: columns,
                    swimlaneSettings: swimlaneSettings,
                    orphansAtTheTop: board.orphansAtTheTop ?? false,
                    hideOrphansSwimlane: board.hideOrphansSwimlane ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fetchFavoriteBoardDetails(for favorites: [IssueBoard]) async -> [String: IssueBoard] {
        guard let seed = favorites.first else { return [:] }
        guard let (fields, seedDetail) = await fetchDetailCandidate(for: seed) else { return [:] }

        var detailedByID: [String: IssueBoard] = [seed.id: seedDetail]
        let remaining = favorites.dropFirst()
        guard !remaining.isEmpty else { return detailedByID }

        await withTaskGroup(of: (String, IssueBoard?).self) { group in
            for board in remaining {
                group.addTask { [weak self] in
                    guard let self else { return (board.id, nil) }
                    do {
                        let detail = try await self.fetchBoardDetails(id: board.id, fields: fields)
                        guard let mappedDetail = self.mapBoards([detail]).first else { return (board.id, nil) }
                        let adjusted = self.applyingFavorite(board.isFavorite, to: mappedDetail)
                        return (board.id, adjusted)
                    } catch {
                        return (board.id, nil)
                    }
                }
            }

            for await (id, detail) in group {
                if let detail {
                    detailedByID[id] = detail
                }
            }
        }

        return detailedByID
    }

    private func fetchDetailCandidate(for board: IssueBoard) async -> (String, IssueBoard)? {
        for fields in Self.agileDetailFieldCandidates {
            do {
                let detail = try await fetchBoardDetails(id: board.id, fields: fields)
                guard let mappedDetail = mapBoards([detail]).first else { return nil }
                return (fields, applyingFavorite(board.isFavorite, to: mappedDetail))
            } catch let error as YouTrackAPIError {
                if case .http(let statusCode, _) = error, statusCode == 400 {
                    continue
                }
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    private func fetchBoardDetails(id: String, fields: String) async throws -> YouTrackAgileBoard {
        let queryItems = [URLQueryItem(name: "fields", value: fields)]
        let data = try await client.get(path: "agiles/\(id)", queryItems: queryItems)
        return try decoder.decode(YouTrackAgileBoard.self, from: data)
    }

    private func applyingFavorite(_ favorite: Bool, to board: IssueBoard) -> IssueBoard {
        guard board.isFavorite != favorite else { return board }
        return IssueBoard(
            id: board.id,
            name: board.name,
            isFavorite: favorite,
            projectNames: board.projectNames,
            sprints: board.sprints,
            currentSprintID: board.currentSprintID,
            sprintFieldName: board.sprintFieldName,
            columnFieldName: board.columnFieldName,
            columns: board.columns,
            swimlaneSettings: board.swimlaneSettings,
            orphansAtTheTop: board.orphansAtTheTop,
            hideOrphansSwimlane: board.hideOrphansSwimlane
        )
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
                let fallbackName = column.resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title: String
                if !presentation.isEmpty {
                    title = presentation
                } else if !fallbackName.isEmpty {
                    title = fallbackName
                } else {
                    title = valueNames.joined(separator: ", ")
                }
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

    private func mapSprints(_ sprints: [YouTrackAgileBoard.Sprint]?, current: YouTrackAgileBoard.Sprint?) -> [IssueBoardSprint] {
        let mapped = (sprints ?? []).compactMap { mapSprint($0) }
        guard let current, let currentMapped = mapSprint(current) else {
            return mapped
        }
        if mapped.contains(where: { $0.id == currentMapped.id }) {
            return mapped
        }
        return [currentMapped] + mapped
    }

    private func mapSprint(_ sprint: YouTrackAgileBoard.Sprint) -> IssueBoardSprint? {
        let name = sprint.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        return IssueBoardSprint(
            id: sprint.id,
            name: name,
            start: sprint.startDate,
            finish: sprint.finishDate,
            isArchived: sprint.archived ?? false,
            isDefault: sprint.isDefault ?? false
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
    let sprints: [Sprint]?
    let currentSprint: Sprint?
    let orphansAtTheTop: Bool?
    let hideOrphansSwimlane: Bool?
    let columnSettings: ColumnSettings?
    let swimlaneSettings: SwimlaneSettings?
    let sprintsSettings: SprintsSettings?

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
        let fullName: String?
        let login: String?

        var resolvedName: String? {
            name ?? localizedName ?? fullName ?? login
        }
    }

    struct ColumnSettings: Decodable {
        let field: Field?
        let columns: [Column]?
    }

    struct Column: Decodable {
        let id: String?
        let name: String?
        let localizedName: String?
        let presentation: String?
        let isResolved: Bool?
        let ordinal: Int?
        let parent: ColumnParent?
        let fieldValues: [FieldValue]?

        var resolvedName: String? {
            name ?? localizedName
        }
    }

    struct ColumnParent: Decodable {
        let id: String?
    }

    struct SprintsSettings: Decodable {
        let sprintSyncField: Field?
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

    struct Sprint: Decodable {
        let id: String
        let name: String?
        let start: Int?
        let finish: Int?
        let archived: Bool?
        let isDefault: Bool?

        var startDate: Date? {
            guard let start else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(start) / 1000.0)
        }

        var finishDate: Date? {
            guard let finish else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(finish) / 1000.0)
        }
    }
}

private extension YouTrackIssueBoardRepository {
    static let agileSummaryFieldCandidates: [String] = [
        "id,name,favorite",
        "id,name,isFavorite",
        "id,name,isStarred"
    ]

    static let agileDetailFieldCandidates: [String] = [
        agileDetailFieldsWithUsers,
        agileDetailFieldsBase
    ]

    static let agileDetailFieldsBase: String = [
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
        "columnSettings(id,field(id,name,localizedName),columns(id,name,localizedName,presentation,isResolved,ordinal,wipLimit(id,min,max),parent(id),fieldValues(id,name,localizedName,isResolved)))",
        "swimlaneSettings($type,id,enabled,field(id,name,localizedName),values(id,name,localizedName))",
        "sprintsSettings(id,isExplicit,cardOnSeveralSprints,defaultSprint(id,name),disableSprints,explicitQuery,sprintSyncField(id,name,localizedName),hideSubtasksOfCards)",
        "colorCoding(id)",
        "status(id,valid,hasJobs,errors,warnings)"
    ].joined(separator: ",")

    static let agileDetailFieldsWithUsers: String = [
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
        "columnSettings(id,field(id,name,localizedName),columns(id,name,localizedName,presentation,isResolved,ordinal,wipLimit(id,min,max),parent(id),fieldValues(id,name,localizedName,fullName,login,isResolved)))",
        "swimlaneSettings($type,id,enabled,field(id,name,localizedName),values(id,name,localizedName,fullName,login))",
        "sprintsSettings(id,isExplicit,cardOnSeveralSprints,defaultSprint(id,name),disableSprints,explicitQuery,sprintSyncField(id,name,localizedName),hideSubtasksOfCards)",
        "colorCoding(id)",
        "status(id,valid,hasJobs,errors,warnings)"
    ].joined(separator: ",")
}
