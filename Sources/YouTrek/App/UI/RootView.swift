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

    private var sidebarContent: some View {
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
            }
        }
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

@MainActor
private struct AppKitSidebarPane: NSViewRepresentable {
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?
    let onDeleteSavedSearch: ((String) -> Void)?
    let onRefreshBoard: ((SidebarItem) -> Void)?
    let onOpenBoardInWeb: ((SidebarItem) -> Void)?
    let boardSyncStatus: ((SidebarItem) -> String?)?
    let onCreateTodoList: (() -> Void)?
    let onRenameTodoList: ((SidebarItem) -> Void)?
    let onDeleteTodoList: ((SidebarItem) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SidebarOutlineContainerView {
        let view = SidebarOutlineContainerView()
        context.coordinator.configure(outlineView: view.outlineView)
        context.coordinator.apply(parent: self, outlineView: view.outlineView)
        return view
    }

    func updateNSView(_ nsView: SidebarOutlineContainerView, context: Context) {
        context.coordinator.apply(parent: self, outlineView: nsView.outlineView)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSOutlineViewDataSource, @preconcurrency NSOutlineViewDelegate, @preconcurrency NSMenuDelegate {
        private var parent: AppKitSidebarPane
        private weak var outlineView: NSOutlineView?
        private var sectionNodes: [SidebarSectionNode] = []
        private var childNodesBySectionID: [String: [AnyObject]] = [:]
        private var isApplyingSelection = false
        private let contextMenu = NSMenu(title: "Sidebar")

        init(parent: AppKitSidebarPane) {
            self.parent = parent
            super.init()
        }

        func configure(outlineView: NSOutlineView) {
            self.outlineView = outlineView
            outlineView.delegate = self
            outlineView.dataSource = self
            outlineView.menu = contextMenu
            contextMenu.delegate = self
        }

        func apply(parent: AppKitSidebarPane, outlineView: NSOutlineView) {
            self.parent = parent
            rebuildNodes()
            outlineView.reloadData()
            for sectionNode in sectionNodes {
                outlineView.expandItem(sectionNode)
            }
            syncSelection(with: outlineView)
        }

        private func rebuildNodes() {
            sectionNodes = parent.sections.map(SidebarSectionNode.init)
            childNodesBySectionID = [:]
            for section in parent.sections {
                var children: [AnyObject] = section.items.map { SidebarItemNode(item: $0) }
                if children.isEmpty, let emptyMessage = section.emptyMessage {
                    children = [
                        SidebarEmptyNode(
                            sectionID: section.id,
                            message: emptyMessage,
                            isCreateAction: section.id == "todo"
                        )
                    ]
                }
                childNodesBySectionID[section.id] = children
            }
        }

        private func syncSelection(with outlineView: NSOutlineView) {
            guard let selected = parent.selection else {
                if outlineView.selectedRow != -1 {
                    isApplyingSelection = true
                    outlineView.deselectAll(nil)
                    isApplyingSelection = false
                }
                return
            }
            guard let targetNode = itemNode(for: selected.id) else { return }
            let row = outlineView.row(forItem: targetNode)
            guard row >= 0, outlineView.selectedRow != row else { return }
            isApplyingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func itemNode(for id: SidebarItem.ID) -> SidebarItemNode? {
            for children in childNodesBySectionID.values {
                for child in children {
                    if let itemNode = child as? SidebarItemNode, itemNode.item.id == id {
                        return itemNode
                    }
                }
            }
            return nil
        }

        private func item(for id: SidebarItem.ID) -> SidebarItem? {
            for section in parent.sections {
                if let item = section.items.first(where: { $0.id == id }) {
                    return item
                }
            }
            return nil
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return sectionNodes.count
            }
            if let sectionNode = item as? SidebarSectionNode {
                return childNodesBySectionID[sectionNode.section.id]?.count ?? 0
            }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is SidebarSectionNode
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return sectionNodes[index]
            }
            if let sectionNode = item as? SidebarSectionNode,
               let children = childNodesBySectionID[sectionNode.section.id] {
                return children[index]
            }
            return NSObject()
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            if item is SidebarSectionNode {
                return false
            }
            if let emptyNode = item as? SidebarEmptyNode {
                if emptyNode.isCreateAction {
                    parent.onCreateTodoList?()
                }
                return false
            }
            return item is SidebarItemNode
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outlineView else { return }
            let selectedRow = outlineView.selectedRow
            guard selectedRow >= 0,
                  let itemNode = outlineView.item(atRow: selectedRow) as? SidebarItemNode else {
                if parent.selection != nil {
                    parent.selection = nil
                }
                return
            }
            if parent.selection?.id != itemNode.item.id {
                parent.selection = itemNode.item
            }
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            if item is SidebarSectionNode { return 30 }
            if item is SidebarEmptyNode { return 24 }
            return 26
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let sectionNode = item as? SidebarSectionNode {
                let view = outlineView.makeView(withIdentifier: SidebarSectionCell.identifier, owner: nil) as? SidebarSectionCell
                    ?? SidebarSectionCell()
                view.configure(title: sectionNode.section.title)
                return view
            }
            if let itemNode = item as? SidebarItemNode {
                let view = outlineView.makeView(withIdentifier: SidebarItemCell.identifier, owner: nil) as? SidebarItemCell
                    ?? SidebarItemCell()
                view.configure(item: itemNode.item)
                return view
            }
            if let emptyNode = item as? SidebarEmptyNode {
                let view = outlineView.makeView(withIdentifier: SidebarEmptyCell.identifier, owner: nil) as? SidebarEmptyCell
                    ?? SidebarEmptyCell()
                view.configure(message: emptyNode.message, isAction: emptyNode.isCreateAction)
                return view
            }
            return nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let clickedRow = outlineView.clickedRow
            guard clickedRow >= 0 else { return }
            guard let clickedItem = outlineView.item(atRow: clickedRow) else { return }

            if let sectionNode = clickedItem as? SidebarSectionNode {
                if sectionNode.section.id == "todo" {
                    let item = NSMenuItem(title: "Create Todo List", action: #selector(createTodoList), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
                return
            }

            if let emptyNode = clickedItem as? SidebarEmptyNode {
                if emptyNode.isCreateAction {
                    let item = NSMenuItem(title: "Create Todo List", action: #selector(createTodoList), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
                return
            }

            guard let itemNode = clickedItem as? SidebarItemNode else { return }
            let sidebarItem = itemNode.item

            if let savedQueryID = sidebarItem.savedQueryID {
                let delete = NSMenuItem(title: "Delete Saved Search", action: #selector(deleteSavedSearch(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = savedQueryID
                menu.addItem(delete)
                return
            }

            if sidebarItem.isBoard {
                let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshBoard(_:)), keyEquivalent: "")
                refresh.target = self
                refresh.representedObject = sidebarItem.id
                menu.addItem(refresh)

                let openInWeb = NSMenuItem(title: "Open in Web", action: #selector(openBoardInWeb(_:)), keyEquivalent: "")
                openInWeb.target = self
                openInWeb.representedObject = sidebarItem.id
                menu.addItem(openInWeb)

                if let status = parent.boardSyncStatus?(sidebarItem) {
                    menu.addItem(NSMenuItem.separator())
                    let statusItem = NSMenuItem(title: "Last synced: \(status)", action: nil, keyEquivalent: "")
                    statusItem.isEnabled = false
                    menu.addItem(statusItem)
                }
                return
            }

            if sidebarItem.isTodoList {
                let rename = NSMenuItem(title: "Rename", action: #selector(renameTodoList(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = sidebarItem.id
                menu.addItem(rename)

                let delete = NSMenuItem(title: "Delete", action: #selector(deleteTodoList(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = sidebarItem.id
                menu.addItem(delete)
            }
        }

        @objc private func createTodoList() {
            parent.onCreateTodoList?()
        }

        @objc private func deleteSavedSearch(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            parent.onDeleteSavedSearch?(id)
        }

        @objc private func refreshBoard(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? SidebarItem.ID,
                  let item = item(for: id) else { return }
            parent.onRefreshBoard?(item)
        }

        @objc private func openBoardInWeb(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? SidebarItem.ID,
                  let item = item(for: id) else { return }
            parent.onOpenBoardInWeb?(item)
        }

        @objc private func renameTodoList(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? SidebarItem.ID,
                  let item = item(for: id) else { return }
            parent.onRenameTodoList?(item)
        }

        @objc private func deleteTodoList(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? SidebarItem.ID,
                  let item = item(for: id) else { return }
            parent.onDeleteTodoList?(item)
        }
    }
}

@MainActor
private final class SidebarOutlineContainerView: NSView {
    let outlineView = NSOutlineView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar-column"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        if #available(macOS 12.0, *) {
            outlineView.style = .sourceList
        }
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class SidebarSectionNode: NSObject {
    let section: SidebarSection

    init(_ section: SidebarSection) {
        self.section = section
    }
}

private final class SidebarItemNode: NSObject {
    let item: SidebarItem

    init(item: SidebarItem) {
        self.item = item
    }
}

private final class SidebarEmptyNode: NSObject {
    let sectionID: String
    let message: String
    let isCreateAction: Bool

    init(sectionID: String, message: String, isCreateAction: Bool) {
        self.sectionID = sectionID
        self.message = message
        self.isCreateAction = isCreateAction
    }
}

private final class SidebarSectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-section-cell")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String) {
        label.stringValue = title.uppercased()
    }
}

private final class SidebarItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-item-cell")
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .labelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(item: SidebarItem) {
        label.stringValue = item.title
        iconView.image = NSImage(systemSymbolName: item.iconName, accessibilityDescription: item.title)
    }
}

private final class SidebarEmptyCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-empty-cell")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(message: String, isAction: Bool) {
        label.stringValue = isAction ? "+ \(message)" : message
    }
}

private struct AppKitRootSplitView: NSViewControllerRepresentable {
    let sidebar: AnyView
    let main: AnyView
    let inspector: AnyView
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isInspectorVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context) -> RootSplitViewController {
        let controller = RootSplitViewController()
        controller.configure(sidebar: sidebar, main: main, inspector: inspector)
        controller.onSidebarVisibilityChanged = { isSidebarVisible in
            Task { @MainActor in
                context.coordinator.updateColumnVisibility(sidebarVisible: isSidebarVisible)
            }
        }
        controller.apply(columnVisibility: columnVisibility, isInspectorVisible: isInspectorVisible)
        return controller
    }

    func updateNSViewController(_ controller: RootSplitViewController, context: Context) {
        context.coordinator.parent = self
        controller.configure(sidebar: sidebar, main: main, inspector: inspector)
        controller.onSidebarVisibilityChanged = { isSidebarVisible in
            Task { @MainActor in
                context.coordinator.updateColumnVisibility(sidebarVisible: isSidebarVisible)
            }
        }
        controller.apply(columnVisibility: columnVisibility, isInspectorVisible: isInspectorVisible)
    }

    final class Coordinator {
        var parent: AppKitRootSplitView

        init(parent: AppKitRootSplitView) {
            self.parent = parent
        }

        @MainActor func updateColumnVisibility(sidebarVisible: Bool) {
            let nextVisibility: NavigationSplitViewVisibility
            if sidebarVisible {
                nextVisibility = parent.columnVisibility == .all ? .all : .doubleColumn
            } else {
                nextVisibility = .detailOnly
            }
            guard parent.columnVisibility != nextVisibility else { return }
            parent.columnVisibility = nextVisibility
        }
    }
}

@MainActor
private final class RootSplitViewController: NSSplitViewController {
    var onSidebarVisibilityChanged: ((Bool) -> Void)?

