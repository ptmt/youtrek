import AppKit
import SwiftUI
#if DEBUG
import Combine
#endif

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        RootContentView(appState: container.appState)
            .environmentObject(container)
    }
}

private struct RootContentView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var isInspectorVisible: Bool = true
    @AppStorage("issueList.showAssigneeColumn") private var showAssigneeColumn: Bool = false
    #if DEBUG
    @AppStorage(AppDebugSettings.Keys.simulateSlowResponses) private var simulateSlowResponses: Bool = false
    @AppStorage(AppDebugSettings.Keys.showNetworkFooter) private var showNetworkFooter: Bool = false
    @AppStorage(AppDebugSettings.Keys.disableSyncing) private var disableSyncing: Bool = false
    @AppStorage(AppDebugSettings.Keys.showBoardDiagnostics) private var showBoardDiagnostics: Bool = false
    @AppStorage(AppDebugSettings.Keys.showIssueListDiagnostics) private var showIssueListDiagnostics: Bool = false
    #else
    private let showBoardDiagnostics: Bool = false
    private let showIssueListDiagnostics: Bool = false
    #endif
    private var selectedIssues: [IssueSummary] {
        appState.issues.filter { appState.selectedIssueIDs.contains($0.id) }
    }
    private var hasUnreadIssues: Bool {
        appState.issues.contains { appState.isIssueUnread($0) }
    }
    private var showsDraftsInList: Bool {
        guard let selection = appState.selectedSidebarItem else { return false }
        return selectionShowsDrafts(selection)
    }
    private var visibleIssues: [IssueSummary] {
        let baseIssues: [IssueSummary]
        if showsDraftsInList {
            let drafts = appState.draftRecords
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { IssueSummary.draft($0) }
            baseIssues = drafts + appState.issues
        } else {
            baseIssues = appState.issues
        }
        return appState.filteredIssues(baseIssues, searchQuery: searchQuery)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    private func selectionShowsDrafts(_ selection: SidebarItem) -> Bool {
        selection.isInbox || selection.title.caseInsensitiveCompare("Inbox") == .orderedSame
    }

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
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            sidebarContent
        } detail: {
            mainContent
                .toolbar(id: "main-toolbar") { mainToolbar }
        }
        .inspector(isPresented: $isInspectorVisible) {
            inspectorContent
        }
        .navigationSplitViewStyle(.prominentDetail)
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

    private var sidebarContent: some View {
        SidebarView(
            sections: appState.sidebarSections,
            selection: $appState.selectedSidebarItem,
            isSyncing: appState.isSyncing,
            syncStatusMessage: appState.syncStatusMessage,
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
            },
            onToggleSidebar: toggleSidebar
        )
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var mainContent: some View {
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
        } else {
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left",
                description: Text("Pick an item from the sidebar to continue.")
            )
        }
    }

    private var mainToolbar: some CustomizableToolbarContent {
        MainToolbar(
            container: container,
            searchQuery: $searchQuery,
            hasUnreadIssues: hasUnreadIssues,
            onToggleSidebar: toggleSidebar,
            onToggleInspector: {
                isInspectorVisible.toggle()
                appState.setInspectorVisible(isInspectorVisible)
            }
        )
    }

    private var inspectorContent: some View {
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

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }

    private func promptForTodoListName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(string: defaultValue)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let resolved = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }

    private func confirmDeleteTodoList(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Todo List"
        alert.informativeText = "Delete \"\(name)\" permanently?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

}

#if DEBUG
private struct RootDebugStateTracker: View {
    @ObservedObject var appState: AppState
    let container: AppContainer
    @StateObject private var observer: RootDebugStateObserver

    init(appState: AppState, container: AppContainer) {
        self.appState = appState
        self.container = container
        _observer = StateObject(wrappedValue: RootDebugStateObserver(appState: appState, container: container))
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                observer.start()
            }
    }
}

@MainActor
private final class RootDebugStateObserver: ObservableObject {
    private let appState: AppState
    private let container: AppContainer
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false

    init(appState: AppState, container: AppContainer) {
        self.appState = appState
        self.container = container
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        logSnapshot("initial")
        observeAppState()
        observeContainer()
    }

