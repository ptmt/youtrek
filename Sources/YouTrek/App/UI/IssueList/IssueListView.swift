import SwiftUI

struct IssueListView: View {
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let showAssigneeColumn: Bool
    let isLoading: Bool
    let hasCompletedSync: Bool
    let isIssueUnread: (IssueSummary) -> Bool
    let onIssuesRendered: ((Int) -> Void)?
    let onDeleteDraft: ((UUID) -> Void)?
    @State private var sortOrder: [KeyPathComparator<IssueSummary>] = [
        .init(\IssueSummary.updatedAt, order: .reverse)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .onAppear(perform: syncSelectionState)
        .onChange(of: selection?.id) { _, _ in
            syncSelectionState()
        }
        .onChange(of: selectedIDs) { _, newIDs in
            updateSelection(from: newIDs)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && issues.isEmpty {
            loadingView
        } else if issues.isEmpty && hasCompletedSync {
            emptyView
        } else if issues.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            issueTable
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading issues…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView(
            title: "No issues",
            systemImage: "tray",
            description: "Refine your filters or sync to pull the latest issues."
        )
    }

    private var issueTable: some View {
        Table(issues, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \IssueSummary.title) { issue in
                titleCell(for: issue)
            }
            .width(min: 220, ideal: 420)
            if showAssigneeColumn {
                TableColumn("Assignee", value: \IssueSummary.assigneeDisplayName) { issue in
                    assigneeCell(for: issue)
                }
                .width(min: 160, ideal: 200)
            }
        }
        .tableStyle(.inset)
        .onAppear {
            onIssuesRendered?(issues.count)
        }
    }

    @ViewBuilder
    private func titleCell(for issue: IssueSummary) -> some View {
        let unread = isIssueUnread(issue)
        let row = HStack(alignment: .top, spacing: 10) {
            UserAvatarView(person: issue.assignee, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.headline.weight(unread ? .semibold : .regular))
                    .foregroundStyle(titleColor(isUnread: unread))
                metadataRow(for: issue, isUnread: unread)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
        if let draftID = issue.draftID {
            row.contextMenu {
                Button("Delete", role: .destructive) {
                    onDeleteDraft?(draftID)
                }
            }
        } else {
            row
        }
    }

    private func assigneeCell(for issue: IssueSummary) -> some View {
        let unread = isIssueUnread(issue)
        return Text(issue.assigneeDisplayName)
            .foregroundStyle(issue.assignee == nil ? .secondary : .primary)
            .fontWeight(unread ? .semibold : .regular)
    }

    private func metadataRow(for issue: IssueSummary, isUnread: Bool) -> some View {
        return HStack(spacing: 8) {
            Text(issue.projectName)
                .foregroundStyle(.secondary)
            IssueMetaDotLabel(text: issue.status.displayName, colors: issue.status.badgeColors)
            if !issue.priority.isNormalSemantic {
                IssueMetaDotLabel(
                    text: issue.priority.displayName,
                    colors: issue.priority.badgeColors,
                    textOpacity: 0.78
                )
            }
            Spacer(minLength: 0)
            Text(IssueTimestampFormatter.label(for: issue.updatedAt))
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(isUnread ? .medium : .regular))
        .lineLimit(1)
    }

    private func titleColor(isUnread: Bool) -> Color {
        isUnread ? .primary : .primary.opacity(0.74)
    }

    private func syncSelectionState() {
        Task { @MainActor in
            if let selectedIssue = selection {
                let nextIDs: Set<IssueSummary.ID> = [selectedIssue.id]
                guard selectedIDs != nextIDs else { return }
                selectedIDs = nextIDs
            } else if selectedIDs.count <= 1, !selectedIDs.isEmpty {
                selectedIDs.removeAll()
            }
        }
    }

    private func updateSelection(from newIDs: Set<IssueSummary.ID>) {
        let nextSelection: IssueSummary?
        if newIDs.count == 1, let firstID = newIDs.first, let issue = issues.first(where: { $0.id == firstID }) {
            nextSelection = issue
        } else {
            nextSelection = nil
        }
        guard nextSelection?.id != selection?.id else { return }
        Task { @MainActor in
            selection = nextSelection
        }
    }
}

private struct IssueMetaDotLabel: View {
    let text: String
    let colors: IssueBadgeColors
    let textOpacity: Double

    init(text: String, colors: IssueBadgeColors, textOpacity: Double = 0.86) {
        self.text = text
        self.colors = colors
        self.textOpacity = textOpacity
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colors.foreground)
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(Color.primary.opacity(textOpacity))
        }
    }
}

enum IssueTimestampFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func label(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return dateFormatter.string(from: date)
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