    private let sidebarController = NSHostingController(rootView: AnyView(EmptyView()))
    private let mainController = NSHostingController(rootView: AnyView(EmptyView()))
    private let inspectorController = NSHostingController(rootView: AnyView(EmptyView()))

    private lazy var sidebarItem: NSSplitViewItem = {
        let item = NSSplitViewItem(sidebarWithViewController: sidebarController)
        item.canCollapse = true
        item.minimumThickness = 220
        item.maximumThickness = 340
        return item
    }()

    private lazy var mainItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: mainController)
        item.minimumThickness = 420
        return item
    }()

    private lazy var inspectorItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: inspectorController)
        item.canCollapse = true
        item.minimumThickness = 320
        item.maximumThickness = 500
        return item
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(sidebar: AnyView, main: AnyView, inspector: AnyView) {
        sidebarController.rootView = sidebar
        mainController.rootView = main
        inspectorController.rootView = inspector
    }

    func apply(columnVisibility: NavigationSplitViewVisibility, isInspectorVisible: Bool) {
        let sidebarVisible = isSidebarVisible(for: columnVisibility)
        let shouldHideSidebar = !sidebarVisible
        if sidebarItem.isCollapsed != shouldHideSidebar {
            sidebarItem.isCollapsed = shouldHideSidebar
        }

        let shouldHideInspector = !isInspectorVisible
        if inspectorItem.isCollapsed != shouldHideInspector {
            inspectorItem.isCollapsed = shouldHideInspector
        }
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        onSidebarVisibilityChanged?(!sidebarItem.isCollapsed)
    }

    private func isSidebarVisible(for visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
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
