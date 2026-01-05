import SwiftUI

struct IssueDetailView: View {
    let issue: IssueSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                metadata
                Divider()
                Text("Timeline and comments will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.readableID)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(issue.title)
                .font(.system(size: 24, weight: .bold))
            HStack(spacing: 8) {
                BadgeLabel(text: issue.status.displayName, tint: issue.status.tint)
                BadgeLabel(text: issue.priority.displayName, tint: issue.priority.tint)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let assignee = issue.assignee {
                Label("Assigned to \(assignee.displayName)", systemImage: "person.fill")
            }
            Label("Updated \(issue.updatedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
            Label("Project: \(issue.projectName)", systemImage: "folder")
            if !issue.tags.isEmpty {
                Label("Tags: \(issue.tags.joined(separator: ", "))", systemImage: "tag")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct BadgeLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
