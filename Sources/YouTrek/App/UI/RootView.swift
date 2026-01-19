import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        RootContentView(appState: container.appState)
            .environmentObject(container)
    }
}

private struct RootContentView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var isInspectorVisible: Bool = true
    @AppStorage("issueList.showAssigneeColumn") private var showAssigneeColumn: Bool = false
    @AppStorage("issueList.showUpdatedColumn") private var showUpdatedColumn: Bool = true
    @State private var simulateSlowResponses: Bool = AppDebugSettings.simulateSlowResponses
    @State private var showNetworkFooter: Bool = AppDebugSettings.showNetworkFooter
    @State private var disableSyncing: Bool = AppDebugSettings.disableSyncing

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.columnVisibility) {
            SidebarView(
                sections: appState.sidebarSections,
                selection: $appState.selectedSidebarItem,
                isSyncing: appState.isSyncing,
                syncStatusMessage: appState.syncStatusMessage,
                onDeleteSavedSearch: { savedQueryID in
                    Task {
                        await container.deleteSavedSearch(id: savedQueryID)
                    }
                }
            )
        } content: {
            Group {
                if let selection = appState.selectedSidebarItem, selection.isBoard {
                    IssueBoardView(
                        boardTitle: selection.title,
                        issues: appState.filteredIssues(searchQuery: searchQuery),
                        selection: $appState.selectedIssue,
                        isLoading: appState.isLoadingIssues
                    )
                } else {
                    IssueListView(
                        issues: appState.filteredIssues(searchQuery: searchQuery),
                        selection: $appState.selectedIssue,
                        showAssigneeColumn: showAssigneeColumn,
                        showUpdatedColumn: showUpdatedColumn,
                        isLoading: appState.isLoadingIssues
                    )
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    NewIssueToolbar(container: container)
                        .frame(maxWidth: 280)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: container.commandPalette.open) {
                        Label("Command Palette", systemImage: "command.square")
                    }
                    .buttonStyle(.accessoryBar)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isInspectorVisible.toggle()
                        appState.setInspectorVisible(isInspectorVisible)
                    } label: {
                        Label("Toggle Inspector", systemImage: "sidebar.trailing")
                    }
                    .buttonStyle(.accessoryBar)
                    .help("Show or hide the inspector column")
                }

                ToolbarItem(placement: .automatic) {
                    Menu {
                        Toggle("Assignee as Column", isOn: $showAssigneeColumn)
                        Toggle("Updated as Column", isOn: $showUpdatedColumn)
                    } label: {
                        Label("Columns", systemImage: "tablecells")
                    }
                    .help("Show or hide optional columns in the issue list")
                }

                #if DEBUG
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Toggle("Simulate slow responses", isOn: $simulateSlowResponses)
                        Toggle("Show network footer", isOn: $showNetworkFooter)
                        Toggle("Disable syncing", isOn: $disableSyncing)
                    } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
                #endif
            }
        } detail: {
            Text("Select an issue")
                .foregroundStyle(.secondary)
        }
        .inspector(isPresented: $isInspectorVisible) {
            Group {
                if let issue = appState.selectedIssue {
                    IssueDetailView(issue: issue)
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
        .searchable(text: $searchQuery, placement: .toolbar, prompt: Text("Search issues"))
        .navigationSplitViewStyle(.balanced)
        #if DEBUG
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showNetworkFooter {
                NetworkRequestFooterView(monitor: container.networkMonitor)
            }
        }
        #endif
        .task {
            isInspectorVisible = appState.isInspectorVisible
        }
        .onChange(of: simulateSlowResponses) { _, newValue in
            AppDebugSettings.setSimulateSlowResponses(newValue)
        }
        .onChange(of: showNetworkFooter) { _, newValue in
            AppDebugSettings.setShowNetworkFooter(newValue)
        }
        .onChange(of: disableSyncing) { _, newValue in
            AppDebugSettings.setDisableSyncing(newValue)
        }
        .onChange(of: searchQuery) { _, query in
            appState.updateSearch(query: query)
        }
        .onChange(of: appState.isInspectorVisible) { _, newValue in
            isInspectorVisible = newValue
        }
        .onChange(of: appState.selectedSidebarItem) { _, selection in
            guard let selection else { return }
            Task {
                await container.loadIssues(for: selection)
            }
        }
        .onChange(of: container.router.shouldOpenNewIssueWindow) { _, shouldOpen in
            guard shouldOpen else { return }
            openWindow(id: SceneID.newIssue.rawValue)
            container.router.consumeNewIssueWindowFlag()
        }
        .sheet(item: $appState.activeConflict) { conflict in
            ConflictResolutionDialog(conflict: conflict)
        }
    }

}

struct SyncStatusIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label ?? "Syncing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}
