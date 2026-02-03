import Foundation

struct StoredAccount: Identifiable, Codable, Equatable {
    enum AuthMethod: String, Codable {
        case token
        case oauth
    }

    let id: UUID
    var baseURL: String
    var displayName: String?
    var login: String?
    var userID: String?
    var lastSidebarSelectionID: String?
    var initialIssueSyncCompleted: Bool
    var initialBoardSyncCompleted: Bool
    var initialSavedSearchSyncCompleted: Bool
    var authMethod: AuthMethod
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        baseURL: String,
        displayName: String? = nil,
        login: String? = nil,
        userID: String? = nil,
        lastSidebarSelectionID: String? = nil,
        initialIssueSyncCompleted: Bool = false,
        initialBoardSyncCompleted: Bool = false,
        initialSavedSearchSyncCompleted: Bool = false,
        authMethod: AuthMethod = .token,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.baseURL = baseURL
        self.displayName = displayName
        self.login = login
        self.userID = userID
        self.lastSidebarSelectionID = lastSidebarSelectionID
        self.initialIssueSyncCompleted = initialIssueSyncCompleted
        self.initialBoardSyncCompleted = initialBoardSyncCompleted
        self.initialSavedSearchSyncCompleted = initialSavedSearchSyncCompleted
        self.authMethod = authMethod
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseURL
        case displayName
        case login
        case userID
        case lastSidebarSelectionID
        case initialIssueSyncCompleted
        case initialBoardSyncCompleted
        case initialSavedSearchSyncCompleted
        case authMethod
        case createdAt
        case lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        login = try container.decodeIfPresent(String.self, forKey: .login)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
        lastSidebarSelectionID = try container.decodeIfPresent(String.self, forKey: .lastSidebarSelectionID)
        initialIssueSyncCompleted = try container.decodeIfPresent(Bool.self, forKey: .initialIssueSyncCompleted) ?? false
        initialBoardSyncCompleted = try container.decodeIfPresent(Bool.self, forKey: .initialBoardSyncCompleted) ?? false
        initialSavedSearchSyncCompleted = try container.decodeIfPresent(Bool.self, forKey: .initialSavedSearchSyncCompleted) ?? false
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .token
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(login, forKey: .login)
        try container.encodeIfPresent(userID, forKey: .userID)
        try container.encodeIfPresent(lastSidebarSelectionID, forKey: .lastSidebarSelectionID)
        try container.encode(initialIssueSyncCompleted, forKey: .initialIssueSyncCompleted)
        try container.encode(initialBoardSyncCompleted, forKey: .initialBoardSyncCompleted)
        try container.encode(initialSavedSearchSyncCompleted, forKey: .initialSavedSearchSyncCompleted)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}

extension StoredAccount {
    var apiBaseURL: URL? {
        URL(string: baseURL)
    }

    var displayTitle: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let login = login?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
            return login
        }
        if let host = apiBaseURL?.host, !host.isEmpty {
            return host
        }
        return "YouTrack Account"
    }

    var subtitle: String? {
        guard let apiBase = apiBaseURL else { return nil }
        if var trimmed = URL(string: baseURL) {
            if trimmed.lastPathComponent.lowercased() == "api" {
                trimmed.deleteLastPathComponent()
            }
            if let host = trimmed.host, !host.isEmpty {
                return host
            }
            return trimmed.absoluteString
        }
        return apiBase.absoluteString
    }
}
