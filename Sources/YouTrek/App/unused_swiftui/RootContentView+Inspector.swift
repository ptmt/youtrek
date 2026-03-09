import SwiftUI

extension RootContentView {
    var inspectorContent: some View {
        Group {
            if let draftID = appState.selectedDraftID,
               let record = appState.draftRecord(id: draftID) {
                DraftIssueDetailView(record: record)
            } else if appState.selectedDraftID != nil {
                ContentUnavailableView(
                    "Draft not found",
                    systemImage: "square.and.pencil",
                    description: Text("The selected draft is no longer available.")
                )
            } else if selectedIssues.count > 1 {
                MultiIssueSelectionView(issues: selectedIssues)
            } else if let issue = appState.selectedIssue ?? selectedIssues.first {
                IssueDetailView(
                    issue: issue,
                    detail: appState.issueDetail(for: issue),
                    isLoadingDetail: appState.isIssueDetailLoading(issue.id)
                )
            } else if appState.sidebarSections.isEmpty || (appState.isLoadingIssues && appState.issues.isEmpty) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select an issue",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose an issue from the middle column to inspect details.")
                )
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 400, max: 500)
        .background(.ultraThinMaterial)
    }
}
