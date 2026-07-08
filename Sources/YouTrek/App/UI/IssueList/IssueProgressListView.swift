import AppKit
import SwiftUI

struct IssueProgressListView: View {
    @EnvironmentObject private var container: AppContainer
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let isIssueUnread: (IssueSummary) -> Bool

    @State private var statusOptionsByProject: [String: [IssueFieldOption]] = [:]

    var body: some View {
        IssueProgressTableView(
            container: container,
            issues: issues,
            selection: $selection,
            selectedIDs: $selectedIDs,
            statusOptionsByProject: statusOptionsByProject,
            isIssueUnread: isIssueUnread
        )
        .task(id: issues.map(\.projectName).sorted().joined()) {
            statusOptionsByProject = [:]
            let groupedIssues = Dictionary(grouping: issues, by: projectStatusKey(for:))
            var loaded: [String: [IssueFieldOption]] = [:]
            for (_, grouped) in groupedIssues where !grouped.isEmpty {
                guard let issue = grouped.first else { continue }
                loaded[projectStatusKey(for: issue)] = await container.loadStatusOptions(for: issue)
            }
            statusOptionsByProject = loaded
        }
        .task(id: issues.map(\.id)) {
            await loadMissingDetails()
        }
    }

    private func projectStatusKey(for issue: IssueSummary) -> String {
        issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadMissingDetails() async {
        let appState = container.appState
        let needsLoading = issues.filter {
            !$0.isDraft && appState.issueDetail(for: $0) == nil
        }
        await withTaskGroup(of: Void.self) { group in
            for issue in needsLoading {
                group.addTask {
                    await container.loadIssueDetail(for: issue)
                }
            }
        }
    }
}

@MainActor
private struct IssueProgressTableView: NSViewRepresentable {
    let container: AppContainer
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let statusOptionsByProject: [String: [IssueFieldOption]]
    let isIssueUnread: (IssueSummary) -> Bool

    private let primaryColumnID = NSUserInterfaceItemIdentifier("issue-progress-primary-column")

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> IssueProgressListContainerView {
        let view = IssueProgressListContainerView()
        context.coordinator.configure(containerView: view)
        context.coordinator.apply(parent: self, containerView: view)
        return view
    }

    func updateNSView(_ nsView: IssueProgressListContainerView, context: Context) {
        context.coordinator.apply(parent: self, containerView: nsView)
    }

