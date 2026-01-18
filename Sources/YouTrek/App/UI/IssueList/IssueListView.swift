import SwiftUI

struct IssueListView: View {
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?

    @State private var selectedIDs: Set<IssueSummary.ID> = []
    @State private var sortOrder: [KeyPathComparator<IssueSummary>] = [
        .init(\IssueSummary.updatedAt, order: .reverse)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if issues.isEmpty {
                ContentUnavailableView(
                    "No issues",
                    systemImage: "tray",
                    description: Text("Refine your filters or sync to pull the latest issues.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(issues, selection: $selectedIDs, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \IssueSummary.title) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.headline)
                            metadataRow(for: issue)
                        }
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    }
                    .width(min: 220, ideal: 420)
                    TableColumn("Assignee", value: \IssueSummary.assigneeDisplayName) { issue in
                        if let assignee = issue.assignee {
                            Label(assignee.displayName, systemImage: "person.fill")
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text(issue.assigneeDisplayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 160, ideal: 200)
                    TableColumn("Updated") { issue in
                        Text(issue.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    .width(140)
                }
                .tableStyle(.inset)
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

    private func metadataRow(for issue: IssueSummary) -> some View {
        HStack(spacing: 8) {
            Text(issue.projectName)
                .foregroundStyle(.secondary)
            Text(issue.status.displayName)
                .foregroundStyle(issue.status.tint)
            Text(issue.priority.displayName)
                .foregroundStyle(issue.priority.tint)
        }
        .font(.caption)
        .lineLimit(1)
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
