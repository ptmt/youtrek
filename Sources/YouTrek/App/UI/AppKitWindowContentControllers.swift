import AppKit
import Combine
import SwiftUI

private enum NativeWindowChrome {
    static let trafficLightCenterInset: CGFloat = 18
    static let trafficLightSpacing: CGFloat = 6

    @MainActor
    static func alignTrafficLights(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ]
        .compactMap { $0 }
        .filter { !$0.isHidden }

        guard let firstButton = buttons.first,
              let titlebarView = firstButton.superview else { return }

        let centerY = titlebarView.bounds.height - trafficLightCenterInset
        var originX = trafficLightCenterInset - (firstButton.frame.width / 2)

        for button in buttons {
            let originY = centerY - (button.frame.height / 2)
            button.setFrameOrigin(
                NSPoint(
                    x: originX.rounded(.toNearestOrAwayFromZero),
                    y: originY.rounded(.toNearestOrAwayFromZero)
                )
            )
            originX += button.frame.width + trafficLightSpacing
        }
    }
}

@MainActor
final class MainWindowViewController: NSViewController {
    private enum WindowSizing {
        static let setupContent = NSSize(width: 480, height: 340)
        static let workspaceDefault = NSSize(width: 1280, height: 800)
        static let workspaceMinimum = NSSize(width: 720, height: 560)
    }

    private let container: AppContainer
    private let setupController: NSHostingController<AnyView>
    private let workspaceController: WorkspaceViewController
    private var activeController: NSViewController?
    private var containerCancellable: AnyCancellable?

    private var isSetup = false
    private var lastConfiguredForSetup: Bool?
    private var pendingConfiguration = false
    private var hasAppliedSetupPresentation = false

    init(container: AppContainer) {
        self.container = container
        self.setupController = NSHostingController(
            rootView: AnyView(
                SetupWindow()
                    .environmentObject(container)
            )
        )
        self.workspaceController = WorkspaceViewController(container: container)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        refreshPresentation()
        containerCancellable = container.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshPresentation()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleWindowConfiguration()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        // Window sizing is managed explicitly here. Hosted SwiftUI content can briefly report a
        // tiny fitting size during updates, which would otherwise collapse the window height.
        scheduleWindowConfiguration()
    }

