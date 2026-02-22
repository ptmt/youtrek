import SwiftUI

extension RootContentView {
    var body: some View {
        rootSplitView
            .background(ToolbarSidebarToggleHider())
            .background(SplitViewFullHeightLayoutEnabler())
            .toolbar(removing: .sidebarToggle)
            .animation(.easeOut(duration: 0.15), value: appState.activeCommandPalette?.id)
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { appState.columnVisibility },
            set: { newValue in
                appState.updateColumnVisibility(newValue, source: "NavigationSplitView")
            }
        )
    }

    private var rootSplitView: some View {
        AppKitRootSplitView(
            sidebar: AnyView(sidebarContent),
            main: AnyView(mainContent),
            inspector: AnyView(inspectorContent),
            columnVisibility: columnVisibilityBinding,
            isInspectorVisible: $isInspectorVisible
        )
        .toolbar(id: "main-toolbar") { mainToolbar }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: searchQuery) { _, query in
            appState.updateSearch(query: query)
        }
        .onChange(of: appState.isInspectorVisible) { _, newValue in
            isInspectorVisible = newValue
        }
        .onChange(of: appState.selectedIssue) { _, issue in
            guard let issue else {
                appState.selectedDraftID = nil
                return
            }
            if !isInspectorVisible {
                isInspectorVisible = true
                appState.setInspectorVisible(true)
            }
            Task { @MainActor in
                if appState.selectedIssueIDs != [issue.id] {
                    appState.selectedIssueIDs = [issue.id]
                }
            }
            if issue.isDraft, let draftID = issue.draftID {
                appState.selectedDraftID = draftID
                if appState.draftRecord(id: draftID) != nil {
                    container.selectDraft(recordID: draftID)
                }
                return
            }
            appState.selectedDraftID = nil
            container.markIssueSeen(issue)
            Task {
                await container.loadIssueDetail(for: issue)
            }
        }
        .onChange(of: appState.selectedSidebarItem) { previousSelection, selection in
            guard let selection else { return }
            container.recordSidebarSelection(selection)
            if (selection.isBoard || selection.isTodoList), isInspectorVisible {
                isInspectorVisible = false
                appState.setInspectorVisible(false)
            }
            if selection.isTodoList {
                appState.selectedDraftID = nil
                appState.selectedIssue = nil
                appState.selectedIssueIDs.removeAll()

                if let todoListID = selection.todoListID {
                    let previousTodoListID = previousSelection?.todoListID
                    let enteredNewTodoList = previousTodoListID != todoListID
                    if enteredNewTodoList, appState.isSidebarVisible {
                        appState.updateColumnVisibility(.doubleColumn, source: "todoList-default")
                    }
                }
            }
            if !selectionShowsDrafts(selection), appState.selectedIssue?.isDraft == true {
                appState.selectedDraftID = nil
                appState.selectedIssue = nil
                appState.selectedIssueIDs.removeAll()
            }
            Task {
                await container.loadIssues(for: selection)
            }
        }
        .sheet(item: $appState.activeConflict) { conflict in
            ConflictResolutionDialog(conflict: conflict)
        }
        .sheet(item: $appState.activeNewIssueDialog) { _ in
            NewIssueDialog(state: newIssueDialogBinding)
        }
        .overlay {
            if appState.activeCommandPalette != nil {
                CommandPaletteOverlay(
                    state: commandPaletteBinding,
                    onClose: { appState.dismissCommandPalette() }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if let toast = appState.activeToast {
                ToastView(toast: toast)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await MainActor.run {
                            if appState.activeToast?.id == toast.id {
                                appState.dismissToast()
                            }
                        }
                    }
            }
        }
        #if DEBUG
        .background(RootDebugStateTracker(appState: appState, container: container))
        #endif
    }

    private var newIssueDialogBinding: Binding<NewIssueDialogState> {
        Binding(
            get: { appState.activeNewIssueDialog ?? NewIssueDialogState() },
            set: { appState.activeNewIssueDialog = $0 }
        )
    }

    private var commandPaletteBinding: Binding<CommandPaletteState> {
        Binding(
            get: { appState.activeCommandPalette ?? CommandPaletteState() },
            set: { newValue in
                guard appState.activeCommandPalette != nil else { return }
                appState.activeCommandPalette = newValue
            }
        )
    }
}
