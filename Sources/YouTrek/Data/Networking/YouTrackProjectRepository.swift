import Foundation

final class YouTrackProjectRepository: ProjectRepository, Sendable {
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

    func fetchProjects() async throws -> [IssueProject] {
        let pageSize = 200
        var skip = 0
        var projects: [YouTrackProject] = []

        while true {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "fields", value: "id,name,shortName,archived"),
                URLQueryItem(name: "\u{24}top", value: String(pageSize)),
                URLQueryItem(name: "\u{24}skip", value: String(skip))
            ]

            let data = try await client.get(path: "admin/projects", queryItems: queryItems)
            let page = try decoder.decode([YouTrackProject].self, from: data)
            projects.append(contentsOf: page)

            if page.count < pageSize { break }
            skip += pageSize
        }

        return projects
            .map { project in
                IssueProject(
                    id: project.id,
                    name: project.name ?? "",
                    shortName: project.shortName,
                    isArchived: project.archived ?? false
                )
            }
            .sorted { left, right in
                let leftKey = left.shortName ?? left.name
                let rightKey = right.shortName ?? right.name
                if leftKey != rightKey {
                    return leftKey.localizedCaseInsensitiveCompare(rightKey) == .orderedAscending
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }
}

private struct YouTrackProject: Decodable {
    let id: String
    let name: String?
    let shortName: String?
    let archived: Bool?
}
