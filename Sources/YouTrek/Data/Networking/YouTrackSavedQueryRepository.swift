import Foundation

final class YouTrackSavedQueryRepository: SavedQueryRepository, Sendable {
    private let client: YouTrackAPIClient
    private let decoder: JSONDecoder

    init(client: YouTrackAPIClient, decoder: JSONDecoder = YouTrackSavedQueryRepository.makeDecoder()) {
        self.client = client
        self.decoder = decoder
    }

    convenience init(configuration: YouTrackAPIConfiguration, session: URLSession = .shared) {
        self.init(client: YouTrackAPIClient(configuration: configuration, session: session))
    }

    func fetchSavedQueries() async throws -> [SavedQuery] {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: "id,name,query"),
            URLQueryItem(name: "\u{24}top", value: "200"),
            URLQueryItem(name: "\u{24}skip", value: "0")
        ]

        let data = try await client.get(path: "savedQueries", queryItems: queryItems)
        let savedQueries = try decoder.decode([YouTrackSavedQuery].self, from: data)
        return savedQueries
            .compactMap { savedQuery in
                let trimmedQuery = savedQuery.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmedQuery.isEmpty else { return nil }
                return SavedQuery(id: savedQuery.id, name: savedQuery.name, query: trimmedQuery)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private struct YouTrackSavedQuery: Decodable {
    let id: String
    let name: String
    let query: String?
}
