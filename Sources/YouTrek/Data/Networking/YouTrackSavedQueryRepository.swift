import Foundation

final class YouTrackSavedQueryRepository: SavedQueryRepository, Sendable {
    private let client: YouTrackAPIClient
    private let decoder: JSONDecoder

    init(client: YouTrackAPIClient, decoder: JSONDecoder = YouTrackSavedQueryRepository.makeDecoder()) {
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

    func fetchSavedQueries() async throws -> [SavedQuery] {
        let currentUser = try? await fetchCurrentUser()
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: "id,name,query,updated,owner(id,login,name,fullName)"),
            URLQueryItem(name: "\u{24}top", value: "200"),
            URLQueryItem(name: "\u{24}skip", value: "0")
        ]

        let data = try await client.get(path: "savedQueries", queryItems: queryItems)
        let savedQueries = try decoder.decode([YouTrackSavedQuery].self, from: data)
        let candidates = savedQueries.compactMap { savedQuery -> SavedQueryCandidate? in
            let trimmedQuery = savedQuery.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedQuery.isEmpty else { return nil }
            return SavedQueryCandidate(
                id: savedQuery.id,
                name: savedQuery.name,
                query: trimmedQuery,
                updated: savedQuery.updated,
                owner: savedQuery.owner
            )
        }

        let filteredCandidates = candidates.filter { candidate in
            guard let currentUser else { return true }
            return candidate.owner?.matches(user: currentUser) ?? false
        }

        return filteredCandidates
            .sorted { left, right in
                let leftUpdated = left.updated ?? 0
                let rightUpdated = right.updated ?? 0
                if leftUpdated != rightUpdated {
                    return leftUpdated > rightUpdated
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
            .map { SavedQuery(id: $0.id, name: $0.name, query: $0.query) }
    }

    func deleteSavedQuery(id: String) async throws {
        try await client.delete(path: "savedQueries/\(id)")
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func fetchCurrentUser() async throws -> YouTrackUser {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: "id,login,name,fullName")
        ]

        let data = try await client.get(path: "users/me", queryItems: queryItems)
        return try decoder.decode(YouTrackUser.self, from: data)
    }
}

private struct YouTrackSavedQuery: Decodable {
    let id: String
    let name: String
    let query: String?
    let updated: Int64?
    let owner: YouTrackSavedQueryOwner?
}

private struct YouTrackSavedQueryOwner: Decodable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?

    func matches(user: YouTrackUser) -> Bool {
        if let id, let userID = user.id {
            return id == userID
        }
        if let login, let userLogin = user.login {
            return login.caseInsensitiveCompare(userLogin) == .orderedSame
        }
        if let name, let userName = user.name ?? user.fullName {
            return name.caseInsensitiveCompare(userName) == .orderedSame
        }
        if let fullName, let userFullName = user.fullName ?? user.name {
            return fullName.caseInsensitiveCompare(userFullName) == .orderedSame
        }
        return false
    }
}

private struct YouTrackUser: Decodable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?
}

private struct SavedQueryCandidate {
    let id: String
    let name: String
    let query: String
    let updated: Int64?
    let owner: YouTrackSavedQueryOwner?
}