    private func refreshPresentation() {
        let needsSetupPresentation = container.requiresSetup || !container.appState.hasCompletedInitialSync
        let targetController: NSViewController = needsSetupPresentation ? setupController : workspaceController
        let presentationChanged = activeController !== targetController || isSetup != needsSetupPresentation
        guard presentationChanged else { return }

        if activeController !== targetController {
            if let activeController {
                activeController.view.removeFromSuperview()
                activeController.removeFromParent()
            }
            addChild(targetController)
            targetController.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(targetController.view)
            NSLayoutConstraint.activate([
                targetController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                targetController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                targetController.view.topAnchor.constraint(equalTo: view.topAnchor),
                targetController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            activeController = targetController
        }

        isSetup = needsSetupPresentation
        scheduleWindowConfiguration()
    }

    private func scheduleWindowConfiguration() {
        guard !pendingConfiguration else { return }
        pendingConfiguration = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingConfiguration = false
            self.configureWindowIfNeeded()
        }
    }

    private func configureWindowIfNeeded() {
        guard let window = view.window else { return }
        let needsReconfigure = lastConfiguredForSetup != isSetup
        if needsReconfigure {
            lastConfiguredForSetup = isSetup
        }

        #if DEBUG
        let initialSize = window.frame.size
        LoggingService.general.info(
            "MainWindowViewController: configure start isSetup=\(self.isSetup, privacy: .public) needsReconfigure=\(needsReconfigure, privacy: .public) size=\(Double(initialSize.width), privacy: .public)x\(Double(initialSize.height), privacy: .public)"
        )
        #endif

        if isSetup {
            window.contentMinSize = WindowSizing.setupContent
            window.toolbar = nil
            if needsReconfigure {
                window.styleMask = [.titled, .closable, .fullSizeContentView]
                hasAppliedSetupPresentation = false
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                if let layer = contentView.layer {
                    layer.cornerRadius = 12
                    if #available(macOS 10.13, *) {
                        layer.cornerCurve = .continuous
                    }
                    layer.masksToBounds = true
                }
            }
            if !hasAppliedSetupPresentation {
                window.setContentSize(WindowSizing.setupContent)
                window.center()
                window.makeKeyAndOrderFront(nil)
                hasAppliedSetupPresentation = true
            }
            DispatchQueue.main.async {
                NativeWindowChrome.alignTrafficLights(in: window)
            }
        } else {
            window.contentMinSize = WindowSizing.workspaceMinimum
            if needsReconfigure {
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                if #available(macOS 11.0, *) {
                    window.toolbarStyle = .unified
                    window.titlebarSeparatorStyle = .none
                }
                window.isMovableByWindowBackground = false
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                if let contentView = window.contentView, let layer = contentView.layer {
                    layer.cornerRadius = 0
                    if #available(macOS 10.13, *) {
                        layer.cornerCurve = .continuous
                    }
                    layer.masksToBounds = false
                }
                window.setContentSize(WindowSizing.workspaceDefault)
                window.center()
                hasAppliedSetupPresentation = false
            }
            ensureContentSize(atLeast: WindowSizing.workspaceMinimum, for: window)
        }

        #if DEBUG
        let finalSize = window.frame.size
        LoggingService.general.info(
            "MainWindowViewController: configure end isSetup=\(self.isSetup, privacy: .public) size=\(Double(finalSize.width), privacy: .public)x\(Double(finalSize.height), privacy: .public)"
        )
        #endif
    }

    private func ensureContentSize(atLeast minimumSize: NSSize, for window: NSWindow) {
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let targetSize = NSSize(
            width: max(currentContentSize.width, minimumSize.width),
            height: max(currentContentSize.height, minimumSize.height)
        )
        guard targetSize != currentContentSize else { return }
        window.setContentSize(targetSize)
    }
}

struct WorkspaceIssueListComposer {
    static func selectionShowsDrafts(_ selection: SidebarItem) -> Bool {
        selection.isInbox || selection.title.caseInsensitiveCompare("Inbox") == .orderedSame
    }

