import SwiftUI

extension RootContentView {
    @ViewBuilder
    var mainContent: some View {
        if let selection = appState.selectedSidebarItem {
            if selection.isBoard {
                BoardContentView(
                    appState: appState,
                    selection: selection,
                    searchQuery: searchQuery,
                    showDiagnostics: showBoardDiagnostics
                )
            } else if selection.isTodoList, let todoListID = selection.todoListID {
                TodoListContentView(
                    listID: todoListID,
                    title: selection.title,
                    markdownStore: container,
                    issueLinkHandler: container,
                    todoListManager: container
                )
                .id(todoListID)
            } else if isProgressReportingMode {
                IssueProgressListView(
                    issues: visibleIssues,
                    selection: $appState.selectedIssue,
                    selectedIDs: $appState.selectedIssueIDs,
                    isIssueUnread: { issue in
                        appState.isIssueUnread(issue)
                    }
                )
            } else {
                let listID = selection.id
                let diagnosticEvents = appState.issueListDataSourceEvents(for: listID)
                let diagnosticsQuery = selection.query.diagnosticsLabel
                IssueListView(
                    issues: visibleIssues,
                    selection: $appState.selectedIssue,
                    selectedIDs: $appState.selectedIssueIDs,
                    showAssigneeColumn: showAssigneeColumn,
                    isLoading: appState.isLoadingIssues,
                    hasCompletedSync: appState.hasCompletedIssueSync,
                    showDiagnostics: showIssueListDiagnostics,
                    diagnosticEvents: diagnosticEvents,
                    diagnosticsTitle: selection.title,
                    diagnosticsID: selection.id,
                    diagnosticsQuery: diagnosticsQuery,
                    diagnosticsSearch: searchQuery,
                    isIssueUnread: { issue in
                        appState.isIssueUnread(issue)
                    },
                    onIssuesRendered: { count in
                        appState.recordIssueListRendered(issueCount: count)
                    },
                    onDeleteDraft: { draftID in
                        container.discardDraft(recordID: draftID)
                    }
                )
            }
        } else if appState.sidebarSections.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left",
                description: Text("Pick an item from the sidebar to continue.")
            )
        }
    }

    var mainToolbar: some CustomizableToolbarContent {
        MainToolbar(
            container: container,
            searchQuery: $searchQuery,
            isProgressReportingMode: $isProgressReportingMode,
            hasUnreadIssues: hasUnreadIssues,
            onToggleSidebar: toggleSidebar,
            onToggleInspector: {
                isInspectorVisible.toggle()
                appState.setInspectorVisible(isInspectorVisible)
            }
        )
    }
}
