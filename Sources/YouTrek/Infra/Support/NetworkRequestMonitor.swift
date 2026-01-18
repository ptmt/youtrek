import Foundation
import Combine

struct NetworkRequestEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let method: String
    let endpoint: String
    let statusCode: Int?
    let duration: TimeInterval
    let timestamp: Date
    let errorDescription: String?

    init(
        id: UUID = UUID(),
        method: String,
        endpoint: String,
        statusCode: Int?,
        duration: TimeInterval,
        timestamp: Date = Date(),
        errorDescription: String?
    ) {
        self.id = id
        self.method = method
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.duration = duration
        self.timestamp = timestamp
        self.errorDescription = errorDescription
    }

    var durationText: String {
        if duration < 1 {
            return "\(Int(duration * 1000)) ms"
        }
        return String(format: "%.2f s", duration)
    }
}

@MainActor
final class NetworkRequestMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var entries: [NetworkRequestEntry] = []
    private let maxEntries: Int

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func record(method: String, url: URL?, statusCode: Int?, duration: TimeInterval, errorDescription: String?) {
        #if DEBUG
        let endpoint = Self.describeEndpoint(for: url)
        let entry = NetworkRequestEntry(
            method: method,
            endpoint: endpoint,
            statusCode: statusCode,
            duration: duration,
            errorDescription: errorDescription
        )

        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        #endif
    }
}

private extension NetworkRequestMonitor {
    static func describeEndpoint(for url: URL?) -> String {
        guard let url else { return "Unknown URL" }
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        if host.isEmpty {
            return "\(path)\(query)"
        }
        return "\(host)\(path)\(query)"
    }
}
