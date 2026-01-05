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

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.columnVisibility) {
            SidebarView(sections: appState.sidebarSections, selection: $appState.selectedSidebarItem)
        } content: {
            IssueListView(
                issues: appState.filteredIssues(searchQuery: searchQuery),
                selection: $appState.selectedIssue
            )
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
            }
        } detail: {
            Group {
                if isInspectorVisible {
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
            }
            .background {
                if isInspectorVisible {
                    Rectangle().fill(.thinMaterial)
                }
            }
            .navigationSplitViewColumnWidth(
                min: isInspectorVisible ? 320 : 0,
                ideal: isInspectorVisible ? 400 : 0
            )
        }
        .searchable(text: $searchQuery, placement: .toolbar, prompt: Text("Search issues"))
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            isInspectorVisible = appState.isInspectorVisible
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
    }

}
