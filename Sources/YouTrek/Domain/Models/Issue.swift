import Foundation
import SwiftUI

struct IssueSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let readableID: String
    let title: String
    let projectName: String
    let updatedAt: Date
    let assignee: Person?
    let priority: IssuePriority
    let status: IssueStatus
    let tags: [String]

    init(
        id: UUID = UUID(),
        readableID: String,
        title: String,
        projectName: String,
        updatedAt: Date = .now,
        assignee: Person? = nil,
        priority: IssuePriority = .normal,
        status: IssueStatus = .open,
        tags: [String] = []
    ) {
        self.id = id
        self.readableID = readableID
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.assignee = assignee
        self.priority = priority
        self.status = status
        self.tags = tags
    }

    var assigneeDisplayName: String {
        assignee?.displayName ?? "Unassigned"
    }
}

struct Person: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let avatarURL: URL?

    init(id: UUID = UUID(), displayName: String, avatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

enum IssuePriority: String, CaseIterable, Hashable, Sendable {
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

enum IssueStatus: String, CaseIterable, Hashable, Sendable {
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