    @MainActor
    static func visibleIssues(appState: AppState, selection: SidebarItem?, searchQuery: String) -> [IssueSummary] {
        let baseIssues: [IssueSummary]
        if let selection, selectionShowsDrafts(selection) {
            let drafts = appState.draftRecords
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { IssueSummary.draft($0) }
            baseIssues = drafts + appState.issues
        } else {
            baseIssues = appState.issues
        }
        return appState.filteredIssues(baseIssues, searchQuery: searchQuery)
    }
}

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum DefaultsKey {
        static let showAssigneeColumn = "issueList.showAssigneeColumn"
    }

    private let container: AppContainer
    private let appState: AppState
    private let splitController = RootSplitViewController()
    private let overlayController = NSHostingController(rootView: AnyView(EmptyView()))

    private var toolbarController: WorkspaceToolbarController?
    private var cancellables: Set<AnyCancellable> = []
    private var previousSidebarSelection: SidebarItem?
    private let uiState: WorkspaceUIState

    private var isToolbarRefreshScheduled = false
    private var issueDetailLoadTask: Task<Void, Never>?
    private var lastOverlayShowsNetworkFooter: Bool?

    init(container: AppContainer) {
        self.container = container
        self.appState = container.appState
        self.previousSidebarSelection = container.appState.selectedSidebarItem
        self.uiState = WorkspaceUIState(
            showAssigneeColumn: UserDefaults.standard.bool(forKey: DefaultsKey.showAssigneeColumn)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        issueDetailLoadTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        splitController.onSidebarVisibilityChanged = { [weak self] isSidebarVisible in
            self?.handleSidebarVisibilityChanged(isSidebarVisible)
        }

        addChild(splitController)
        splitController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitController.view)

        addChild(overlayController)
        overlayController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayController.view)

        NSLayoutConstraint.activate([
            splitController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitController.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayController.view.topAnchor.constraint(equalTo: view.topAnchor),
            overlayController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observeState()
        configurePanes()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbarIfNeeded()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        // Keep child hosting controllers from bubbling transient preferred sizes up to the window.
    }

    private func observeState() {
        // Pane root views observe AppState themselves; the controller only needs
        // to keep the (cheap) toolbar state in sync.
        appState.objectWillChange
            .sink { [weak self] in
                self?.scheduleToolbarRefresh()
            }
            .store(in: &cancellables)

        uiState.objectWillChange
            .sink { [weak self] in
                self?.scheduleToolbarRefresh()
            }
            .store(in: &cancellables)

        appState.$selectedIssue
            .dropFirst()
            .sink { [weak self] issue in
                self?.handleSelectedIssueChange(issue)
            }
            .store(in: &cancellables)

        appState.$selectedSidebarItem
            .dropFirst()
            .sink { [weak self] selection in
                guard let self else { return }
                let previousSelection = self.previousSidebarSelection
                self.previousSidebarSelection = selection
                self.handleSelectedSidebarSelectionChange(previous: previousSelection, selection: selection)
            }
            .store(in: &cancellables)

        appState.$columnVisibility
            .dropFirst()
            .sink { [weak self] _ in
                self?.applySplitState()
            }
            .store(in: &cancellables)

        appState.$isInspectorVisible
            .dropFirst()
            .sink { [weak self] _ in
                self?.applySplitState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.applyUserDefaultsChanges()
        }
        .store(in: &cancellables)
    }

    private func applyUserDefaultsChanges() {
        let showAssignee = UserDefaults.standard.bool(forKey: DefaultsKey.showAssigneeColumn)
        if uiState.showAssigneeColumn != showAssignee {
            uiState.showAssigneeColumn = showAssignee
        }
        #if DEBUG
        if uiState.showBoardDiagnostics != AppDebugSettings.showBoardDiagnostics {
            uiState.showBoardDiagnostics = AppDebugSettings.showBoardDiagnostics
        }
        if uiState.showIssueListDiagnostics != AppDebugSettings.showIssueListDiagnostics {
            uiState.showIssueListDiagnostics = AppDebugSettings.showIssueListDiagnostics
        }
        #endif
        updateOverlayContent()
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window else { return }
        if toolbarController == nil {
            let controller = WorkspaceToolbarController(owner: self)
            toolbarController = controller
            window.toolbar = controller.toolbar
            if #available(macOS 11.0, *) {
                window.toolbarStyle = .unified
            }
            DispatchQueue.main.async {
                NativeWindowChrome.alignTrafficLights(in: window)
            }
        }
        toolbarController?.refresh()
    }

    private func scheduleToolbarRefresh() {
        guard !isToolbarRefreshScheduled else { return }
        isToolbarRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isToolbarRefreshScheduled = false
            self.toolbarController?.refresh()
        }
    }

    // Pane root views are installed once and observe AppState/WorkspaceUIState
    // themselves; reassigning rootView on every state change forces SwiftUI to
    // re-root all three hierarchies and is the main source of UI churn.
    private func configurePanes() {
        splitController.configure(
            sidebar: AnyView(
                WorkspaceSidebarPaneRoot(appState: appState, actions: makeSidebarActions())
            ),
            main: AnyView(
                WorkspaceMainPaneRoot(
                    appState: appState,
                    uiState: uiState,
                    container: container
                )
                .environmentObject(container)
            ),
            inspector: AnyView(
                WorkspaceInspectorPaneRoot(appState: appState)
                    .environmentObject(container)
            )
        )
        applySplitState()
        updateOverlayContent()
    }

    private func makeSidebarActions() -> WorkspaceSidebarActions {
        WorkspaceSidebarActions(
            deleteSavedSearch: { [weak self] savedQueryID in
                guard let self else { return }
                Task {
                    await self.container.deleteSavedSearch(id: savedQueryID)
                }
            },
            refreshBoard: { [weak self] item in
                guard let self else { return }
                Task {
                    await self.container.refreshBoardIssues(for: item)
                }
            },
            openBoardInWeb: { [weak self] item in
                self?.container.openBoardInWeb(item)
            },
            boardSyncStatus: { [weak self] item in
                self?.appState.boardSyncStatus(for: item)
            },
            createTodoList: { [weak self] in
                guard let self else { return }
                let suggestedName = "Todo List"
                guard let resolvedName = self.promptForTodoListName(
                    title: "New Todo List",
                    message: "Name your new todo list.",
                    defaultValue: suggestedName
                ) else { return }
                Task {
                    await self.container.createTodoList(named: resolvedName)
                }
            },
            renameTodoList: { [weak self] item in
                guard let self,
                      let listID = item.todoListID else { return }
                guard let resolvedName = self.promptForTodoListName(
                    title: "Rename Todo List",
                    message: "Set a new name for this todo list.",
                    defaultValue: item.title
                ) else { return }
                Task {
                    await self.container.renameTodoList(id: listID, name: resolvedName)
                }
            },
            deleteTodoList: { [weak self] item in
                guard let self,
                      let listID = item.todoListID else { return }
                guard self.confirmDeleteTodoList(named: item.title) else { return }
                Task {
                    await self.container.deleteTodoList(id: listID)
                }
            }
        )
    }

    private func applySplitState() {
        splitController.apply(
            columnVisibility: appState.columnVisibility,
            isInspectorVisible: appState.isInspectorVisible
        )
    }

    private func updateOverlayContent() {
        // The overlay observes AppState itself; only reassign the root view when its
        // non-observed inputs change instead of on every render pass.
        #if DEBUG
        let showNetworkFooter = AppDebugSettings.showNetworkFooter
        guard lastOverlayShowsNetworkFooter != showNetworkFooter else { return }
        lastOverlayShowsNetworkFooter = showNetworkFooter
        let overlay = WorkspaceOverlayHostView(
            appState: appState,
            container: container,
            showNetworkFooter: showNetworkFooter
        )
        #else
        guard lastOverlayShowsNetworkFooter == nil else { return }
        lastOverlayShowsNetworkFooter = false
        let overlay = WorkspaceOverlayHostView(appState: appState, container: container)
        #endif
        overlayController.rootView = AnyView(overlay.environmentObject(container))
    }

    private var hasUnreadIssues: Bool {
        appState.issues.contains { appState.isIssueUnread($0) }
    }

    private func handleSelectedIssueChange(_ issue: IssueSummary?) {
        // Rapid selection changes should not stack overlapping detail fetches;
        // cancel the previous in-flight load before starting the next one.
        issueDetailLoadTask?.cancel()
        issueDetailLoadTask = nil
        guard let issue else {
            appState.selectedDraftID = nil
            return
        }
        if !appState.isInspectorVisible {
            appState.setInspectorVisible(true)
        }
        if appState.selectedIssueIDs != [issue.id] {
            appState.selectedIssueIDs = [issue.id]
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
        issueDetailLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.container.loadIssueDetail(for: issue)
        }
    }

    private func handleSelectedSidebarSelectionChange(previous: SidebarItem?, selection: SidebarItem?) {
        guard let selection else { return }
        container.recordSidebarSelection(selection)

        if (selection.isBoard || selection.isTodoList), appState.isInspectorVisible {
            appState.setInspectorVisible(false)
        }

        if selection.isTodoList {
            appState.selectedDraftID = nil
            appState.selectedIssue = nil
            appState.selectedIssueIDs.removeAll()

            if let todoListID = selection.todoListID {
                let previousTodoListID = previous?.todoListID
                let enteredNewTodoList = previousTodoListID != todoListID
                if enteredNewTodoList, appState.isSidebarVisible {
                    appState.updateColumnVisibility(.doubleColumn, source: "todoList-default")
                }
            }
        }

        if !WorkspaceIssueListComposer.selectionShowsDrafts(selection), appState.selectedIssue?.isDraft == true {
            appState.selectedDraftID = nil
            appState.selectedIssue = nil
            appState.selectedIssueIDs.removeAll()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.container.loadIssues(for: selection)
        }
    }

    private func handleSidebarVisibilityChanged(_ isSidebarVisible: Bool) {
        let nextVisibility: NavigationSplitViewVisibility
        if isSidebarVisible {
            nextVisibility = appState.columnVisibility == .all ? .all : .doubleColumn
        } else {
            nextVisibility = .detailOnly
        }
        guard appState.columnVisibility != nextVisibility else { return }
        appState.updateColumnVisibility(nextVisibility, source: "appkit-split")
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

    fileprivate func setSearchQuery(_ query: String) {
        guard uiState.searchQuery != query else { return }
        uiState.searchQuery = query
        appState.updateSearch(query: query)
    }

    fileprivate var currentSearchQuery: String {
        uiState.searchQuery
    }

    fileprivate func toggleProgressReportingMode() {
        uiState.isProgressReportingMode.toggle()
    }

    fileprivate var isProgressReportingModeEnabled: Bool {
        uiState.isProgressReportingMode
    }

    fileprivate var hasUnreadIssuesInSelection: Bool {
        hasUnreadIssues
    }

    fileprivate func markAllIssuesSeen() {
        container.markAllIssuesSeen()
    }

    fileprivate func openNewIssue() {
        container.presentNewIssueDialog()
    }

    fileprivate func openCommandPalette() {
        container.commandPalette.open()
    }

    fileprivate func toggleInspector() {
        appState.setInspectorVisible(!appState.isInspectorVisible)
    }

    fileprivate func toggleSidebar() {
        if NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) {
            return
        }
        appState.toggleSidebarVisibility(source: "toolbar-fallback")
    }
}