    private func projectStatusKey(for issue: IssueSummary) -> String {
        issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate func statusOptions(for issue: IssueSummary) -> [IssueFieldOption] {
        statusOptionsByProject[projectStatusKey(for: issue)] ?? []
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: IssueProgressTableView
        private weak var tableView: NSTableView?
        private var isApplyingSelection = false
        private var lastReloadInput: ReloadInput?
        private var commentDrafts: [IssueSummary.ID: String] = [:]
        private var submittingIssueIDs: Set<IssueSummary.ID> = []
        private var submitErrors: [IssueSummary.ID: String] = [:]

        private struct ReloadInput: Equatable {
            let issues: [IssueSummary]
            let statusOptionsByProject: [String: [IssueFieldOption]]
            let unreadIDs: Set<IssueSummary.ID>
            let latestCommentSignatures: [IssueSummary.ID: String]
        }

        init(parent: IssueProgressTableView) {
            self.parent = parent
            super.init()
        }

        func configure(containerView: IssueProgressListContainerView) {
            let tableView = containerView.tableView
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.cornerView = nil
            tableView.gridStyleMask = [.solidHorizontalGridLineMask]
            tableView.gridColor = .separatorColor.withAlphaComponent(0.35)
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.selectionHighlightStyle = .regular
            tableView.focusRingType = .none
            rebuildColumns(on: tableView)
            self.tableView = tableView
        }

        func apply(parent: IssueProgressTableView, containerView: IssueProgressListContainerView) {
            self.parent = parent
            tableView = containerView.tableView
            rebuildColumns(on: containerView.tableView)
            normalizeSelectionState()
            syncSelection(with: containerView.tableView)
            let issueIDs = Set(parent.issues.map(\.id))
            commentDrafts = commentDrafts.filter { issueIDs.contains($0.key) }
            submittingIssueIDs = submittingIssueIDs.filter { issueIDs.contains($0) }
            submitErrors = submitErrors.filter { issueIDs.contains($0.key) }
            let reloadInput = ReloadInput(
                issues: parent.issues,
                statusOptionsByProject: parent.statusOptionsByProject,
                unreadIDs: Set(parent.issues.filter(parent.isIssueUnread).map(\.id)),
                latestCommentSignatures: latestCommentSignaturesByIssueID()
            )
            if reloadInput != lastReloadInput {
                containerView.tableView.reloadData()
                lastReloadInput = reloadInput
            }
        }

        private func normalizeSelectionState() {
            guard !parent.issues.isEmpty else {
                if parent.selection != nil {
                    parent.selection = nil
                }
                if !parent.selectedIDs.isEmpty {
                    parent.selectedIDs.removeAll()
                }
                return
            }

            if let selected = parent.selection,
               let matchedIssue = parent.issues.first(where: { $0.id == selected.id }) {
                let expectedIDs: Set<IssueSummary.ID> = [matchedIssue.id]
                if parent.selectedIDs != expectedIDs {
                    parent.selectedIDs = expectedIDs
                }
                return
            }

            if let selectedID = parent.selectedIDs.first,
               let issue = parent.issues.first(where: { $0.id == selectedID }) {
                if parent.selection?.id != issue.id {
                    parent.selection = issue
                }
                let expectedIDs: Set<IssueSummary.ID> = [issue.id]
                if parent.selectedIDs != expectedIDs {
                    parent.selectedIDs = expectedIDs
                }
                return
            }

            if parent.selection != nil {
                parent.selection = nil
            }
            if !parent.selectedIDs.isEmpty {
                parent.selectedIDs.removeAll()
            }
        }

        private func syncSelection(with tableView: NSTableView) {
            let targetID = parent.selection?.id ?? parent.selectedIDs.first
            let selectedRow: Int?
            if let targetID {
                selectedRow = parent.issues.firstIndex(where: { $0.id == targetID })
            } else {
                selectedRow = nil
            }

            let indexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            if tableView.selectedRowIndexes != indexes {
                isApplyingSelection = true
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                isApplyingSelection = false
            }
        }

        private func rebuildColumns(on tableView: NSTableView) {
            guard tableView.tableColumn(withIdentifier: parent.primaryColumnID) == nil else { return }
            let column = NSTableColumn(identifier: parent.primaryColumnID)
            column.isEditable = false
            column.minWidth = 320
            column.width = 700
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.issues.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            row >= 0 && row < parent.issues.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let row = tableView.selectedRow
            if row >= 0, row < parent.issues.count {
                let issue = parent.issues[row]
                if parent.selection?.id != issue.id {
                    parent.selection = issue
                }
                let selected: Set<IssueSummary.ID> = [issue.id]
                if parent.selectedIDs != selected {
                    parent.selectedIDs = selected
                }
            } else {
                if parent.selection != nil {
                    parent.selection = nil
                }
                if !parent.selectedIDs.isEmpty {
                    parent.selectedIDs.removeAll()
                }
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            136
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.issues.count else { return nil }
            let issue = parent.issues[row]
            let cell = tableView.makeView(withIdentifier: IssueProgressRowCell.identifier, owner: nil) as? IssueProgressRowCell
                ?? IssueProgressRowCell()
            let latestComment = parent.container.appState.issueDetail(for: issue)?.comments.last
            let statusOptions = resolvedStatusOptions(for: issue)
            cell.configure(
                issue: issue,
                statusOptions: statusOptions,
                latestComment: latestComment,
                commentText: commentDrafts[issue.id] ?? "",
                isSubmitting: submittingIssueIDs.contains(issue.id),
                submitError: submitErrors[issue.id],
                isUnread: parent.isIssueUnread(issue),
                onCommentChanged: { [weak self] nextText in
                    guard let self else { return }
                    self.commentDrafts[issue.id] = nextText
                    self.submitErrors[issue.id] = nil
                },
                onSubmitComment: { [weak self] rawText in
                    self?.submitComment(issue: issue, rawText: rawText)
                },
                onSelectStatus: { [weak self] option in
                    self?.updateStatus(issue: issue, option: option)
                },
                onActivate: { [weak self] in
                    self?.selectIssue(id: issue.id)
                }
            )
            return cell
        }

        private func latestCommentSignaturesByIssueID() -> [IssueSummary.ID: String] {
            var signatures: [IssueSummary.ID: String] = [:]
            for issue in parent.issues {
                guard let latestComment = parent.container.appState.issueDetail(for: issue)?.comments.last else { continue }
                signatures[issue.id] = latestCommentSignature(for: latestComment)
            }
            return signatures
        }

        private func latestCommentSignature(for comment: IssueComment) -> String {
            let author = comment.author?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(comment.id)|\(comment.createdAt.timeIntervalSince1970)|\(author)|\(comment.text)"
        }

        private func selectIssue(id: IssueSummary.ID) {
            guard let row = parent.issues.firstIndex(where: { $0.id == id }) else { return }
            let selected: Set<IssueSummary.ID> = [id]
            if parent.selectedIDs != selected {
                parent.selectedIDs = selected
            }
            if parent.selection?.id != id {
                parent.selection = parent.issues[row]
            }
            guard let tableView else { return }
            let indexes = IndexSet(integer: row)
            if tableView.selectedRowIndexes != indexes {
                isApplyingSelection = true
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                isApplyingSelection = false
            }
        }

        private func updateStatus(issue: IssueSummary, option: IssueFieldOption) {
            selectIssue(id: issue.id)
            guard !optionMatchesStatus(option, issue: issue) else { return }
            var patch = IssuePatch(title: nil, description: nil, status: nil, statusOption: option, priority: nil)
            patch.issueReadableID = issue.readableID
            Task { @MainActor in
                await parent.container.updateIssue(id: issue.id, patch: patch)
            }
        }

        private func submitComment(issue: IssueSummary, rawText: String) {
            selectIssue(id: issue.id)
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !submittingIssueIDs.contains(issue.id) else { return }
            submitErrors[issue.id] = nil
            submittingIssueIDs.insert(issue.id)
            reloadRow(issueID: issue.id)

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.parent.container.addComment(to: issue, text: trimmed)
                    self.submittingIssueIDs.remove(issue.id)
                    self.commentDrafts[issue.id] = ""
                    self.submitErrors[issue.id] = nil
                    self.reloadRow(issueID: issue.id)
                } catch {
                    self.submittingIssueIDs.remove(issue.id)
                    self.submitErrors[issue.id] = error.localizedDescription
                    self.reloadRow(issueID: issue.id)
                }
            }
        }

        private func reloadRow(issueID: IssueSummary.ID) {
            guard let tableView else { return }
            guard let row = parent.issues.firstIndex(where: { $0.id == issueID }) else { return }
            guard tableView.numberOfColumns > 0 else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }

        private func resolvedStatusOptions(for issue: IssueSummary) -> [IssueFieldOption] {
            let loaded = parent.statusOptions(for: issue)
            let base = loaded.isEmpty ? fallbackOptions : loaded
            return mergedOptions(base, currentName: issue.status.displayName)
        }

        private var fallbackOptions: [IssueFieldOption] {
            IssueStatus.fallbackCases.map {
                IssueFieldOption(id: "", name: $0.displayName, displayName: $0.displayName)
            }
        }

        private func mergedOptions(_ base: [IssueFieldOption], currentName: String) -> [IssueFieldOption] {
            let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return base }
            if base.contains(where: { optionMatches($0, name: trimmed) }) {
                return base
            }
            var extended = base
            extended.append(IssueFieldOption(id: "", name: trimmed, displayName: trimmed))
            return extended
        }

