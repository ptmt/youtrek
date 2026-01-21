import Foundation
import Combine

struct NetworkRequestEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let method: String
    let endpoint: String
    let urlString: String
    let statusCode: Int?
    let duration: TimeInterval?
    let timestamp: Date
    let errorDescription: String?

    init(
        id: UUID = UUID(),
        method: String,
        endpoint: String,
        urlString: String? = nil,
        statusCode: Int?,
        duration: TimeInterval?,
        timestamp: Date = Date(),
        errorDescription: String?
    ) {
        self.id = id
        self.method = method
        self.endpoint = endpoint
        self.urlString = urlString ?? endpoint
        self.statusCode = statusCode
        self.duration = duration
        self.timestamp = timestamp
        self.errorDescription = errorDescription
    }

    var isPending: Bool {
        statusCode == nil && errorDescription == nil && duration == nil
    }

    var durationText: String {
        guard let duration else { return "pending" }
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
        let urlString = url?.absoluteString ?? endpoint
        let entry = NetworkRequestEntry(
            method: method,
            endpoint: endpoint,
            urlString: urlString,
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

    func recordStart(method: String, url: URL?) -> UUID {
        let id = UUID()
        #if DEBUG
        let endpoint = Self.describeEndpoint(for: url)
        let urlString = url?.absoluteString ?? endpoint
        let entry = NetworkRequestEntry(
            id: id,
            method: method,
            endpoint: endpoint,
            urlString: urlString,
            statusCode: nil,
            duration: nil,
            errorDescription: nil
        )

        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        #endif
        return id
    }

    func recordFinish(
        id: UUID,
        method: String,
        url: URL?,
        statusCode: Int?,
        duration: TimeInterval,
        errorDescription: String?
    ) {
        #if DEBUG
        let resolvedDuration = max(duration, 0)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let existing = entries[index]
            entries[index] = NetworkRequestEntry(
                id: id,
                method: existing.method,
                endpoint: existing.endpoint,
                urlString: existing.urlString,
                statusCode: statusCode,
                duration: resolvedDuration,
                timestamp: existing.timestamp,
                errorDescription: errorDescription
            )
        } else {
            let endpoint = Self.describeEndpoint(for: url)
            let urlString = url?.absoluteString ?? endpoint
            let entry = NetworkRequestEntry(
                id: id,
                method: method,
                endpoint: endpoint,
                urlString: urlString,
                statusCode: statusCode,
                duration: resolvedDuration,
                errorDescription: errorDescription
            )
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
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