@MainActor
private final class WorkspaceToolbarController: NSObject, NSToolbarDelegate {
    private enum ItemID {
        static let toggleSidebar = NSToolbarItem.Identifier("workspace.toggleSidebar")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let commandPalette = NSToolbarItem.Identifier("workspace.commandPalette")
        static let progressMode = NSToolbarItem.Identifier("workspace.progressMode")
        static let markAllRead = NSToolbarItem.Identifier("workspace.markAllRead")
        static let newIssue = NSToolbarItem.Identifier("workspace.newIssue")
        static let toggleInspector = NSToolbarItem.Identifier("workspace.toggleInspector")
    }

    weak var owner: WorkspaceViewController?
    let toolbar = NSToolbar(identifier: "workspace.toolbar")

    private let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 230, height: 0))
    private weak var progressModeItem: NSToolbarItem?
    private weak var markAllReadItem: NSToolbarItem?

    init(owner: WorkspaceViewController) {
        self.owner = owner
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true

        searchField.sendsSearchStringImmediately = true
        searchField.placeholderString = "Filter issues"
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange)
    }

    func refresh() {
        guard let owner else { return }
        if searchField.stringValue != owner.currentSearchQuery {
            searchField.stringValue = owner.currentSearchQuery
        }

        let progressEnabled = owner.isProgressReportingModeEnabled
        progressModeItem?.label = progressEnabled ? "Exit Progress" : "Report Progress"
        progressModeItem?.paletteLabel = progressEnabled ? "Exit Progress" : "Report Progress"
        progressModeItem?.toolTip = progressEnabled
            ? "Exit progress reporting mode"
            : "Report progress on issues inline"
        progressModeItem?.image = NSImage(systemSymbolName: progressEnabled ? "text.bubble.fill" : "text.bubble", accessibilityDescription: nil)

        markAllReadItem?.isEnabled = owner.hasUnreadIssuesInSelection
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .space,
            ItemID.toggleSidebar,
            ItemID.search,
            ItemID.commandPalette,
            ItemID.progressMode,
            ItemID.markAllRead,
            ItemID.newIssue,
            ItemID.toggleInspector
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.toggleSidebar,
            .space,
            ItemID.search,
            .flexibleSpace,
            ItemID.commandPalette,
            ItemID.progressMode,
            ItemID.markAllRead,
            ItemID.newIssue,
            ItemID.toggleInspector
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.toggleSidebar:
            return makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "Toggle Sidebar",
                symbolName: "sidebar.left",
                action: #selector(toggleSidebar)
            )
        case ItemID.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.toolTip = "Filter issues"
            item.view = searchField
            return item
        case ItemID.commandPalette:
            return makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "Command Palette",
                symbolName: "command.square",
                action: #selector(openCommandPalette)
            )
        case ItemID.progressMode:
            let item = makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "Report Progress",
                symbolName: "text.bubble",
                action: #selector(toggleProgressMode)
            )
            progressModeItem = item
            return item
        case ItemID.markAllRead:
            let item = makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "Mark All Read",
                symbolName: "checkmark.circle",
                action: #selector(markAllRead)
            )
            markAllReadItem = item
            return item
        case ItemID.newIssue:
            return makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "New Issue",
                symbolName: "plus.circle",
                action: #selector(openNewIssue)
            )
        case ItemID.toggleInspector:
            return makeButtonItem(
                itemIdentifier: itemIdentifier,
                label: "Toggle Details",
                symbolName: "sidebar.trailing",
                action: #selector(toggleInspector)
            )
        default:
            return nil
        }
    }

    private func makeButtonItem(
        itemIdentifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        return item
    }

    @objc private func searchFieldDidChange() {
        owner?.setSearchQuery(searchField.stringValue)
    }

    @objc private func toggleSidebar() {
        owner?.toggleSidebar()
    }

    @objc private func openCommandPalette() {
        owner?.openCommandPalette()
    }

    @objc private func toggleProgressMode() {
        owner?.toggleProgressReportingMode()
    }

    @objc private func markAllRead() {
        owner?.markAllIssuesSeen()
    }

    @objc private func openNewIssue() {
        owner?.openNewIssue()
    }

    @objc private func toggleInspector() {
        owner?.toggleInspector()
    }
}

