import Foundation
import SwiftUI

struct IssueSummary: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let readableID: String
    let title: String
    let projectName: String
    let updatedAt: Date
    let assignee: Person?
    let reporter: Person?
    let priority: IssuePriority
    let status: IssueStatus
    let tags: [String]
    let customFieldValues: [String: [String]]

    init(
        id: UUID = UUID(),
        readableID: String,
        title: String,
        projectName: String,
        updatedAt: Date = .now,
        assignee: Person? = nil,
        reporter: Person? = nil,
        priority: IssuePriority = .normal,
        status: IssueStatus = .open,
        tags: [String] = [],
        customFieldValues: [String: [String]] = [:]
    ) {
        self.id = id
        self.readableID = readableID
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.assignee = assignee
        self.reporter = reporter
        self.priority = priority
        self.status = status
        self.tags = tags
        self.customFieldValues = customFieldValues
    }

    var assigneeDisplayName: String {
        assignee?.displayName ?? "Unassigned"
    }

    var reporterDisplayName: String {
        reporter?.displayName ?? "Unknown"
    }

    func fieldValues(named fieldName: String) -> [String] {
        let key = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return customFieldValues[key] ?? []
    }
}

struct Person: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let displayName: String
    let avatarURL: URL?

    init(id: UUID = UUID(), displayName: String, avatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

enum IssuePriority: String, CaseIterable, Hashable, Sendable, Codable {
    case critical
    case high
    case normal
    case low

    var displayName: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }

    var iconName: String {
        switch self {
        case .critical: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.circle.fill"
        case .normal: return "circle"
        case .low: return "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .critical: return .red
        case .high: return .orange
        case .normal: return .secondary
        case .low: return .blue
        }
    }
}

extension IssuePriority {
    static func from(displayName: String) -> IssuePriority? {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "show-stopper", "showstopper", "critical", "blocker": return .critical
        case "major", "high", "important": return .high
        case "normal", "medium", "default": return .normal
        case "minor", "low", "trivial": return .low
        default:
            if let match = IssuePriority(rawValue: normalized) {
                return match
            }
            return nil
        }
    }
}

enum IssueStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case open
    case inProgress
    case inReview
    case blocked
    case done

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .inReview: return "In Review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    var iconName: String {
        switch self {
        case .open: return "bolt.circle"
        case .inProgress: return "clock.badge.checkmark"
        case .inReview: return "eye.circle"
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .open: return .blue
        case .inProgress: return .mint
        case .inReview: return .teal
        case .blocked: return .red
        case .done: return .green
        }
    }
}
