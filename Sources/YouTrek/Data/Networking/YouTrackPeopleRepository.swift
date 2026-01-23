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
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fields", value: "id,login,name,fullName,avatarUrl"),
            URLQueryItem(name: "\u{24}top", value: "100"),
            URLQueryItem(name: "\u{24}skip", value: "0")
        ]

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: trimmedQuery))
        }

        let data = try await client.get(path: "users", queryItems: queryItems)
        let users = try decoder.decode([YouTrackUser].self, from: data)
        return users.compactMap { user in
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
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

private struct YouTrackUser: Decodable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?
    let avatarUrl: String?
}