// Controller-owned UI state that pane root views observe directly, so search
// and mode changes update panes without re-rooting their hosting controllers.
@MainActor
final class WorkspaceUIState: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var isProgressReportingMode: Bool = false
    @Published var showAssigneeColumn: Bool
    #if DEBUG
    @Published var showBoardDiagnostics: Bool = AppDebugSettings.showBoardDiagnostics
    @Published var showIssueListDiagnostics: Bool = AppDebugSettings.showIssueListDiagnostics
    #endif

    init(showAssigneeColumn: Bool) {
        self.showAssigneeColumn = showAssigneeColumn
    }
}

struct WorkspaceSidebarActions {
    let deleteSavedSearch: (String) -> Void
    let refreshBoard: (SidebarItem) -> Void
    let openBoardInWeb: (SidebarItem) -> Void
    let boardSyncStatus: (SidebarItem) -> String?
    let createTodoList: () -> Void
    let renameTodoList: (SidebarItem) -> Void
    let deleteTodoList: (SidebarItem) -> Void
}

private struct WorkspaceSidebarPaneRoot: View {
    @ObservedObject var appState: AppState
    let actions: WorkspaceSidebarActions

    var body: some View {
        AppKitSidebarPane(
            sections: appState.sidebarSections,
            selection: Binding(
                get: { appState.selectedSidebarItem },
                set: { appState.selectedSidebarItem = $0 }
            ),
            onDeleteSavedSearch: actions.deleteSavedSearch,
            onRefreshBoard: actions.refreshBoard,
            onOpenBoardInWeb: actions.openBoardInWeb,
            boardSyncStatus: actions.boardSyncStatus,
            onCreateTodoList: actions.createTodoList,
            onRenameTodoList: actions.renameTodoList,
            onDeleteTodoList: actions.deleteTodoList
        )
        .ignoresSafeArea(.all)
        .frame(minWidth: 220, maxHeight: .infinity)
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

private struct WorkspaceMainPaneRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var uiState: WorkspaceUIState
    let container: AppContainer

    var body: some View {
        if let selection = appState.selectedSidebarItem {
            mainContent(for: selection)
        } else if appState.sidebarSections.isEmpty {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left",
                description: Text("Pick an item from the sidebar to continue.")
            )
        }
    }

