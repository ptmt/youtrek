import Foundation

struct YouTrackOAuthConfiguration: Sendable {
    private enum Keys {
        static let baseURL = "YOUTRACK_BASE_URL"
        static let authorizeURL = "YOUTRACK_HUB_AUTHORIZE_URL"
        static let tokenURL = "YOUTRACK_HUB_TOKEN_URL"
        static let clientID = "YOUTRACK_CLIENT_ID"
        static let redirectURI = "YOUTRACK_REDIRECT_URI"
        static let scopes = "YOUTRACK_SCOPES"
    }

    private static let defaultAPIBase: URL = URL(string: "https://youtrack.jetbrains.com/api")!
    private static let defaultRedirectURI: URL = URL(string: "youtrek://oauth_callback")!

    let apiBaseURL: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL
    let scopes: [String]

    init(apiBaseURL: URL,
         authorizationEndpoint: URL,
         tokenEndpoint: URL,
         clientID: String,
         redirectURI: URL,
         scopes: [String]) {
        self.apiBaseURL = apiBaseURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    static func load(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main
    ) throws -> YouTrackOAuthConfiguration {
        try load(
            environment: processInfo.environment,
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func loadFromEnvironment(processInfo: ProcessInfo = .processInfo) throws -> YouTrackOAuthConfiguration {
        try load(environment: processInfo.environment, infoDictionary: [:])
    }

    static func load(
        environment: [String: String],
        infoDictionary: [String: Any]
    ) throws -> YouTrackOAuthConfiguration {
        let apiBaseURL: URL = {
            if let apiBaseRaw = resolvedValue(for: Keys.baseURL, environment: environment, infoDictionary: infoDictionary),
               let url = URL(string: apiBaseRaw) {
                return url
            }
            return defaultAPIBase
        }()

        let authorizeURL: URL = {
            if let authorizeRaw = resolvedValue(for: Keys.authorizeURL, environment: environment, infoDictionary: infoDictionary),
               let url = URL(string: authorizeRaw) {
                return url
            }
            return Self.derivedHubURL(from: apiBaseURL, pathComponents: ["hub", "api", "rest", "oauth2", "auth"])
        }()

        let tokenURL: URL = {
            if let tokenRaw = resolvedValue(for: Keys.tokenURL, environment: environment, infoDictionary: infoDictionary),
               let url = URL(string: tokenRaw) {
                return url
            }
            return Self.derivedHubURL(from: apiBaseURL, pathComponents: ["hub", "api", "rest", "oauth2", "token"])
        }()

        guard let clientID = resolvedValue(for: Keys.clientID, environment: environment, infoDictionary: infoDictionary) else {
            throw YouTrackOAuthConfigurationError.missingValue(key: Keys.clientID)
        }

        let redirectURL: URL
        if let redirectRaw = resolvedValue(for: Keys.redirectURI, environment: environment, infoDictionary: infoDictionary) {
            guard let url = URL(string: redirectRaw) else {
                throw YouTrackOAuthConfigurationError.invalidURL(value: redirectRaw, key: Keys.redirectURI)
            }
            redirectURL = url
        } else {
            redirectURL = defaultRedirectURI
        }

        let scopesString = resolvedValue(for: Keys.scopes, environment: environment, infoDictionary: infoDictionary) ?? "YouTrack"
        let scopes = scopesString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        return YouTrackOAuthConfiguration(
            apiBaseURL: apiBaseURL,
            authorizationEndpoint: authorizeURL,
            tokenEndpoint: tokenURL,
            clientID: clientID,
            redirectURI: redirectURL,
            scopes: scopes.isEmpty ? ["YouTrack"] : scopes
        )
    }

    private static func resolvedValue(
        for key: String,
        environment: [String: String],
        infoDictionary: [String: Any]
    ) -> String? {
        if let environmentValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        if let infoValue = infoDictionary[key] as? String {
            let trimmed = infoValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func derivedHubURL(from apiBaseURL: URL, pathComponents: [String]) -> URL {
        var hubBase = apiBaseURL
        if hubBase.lastPathComponent.lowercased() == "api" {
            hubBase.deleteLastPathComponent()
        }
        for component in pathComponents {
            hubBase.appendPathComponent(component)
        }
        return hubBase
    }
}

enum YouTrackOAuthConfigurationError: Error, LocalizedError {
    case missingValue(key: String)
    case invalidURL(value: String, key: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let key):
            return "Missing required OAuth configuration value for \(key)."
        case .invalidURL(let value, let key):
            return "Invalid URL '" + value + "' provided for \(key)."
        }
    }
}