    private func observeAppState() {
        var lastColumnVisibility = appState.columnVisibility
        appState.$columnVisibility
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.columnVisibility",
                    old: String(describing: lastColumnVisibility),
                    new: String(describing: newValue)
                )
                lastColumnVisibility = newValue
            }
            .store(in: &cancellables)

        var lastSidebarVisible = appState.isSidebarVisible
        appState.$isSidebarVisible
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.isSidebarVisible", old: lastSidebarVisible, new: newValue)
                lastSidebarVisible = newValue
            }
            .store(in: &cancellables)

        var lastSidebarSections = appState.sidebarSections
        appState.$sidebarSections
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.sidebarSections",
                    old: self.sidebarSectionsSummary(lastSidebarSections),
                    new: self.sidebarSectionsSummary(newValue)
                )
                lastSidebarSections = newValue
            }
            .store(in: &cancellables)

        var lastSidebarSelection = appState.selectedSidebarItem
        appState.$selectedSidebarItem
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.selectedSidebarItem",
                    old: self.sidebarItemSummary(lastSidebarSelection),
                    new: self.sidebarItemSummary(newValue)
                )
                lastSidebarSelection = newValue
            }
            .store(in: &cancellables)

        var lastIssuesCount = appState.issues.count
        appState.$issues
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                let newCount = newValue.count
                self.logStateChange("appState.issues.count", old: lastIssuesCount, new: newCount)
                lastIssuesCount = newCount
            }
            .store(in: &cancellables)

        var lastSelectedIssue = appState.selectedIssue
        appState.$selectedIssue
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.selectedIssue",
                    old: self.issueSummary(lastSelectedIssue),
                    new: self.issueSummary(newValue)
                )
                lastSelectedIssue = newValue
            }
            .store(in: &cancellables)

        var lastSelectedIDs = appState.selectedIssueIDs
        appState.$selectedIssueIDs
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.selectedIssueIDs",
                    old: self.selectionSummary(lastSelectedIDs),
                    new: self.selectionSummary(newValue)
                )
                lastSelectedIDs = newValue
            }
            .store(in: &cancellables)

        var lastInspectorVisible = appState.isInspectorVisible
        appState.$isInspectorVisible
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.isInspectorVisible", old: lastInspectorVisible, new: newValue)
                lastInspectorVisible = newValue
            }
            .store(in: &cancellables)

        var lastLoadingIssues = appState.isLoadingIssues
        appState.$isLoadingIssues
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.isLoadingIssues", old: lastLoadingIssues, new: newValue)
                lastLoadingIssues = newValue
            }
            .store(in: &cancellables)

        var lastSyncing = appState.isSyncing
        appState.$isSyncing
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.isSyncing", old: lastSyncing, new: newValue)
                lastSyncing = newValue
            }
            .store(in: &cancellables)

        var lastSyncStatus = appState.syncStatusMessage
        appState.$syncStatusMessage
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange(
                    "appState.syncStatusMessage",
                    old: lastSyncStatus ?? "nil",
                    new: newValue ?? "nil"
                )
                lastSyncStatus = newValue
            }
            .store(in: &cancellables)

        var lastIssueSync = appState.hasCompletedIssueSync
        appState.$hasCompletedIssueSync
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.hasCompletedIssueSync", old: lastIssueSync, new: newValue)
                lastIssueSync = newValue
            }
            .store(in: &cancellables)

        var lastBoardSync = appState.hasCompletedBoardSync
        appState.$hasCompletedBoardSync
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.hasCompletedBoardSync", old: lastBoardSync, new: newValue)
                lastBoardSync = newValue
            }
            .store(in: &cancellables)

        var lastSavedSync = appState.hasCompletedSavedSearchSync
        appState.$hasCompletedSavedSearchSync
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("appState.hasCompletedSavedSearchSync", old: lastSavedSync, new: newValue)
                lastSavedSync = newValue
            }
            .store(in: &cancellables)

        var lastInitialSync = appState.hasCompletedInitialSync
        Publishers.CombineLatest3(
            appState.$hasCompletedIssueSync,
            appState.$hasCompletedBoardSync,
            appState.$hasCompletedSavedSearchSync
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            guard let self else { return }
            let newValue = self.appState.hasCompletedInitialSync
            self.logStateChange("appState.hasCompletedInitialSync", old: lastInitialSync, new: newValue)
            lastInitialSync = newValue
        }
        .store(in: &cancellables)
    }

    private func observeContainer() {
        var lastRequiresSetup = container.requiresSetup
        container.$requiresSetup
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.logStateChange("container.requiresSetup", old: lastRequiresSetup, new: newValue)
                lastRequiresSetup = newValue
            }
            .store(in: &cancellables)
    }

    private func logStateChange(_ label: String, old: Any, new: Any) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let formatted = String(format: "%.2f", uptime)
        LoggingService.general.info(
            "RootView state: \(label, privacy: .public) \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public) @\(formatted, privacy: .public)s"
        )
    }

    private func logSnapshot(_ reason: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let formatted = String(format: "%.2f", uptime)
        LoggingService.general.info(
            """
            RootView snapshot (\(reason, privacy: .public)) @\(formatted, privacy: .public)s \
            column=\(String(describing: self.appState.columnVisibility), privacy: .public) \
            sidebar=\(self.sidebarSectionsSummary(self.appState.sidebarSections), privacy: .public) \
            selectedSidebar=\(self.sidebarItemSummary(self.appState.selectedSidebarItem), privacy: .public) \
            issues=\(self.appState.issues.count, privacy: .public) \
            selectedIssue=\(self.issueSummary(self.appState.selectedIssue), privacy: .public) \
            selectedIDs=\(self.selectionSummary(self.appState.selectedIssueIDs), privacy: .public) \
            inspector=\(self.appState.isInspectorVisible, privacy: .public) \
            loadingIssues=\(self.appState.isLoadingIssues, privacy: .public) \
            initialSync=\(self.appState.hasCompletedInitialSync, privacy: .public) \
            requiresSetup=\(self.container.requiresSetup, privacy: .public)
            """
        )
    }

    private func sidebarSectionsSummary(_ sections: [SidebarSection]) -> String {
        let itemCount = sections.reduce(0) { $0 + $1.items.count }
        return "sections=\(sections.count) items=\(itemCount)"
    }

    private func sidebarItemSummary(_ item: SidebarItem?) -> String {
        guard let item else { return "nil" }
        return "\(item.id) [\(item.kind.rawValue)]"
    }

    private func issueSummary(_ issue: IssueSummary?) -> String {
        guard let issue else { return "nil" }
        return "\(issue.readableID)"
    }

    private func selectionSummary(_ ids: Set<IssueSummary.ID>) -> String {
        guard !ids.isEmpty else { return "count=0" }
        let sample = ids.map(\.uuidString).sorted().prefix(3).joined(separator: ",")
        return "count=\(ids.count) sample=[\(sample)]"
    }
}
#endif