    @ViewBuilder
    private func mainContent(for selection: SidebarItem) -> some View {
        if selection.isBoard {
            BoardContentView(
                appState: appState,
                selection: selection,
                searchQuery: uiState.searchQuery,
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
        } else if uiState.isProgressReportingMode {
            IssueProgressListView(
                issues: visibleIssues(for: selection),
                selection: selectedIssueBinding,
                selectedIDs: selectedIssueIDsBinding,
                isIssueUnread: { [appState] issue in
                    appState.isIssueUnread(issue)
                }
            )
        } else {
            issueList(for: selection)
        }
    }

    private func issueList(for selection: SidebarItem) -> some View {
        IssueListView(
            issues: visibleIssues(for: selection),
            selection: selectedIssueBinding,
            selectedIDs: selectedIssueIDsBinding,
            showAssigneeColumn: uiState.showAssigneeColumn,
            isLoading: appState.isLoadingIssues,
            hasCompletedSync: appState.hasCompletedIssueSync,
            showDiagnostics: showIssueListDiagnostics,
            diagnosticEvents: appState.issueListDataSourceEvents(for: selection.id),
            diagnosticsTitle: selection.title,
            diagnosticsID: selection.id,
            diagnosticsQuery: selection.query.diagnosticsLabel,
            diagnosticsSearch: uiState.searchQuery,
            isIssueUnread: { [appState] issue in
                appState.isIssueUnread(issue)
            },
            onIssuesRendered: { [appState] count in
                appState.recordIssueListRendered(issueCount: count)
            },
            onDeleteDraft: { [container] draftID in
                container.discardDraft(recordID: draftID)
            }
        )
    }

    private func visibleIssues(for selection: SidebarItem) -> [IssueSummary] {
        WorkspaceIssueListComposer.visibleIssues(
            appState: appState,
            selection: selection,
            searchQuery: uiState.searchQuery
        )
    }

    private var selectedIssueBinding: Binding<IssueSummary?> {
        Binding(
            get: { appState.selectedIssue },
            set: { appState.selectedIssue = $0 }
        )
    }

    private var selectedIssueIDsBinding: Binding<Set<IssueSummary.ID>> {
        Binding(
            get: { appState.selectedIssueIDs },
            set: { appState.selectedIssueIDs = $0 }
        )
    }

    private var showBoardDiagnostics: Bool {
        #if DEBUG
        uiState.showBoardDiagnostics
        #else
        false
        #endif
    }

    private var showIssueListDiagnostics: Bool {
        #if DEBUG
        uiState.showIssueListDiagnostics
        #else
        false
        #endif
    }
}

private struct WorkspaceInspectorPaneRoot: View {
    @ObservedObject var appState: AppState

