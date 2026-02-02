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
        }
    }
}

struct IssuePriorityBadge: View {
    let text: String
    let isTopPriority: Bool
    var isMuted: Bool = false

    init(priority: IssuePriority, isMuted: Bool = false) {
        self.text = priority.displayName
        self.isTopPriority = priority.isTopPriority
        self.isMuted = isMuted
    }

    init(text: String, isTopPriority: Bool, isMuted: Bool = false) {
        self.text = text
        self.isTopPriority = isTopPriority
        self.isMuted = isMuted
    }

    var body: some View {
        HStack(spacing: 5) {
            if isTopPriority {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(isMuted ? 0.7 : 1.0))
            }
            Text(text)
                .foregroundStyle(Color.primary.opacity(isMuted ? 0.55 : 0.78))
        }
    }
}
