import Foundation
import OSLog

struct LoggingService {
    static let general = Logger(subsystem: "com.potomushto.youtrek.app", category: "general")
    static let networking = Logger(subsystem: "com.potomushto.youtrek.app", category: "networking")
    static let sync = Logger(subsystem: "com.potomushto.youtrek.app", category: "sync")

    static var isVerboseRequestLoggingEnabled: Bool {
        #if DEBUG
        AppDebugSettings.verboseRequestLogging
        #else
        false
        #endif
    }

    static func networkVerbose(_ message: String) {
        guard isVerboseRequestLoggingEnabled else { return }
        networking.debug("\(message)")
    }

    static func syncVerbose(_ message: String) {
        guard isVerboseRequestLoggingEnabled else { return }
        sync.debug("\(message)")
    }
}