    var body: some View {
        content
            .inspectorColumnWidth(min: 320, ideal: 400, max: 500)
            .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if let draftID = appState.selectedDraftID {
            if let record = appState.draftRecord(id: draftID) {
                DraftIssueDetailView(record: record)
            } else {
                ContentUnavailableView(
                    "Draft not found",
                    systemImage: "square.and.pencil",
                    description: Text("The selected draft is no longer available.")
                )
            }
        } else if selectedIssues.count > 1 {
            MultiIssueSelectionView(issues: selectedIssues)
        } else if let issue = appState.selectedIssue ?? selectedIssues.first {
            IssueDetailView(
                issue: issue,
                detail: appState.issueDetail(for: issue),
                isLoadingDetail: appState.isIssueDetailLoading(issue.id)
            )
        } else if appState.sidebarSections.isEmpty || (appState.isLoadingIssues && appState.issues.isEmpty) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select an issue",
                systemImage: "square.stack.3d.up",
                description: Text("Choose an issue from the middle column to inspect details.")
            )
        }
    }

    private var selectedIssues: [IssueSummary] {
        appState.issues.filter { appState.selectedIssueIDs.contains($0.id) }
    }
}

private struct WorkspaceOverlayHostView: View {
    @ObservedObject var appState: AppState
    let container: AppContainer

