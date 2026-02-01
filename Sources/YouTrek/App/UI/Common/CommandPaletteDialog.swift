import SwiftUI

struct CommandPaletteDialog: View {
    @EnvironmentObject private var container: AppContainer
    @Binding var state: CommandPaletteState
    @FocusState private var isSearchFocused: Bool
    @State private var selectionID: CommandPaletteItem.ID?
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var trimmedQuery: String {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var issueItems: [CommandPaletteItem] {
        container.appState.issues
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { issue in
                let subtitle = issueSubtitle(for: issue)
                return CommandPaletteItem(
                    id: "issue:\(issue.id.uuidString)",
                    title: issue.title,
                    subtitle: subtitle,
                    iconName: "doc.text",
                    kind: .issue(issue),
                    searchTokens: [
                        issue.title,
                        issue.readableID,
                        issue.projectName,
                        issue.assignee?.displayName,
                        issue.reporter?.displayName,
                        issueSubmoduleLabel(for: issue)
                    ].compactMap { $0 },
                    score: 0
                )
            }
    }

    private var boardItems: [CommandPaletteItem] {
        container.appState.sidebarSections
            .flatMap(\.items)
            .filter { $0.isBoard }
            .map { item in
                let board = item.board
                let projectNames = board?.projectNames.joined(separator: ", ")
                let subtitle = projectNames?.isEmpty == false
                    ? "Board • \(projectNames ?? "")"
                    : "Board"
                return CommandPaletteItem(
                    id: "board:\(item.id)",
                    title: item.title,
                    subtitle: subtitle,
                    iconName: "rectangle.3.group.fill",
                    kind: .board(item),
                    searchTokens: [
                        item.title,
                        board?.name,
                        board?.projectNames.joined(separator: " ")
                    ].compactMap { $0 },
                    score: 0
                )
            }
    }

    private var actionItems: [CommandPaletteItem] {
        let actions: [CommandPaletteAction] = [
            CommandPaletteAction(
                id: "resync",
                title: "Re-sync",
                subtitle: "Refresh issues, boards, and saved searches",
                iconName: "arrow.clockwise"
            ) {
                Task {
                    await container.resyncWorkspace()
                    if let selection = container.appState.selectedSidebarItem {
                        if selection.isBoard {
                            await container.refreshBoardIssues(for: selection)
                        } else {
                            await container.loadIssues(for: selection)
                        }
                    }
                }
            },
            CommandPaletteAction(
                id: "logout",
                title: "Log out",
                subtitle: "Sign out and return to setup",
                iconName: "rectangle.portrait.and.arrow.forward"
            ) {
                Task {
                    await container.signOut()
                }
            }
        ]

        return actions.map { action in
            CommandPaletteItem(
                id: "action:\(action.id)",
                title: action.title,
                subtitle: action.subtitle,
                iconName: action.iconName,
                kind: .action(action),
                searchTokens: [action.title, action.subtitle],
                score: 0
            )
        }
    }

    private var sections: [CommandPaletteSection] {
        let query = trimmedQuery
        let issues = filter(items: issueItems, query: query)
        let boards = filter(items: boardItems, query: query)
        let actions = filter(items: actionItems, query: query)
        return [
            CommandPaletteSection(id: "issues", title: "Issues", items: issues),
            CommandPaletteSection(id: "boards", title: "Boards", items: boards),
            CommandPaletteSection(id: "actions", title: "Actions", items: actions)
        ].filter { !$0.items.isEmpty }
    }

    private var flattenedItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dialogHeader
            Divider()
            searchField
            Divider()
            resultsList
            Divider()
            dialogFooter
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720)
        .frame(minHeight: 420, idealHeight: 520)
        .background(.regularMaterial)
        .background(
            KeyEventHandlingView(
                onMove: { offset in
                    moveSelection(offset: offset)
                },
                onSubmit: {
                    openSelection()
                },
                onEscape: {
                    closePalette()
                }
            )
        )
        .task {
            isSearchFocused = true
            selectionID = flattenedItems.first?.id
        }
        .onChange(of: trimmedQuery) { _, _ in
            selectionID = flattenedItems.first?.id
        }
    }

    private var dialogHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "command.square")
                .foregroundStyle(.secondary)
            Text("Command Palette")
                .font(.headline)
            Spacer()
            Button {
                closePalette()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search commands, issues, and boards", text: $state.query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { openSelection() }
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command palette search")
    }

    private var resultsList: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectionID) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                CommandPaletteRow(item: item, query: trimmedQuery)
                                    .contentShape(Rectangle())
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .tag(item.id)
                                    .onTapGesture {
                                        selectionID = item.id
                                        handleSelection(item)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dialogFooter: some View {
        HStack(spacing: 12) {
            Text("Enter to open")
            Text("Esc to close")
            Spacer()
            Text("\(flattenedItems.count) results")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func filter(items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        guard !query.isEmpty else { return items }
        return items.compactMap { item in
            guard let score = FuzzyMatcher.score(query: query, candidates: item.searchTokens) else { return nil }
            return item.scored(score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }

    private func openSelection() {
        if let selectionID,
           let selected = flattenedItems.first(where: { $0.id == selectionID }) {
            handleSelection(selected)
            return
        }
        if let first = flattenedItems.first {
            handleSelection(first)
        }
    }

    private func handleSelection(_ item: CommandPaletteItem) {
        switch item.kind {
        case .issue(let issue):
            container.appState.selectedIssue = issue
            container.appState.selectedIssueIDs = [issue.id]
        case .board(let boardItem):
            container.appState.selectedSidebarItem = boardItem
        case .action(let action):
            action.perform()
        }
        closePalette()
    }

    private func closePalette() {
        container.appState.dismissCommandPalette()
    }

    private func moveSelection(offset: Int) {
        let items = flattenedItems
        guard !items.isEmpty else {
            selectionID = nil
            return
        }
        let currentIndex = items.firstIndex { $0.id == selectionID } ?? 0
        let nextIndex = max(0, min(items.count - 1, currentIndex + offset))
        selectionID = items[nextIndex].id
    }

    private func issueSubtitle(for issue: IssueSummary) -> String? {
        var parts: [String] = []
        parts.append(issue.readableID)
        parts.append(issue.assignee?.displayName ?? "Unassigned")
        if let submodule = issueSubmoduleLabel(for: issue) {
            parts.append(submodule)
        }
        parts.append(updatedLabel(for: issue))
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func issueSubmoduleLabel(for issue: IssueSummary) -> String? {
        let subsystem = issue.fieldValues(named: "subsystem").first
        let module = issue.fieldValues(named: "module").first
        let value = (subsystem ?? module)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return "Submodule: \(value)"
    }

    private func updatedLabel(for issue: IssueSummary) -> String {
        let relative = Self.relativeFormatter.localizedString(for: issue.updatedAt, relativeTo: Date())
        return "Updated \(relative)"
    }
}

private struct CommandPaletteSection: Identifiable {
    let id: String
    let title: String
    let items: [CommandPaletteItem]
}

private struct CommandPaletteAction {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String
    let perform: () -> Void
}

private struct CommandPaletteItem: Identifiable {
    enum Kind {
        case issue(IssueSummary)
        case board(SidebarItem)
        case action(CommandPaletteAction)
    }

    let id: String
    let title: String
    let subtitle: String?
    let iconName: String
    let kind: Kind
    let searchTokens: [String]
    let score: Int

    func scored(_ score: Int) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            iconName: iconName,
            kind: kind,
            searchTokens: searchTokens,
            score: score
        )
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let query: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                highlightedText(item.title, query: query)
                    .font(.body.weight(.medium))
                if let subtitle = item.subtitle {
                    highlightedText(subtitle, query: query)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: term, options: [.caseInsensitive], range: searchRange) {
                if let attributedRange = Range(range, in: attributed) {
                    attributed[attributedRange].backgroundColor = Color.yellow.opacity(0.35)
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return Text(attributed)
    }
}

private struct KeyEventHandlingView: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.onMove = onMove
        view.onSubmit = onSubmit
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.onMove = onMove
        nsView.onSubmit = onSubmit
        nsView.onEscape = onEscape
    }
}

@MainActor
private final class KeyEventView: NSView {
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: // down
                self.onMove?(1)
                return nil
            case 126: // up
                self.onMove?(-1)
                return nil
            case 36: // return
                self.onSubmit?()
                return nil
            case 53: // escape
                self.onEscape?()
                return nil
            default:
                return event
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private enum FuzzyMatcher {
    static func score(query: String, candidates: [String]) -> Int? {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard !terms.isEmpty else { return 0 }
        var total = 0
        for term in terms {
            var best: Int?
            for candidate in candidates where !candidate.isEmpty {
                if let score = score(term, in: candidate) {
                    best = max(best ?? score, score)
                }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    private static func score(_ query: String, in candidate: String) -> Int? {
        let query = query.lowercased()
        let candidate = candidate.lowercased()
        guard !query.isEmpty else { return 0 }

        var score = 0
        var searchIndex = candidate.startIndex
        var lastMatchIndex: String.Index?

        for char in query {
            guard let matchIndex = candidate[searchIndex...].firstIndex(of: char) else { return nil }
            let gap = candidate.distance(from: searchIndex, to: matchIndex)
            let isConsecutive = lastMatchIndex.map { candidate.index(after: $0) == matchIndex } ?? false

            score += 10
            if isConsecutive {
                score += 6
            }
            if gap > 0 {
                score -= gap
            }
            if isWordBoundary(candidate, at: matchIndex) {
                score += 4
            }

            lastMatchIndex = matchIndex
            searchIndex = candidate.index(after: matchIndex)
        }

        score -= max(0, candidate.count - query.count) / 4
        return score
    }

    private static func isWordBoundary(_ value: String, at index: String.Index) -> Bool {
        if index == value.startIndex {
            return true
        }
        let previous = value[value.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }
}