        private func optionMatches(_ option: IssueFieldOption, name: String) -> Bool {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedName.isEmpty else { return false }
            let candidates = [
                option.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                option.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ]
            return candidates.contains(normalizedName)
        }

        private func optionMatchesStatus(_ option: IssueFieldOption, issue: IssueSummary) -> Bool {
            optionMatches(option, name: issue.status.displayName)
        }
    }
}

@MainActor
private final class IssueProgressListContainerView: NSView {
    let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

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

@MainActor
private final class IssueProgressRowCell: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("issue-progress-row-cell")
    private static let avatarSize: CGFloat = 24
    private static let readableIDWidth: CGFloat = 112
    private static let statusMenuWidth: CGFloat = 148
    private static let priorityWidth: CGFloat = 78
    private static let submitButtonWidth: CGFloat = 30
    private static let submitButtonHeight: CGFloat = 26

    private let avatarView = IssueProgressAvatarView(size: avatarSize)
    private let readableIDLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let priorityLabel = NSTextField(labelWithString: "")

    private let latestCommentStack = NSStackView(frame: .zero)
    private let latestCommentIcon = NSImageView(frame: .zero)
    private let latestCommentMetaLabel = NSTextField(labelWithString: "")
    private let latestCommentTextLabel = NSTextField(wrappingLabelWithString: "")

