import SwiftUI

struct IssueStatusBadge: View {
    let text: String
    let colors: IssueBadgeColors
    var textOpacity: Double = 0.86
    var dotOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colors.foreground.opacity(dotOpacity))
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(Color.primary.opacity(textOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct IssuePriorityBadge: View {
    let text: String
    let colors: IssueBadgeColors
    var textOpacity: Double = 0.78
    var dotOpacity: Double = 1.0

    init(priority: IssuePriority, isMuted: Bool = false) {
        self.text = priority.displayName
        self.colors = priority.badgeColors
        self.textOpacity = isMuted ? 0.55 : 0.78
        self.dotOpacity = isMuted ? 0.6 : 1.0
    }

    init(text: String, colors: IssueBadgeColors, isMuted: Bool = false) {
        self.text = text
        self.colors = colors
        self.textOpacity = isMuted ? 0.55 : 0.78
        self.dotOpacity = isMuted ? 0.6 : 1.0
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colors.foreground.opacity(dotOpacity))
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(Color.primary.opacity(textOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct IssueStatusOptionRow: View {
    let text: String
    let colors: IssueBadgeColors
    var showsSelection: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            IssueStatusBadge(text: text, colors: colors)
            if showsSelection {
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct IssuePriorityOptionRow: View {
    let text: String
    let colors: IssueBadgeColors
    var showsSelection: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            IssuePriorityBadge(text: text, colors: colors)
            if showsSelection {
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
