import AppKit
import SwiftUI

@MainActor
struct IssueListView: NSViewRepresentable {
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let showAssigneeColumn: Bool
    let isLoading: Bool
    let hasCompletedSync: Bool
    let showDiagnostics: Bool
    let diagnosticEvents: [IssueListDataSourceEvent]
    let diagnosticsTitle: String?
    let diagnosticsID: String?
    let diagnosticsQuery: String?
    let diagnosticsSearch: String?
    let isIssueUnread: (IssueSummary) -> Bool
    let onIssuesRendered: ((Int) -> Void)?
    let onDeleteDraft: ((UUID) -> Void)?

    private static let loadingIndicatorDelayNanoseconds: UInt64 = 250_000_000

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> IssueListContainerView {
        let view = IssueListContainerView()
        context.coordinator.configure(containerView: view)
        context.coordinator.apply(parent: self, containerView: view)
        return view
    }

    func updateNSView(_ nsView: IssueListContainerView, context: Context) {
        context.coordinator.apply(parent: self, containerView: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var parent: IssueListView
        private weak var tableView: NSTableView?
        private weak var containerView: IssueListContainerView?
        private var isApplyingSelection = false
        private let contextMenu = NSMenu(title: "Issue List")
        private let titleColumnID = NSUserInterfaceItemIdentifier("issue-title-column")
        private let assigneeColumnID = NSUserInterfaceItemIdentifier("issue-assignee-column")

        private var loadingVisibilityTask: Task<Void, Never>?
        private var showsLoadingView = false
        private var loadingInput: LoadingInput?
        private var hasAppliedSelectionState = false
        private var lastSelectionID: IssueSummary.ID?
        private var lastSelectedIDs: Set<IssueSummary.ID>?
        private var lastRenderSnapshot: IssueListRenderSnapshot?

        private struct LoadingInput: Equatable {
            let isLoading: Bool
            let isEmpty: Bool
        }

        init(parent: IssueListView) {
            self.parent = parent
            super.init()
        }

        deinit {
            loadingVisibilityTask?.cancel()
        }

        func configure(containerView: IssueListContainerView) {
            self.containerView = containerView
            self.tableView = containerView.tableView
            configure(tableView: containerView.tableView)
            containerView.diagnosticsView.onCopy = { [weak self] in
                self?.copyDiagnostics()
            }
        }

        func apply(parent: IssueListView, containerView: IssueListContainerView) {
            self.parent = parent
            self.containerView = containerView
            self.tableView = containerView.tableView

            let isInitialApply = !hasAppliedSelectionState
            let selectionChanged = lastSelectionID != parent.selection?.id
            if isInitialApply || selectionChanged {
                syncSelectionState()
            }
            let selectedIDsChanged = lastSelectedIDs != parent.selectedIDs
            if isInitialApply || selectedIDsChanged {
                updateSelection(from: parent.selectedIDs)
            }
            hasAppliedSelectionState = true
            lastSelectionID = parent.selection?.id
            lastSelectedIDs = parent.selectedIDs

            // `apply` runs on every SwiftUI invalidation of the hosting view; only touch
            // the table when the rendered content actually changed.
            let snapshot = IssueListRenderSnapshot(
                issues: parent.issues,
                unreadFlags: parent.issues.map(parent.isIssueUnread),
                showAssigneeColumn: parent.showAssigneeColumn
            )
            switch IssueListReloadPlanner.action(previous: lastRenderSnapshot, next: snapshot) {
            case .none:
                break
            case .full:
                rebuildColumns(on: containerView.tableView)
                containerView.tableView.reloadData()
            case .rows(let rows):
                let columns = IndexSet(integersIn: 0..<containerView.tableView.tableColumns.count)
                containerView.tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
            }
            lastRenderSnapshot = snapshot
            syncSelection(with: containerView.tableView)

            updateLoadingVisibilityIfNeeded()
            updateContentVisibility()
            updateDiagnostics()

            parent.onIssuesRendered?(parent.issues.count)
        }

        private func configure(tableView: NSTableView) {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.menu = contextMenu
            tableView.headerView = nil
            tableView.cornerView = nil
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.gridStyleMask = []
            tableView.focusRingType = .none
            tableView.selectionHighlightStyle = .regular
            tableView.intercellSpacing = NSSize(width: 0, height: 3)
            tableView.rowHeight = 40
            contextMenu.delegate = self
            rebuildColumns(on: tableView)
        }

        private func syncSelectionState() {
            if let selectedIssue = parent.selection {
                let nextIDs: Set<IssueSummary.ID> = [selectedIssue.id]
                if parent.selectedIDs != nextIDs {
                    parent.selectedIDs = nextIDs
                }
            } else if parent.selectedIDs.count <= 1, !parent.selectedIDs.isEmpty {
                parent.selectedIDs.removeAll()
            }
        }

        private func updateSelection(from newIDs: Set<IssueSummary.ID>) {
            let nextSelection: IssueSummary?
            if newIDs.count == 1,
               let firstID = newIDs.first,
               let issue = parent.issues.first(where: { $0.id == firstID }) {
                nextSelection = issue
            } else {
                nextSelection = nil
            }

            if parent.selection?.id != nextSelection?.id {
                parent.selection = nextSelection
            }
        }

        private func updateLoadingVisibilityIfNeeded() {
            let nextInput = LoadingInput(isLoading: parent.isLoading, isEmpty: parent.issues.isEmpty)
            guard loadingInput != nextInput else { return }
            loadingInput = nextInput

            loadingVisibilityTask?.cancel()
            loadingVisibilityTask = nil

            guard nextInput.isLoading, nextInput.isEmpty else {
                showsLoadingView = false
                return
            }

            showsLoadingView = false
            loadingVisibilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: IssueListView.loadingIndicatorDelayNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.showsLoadingView = true
                self.loadingVisibilityTask = nil
                self.updateContentVisibility()
            }
        }

        private func updateContentVisibility() {
            guard let containerView else { return }
            let state: IssueListContainerView.ContentState
            if !parent.issues.isEmpty {
                state = .table
            } else if showsLoadingView && parent.issues.isEmpty {
                state = .loading
            } else if parent.issues.isEmpty && parent.hasCompletedSync {
                state = .empty
            } else {
                state = .placeholder
            }
            containerView.setContentState(state)
        }

        private func updateDiagnostics() {
            guard let containerView else { return }
            containerView.diagnosticsView.isHidden = !parent.showDiagnostics
            guard parent.showDiagnostics else { return }
            containerView.diagnosticsView.update(text: diagnosticsDisplayText())
        }

        private static let diagnosticsDisplayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        private static let diagnosticsCopyFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return formatter
        }()

