import Foundation

struct TelemetryService {
    func capture(event: String, metadata: [String: String] = [:]) {
        // TODO: Send to Sentry once the SDK is configured.
        print("Telemetry: \(event) - \(metadata)")
    }
}
