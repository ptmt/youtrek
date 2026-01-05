import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "com.potomushto.youtrek.appearance.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
