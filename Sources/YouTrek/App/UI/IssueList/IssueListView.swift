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
                    systemImage: "rectangle.stack.badge.questionmark",
                    description: Text("Refine your filters or sync to pull the latest issues.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(issues, selection: $selectedIDs, sortOrder: $sortOrder) {
                    TableColumn("ID", value: \IssueSummary.readableID)
                    TableColumn("Title", value: \IssueSummary.title) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.headline)
                            metadataRow(for: issue)
                        }
                        .padding(.vertical, 4)
                    }
                    TableColumn("Updated") { issue in
                        Text(issue.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.subheadline)
                    }
                }
                .tableStyle(.inset)
            }
        }
        .onAppear(perform: syncSelectionState)
        .onChange(of: selection?.id) { _ in
            syncSelectionState()
        }
        .onChange(of: selectedIDs) { newIDs in
            guard let firstID = newIDs.first, let issue = issues.first(where: { $0.id == firstID }) else {
                selection = nil
                return
            }
            selection = issue
        }
        .animation(.default, value: issues)
    }

    private func metadataRow(for issue: IssueSummary) -> some View {
        HStack(spacing: 8) {
            Text(issue.projectName)
                .foregroundStyle(.secondary)
            if let assignee = issue.assignee {
                Label(assignee.displayName, systemImage: "person.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Label(issue.status.displayName, systemImage: issue.status.iconName)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(issue.status.tint)
            Label(issue.priority.displayName, systemImage: issue.priority.iconName)
                .labelStyle(.titleAndIcon)
                .foregroundColor(issue.priority.tint)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func syncSelectionState() {
        if let selectedIssue = selection {
            selectedIDs = [selectedIssue.id]
        } else {
            selectedIDs.removeAll()
        }
    }
}
