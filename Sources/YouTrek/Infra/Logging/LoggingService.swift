import Foundation
import OSLog

struct LoggingService {
    static let general = Logger(subsystem: "com.potomushto.youtrek.app", category: "general")
    static let networking = Logger(subsystem: "com.potomushto.youtrek.app", category: "networking")
    static let sync = Logger(subsystem: "com.potomushto.youtrek.app", category: "sync")
}