        private func diagnosticsDisplayText() -> String {
            let title = parent.diagnosticsTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleLabel = (title?.isEmpty == false) ? title ?? "-" : "-"
            let id = parent.diagnosticsID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let idLabel = (id?.isEmpty == false) ? id ?? "-" : "-"
            let query = parent.diagnosticsQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryLabel = (query?.isEmpty == false) ? query ?? "-" : "-"
            let search = parent.diagnosticsSearch?.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchLabel = (search?.isEmpty == false) ? search ?? "-" : "-"

            var lines: [String] = []
            lines.append("Selection: \(titleLabel)")
            if idLabel != "-" {
                lines.append("Selection ID: \(idLabel)")
            }
            lines.append("Issues: \(parent.issues.count)  Loading: \(parent.isLoading ? "Yes" : "No")")
            lines.append("Query: \(queryLabel)")
            lines.append("Search filter: \(searchLabel)")

            if parent.diagnosticEvents.isEmpty {
                lines.append("Data source events: none")
            } else {
                lines.append("Data source events (\(parent.diagnosticEvents.count)):")
                for event in parent.diagnosticEvents.reversed() {
                    let stamp = Self.diagnosticsDisplayFormatter.string(from: event.timestamp)
                    lines.append("\(stamp)  \(event.message)")
                }
            }

            return lines.joined(separator: "\n")
        }