private struct ToolbarSidebarToggleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarSidebarToggleHostView {
        ToolbarSidebarToggleHostView()
    }

    func updateNSView(_ nsView: ToolbarSidebarToggleHostView, context: Context) {
        nsView.removeSidebarToggleIfNeeded()
    }
}

private struct CommandPaletteOverlay: View {
    @Binding var state: CommandPaletteState
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }
            CommandPaletteDialog(state: $state, onClose: onClose)
                .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 8)
        }
        .transition(.opacity)
    }
}

private struct SplitViewFullHeightLayoutEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitViewFullHeightHostView {
        SplitViewFullHeightHostView()
    }

    func updateNSView(_ nsView: SplitViewFullHeightHostView, context: Context) {
        nsView.scheduleApply()
    }
}

private final class SplitViewFullHeightHostView: NSView {
    private var applyAttempts = 0
    private let maxApplyAttempts = 6
    private var hasScheduledApply = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAttempts = 0
        scheduleApply()
    }

    func scheduleApply() {
        guard !hasScheduledApply else { return }
        hasScheduledApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledApply = false
            self.applyFullHeightLayoutIfNeeded()
        }
    }

    private func applyFullHeightLayoutIfNeeded() {
        if applyFullHeightLayout() {
            applyAttempts = 0
            return
        }
        applyAttempts += 1
        guard applyAttempts < maxApplyAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.applyFullHeightLayoutIfNeeded()
        }
    }

    @discardableResult
    private func applyFullHeightLayout() -> Bool {
        guard let window else { return false }
        let splitViewControllers = resolveSplitViewControllers(for: window)
        guard !splitViewControllers.isEmpty else { return false }
        for splitViewController in splitViewControllers {
            for item in splitViewController.splitViewItems where !item.allowsFullHeightLayout {
                item.allowsFullHeightLayout = true
            }
        }
        return true
    }

    private func resolveSplitViewControllers(for window: NSWindow) -> [NSSplitViewController] {
        var controllers = collectSplitViewControllers(from: window.contentViewController)
        controllers.append(contentsOf: collectSplitViewControllers(from: window.contentView))
        var seen = Set<ObjectIdentifier>()
        return controllers.filter { controller in
            let id = ObjectIdentifier(controller)
            if seen.contains(id) {
                return false
            }
            seen.insert(id)
            return true
        }
    }

    private func collectSplitViewControllers(from viewController: NSViewController?) -> [NSSplitViewController] {
        guard let viewController else { return [] }
        var controllers: [NSSplitViewController] = []
        if let splitViewController = viewController as? NSSplitViewController {
            controllers.append(splitViewController)
        }
        for child in viewController.children {
            controllers.append(contentsOf: collectSplitViewControllers(from: child))
        }
        return controllers
    }

    private func collectSplitViewControllers(from view: NSView?) -> [NSSplitViewController] {
        guard let view else { return [] }
        var controllers: [NSSplitViewController] = []
        if let splitView = view as? NSSplitView {
            if let controller = splitView.delegate as? NSSplitViewController {
                controllers.append(controller)
            } else if let controller = splitViewController(from: splitView) {
                controllers.append(controller)
            }
        }
        for subview in view.subviews {
            controllers.append(contentsOf: collectSplitViewControllers(from: subview))
        }
        return controllers
    }

    private func splitViewController(from view: NSView) -> NSSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let splitViewController = current as? NSSplitViewController {
                return splitViewController
            }
            responder = current.nextResponder
        }
        return nil
    }
}

