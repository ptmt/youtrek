import Foundation

struct YouTrackOAuthConfiguration: Sendable {
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

    static func loadFromEnvironment(processInfo: ProcessInfo = .processInfo) throws -> YouTrackOAuthConfiguration {
        let environment = processInfo.environment

        let apiBaseURL: URL = {
            if let apiBaseRaw = environment["YOUTRACK_BASE_URL"], !apiBaseRaw.isEmpty, let url = URL(string: apiBaseRaw) {
                return url
            }
            return defaultAPIBase
        }()

        let authorizeURL: URL = {
            if let authorizeRaw = environment["YOUTRACK_HUB_AUTHORIZE_URL"], !authorizeRaw.isEmpty, let url = URL(string: authorizeRaw) {
                return url
            }
            return Self.derivedHubURL(from: apiBaseURL, pathComponents: ["hub", "api", "rest", "oauth2", "auth"])
        }()

        let tokenURL: URL = {
            if let tokenRaw = environment["YOUTRACK_HUB_TOKEN_URL"], !tokenRaw.isEmpty, let url = URL(string: tokenRaw) {
                return url
            }
            return Self.derivedHubURL(from: apiBaseURL, pathComponents: ["hub", "api", "rest", "oauth2", "token"])
        }()

        guard let clientID = environment["YOUTRACK_CLIENT_ID"], !clientID.isEmpty else {
            throw YouTrackOAuthConfigurationError.missingValue(key: "YOUTRACK_CLIENT_ID")
        }

        let redirectURL: URL
        if let redirectRaw = environment["YOUTRACK_REDIRECT_URI"], !redirectRaw.isEmpty {
            guard let url = URL(string: redirectRaw) else {
                throw YouTrackOAuthConfigurationError.invalidURL(value: redirectRaw, key: "YOUTRACK_REDIRECT_URI")
            }
            redirectURL = url
        } else {
            redirectURL = defaultRedirectURI
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
            return "Missing required environment value for \(key)."
        case .invalidURL(let value, let key):
            return "Invalid URL '" + value + "' provided for \(key)."
        }
    }
}