        private func diagnosticsCopyText() -> String {
            let title = parent.diagnosticsTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleLabel = (title?.isEmpty == false) ? title ?? "-" : "-"
            let id = parent.diagnosticsID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let idLabel = (id?.isEmpty == false) ? id ?? "-" : "-"
            let query = parent.diagnosticsQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryLabel = (query?.isEmpty == false) ? query ?? "-" : "-"
            let search = parent.diagnosticsSearch?.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchLabel = (search?.isEmpty == false) ? search ?? "-" : "-"

            var lines: [String] = []
            lines.append("Selection: \(titleLabel)")
            if idLabel != "-" {
                lines.append("Selection ID: \(idLabel)")
            }
            lines.append("Issues: \(parent.issues.count)  Loading: \(parent.isLoading ? "Yes" : "No")")
            lines.append("Query: \(queryLabel)")
            lines.append("Search filter: \(searchLabel)")
            if parent.diagnosticEvents.isEmpty {
                lines.append("Data source events: none")
            } else {
                lines.append("Data source events:")
                for event in parent.diagnosticEvents {
                    let stamp = Self.diagnosticsCopyFormatter.string(from: event.timestamp)
                    lines.append("\(stamp)  \(event.message)")
                }
            }
            return lines.joined(separator: "\n")
        }