    #if DEBUG
    let showNetworkFooter: Bool
    #endif

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(item: conflictBinding) { conflict in
                ConflictResolutionDialog(conflict: conflict)
            }
            .sheet(item: newIssueDialogItemBinding) { _ in
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
                    ToastView(toast: toast) {
                        container.activateToast(toast)
                    }
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
            .overlay(alignment: .bottom) {
                if showNetworkFooter {
                    NetworkRequestFooterView(monitor: container.networkMonitor)
                }
            }
            .background(RootDebugStateTracker(appState: appState, container: container))
            #endif
    }

    private var conflictBinding: Binding<ConflictNotice?> {
        Binding(
            get: { appState.activeConflict },
            set: { appState.activeConflict = $0 }
        )
    }

    private var newIssueDialogItemBinding: Binding<NewIssueDialogState?> {
        Binding(
            get: { appState.activeNewIssueDialog },
            set: { appState.activeNewIssueDialog = $0 }
        )
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

@MainActor
final class SettingsWindowViewController: NSViewController {
    private let container: AppContainer
    private let themeControl = NSSegmentedControl(
        labels: AppTheme.allCases.map(\AppTheme.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    init(container: AppContainer) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20

        let signInButton = NSButton(title: "Sign in to YouTrack", target: self, action: #selector(beginSignIn))
        signInButton.keyEquivalent = "l"
        signInButton.keyEquivalentModifierMask = [.command]

        themeControl.target = self
        themeControl.action = #selector(themeSelectionDidChange)
        themeControl.segmentStyle = .rounded
        updateThemeSelection()

        let useVibrancy = NSButton(checkboxWithTitle: "Use vibrancy", target: nil, action: nil)
        useVibrancy.state = .on
        useVibrancy.isEnabled = false

        let highContrast = NSButton(checkboxWithTitle: "High contrast", target: nil, action: nil)
        highContrast.state = .off
        highContrast.isEnabled = false

        let refreshNowButton = NSButton(title: "Refresh now", target: nil, action: nil)
        refreshNowButton.isEnabled = false

        stack.addArrangedSubview(makeSection(title: "Account", views: [signInButton]))
        stack.addArrangedSubview(makeSection(title: "Appearance", views: [themeControl, useVibrancy, highContrast]))
        stack.addArrangedSubview(makeSection(title: "Data", views: [refreshNowButton]))

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateThemeSelection()
    }

    private func makeSection(title: String, views: [NSView]) -> NSView {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        sectionStack.addArrangedSubview(titleLabel)

        for subview in views {
            sectionStack.addArrangedSubview(subview)
        }

        return sectionStack
    }

    private func updateThemeSelection() {
        let rawTheme = UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? AppTheme.dark.rawValue
        let theme = AppTheme(rawValue: rawTheme) ?? .dark
        let index = AppTheme.allCases.firstIndex(of: theme) ?? 0
        themeControl.selectedSegment = index
    }

    @objc private func beginSignIn() {
        container.beginSignIn()
    }

    @objc private func themeSelectionDidChange() {
        let index = themeControl.selectedSegment
        guard AppTheme.allCases.indices.contains(index) else { return }
        let theme = AppTheme.allCases[index]
        UserDefaults.standard.set(theme.rawValue, forKey: AppTheme.storageKey)
    }
}
