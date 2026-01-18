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
    private let monitor: NetworkRequestMonitor?

    init(configuration: YouTrackAPIConfiguration, session: URLSession = .shared, monitor: NetworkRequestMonitor? = nil) {
        self.configuration = configuration
        self.session = session
        self.monitor = monitor
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

        var loggedResponse: URLResponse?
        var loggedError: Error?
        let requestStart = Date()
        defer {
            let duration = Date().timeIntervalSince(requestStart)
            if let monitor {
                Task { @MainActor in
                    monitor.record(request: request, response: loggedResponse, error: loggedError, duration: duration)
                }
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            loggedResponse = response
            guard let http = response as? HTTPURLResponse else {
                let error = YouTrackAPIError.invalidResponse
                loggedError = error
                throw error
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                let error = YouTrackAPIError.http(statusCode: http.statusCode, body: body)
                loggedError = error
                throw error
            }

            return data
        } catch let error as YouTrackAPIError {
            loggedError = error
            throw error
        } catch {
            let transportError = YouTrackAPIError.transport(underlying: error)
            loggedError = transportError
            throw transportError
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

        var loggedResponse: URLResponse?
        var loggedError: Error?
        let requestStart = Date()
        defer {
            let duration = Date().timeIntervalSince(requestStart)
            if let monitor {
                Task { @MainActor in
                    monitor.record(request: request, response: loggedResponse, error: loggedError, duration: duration)
                }
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            loggedResponse = response
            guard let http = response as? HTTPURLResponse else {
                let error = YouTrackAPIError.invalidResponse
                loggedError = error
                throw error
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                let error = YouTrackAPIError.http(statusCode: http.statusCode, body: body)
                loggedError = error
                throw error
            }
        } catch let error as YouTrackAPIError {
            loggedError = error
            throw error
        } catch {
            let transportError = YouTrackAPIError.transport(underlying: error)
            loggedError = transportError
            throw transportError
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