        private func copyDiagnostics() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(diagnosticsCopyText(), forType: .string)
        }

        private func rebuildColumns(on tableView: NSTableView) {
            let identifiers = Set(tableView.tableColumns.map(\.identifier))
            if !identifiers.contains(titleColumnID) {
                let titleColumn = NSTableColumn(identifier: titleColumnID)
                titleColumn.isEditable = false
                titleColumn.minWidth = 220
                titleColumn.width = 420
                titleColumn.resizingMask = .autoresizingMask
                tableView.addTableColumn(titleColumn)
            }

            let assigneeColumn = tableView.tableColumn(withIdentifier: assigneeColumnID)
            if parent.showAssigneeColumn {
                if assigneeColumn == nil {
                    let column = NSTableColumn(identifier: assigneeColumnID)
                    column.isEditable = false
                    column.minWidth = 160
                    column.width = 200
                    column.resizingMask = .userResizingMask
                    tableView.addTableColumn(column)
                }
            } else if let assigneeColumn {
                tableView.removeTableColumn(assigneeColumn)
            }
        }

        private func syncSelection(with tableView: NSTableView) {
            var idsToSelect = parent.selectedIDs
            if idsToSelect.isEmpty, let selectedIssue = parent.selection {
                idsToSelect = [selectedIssue.id]
            }

            var indexes = IndexSet()
            for (row, issue) in parent.issues.enumerated() where idsToSelect.contains(issue.id) {
                indexes.insert(row)
            }

            if tableView.selectedRowIndexes != indexes {
                isApplyingSelection = true
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                isApplyingSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.issues.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            row >= 0 && row < parent.issues.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            var ids: Set<IssueSummary.ID> = []
            for row in selectedRows where row >= 0 && row < parent.issues.count {
                ids.insert(parent.issues[row].id)
            }
            if parent.selectedIDs != ids {
                parent.selectedIDs = ids
            }

            let nextSelection: IssueSummary?
            if selectedRows.count == 1,
               let row = selectedRows.first,
               row >= 0 && row < parent.issues.count {
                nextSelection = parent.issues[row]
            } else {
                nextSelection = nil
            }
            if parent.selection?.id != nextSelection?.id {
                parent.selection = nextSelection
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.issues.count else { return nil }
            let issue = parent.issues[row]
            let unread = parent.isIssueUnread(issue)
            let isClosed = issue.status.isClosed

            if tableColumn?.identifier == assigneeColumnID {
                let cell = tableView.makeView(withIdentifier: IssueAssigneeCell.identifier, owner: nil) as? IssueAssigneeCell
                    ?? IssueAssigneeCell()
                cell.configure(
                    assignee: issue.assigneeDisplayName,
                    isUnread: unread,
                    isClosed: isClosed,
                    hasAssignee: issue.assignee != nil
                )
                return cell
            }

            let cell = tableView.makeView(withIdentifier: IssueTitleCell.identifier, owner: nil) as? IssueTitleCell
                ?? IssueTitleCell()
            cell.configure(
                title: issue.title,
                metadata: metadataText(for: issue),
                isUnread: unread,
                isClosed: isClosed,
                assignee: issue.assignee
            )
            return cell
        }

        private func metadataText(for issue: IssueSummary) -> String {
            var parts: [String] = [issue.readableID, issue.status.displayName]
            if !issue.priority.isNormalSemantic {
                parts.append(issue.priority.rawValue)
            }
            parts.append(IssueTimestampFormatter.label(for: issue.updatedAt))
            return parts.joined(separator: "  •  ")
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let clickedRow = tableView.clickedRow
            guard clickedRow >= 0, clickedRow < parent.issues.count else { return }
            let issue = parent.issues[clickedRow]
            guard let draftID = issue.draftID else { return }

            let delete = NSMenuItem(title: "Delete", action: #selector(deleteDraft(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = draftID
            menu.addItem(delete)
        }

        @objc private func deleteDraft(_ sender: NSMenuItem) {
            guard let draftID = sender.representedObject as? UUID else { return }
            parent.onDeleteDraft?(draftID)
        }
    }
}

/// Inputs that affect what the issue table renders. Selection is applied separately
/// via `selectRowIndexes` and intentionally not part of the snapshot.
struct IssueListRenderSnapshot: Equatable {
    let issues: [IssueSummary]
    let unreadFlags: [Bool]
    let showAssigneeColumn: Bool
}

/// Decides how much of the table needs reloading between two renders.
enum IssueListReloadPlanner {
    enum Action: Equatable {
        case none
        case full
        case rows(IndexSet)
    }

    static func action(previous: IssueListRenderSnapshot?, next: IssueListRenderSnapshot) -> Action {
        guard let previous else { return .full }
        if previous.showAssigneeColumn != next.showAssigneeColumn { return .full }
        if previous.issues != next.issues { return .full }
        if previous.unreadFlags != next.unreadFlags {
            guard previous.unreadFlags.count == next.unreadFlags.count else { return .full }
            var changed = IndexSet()
            for (index, flag) in next.unreadFlags.enumerated() where previous.unreadFlags[index] != flag {
                changed.insert(index)
            }
            return changed.isEmpty ? .none : .rows(changed)
        }
        return .none
    }
}

@MainActor
final class IssueListContainerView: NSView {
    enum ContentState {
        case table
        case loading
        case empty
        case placeholder
    }

    let tableView = NSTableView(frame: .zero)
    let diagnosticsView = IssueListDiagnosticsView(frame: .zero)

    private let scrollView = NSScrollView(frame: .zero)
    private let loadingView = IssueListLoadingStateView(frame: .zero)
    private let emptyView = IssueListEmptyStateView(frame: .zero)
    private let placeholderView = NSView(frame: .zero)
    private var currentState: ContentState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(placeholderView)
        addSubview(scrollView)
        addSubview(loadingView)
        addSubview(emptyView)
        addSubview(diagnosticsView)

        NSLayoutConstraint.activate([
            placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: bottomAnchor),

            diagnosticsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            diagnosticsView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            diagnosticsView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            diagnosticsView.heightAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])

        diagnosticsView.isHidden = true
        setContentState(.placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setContentState(_ state: ContentState) {
        guard state != currentState else { return }
        currentState = state
        scrollView.isHidden = state != .table
        loadingView.isHidden = state != .loading
        emptyView.isHidden = state != .empty
        placeholderView.isHidden = state != .placeholder
    }
}

@MainActor
private final class IssueListLoadingStateView: NSView {
    private let stack = NSStackView(frame: .zero)
    private let progress = NSProgressIndicator(frame: .zero)
    private let label = NSTextField(labelWithString: "Loading issues...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)

        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
private final class IssueListEmptyStateView: NSView {
    private let stack = NSStackView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "No issues")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "Refine your filters or sync to pull the latest issues.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        if let image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil) {
            iconView.image = image
            iconView.contentTintColor = .secondaryLabelColor
        }

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .vertical)
        iconView.setContentCompressionResistancePriority(.required, for: .vertical)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 2

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(descriptionLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
final class IssueListDiagnosticsView: NSVisualEffectView {
    var onCopy: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Issue list diagnostics")
    private let copyButton = NSButton(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        material = .hudWindow
        state = .active
        blendingMode = .withinWindow

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .inline
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.toolTip = "Copy issue list diagnostics"
        if let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy diagnostics") {
            copyButton.image = image
            copyButton.imagePosition = .imageOnly
        } else {
            copyButton.title = "Copy"
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 2)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        addSubview(titleLabel)
        addSubview(copyButton)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(text: String) {
        textView.string = text
    }

    @objc private func handleCopy() {
        onCopy?()
    }
}

private final class IssueTitleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("issue-title-cell")
    private static let avatarSize: CGFloat = 24
    private let avatarView = IssueAvatarView(size: IssueTitleCell.avatarSize)
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        avatarView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.maximumNumberOfLines = 1

        addSubview(avatarView)
        addSubview(titleLabel)
        addSubview(metadataLabel)

        let textLeading = avatarView.trailingAnchor
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),

            titleLabel.leadingAnchor.constraint(equalTo: textLeading, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            metadataLabel.leadingAnchor.constraint(equalTo: textLeading, constant: 8),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metadataLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, metadata: String, isUnread: Bool, isClosed: Bool, assignee: Person?) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: (isUnread && !isClosed) ? .semibold : .regular)
        titleLabel.textColor = isClosed ? .secondaryLabelColor : .labelColor

        metadataLabel.stringValue = metadata
        metadataLabel.textColor = isClosed ? .tertiaryLabelColor : .secondaryLabelColor

        avatarView.configure(person: assignee)
    }
}

