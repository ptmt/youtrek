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
        let fieldCandidates = [
            "id,name,isFavorite,projects(shortName,name)",
            "id,name,favorite,projects(shortName,name)",
            "id,name,isStarred,projects(shortName,name)",
            "id,name,projects(shortName,name)"
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
                return IssueBoard(
                    id: board.id,
                    name: board.name,
                    isFavorite: isFavorite,
                    projectNames: projectNames
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct YouTrackAgileBoard: Decodable {
    let id: String
    let name: String
    let favorite: Bool?
    let isFavorite: Bool?
    let isStarred: Bool?
    let projects: [Project]?

    struct Project: Decodable {
        let name: String?
        let shortName: String?
    }
}
