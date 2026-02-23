import SwiftUI

extension RootContentView {
    var sidebarContent: some View {
        AppKitSidebarPane(
            sections: appState.sidebarSections,
            selection: $appState.selectedSidebarItem,
            onDeleteSavedSearch: { savedQueryID in
                Task {
                    await container.deleteSavedSearch(id: savedQueryID)
                }
            },
            onRefreshBoard: { item in
                Task {
                    await container.refreshBoardIssues(for: item)
                }
            },
            onOpenBoardInWeb: { item in
                container.openBoardInWeb(item)
            },
            boardSyncStatus: { item in
                appState.boardSyncStatus(for: item)
            },
            onCreateTodoList: {
                let suggestedName = "Todo List"
                guard let resolvedName = promptForTodoListName(
                    title: "New Todo List",
                    message: "Name your new todo list.",
                    defaultValue: suggestedName
                ) else { return }
                Task {
                    await container.createTodoList(named: resolvedName)
                }
            },
            onRenameTodoList: { item in
                guard let listID = item.todoListID else { return }
                guard let resolvedName = promptForTodoListName(
                    title: "Rename Todo List",
                    message: "Set a new name for this todo list.",
                    defaultValue: item.title
                ) else { return }
                Task {
                    await container.renameTodoList(id: listID, name: resolvedName)
                }
            },
            onDeleteTodoList: { item in
                guard let listID = item.todoListID else { return }
                guard confirmDeleteTodoList(named: item.title) else { return }
                Task {
                    await container.deleteTodoList(id: listID)
                }
            }
        )
        .frame(minWidth: 220, maxHeight: .infinity)
        .padding(.bottom, 28)
        .overlay(alignment: .bottomLeading) {
            if appState.isSyncing {
                SyncStatusIndicator(label: appState.syncStatusMessage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Sync status")
            } else if appState.showSyncComplete {
                SyncCompleteIndicator()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Syncing complete")
                    .transition(.opacity)
                    .animation(.easeInOut, value: appState.showSyncComplete)
            }
        }
    }
}
