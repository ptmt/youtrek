import AppKit
import SwiftUI
#if DEBUG
import Combine
#endif

@MainActor
struct AppKitSidebarPane: NSViewRepresentable {
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
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        private var parent: AppKitSidebarPane
        private weak var outlineView: NSOutlineView?
        private var sectionNodes: [SidebarSectionNode] = []
        private var childNodesBySectionID: [String: [AnyObject]] = [:]
        private var isApplyingSelection = false
        private let contextMenu = NSMenu(title: "Sidebar")
        private var lastAppliedSections: [SidebarSection] = []
        private var lastAppliedSelectionID: SidebarItem.ID?

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
            let sectionsChanged = lastAppliedSections != parent.sections
            if sectionsChanged {
                rebuildNodes()
                outlineView.reloadData()
                for sectionNode in sectionNodes {
                    outlineView.expandItem(sectionNode)
                }
                lastAppliedSections = parent.sections
            }
            let selectionID = parent.selection?.id
            if sectionsChanged || selectionID != lastAppliedSelectionID {
                syncSelection(with: outlineView)
                lastAppliedSelectionID = selectionID
            }
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

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            item is SidebarSectionNode
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            item is SidebarSectionNode
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
final class SidebarOutlineContainerView: NSView {
    let outlineView = NSOutlineView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let backgroundView = NSVisualEffectView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar-column"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 4
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

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .contentBackground
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active

        addSubview(backgroundView)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

struct AppKitRootSplitView: NSViewControllerRepresentable {
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
final class RootSplitViewController: NSSplitViewController {
    var onSidebarVisibilityChanged: ((Bool) -> Void)?

    private let sidebarController = SplitPaneHostingController()
    private let mainController = SplitPaneHostingController()
    private let inspectorController = SplitPaneHostingController()

    private lazy var sidebarItem: NSSplitViewItem = {
        let item = NSSplitViewItem(sidebarWithViewController: sidebarController)
        item.canCollapse = true
        item.minimumThickness = 220
        item.maximumThickness = 340
        item.allowsFullHeightLayout = true
        return item
    }()

    private lazy var mainItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: mainController)
        item.minimumThickness = 420
        item.allowsFullHeightLayout = true
        return item
    }()

    private lazy var inspectorItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: inspectorController)
        item.canCollapse = true
        item.minimumThickness = 320
        item.maximumThickness = 500
        item.allowsFullHeightLayout = true
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
        sidebarController.setRootView(sidebar)
        mainController.setRootView(main)
        inspectorController.setRootView(inspector)
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

@MainActor
private final class SplitPaneHostingController: NSViewController {
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))

    override func loadView() {
        view = NSView(frame: .zero)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func setRootView(_ rootView: AnyView) {
        hostingController.rootView = rootView
    }
}

#if DEBUG
struct RootDebugStateTracker: View {
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

struct ToolbarSidebarToggleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarSidebarToggleHostView {
        ToolbarSidebarToggleHostView()
    }

    func updateNSView(_ nsView: ToolbarSidebarToggleHostView, context: Context) {
        nsView.removeSidebarToggleIfNeeded()
    }
}

struct CommandPaletteOverlay: View {
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

struct SplitViewFullHeightLayoutEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> SplitViewFullHeightHostView {
        SplitViewFullHeightHostView()
    }

    func updateNSView(_ nsView: SplitViewFullHeightHostView, context: Context) {
        nsView.scheduleApply()
    }
}

final class SplitViewFullHeightHostView: NSView {
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

final class ToolbarSidebarToggleHostView: NSView {
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

struct MainToolbar: CustomizableToolbarContent {
    @ObservedObject var container: AppContainer
    @Binding var searchQuery: String
    @Binding var isProgressReportingMode: Bool
    let hasUnreadIssues: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "toggle-sidebar", placement: .navigation) {
            Button(action: onToggleSidebar) {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .help("Show or hide the sidebar")
        }

        ToolbarItem(id: "account-switcher", placement: .navigation) {
            accountSwitcher
        }

        ToolbarItem(id: "search-field", placement: .principal) {
            SearchToolbarField(text: $searchQuery)
        }

        ToolbarItem(id: "command-palette", placement: .automatic) {
            Button(action: container.commandPalette.open) {
                Label("Command Palette", systemImage: "command.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("k", modifiers: [.command])
            .help("Command palette")
        }

        ToolbarItem(id: "progress-mode", placement: .automatic) {
            Button {
                isProgressReportingMode.toggle()
            } label: {
                Label(
                    "Report Progress",
                    systemImage: isProgressReportingMode ? "text.bubble.fill" : "text.bubble"
                )
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(isProgressReportingMode ? "Exit progress reporting mode" : "Report progress on issues inline")
        }

        ToolbarItem(id: "mark-all-read", placement: .automatic) {
            Button(action: container.markAllIssuesSeen) {
                Label("Mark All as Read", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .disabled(!hasUnreadIssues)
            .help("Mark all issues in the current list as read")
        }

        ToolbarItem(id: "new-issue", placement: .primaryAction) {
            NewIssueToolbar(container: container)
                .frame(maxWidth: 280, alignment: .leading)
        }

        ToolbarItem(id: "toggle-details", placement: .automatic) {
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

struct BoardContentView: View {
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

struct MultiIssueSelectionView: View {
    @EnvironmentObject private var container: AppContainer
    let issues: [IssueSummary]
    @State private var statusOptionsByProject: [String: [IssueFieldOption]] = [:]
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
        .task(id: issues.map { "\($0.id.uuidString):\($0.projectName)" }.sorted().joined()) {
            statusOptionsByProject = [:]
            priorityOptions = []
            let groupedIssues = Dictionary(grouping: issues, by: projectStatusKey(for:))
            var loaded: [String: [IssueFieldOption]] = [:]
            for (_, grouped) in groupedIssues where !grouped.isEmpty {
                guard let issue = grouped.first else { continue }
                loaded[projectStatusKey(for: issue)] = await container.loadStatusOptions(for: issue)
            }
            statusOptionsByProject = loaded
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
        if let options = singleProjectStatusOptions, !options.isEmpty {
            return options
        }
        if statusOptionsByProject.values.allSatisfy({ $0.isEmpty }) {
            return IssueStatus.fallbackCases.map { status in
                IssueFieldOption(id: "", name: status.displayName, displayName: status.displayName)
            }
        }
        return statusOptionsByProject.values.flatMap { $0 }
    }

    private var priorityMenuOptions: [IssueFieldOption] {
        if priorityOptions.isEmpty {
            return IssuePriority.fallbackCases.map { priority in
                IssueFieldOption(id: "", name: priority.displayName, displayName: priority.displayName)
            }
        }
        return priorityOptions
    }

    private var singleProjectStatusOptions: [IssueFieldOption]? {
        let projectKeys = Set(issues.map(projectStatusKey(for:)))
        guard projectKeys.count == 1, let key = projectKeys.first else {
            return nil
        }
        return statusOptionsByProject[key]
    }

    private func projectStatusKey(for issue: IssueSummary) -> String {
        issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

struct SyncCompleteIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Syncing complete")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 8)
    }
}

struct ToastView: View {
    let toast: ToastNotice
    var onActivate: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onActivate, toast.isInteractive {
                Button(action: onActivate) {
                    content
                }
                .buttonStyle(.plain)
                .help(toast.issueToOpen.map { "Open \($0.readableID)" } ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Open issue")
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(toast.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if toast.isInteractive {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }
}