@MainActor
private final class IssueAvatarView: NSView {
    private static let imageCache = NSCache<NSURL, NSImage>()

    private let size: CGFloat
    private let imageView = NSImageView(frame: .zero)
    private let initialsLabel = NSTextField(labelWithString: "")
    private let symbolImageView = NSImageView(frame: .zero)
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true

        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        initialsLabel.textColor = .secondaryLabelColor
        initialsLabel.alignment = .center
        initialsLabel.isHidden = true

        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.contentTintColor = .secondaryLabelColor
        symbolImageView.imageScaling = .scaleProportionallyUpOrDown
        symbolImageView.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        symbolImageView.isHidden = false

        addSubview(imageView)
        addSubview(initialsLabel)
        addSubview(symbolImageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            symbolImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolImageView.widthAnchor.constraint(equalToConstant: size * 0.5),
            symbolImageView.heightAnchor.constraint(equalToConstant: size * 0.5)
        ])
    }

    deinit {
        loadTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(person: Person?) {
        loadTask?.cancel()
        loadTask = nil

        currentURL = person?.avatarURL
        setAccessibilityLabel(person.map { "Assignee: \($0.displayName)" } ?? "Unassigned")

        showPlaceholder(initials: initials(for: person))

        guard let url = person?.avatarURL else { return }
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            showImage(cached)
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                await MainActor.run {
                    guard self.currentURL == url else { return }
                    Self.imageCache.setObject(image, forKey: url as NSURL)
                    self.showImage(image)
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.currentURL == url else { return }
                    self.loadTask = nil
                }
            }
        }
    }

    private func showPlaceholder(initials: String?) {
        imageView.image = nil
        imageView.isHidden = true
        if let initials, !initials.isEmpty {
            initialsLabel.stringValue = initials
            initialsLabel.isHidden = false
            symbolImageView.isHidden = true
        } else {
            initialsLabel.stringValue = ""
            initialsLabel.isHidden = true
            symbolImageView.isHidden = false
        }
    }

    private func showImage(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        initialsLabel.isHidden = true
        symbolImageView.isHidden = true
    }

    private func initials(for person: Person?) -> String? {
        guard let person else { return nil }
        let parts = person.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == " " || $0 == "\n" || $0 == "\t" }
        guard let first = parts.first?.first else { return nil }
        var letters: [Character] = [first]
        if parts.count > 1, let second = parts[1].first {
            letters.append(second)
        }
        return String(letters).uppercased()
    }
}

private final class IssueAssigneeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("issue-assignee-cell")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
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

    func configure(assignee: String, isUnread: Bool, isClosed: Bool, hasAssignee: Bool) {
        label.stringValue = assignee
        label.font = .systemFont(ofSize: 12, weight: (isUnread && !isClosed) ? .semibold : .regular)
        if hasAssignee {
            label.textColor = isClosed ? .secondaryLabelColor : .labelColor
        } else {
            label.textColor = .secondaryLabelColor
        }
    }
}

enum IssueTimestampFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func label(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return dateFormatter.string(from: date)
    }
}