    private let commentInput = NSTextField(string: "")
    private let submitButton = NSButton(frame: .zero)
    private let submittingIndicator = NSProgressIndicator(frame: .zero)
    private let submitErrorLabel = NSTextField(wrappingLabelWithString: "")

    private var statusOptions: [IssueFieldOption] = []
    private var onCommentChanged: ((String) -> Void)?
    private var onSubmitComment: ((String) -> Void)?
    private var onSelectStatus: ((IssueFieldOption) -> Void)?
    private var onActivate: (() -> Void)?
    private var suppressStatusChange = false
    private var suppressCommentChange = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        issue: IssueSummary,
        statusOptions: [IssueFieldOption],
        latestComment: IssueComment?,
        commentText: String,
        isSubmitting: Bool,
        submitError: String?,
        isUnread: Bool,
        onCommentChanged: @escaping (String) -> Void,
        onSubmitComment: @escaping (String) -> Void,
        onSelectStatus: @escaping (IssueFieldOption) -> Void,
        onActivate: @escaping () -> Void
    ) {
        self.onCommentChanged = onCommentChanged
        self.onSubmitComment = onSubmitComment
        self.onSelectStatus = onSelectStatus
        self.onActivate = onActivate

        avatarView.configure(person: issue.assignee)

        readableIDLabel.stringValue = issue.readableID
        titleLabel.stringValue = issue.title
        titleLabel.font = .systemFont(ofSize: 13, weight: (isUnread && !issue.status.isClosed) ? .semibold : .medium)
        titleLabel.textColor = issue.status.isClosed ? .secondaryLabelColor : .labelColor

        configureStatusMenu(
            options: statusOptions,
            selectedStatusName: issue.status.displayName,
            isClosed: issue.status.isClosed
        )

        if issue.priority.isNormalSemantic {
            priorityLabel.isHidden = true
            priorityLabel.stringValue = ""
        } else {
            priorityLabel.isHidden = false
            priorityLabel.stringValue = "• \(issue.priority.displayName)"
            priorityLabel.textColor = issue.status.isClosed
                ? .secondaryLabelColor
                : priorityColor(for: issue.priority)
        }

        if let latestComment {
            latestCommentStack.isHidden = false
            let author = latestComment.author?.displayName ?? "Unknown"
            latestCommentMetaLabel.stringValue = "\(author)  \(IssueTimestampFormatter.label(for: latestComment.createdAt))"
            let text = latestComment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            latestCommentTextLabel.stringValue = text.isEmpty ? " " : text
        } else {
            latestCommentStack.isHidden = true
            latestCommentMetaLabel.stringValue = ""
            latestCommentTextLabel.stringValue = ""
        }

        suppressCommentChange = true
        if commentInput.stringValue != commentText {
            commentInput.stringValue = commentText
        }
        suppressCommentChange = false
        commentInput.isEnabled = !isSubmitting

        if isSubmitting {
            submittingIndicator.isHidden = false
            submittingIndicator.startAnimation(nil)
            submitButton.isHidden = true
        } else {
            submittingIndicator.stopAnimation(nil)
            submittingIndicator.isHidden = true
            submitButton.isHidden = false
        }

        let trimmedError = submitError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedError.isEmpty {
            submitErrorLabel.isHidden = true
            submitErrorLabel.stringValue = ""
        } else {
            submitErrorLabel.isHidden = false
            submitErrorLabel.stringValue = trimmedError
        }

        updateSubmitButtonState()
    }

    private func setupViews() {
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        readableIDLabel.translatesAutoresizingMaskIntoConstraints = false
        readableIDLabel.font = .systemFont(ofSize: 11, weight: .regular)
        readableIDLabel.textColor = .secondaryLabelColor
        readableIDLabel.lineBreakMode = .byTruncatingTail
        readableIDLabel.setContentHuggingPriority(.required, for: .horizontal)
        readableIDLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusPopUp.translatesAutoresizingMaskIntoConstraints = false
        statusPopUp.controlSize = .small
        statusPopUp.font = .systemFont(ofSize: 11, weight: .regular)
        statusPopUp.target = self
        statusPopUp.action = #selector(handleStatusSelection(_:))
        statusPopUp.setContentHuggingPriority(.required, for: .horizontal)
        statusPopUp.setContentCompressionResistancePriority(.required, for: .horizontal)

        priorityLabel.translatesAutoresizingMaskIntoConstraints = false
        priorityLabel.font = .systemFont(ofSize: 11, weight: .regular)
        priorityLabel.lineBreakMode = .byTruncatingTail
        priorityLabel.alignment = .right
        priorityLabel.setContentHuggingPriority(.required, for: .horizontal)
        priorityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        if let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil) {
            latestCommentIcon.image = image
        }
        latestCommentIcon.contentTintColor = .tertiaryLabelColor
        latestCommentIcon.translatesAutoresizingMaskIntoConstraints = false
        latestCommentIcon.setContentHuggingPriority(.required, for: .horizontal)

        latestCommentMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        latestCommentMetaLabel.font = .systemFont(ofSize: 10, weight: .medium)
        latestCommentMetaLabel.textColor = .secondaryLabelColor
        latestCommentMetaLabel.lineBreakMode = .byTruncatingTail

        latestCommentTextLabel.translatesAutoresizingMaskIntoConstraints = false
        latestCommentTextLabel.font = .systemFont(ofSize: 11, weight: .regular)
        latestCommentTextLabel.textColor = .secondaryLabelColor
        latestCommentTextLabel.maximumNumberOfLines = 2
        latestCommentTextLabel.lineBreakMode = .byTruncatingTail

        commentInput.translatesAutoresizingMaskIntoConstraints = false
        commentInput.placeholderString = "Report progress…"
        commentInput.font = .systemFont(ofSize: 13, weight: .regular)
        commentInput.target = self
        commentInput.action = #selector(handleSubmit(_:))
        commentInput.delegate = self
        commentInput.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commentInput.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.bezelStyle = .texturedRounded
        submitButton.imagePosition = .imageOnly
        submitButton.target = self
        submitButton.action = #selector(handleSubmit(_:))
        submitButton.toolTip = "Post comment"
        if let image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "Post comment") {
            submitButton.image = image
        } else {
            submitButton.title = "Post"
        }

        submittingIndicator.translatesAutoresizingMaskIntoConstraints = false
        submittingIndicator.style = .spinning
        submittingIndicator.controlSize = .small
        submittingIndicator.isDisplayedWhenStopped = false
        submittingIndicator.isHidden = true

        submitErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        submitErrorLabel.font = .systemFont(ofSize: 10, weight: .regular)
        submitErrorLabel.textColor = .systemRed
        submitErrorLabel.maximumNumberOfLines = 2
        submitErrorLabel.lineBreakMode = .byTruncatingTail
        submitErrorLabel.isHidden = true

        let headerSpacer = NSView(frame: .zero)
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [readableIDLabel, titleLabel, headerSpacer, priorityLabel, statusPopUp])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let latestCommentTextStack = NSStackView(views: [latestCommentMetaLabel, latestCommentTextLabel])
        latestCommentTextStack.translatesAutoresizingMaskIntoConstraints = false
        latestCommentTextStack.orientation = .vertical
        latestCommentTextStack.alignment = .leading
        latestCommentTextStack.spacing = 2

        latestCommentStack.translatesAutoresizingMaskIntoConstraints = false
        latestCommentStack.orientation = .horizontal
        latestCommentStack.alignment = .top
        latestCommentStack.spacing = 6
        latestCommentStack.addArrangedSubview(latestCommentIcon)
        latestCommentStack.addArrangedSubview(latestCommentTextStack)

        let submitActionContainer = NSView(frame: .zero)
        submitActionContainer.translatesAutoresizingMaskIntoConstraints = false
        submitActionContainer.addSubview(submitButton)
        submitActionContainer.addSubview(submittingIndicator)

        let inputRow = NSStackView(views: [commentInput, submitActionContainer])
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8

        let contentStack = NSStackView(views: [topRow, latestCommentStack, inputRow, submitErrorLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6

        let rowStack = NSStackView(views: [avatarView, contentStack])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 10

        addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            contentStack.widthAnchor.constraint(equalTo: rowStack.widthAnchor, constant: -(Self.avatarSize + 10)),
            topRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            latestCommentStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            readableIDLabel.widthAnchor.constraint(equalToConstant: Self.readableIDWidth),
            statusPopUp.widthAnchor.constraint(equalToConstant: Self.statusMenuWidth),
            priorityLabel.widthAnchor.constraint(equalToConstant: Self.priorityWidth),

            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),

            latestCommentIcon.widthAnchor.constraint(equalToConstant: 12),
            latestCommentIcon.heightAnchor.constraint(equalToConstant: 12),
            latestCommentTextStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            commentInput.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),

            submitActionContainer.widthAnchor.constraint(equalToConstant: Self.submitButtonWidth),
            submitActionContainer.heightAnchor.constraint(equalToConstant: Self.submitButtonHeight),
            submitButton.centerXAnchor.constraint(equalTo: submitActionContainer.centerXAnchor),
            submitButton.centerYAnchor.constraint(equalTo: submitActionContainer.centerYAnchor),
            submitButton.widthAnchor.constraint(equalToConstant: Self.submitButtonWidth),
            submitButton.heightAnchor.constraint(equalToConstant: Self.submitButtonHeight),
            submittingIndicator.centerXAnchor.constraint(equalTo: submitActionContainer.centerXAnchor),
            submittingIndicator.centerYAnchor.constraint(equalTo: submitActionContainer.centerYAnchor)
        ])
    }

    private func configureStatusMenu(options: [IssueFieldOption], selectedStatusName: String, isClosed: Bool) {
        statusOptions = options
        suppressStatusChange = true
        statusPopUp.removeAllItems()
        for option in options {
            statusPopUp.addItem(withTitle: option.displayName)
        }
        if let selectedIndex = options.firstIndex(where: { optionMatches($0, name: selectedStatusName) }) {
            statusPopUp.selectItem(at: selectedIndex)
        } else if !options.isEmpty {
            statusPopUp.selectItem(at: 0)
        }
        statusPopUp.contentTintColor = isClosed ? .secondaryLabelColor : .labelColor
        suppressStatusChange = false
    }

    private func updateSubmitButtonState() {
        let trimmed = commentInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        submitButton.isEnabled = !trimmed.isEmpty && submittingIndicator.isHidden
    }

    @objc private func handleStatusSelection(_ sender: NSPopUpButton) {
        guard !suppressStatusChange else { return }
        onActivate?()
        let selectedIndex = sender.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < statusOptions.count else { return }
        onSelectStatus?(statusOptions[selectedIndex])
    }

    @objc private func handleSubmit(_ sender: Any?) {
        onActivate?()
        let trimmed = commentInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitComment?(trimmed)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !suppressCommentChange else { return }
        submitErrorLabel.isHidden = true
        submitErrorLabel.stringValue = ""
        onCommentChanged?(commentInput.stringValue)
        updateSubmitButtonState()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        onActivate?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            handleSubmit(control)
            return true
        }
        return false
    }

    private func optionMatches(_ option: IssueFieldOption, name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return false }
        let candidates = [
            option.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            option.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
        return candidates.contains(normalizedName)
    }

    private func priorityColor(for priority: IssuePriority) -> NSColor {
        switch priority {
        case .critical:
            return .systemRed
        case .high:
            return .systemOrange
        case .normal:
            return .secondaryLabelColor
        case .low:
            return .systemBlue
        case .custom:
            return .secondaryLabelColor
        }
    }
}

@MainActor
private final class IssueProgressAvatarView: NSView {
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
