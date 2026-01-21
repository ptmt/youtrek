import SwiftUI

struct IssueListView: View {
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    let showAssigneeColumn: Bool
    let showUpdatedColumn: Bool
    let isLoading: Bool
    let hasCompletedSync: Bool
    let isIssueUnread: (IssueSummary) -> Bool
    let onIssuesRendered: ((Int) -> Void)?

    @State private var selectedIDs: Set<IssueSummary.ID> = []
    @State private var sortOrder: [KeyPathComparator<IssueSummary>] = [
        .init(\IssueSummary.updatedAt, order: .reverse)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && issues.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading issues…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty && hasCompletedSync {
                ContentUnavailableView(
                    "No issues",
                    systemImage: "tray",
                    description: Text("Refine your filters or sync to pull the latest issues.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(issues, selection: $selectedIDs, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \IssueSummary.title) { issue in
                        let unread = isIssueUnread(issue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.headline.weight(unread ? .semibold : .regular))
                                .foregroundStyle(titleColor(isUnread: unread))
                            metadataRow(for: issue, isUnread: unread)
                        }
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    }
                    .width(min: 220, ideal: 420)
                    if showAssigneeColumn {
                        TableColumn("Assignee", value: \IssueSummary.assigneeDisplayName) { issue in
                            let unread = isIssueUnread(issue)
                            HStack(spacing: 8) {
                                UserAvatarView(person: issue.assignee, size: 20)
                                Text(issue.assigneeDisplayName)
                                    .foregroundStyle(issue.assignee == nil ? .secondary : .primary)
                                    .fontWeight(unread ? .semibold : .regular)
                            }
                        }
                        .width(min: 160, ideal: 200)
                    }
                    if showUpdatedColumn {
                        TableColumn("Updated") { issue in
                            let unread = isIssueUnread(issue)
                            Text(issue.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.subheadline.weight(unread ? .semibold : .regular))
                                .textSelection(.enabled)
                        }
                        .width(140)
                    }
                }
                .tableStyle(.inset)
                .onAppear {
                    onIssuesRendered?(issues.count)
                }
            }
        }
        .onAppear(perform: syncSelectionState)
        .onChange(of: selection?.id) { _, _ in
            syncSelectionState()
        }
        .onChange(of: selectedIDs) { _, newIDs in
            guard let firstID = newIDs.first, let issue = issues.first(where: { $0.id == firstID }) else {
                selection = nil
                return
            }
            selection = issue
        }
    }

    private func metadataRow(for issue: IssueSummary, isUnread: Bool) -> some View {
        HStack(spacing: 8) {
            Text(issue.projectName)
                .foregroundStyle(.secondary)
            Text(issue.status.displayName)
                .foregroundStyle(issue.status.tint)
            if issue.priority != .normal {
                Text(issue.priority.displayName)
                    .foregroundStyle(issue.priority.tint)
            }
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
                selectedIDs = [selectedIssue.id]
            } else {
                selectedIDs.removeAll()
            }
        }
    }
}
