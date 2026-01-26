import Foundation

struct YouTrackAPIConfiguration: Sendable {
    let baseURL: URL
    let tokenProvider: YouTrackAPITokenProvider
    let requestTimeout: TimeInterval

    static let defaultRequestTimeout: TimeInterval = 120

    init(baseURL: URL, tokenProvider: YouTrackAPITokenProvider, requestTimeout: TimeInterval = Self.defaultRequestTimeout) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.requestTimeout = requestTimeout
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
            return "Missing access token. Sign in with YouTrack before retrying."
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
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let requestStart = Date()
        let requestMethod = request.httpMethod ?? "GET"
        let requestURL = request.url
        LoggingService.networking.info("HTTP \(requestMethod, privacy: .public) start \(requestURL?.absoluteString ?? "-", privacy: .public)")
        let requestID = await monitor?.recordStart(method: requestMethod, url: requestURL)
        var didLog = false

        func logOnce(response: URLResponse?, error: Error?) async {
            guard !didLog else { return }
            didLog = true
            let duration = Date().timeIntervalSince(requestStart)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let errorDescription = error?.localizedDescription
            LoggingService.networking.info(
                "HTTP \(requestMethod, privacy: .public) finish status=\(statusCode ?? -1, privacy: .public) duration=\(duration, privacy: .public)s error=\(errorDescription ?? "none", privacy: .public)"
            )
            guard let monitor, let requestID else { return }
            await monitor.recordFinish(
                id: requestID,
                method: requestMethod,
                url: requestURL,
                statusCode: statusCode,
                duration: duration,
                errorDescription: errorDescription
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                let error = YouTrackAPIError.invalidResponse
                await logOnce(response: response, error: error)
                throw error
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                let error = YouTrackAPIError.http(statusCode: http.statusCode, body: body)
                await logOnce(response: response, error: error)
                throw error
            }

            await logOnce(response: response, error: nil)
            return data
        } catch let error as YouTrackAPIError {
            await logOnce(response: nil, error: error)
            throw error
        } catch {
            let transportError = YouTrackAPIError.transport(underlying: error)
            await logOnce(response: nil, error: transportError)
            throw transportError
        }
    }

    func post(path: String, queryItems: [URLQueryItem] = [], body: Data?) async throws -> Data {
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
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let requestStart = Date()
        let requestMethod = request.httpMethod ?? "POST"
        let requestURL = request.url
        LoggingService.networking.info("HTTP \(requestMethod, privacy: .public) start \(requestURL?.absoluteString ?? "-", privacy: .public)")
        let requestID = await monitor?.recordStart(method: requestMethod, url: requestURL)
        var didLog = false

        func logOnce(response: URLResponse?, error: Error?) async {
            guard !didLog else { return }
            didLog = true
            let duration = Date().timeIntervalSince(requestStart)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let errorDescription = error?.localizedDescription
            LoggingService.networking.info(
                "HTTP \(requestMethod, privacy: .public) finish status=\(statusCode ?? -1, privacy: .public) duration=\(duration, privacy: .public)s error=\(errorDescription ?? "none", privacy: .public)"
            )
            guard let monitor, let requestID else { return }
            await monitor.recordFinish(
                id: requestID,
                method: requestMethod,
                url: requestURL,
                statusCode: statusCode,
                duration: duration,
                errorDescription: errorDescription
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                let error = YouTrackAPIError.invalidResponse
                await logOnce(response: response, error: error)
                throw error
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                let error = YouTrackAPIError.http(statusCode: http.statusCode, body: body)
                await logOnce(response: response, error: error)
                throw error
            }

            await logOnce(response: response, error: nil)
            return data
        } catch let error as YouTrackAPIError {
            await logOnce(response: nil, error: error)
            throw error
        } catch {
            let transportError = YouTrackAPIError.transport(underlying: error)
            await logOnce(response: nil, error: transportError)
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
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let requestStart = Date()
        let requestMethod = request.httpMethod ?? "GET"
        let requestURL = request.url
        LoggingService.networking.info("HTTP \(requestMethod, privacy: .public) start \(requestURL?.absoluteString ?? "-", privacy: .public)")
        let requestID = await monitor?.recordStart(method: requestMethod, url: requestURL)
        var didLog = false

        func logOnce(response: URLResponse?, error: Error?) async {
            guard !didLog else { return }
            didLog = true
            let duration = Date().timeIntervalSince(requestStart)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let errorDescription = error?.localizedDescription
            LoggingService.networking.info(
                "HTTP \(requestMethod, privacy: .public) finish status=\(statusCode ?? -1, privacy: .public) duration=\(duration, privacy: .public)s error=\(errorDescription ?? "none", privacy: .public)"
            )
            guard let monitor, let requestID else { return }
            await monitor.recordFinish(
                id: requestID,
                method: requestMethod,
                url: requestURL,
                statusCode: statusCode,
                duration: duration,
                errorDescription: errorDescription
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                let error = YouTrackAPIError.invalidResponse
                await logOnce(response: response, error: error)
                throw error
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                let error = YouTrackAPIError.http(statusCode: http.statusCode, body: body)
                await logOnce(response: response, error: error)
                throw error
            }
            await logOnce(response: response, error: nil)
        } catch let error as YouTrackAPIError {
            await logOnce(response: nil, error: error)
            throw error
        } catch {
            let transportError = YouTrackAPIError.transport(underlying: error)
            await logOnce(response: nil, error: transportError)
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
