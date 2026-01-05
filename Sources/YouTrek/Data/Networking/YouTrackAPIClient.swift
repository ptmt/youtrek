import Foundation

struct YouTrackAPIConfiguration: Sendable {
    let baseURL: URL
    let tokenProvider: YouTrackAPITokenProvider

    init(baseURL: URL, tokenProvider: YouTrackAPITokenProvider) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }
}

struct YouTrackAPITokenProvider: Sendable {
    private let resolver: @Sendable () async throws -> String

    init(resolver: @escaping @Sendable () async throws -> String) {
        self.resolver = resolver
    }

    func token() async throws -> String {
        try await resolver()
    }

    static func constant(_ token: String) -> YouTrackAPITokenProvider {
        YouTrackAPITokenProvider { token }
    }
}

enum YouTrackAPIError: Error, LocalizedError {
    case missingAccessToken
    case unsupportedURL
    case transport(underlying: Error)
    case invalidResponse
    case http(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Missing OAuth access token. Sign in with YouTrack before retrying."
        case .unsupportedURL:
            return "Failed to construct valid YouTrack URL."
        case .transport(let underlying):
            return "Network error while talking to YouTrack: \(underlying.localizedDescription)."
        case .invalidResponse:
            return "Received an invalid response from YouTrack."
        case .http(let statusCode, let body):
            if let body, !body.isEmpty {
                return "YouTrack request failed with status \(statusCode): \(body)."
            } else {
                return "YouTrack request failed with status \(statusCode)."
            }
        }
    }
}

struct YouTrackAPIClient: Sendable {
    private let configuration: YouTrackAPIConfiguration
    private let session: URLSession

    init(configuration: YouTrackAPIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func get(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        try await AppDebugSettings.applySlowResponseIfNeeded()
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: true) else {
            throw YouTrackAPIError.unsupportedURL
        }

        let appendedPath: String
        if components.path.isEmpty {
            appendedPath = "/\(path)"
        } else {
            appendedPath = components.path.appendingPathComponent(path)
        }

        components.path = appendedPath
        components.queryItems = queryItems

        guard let url = components.url else {
            throw YouTrackAPIError.unsupportedURL
        }

        let token = try await configuration.tokenProvider.token()
        guard !token.isEmpty else {
            throw YouTrackAPIError.missingAccessToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw YouTrackAPIError.invalidResponse
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                throw YouTrackAPIError.http(statusCode: http.statusCode, body: body)
            }

            return data
        } catch let error as YouTrackAPIError {
            throw error
        } catch {
            throw YouTrackAPIError.transport(underlying: error)
        }
    }

    func delete(path: String, queryItems: [URLQueryItem] = []) async throws {
        try await AppDebugSettings.applySlowResponseIfNeeded()
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: true) else {
            throw YouTrackAPIError.unsupportedURL
        }

        let appendedPath: String
        if components.path.isEmpty {
            appendedPath = "/\(path)"
        } else {
            appendedPath = components.path.appendingPathComponent(path)
        }

        components.path = appendedPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw YouTrackAPIError.unsupportedURL
        }

        let token = try await configuration.tokenProvider.token()
        guard !token.isEmpty else {
            throw YouTrackAPIError.missingAccessToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw YouTrackAPIError.invalidResponse
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                throw YouTrackAPIError.http(statusCode: http.statusCode, body: body)
            }
        } catch let error as YouTrackAPIError {
            throw error
        } catch {
            throw YouTrackAPIError.transport(underlying: error)
        }
    }
}

private extension String {
    func appendingPathComponent(_ component: String) -> String {
        guard !component.isEmpty else { return self }
        if hasSuffix("/") {
            return self + component
        } else {
            return self + "/" + component
        }
    }
}
