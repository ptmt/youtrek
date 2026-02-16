import AppKit
import SwiftUI

struct IssueListView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .overlay(alignment: .topTrailing) {
            if showDiagnostics {
                diagnosticsOverlay
            }
        }
        .onAppear(perform: syncSelectionState)
        .onChange(of: selection?.id) { _, _ in
            syncSelectionState()
        }
        .onChange(of: selectedIDs) { _, newIDs in
            updateSelection(from: newIDs)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && issues.isEmpty {
            loadingView
        } else if issues.isEmpty && hasCompletedSync {
            emptyView
        } else if issues.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            issueTable
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading issues…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView(
            title: "No issues",
            systemImage: "tray",
            description: "Refine your filters or sync to pull the latest issues."
        )
    }

    private var issueTable: some View {
        AppKitIssueTableView(
            issues: issues,
            selection: $selection,
            selectedIDs: $selectedIDs,
            showAssigneeColumn: showAssigneeColumn,
            isIssueUnread: isIssueUnread,
            onIssuesRendered: onIssuesRendered,
            onDeleteDraft: onDeleteDraft
        )
    }

    private func syncSelectionState() {
        Task { @MainActor in
            if let selectedIssue = selection {
                let nextIDs: Set<IssueSummary.ID> = [selectedIssue.id]
                guard selectedIDs != nextIDs else { return }
                selectedIDs = nextIDs
            } else if selectedIDs.count <= 1, !selectedIDs.isEmpty {
                selectedIDs.removeAll()
            }
        }
    }

    private func updateSelection(from newIDs: Set<IssueSummary.ID>) {
        let nextSelection: IssueSummary?
        if newIDs.count == 1, let firstID = newIDs.first, let issue = issues.first(where: { $0.id == firstID }) {
            nextSelection = issue
        } else {
            nextSelection = nil
        }
        guard nextSelection?.id != selection?.id else { return }
        Task { @MainActor in
            selection = nextSelection
        }
    }

    private var diagnosticsOverlay: some View {
        let events = diagnosticEvents
        let displayEvents = Array(events.reversed())
        let title = diagnosticsTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLabel = (title?.isEmpty == false) ? title ?? "—" : "—"
        let id = diagnosticsID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idLabel = (id?.isEmpty == false) ? id ?? "—" : "—"
        let query = diagnosticsQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLabel = (query?.isEmpty == false) ? query ?? "—" : "—"
        let search = diagnosticsSearch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchLabel = (search?.isEmpty == false) ? search ?? "—" : "—"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Issue list diagnostics")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    copyDiagnostics()
                } label: {
                    Label("Copy diagnostics", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Copy issue list diagnostics")
            }
            Text("Selection: \(titleLabel)")
            if idLabel != "—" {
                Text("Selection ID: \(idLabel)")
            }
            Text("Issues: \(issues.count)  Loading: \(isLoading ? "Yes" : "No")")
            Text("Query: \(queryLabel)")
            Text("Search filter: \(searchLabel)")
            if events.isEmpty {
                Text("Data source events: none")
            } else {
                Divider()
                Text("Data source events (\(events.count))")
                    .font(.caption2.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(displayEvents) { event in
                            Text("\(formattedDiagnosticsTimestamp(event.timestamp))  \(event.message)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .font(.caption2)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.trailing, 12)
        .padding(.top, 8)
        .textSelection(.enabled)
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

    private func formattedDiagnosticsTimestamp(_ date: Date) -> String {
        Self.diagnosticsDisplayFormatter.string(from: date)
    }

    private func diagnosticsCopyText() -> String {
        let title = diagnosticsTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLabel = (title?.isEmpty == false) ? title ?? "—" : "—"
        let id = diagnosticsID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idLabel = (id?.isEmpty == false) ? id ?? "—" : "—"
        let query = diagnosticsQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLabel = (query?.isEmpty == false) ? query ?? "—" : "—"
        let search = diagnosticsSearch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchLabel = (search?.isEmpty == false) ? search ?? "—" : "—"

        var lines: [String] = []
        lines.append("Selection: \(titleLabel)")
        if idLabel != "—" {
            lines.append("Selection ID: \(idLabel)")
        }
        lines.append("Issues: \(issues.count)  Loading: \(isLoading ? "Yes" : "No")")
        lines.append("Query: \(queryLabel)")
        lines.append("Search filter: \(searchLabel)")
        if diagnosticEvents.isEmpty {
            lines.append("Data source events: none")
        } else {
            lines.append("Data source events:")
            for event in diagnosticEvents {
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
}

@MainActor
private struct AppKitIssueTableView: NSViewRepresentable {
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let showAssigneeColumn: Bool
    let isIssueUnread: (IssueSummary) -> Bool
    let onIssuesRendered: ((Int) -> Void)?
    let onDeleteDraft: ((UUID) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> IssueListTableContainerView {
        let view = IssueListTableContainerView()
        context.coordinator.configure(tableView: view.tableView)
        context.coordinator.apply(parent: self, tableView: view.tableView)
        return view
    }

    func updateNSView(_ nsView: IssueListTableContainerView, context: Context) {
        context.coordinator.apply(parent: self, tableView: nsView.tableView)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, @preconcurrency NSTableViewDelegate, @preconcurrency NSMenuDelegate {
        private var parent: AppKitIssueTableView
        private weak var tableView: NSTableView?
        private var isApplyingSelection = false
        private let contextMenu = NSMenu(title: "Issue List")
        private let titleColumnID = NSUserInterfaceItemIdentifier("issue-title-column")
        private let assigneeColumnID = NSUserInterfaceItemIdentifier("issue-assignee-column")

        init(parent: AppKitIssueTableView) {
            self.parent = parent
            super.init()
        }

        func configure(tableView: NSTableView) {
            self.tableView = tableView
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

        func apply(parent: AppKitIssueTableView, tableView: NSTableView) {
            self.parent = parent
            rebuildColumns(on: tableView)
            tableView.reloadData()
            syncSelection(with: tableView)
            parent.onIssuesRendered?(parent.issues.count)
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
                isClosed: isClosed
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

@MainActor
private final class IssueListTableContainerView: NSView {
    let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
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

private final class IssueTitleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("issue-title-cell")
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.maximumNumberOfLines = 1

        addSubview(titleLabel)
        addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            metadataLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metadataLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, metadata: String, isUnread: Bool, isClosed: Bool) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: (isUnread && !isClosed) ? .semibold : .regular)
        titleLabel.textColor = isClosed ? .secondaryLabelColor : .labelColor

        metadataLabel.stringValue = metadata
        metadataLabel.textColor = isClosed ? .tertiaryLabelColor : .secondaryLabelColor
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

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