private final class ToolbarSidebarToggleHostView: NSView {
    private var removalAttempts = 0
    private let maxRemovalAttempts = 6

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeSidebarToggleIfNeeded()
    }

    func removeSidebarToggleIfNeeded() {
        removalAttempts += 1
        guard let toolbar = window?.toolbar else { return }
        let matchesSidebarToggle: (NSToolbarItem) -> Bool = { item in
            item.itemIdentifier == .toggleSidebar ||
                item.action == #selector(NSSplitViewController.toggleSidebar(_:))
        }
        for (index, item) in toolbar.items.enumerated().reversed() where matchesSidebarToggle(item) {
            toolbar.removeItem(at: index)
        }
        let visibleItems = toolbar.visibleItems ?? toolbar.items
        for item in visibleItems where matchesSidebarToggle(item) {
            item.isEnabled = false
            item.view?.isHidden = true
            item.view?.alphaValue = 0
        }
        if removalAttempts < maxRemovalAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.removeSidebarToggleIfNeeded()
            }
        }
    }
}

private struct SearchToolbarField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter issues", text: $text)
                .submitLabel(.search)
        }
        .toolbarFieldStyle()
        .frame(minWidth: 170, idealWidth: 210, maxWidth: 240, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter issues")
    }
}

private struct MainToolbar: CustomizableToolbarContent {
    @ObservedObject var container: AppContainer
    @Binding var searchQuery: String
    let hasUnreadIssues: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "account-switcher") {
            accountSwitcher
        }

        ToolbarItem(id: "search-field", placement: .principal) {
            SearchToolbarField(text: $searchQuery)
        }

        ToolbarItem(id: "command-palette") {
            Button(action: container.commandPalette.open) {
                Label("Command Palette", systemImage: "command.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("k", modifiers: [.command])
            .help("Command palette")
        }

        ToolbarItem(id: "mark-all-read") {
            Button(action: container.markAllIssuesSeen) {
                Label("Mark All as Read", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .disabled(!hasUnreadIssues)
            .help("Mark all issues in the current list as read")
        }

        ToolbarItem(id: "new-issue") {
            NewIssueToolbar(container: container)
                .frame(maxWidth: 280, alignment: .leading)
        }

        ToolbarItem(id: "toggle-details") {
            Button(action: onToggleInspector) {
                Label("Toggle Details", systemImage: "sidebar.trailing")
            }
            .buttonStyle(.accessoryBar)
            .help("Show or hide the issue details column")
        }
    }

    private var accountSwitcher: some View {
        Menu {
            if container.accounts.isEmpty {
                Text("No accounts")
                    .foregroundStyle(.secondary)
                    .disabled(true)
            } else {
                ForEach(container.accounts) { account in
                    Button {
                        Task { await container.switchAccount(to: account.id) }
                    } label: {
                        HStack {
                            Text(account.displayTitle)
                            Spacer(minLength: 0)
                            if account.id == container.activeAccountID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Add Account…") {
                container.startAddingAccount()
            }
        } label: {
            HStack(spacing: 6) {
                UserAvatarView(person: activePerson, size: 22)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.accessoryBar)
        .help("Switch account")
        .accessibilityLabel("Account menu")
    }

    private var activePerson: Person? {
        guard let account = container.activeAccount else { return nil }
        return Person(
            id: Person.stableID(for: account.id.uuidString),
            displayName: account.displayTitle,
            avatarURL: nil,
            login: account.login,
            remoteID: account.userID
        )
    }
}

private struct BoardContentView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var appState: AppState
    let selection: SidebarItem
    let searchQuery: String
    let showDiagnostics: Bool

    var body: some View {
        let board = selection.board ?? IssueBoard(
            id: selection.boardID ?? selection.id,
            name: selection.title,
            isFavorite: true,
            projectNames: []
        )
        let sprintFilter = container.sprintFilter(for: board)
        let diagnosticEvents = appState.boardDataSourceEvents(for: board.id)
        IssueBoardView(
            board: board,
            issues: appState.filteredIssues(searchQuery: searchQuery),
            selection: $appState.selectedIssue,
            isLoading: appState.isLoadingIssues,
            sprintFilter: sprintFilter,
            showDiagnostics: showDiagnostics,
            diagnosticEvents: diagnosticEvents,
            onSelectSprint: { filter in
                Task {
                    await container.updateSprintFilter(filter, for: board)
                }
            }
        )
    }
}

private struct MultiIssueSelectionView: View {
    @EnvironmentObject private var container: AppContainer
    let issues: [IssueSummary]
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                actionSection
                Divider()
                selectionList
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
        .task(id: issues.map(\.id)) {
            statusOptions = []
            priorityOptions = []
            statusOptions = await container.loadStatusOptions(for: issues)
            priorityOptions = await container.loadPriorityOptions(for: issues)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Multiple issues selected")
                .font(.title3.weight(.semibold))
            Text(selectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk actions")
                .font(.headline)
            HStack(spacing: 12) {
                Menu {
                    ForEach(statusMenuOptions, id: \.stableID) { option in
                        Button {
                            applyStatus(option)
                        } label: {
                            let colors = option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
                            statusMenuRow(title: option.displayName, colors: colors)
                        }
                    }
                } label: {
                    Label("Set Status", systemImage: "flag")
                }
                Menu {
                    ForEach(priorityMenuOptions, id: \.stableID) { option in
                        Button {
                            applyPriority(option)
                        } label: {
                            let isTop = IssuePriority(option: option).isTopPriority
                            priorityMenuRow(title: option.displayName, isTopPriority: isTop)
                        }
                    }
                } label: {
                    Label("Set Priority", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private var selectionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected issues")
                .font(.headline)
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    UserAvatarView(person: issue.assignee, size: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(issue.readableID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        HStack(spacing: 8) {
                            Text(issue.projectName)
                                .foregroundStyle(.secondary)
                            Text(issue.assigneeDisplayName)
                                .foregroundStyle(issue.assignee == nil ? .secondary : .primary)
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var selectionSummary: String {
        let issueCount = issues.count
        let projectCount = Set(issues.map(\.projectName)).count
        let peopleCount = Set(issues.compactMap(\.assignee?.id)).count
        return "\(issueCount) \(issueCount == 1 ? "issue" : "issues") in \(projectCount) \(projectCount == 1 ? "project" : "projects") for \(peopleCount) \(peopleCount == 1 ? "person" : "people") selected"
    }

    private var statusMenuOptions: [IssueFieldOption] {
        if statusOptions.isEmpty {
            return IssueStatus.fallbackCases.map { status in
                IssueFieldOption(id: "", name: status.displayName, displayName: status.displayName)
            }
        }
        return statusOptions
    }

    private var priorityMenuOptions: [IssueFieldOption] {
        if priorityOptions.isEmpty {
            return IssuePriority.fallbackCases.map { priority in
                IssueFieldOption(id: "", name: priority.displayName, displayName: priority.displayName)
            }
        }
        return priorityOptions
    }

    private func statusMenuRow(title: String, colors: IssueBadgeColors) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colors.foreground)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.primary)
        }
    }

    private func priorityMenuRow(title: String, isTopPriority: Bool) -> some View {
        HStack(spacing: 8) {
            if isTopPriority {
                Image(systemName: "flag.fill")
                    .foregroundStyle(Color.red)
            } else {
                Color.clear
                    .frame(width: 10, height: 10)
            }
            Text(title)
                .foregroundStyle(.primary)
        }
    }

    private func applyStatus(_ option: IssueFieldOption) {
        applyPatch(IssuePatch(title: nil, description: nil, status: nil, statusOption: option, priority: nil))
    }

    private func applyPriority(_ option: IssueFieldOption) {
        applyPatch(IssuePatch(title: nil, description: nil, status: nil, priority: nil, priorityOption: option))
    }

    private func applyPatch(_ patch: IssuePatch) {
        let selectedIssues = issues
        Task {
            for issue in selectedIssues {
                var issuePatch = patch
                issuePatch.issueReadableID = issue.readableID
                await container.updateIssue(id: issue.id, patch: issuePatch)
            }
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

private struct ToastView: View {
    let toast: ToastNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(toast.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }
}
