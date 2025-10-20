import Foundation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case inbox
    case myIssues
    case assignedToMe
    case recent
    case favorites

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .inbox: return "tray.fill"
        case .myIssues: return "square.stack.3d.up.fill"
        case .assignedToMe: return "person.crop.circle.fill.badge.checkmark"
        case .recent: return "clock.fill"
        case .favorites: return "star.fill"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .inbox: return "Inbox"
        case .myIssues: return "My Issues"
        case .assignedToMe: return "Assigned to Me"
        case .recent: return "Recently Updated"
        case .favorites: return "Favorites"
        }
    }
}
