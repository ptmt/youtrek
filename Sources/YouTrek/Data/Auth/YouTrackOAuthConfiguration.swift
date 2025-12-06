import Foundation

struct YouTrackOAuthConfiguration: Sendable {
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

    static func loadFromEnvironment(processInfo: ProcessInfo = .processInfo) throws -> YouTrackOAuthConfiguration {
        let environment = processInfo.environment

        guard let apiBaseRaw = environment["YOUTRACK_BASE_URL"], !apiBaseRaw.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_BASE_URL")
        }
        guard let apiBaseURL = URL(string: apiBaseRaw) else {
            throw YouTrackOAuthConfigurationError.invalidURL(value: apiBaseRaw, key: "YOUTRACK_BASE_URL")
        }

        guard let authorizeRaw = environment["YOUTRACK_HUB_AUTHORIZE_URL"], !authorizeRaw.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_HUB_AUTHORIZE_URL")
        }
        guard let authorizeURL = URL(string: authorizeRaw) else {
            throw YouTrackOAuthConfigurationError.invalidURL(value: authorizeRaw, key: "YOUTRACK_HUB_AUTHORIZE_URL")
        }

        guard let tokenRaw = environment["YOUTRACK_HUB_TOKEN_URL"], !tokenRaw.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_HUB_TOKEN_URL")
        }
        guard let tokenURL = URL(string: tokenRaw) else {
            throw YouTrackOAuthConfigurationError.invalidURL(value: tokenRaw, key: "YOUTRACK_HUB_TOKEN_URL")
        }

        guard let clientID = environment["YOUTRACK_CLIENT_ID"], !clientID.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_CLIENT_ID")
        }

        guard let redirectRaw = environment["YOUTRACK_REDIRECT_URI"], !redirectRaw.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_REDIRECT_URI")
        }
        guard let redirectURL = URL(string: redirectRaw) else {
            throw YouTrackOAuthConfigurationError.invalidURL(value: redirectRaw, key: "YOUTRACK_REDIRECT_URI")
        }

        let scopesString = environment["YOUTRACK_SCOPES"] ?? "YouTrack"
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
}

enum YouTrackOAuthConfigurationError: Error, LocalizedError {
    case missingValue(key: String)
    case invalidURL(value: String, key: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let key):
            return "Missing required environment value for \(key)."
        case .invalidURL(let value, let key):
            return "Invalid URL '" + value + "' provided for \(key)."
        }
    }
}
