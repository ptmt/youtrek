import AppKit
import SwiftUI

struct IssueBoardView: View {
    let board: IssueBoard
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    let isLoading: Bool
    let sprintFilter: BoardSprintFilter
    let showDiagnostics: Bool
    let diagnosticEvents: [BoardDataSourceEvent]
    let onSelectSprint: (BoardSprintFilter) -> Void

    @State private var collapsedGroups: Set<String> = []
    @State private var showsLoadingView = false
    @State private var loadingVisibilityTask: Task<Void, Never>?

    private let columnWidth: CGFloat = 260
    private let columnSpacing: CGFloat = 12
    private let loadingIndicatorDelayNanoseconds: UInt64 = 250_000_000

    var body: some View {
        // Columns, groups, and per-cell issue buckets are derived in one pass;
        // header/lane child views only display precomputed data instead of
        // re-filtering all issues per column on every render.
        let layout = makeBoardLayout()
        VStack(spacing: 0) {
            boardHeader(layout: layout)
            Divider()
            Group {
                if showsLoadingView && issues.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading board…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if issues.isEmpty {
                    EmptyStateView(
                        title: "No cards on this board",
                        systemImage: "rectangle.3.group",
                        description: "Sync or adjust your filters to pull the latest cards."
                    )
                } else {
                    boardContent(layout: layout)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showDiagnostics {
                diagnosticsOverlay(layout: layout)
            }
        }
        .onAppear {
            updateLoadingVisibility()
        }
        .onChange(of: isLoading) { _, _ in
            updateLoadingVisibility()
        }
        .onChange(of: issues.isEmpty) { _, _ in
            updateLoadingVisibility()
        }
        .onDisappear {
            loadingVisibilityTask?.cancel()
            loadingVisibilityTask = nil
        }
    }

    private func updateLoadingVisibility() {
        loadingVisibilityTask?.cancel()
        guard isLoading, issues.isEmpty else {
            showsLoadingView = false
            loadingVisibilityTask = nil
            return
        }
        loadingVisibilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: loadingIndicatorDelayNanoseconds)
            guard !Task.isCancelled else { return }
            showsLoadingView = true
        }
    }

    private func boardContent(layout: BoardLayout) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16) {
                IssueBoardColumnHeaderRow(
                    columns: layout.columns,
                    columnWidth: columnWidth,
                    spacing: columnSpacing
                )
                ForEach(layout.groups) { group in
                    DisclosureGroup(isExpanded: binding(for: group.id)) {
                        IssueBoardLane(
                            columns: layout.columns,
                            issuesByColumn: layout.cells[group.id] ?? [:],
                            columnWidth: columnWidth,
                            spacing: columnSpacing,
                            onSelect: { selection = $0 }
                        )
                    } label: {
                        IssueBoardGroupHeader(group: group)
                    }
                }
            }
            .frame(minWidth: boardContentWidth(layout: layout), alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.visible)
    }

    private func boardContentWidth(layout: BoardLayout) -> CGFloat {
        let count = max(layout.columns.count, 1)
        let columnsWidth = CGFloat(count) * columnWidth
        let spacingWidth = CGFloat(max(0, count - 1)) * columnSpacing
        return columnsWidth + spacingWidth
    }

    private func boardHeader(layout: BoardLayout) -> some View {
        HStack(spacing: 8) {
            Text("Agile boards")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(board.name)
                .font(.title3.weight(.semibold))
            if showsSprintControls {
                sprintControls
            }
            if !layout.groups.isEmpty {
                Button {
                    toggleCollapseAll(groups: layout.groups)
                } label: {
                    Label(
                        isAllCollapsed(groups: layout.groups) ? "Expand all" : "Collapse all",
                        systemImage: "rectangle.compress.vertical"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var showsSprintControls: Bool {
        board.displaySprints.count > 1
    }

    private var sprintControls: some View {
        let selectedSprintName = board.sprintName(for: sprintFilter)
        let menuTitle = selectedSprintName ?? "Sprint"

        return HStack(spacing: 6) {
            Button {
                onSelectSprint(.backlog)
            } label: {
                Image(systemName: "tray")
                    .foregroundStyle(sprintFilter.isBacklog ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Backlog")

            Menu {
                ForEach(board.displaySprints) { sprint in
                    Button {
                        onSelectSprint(.sprint(id: sprint.id))
                    } label: {
                        if sprint.id == sprintFilter.sprintID {
                            Label(sprint.name, systemImage: "checkmark")
                        } else {
                            Text(sprint.name)
                        }
                    }
                }
            } label: {
                Label(menuTitle, systemImage: "flag.checkered")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(selectedSprintName == nil ? .secondary : .primary)
            }
        }
        .font(.caption)
    }

    private static let unmatchedColumnID = "diagnostics-unmatched"

    private enum BoardColumnRule {
        case fieldValues(Set<String>)
        case status(IssueStatus)
    }

    private struct BoardColumnMatcher {
        let id: String
        let title: String
        let rule: BoardColumnRule
    }

    private struct BoardColumnMatching {
        let matchers: [BoardColumnMatcher]
        let fieldName: String?
        let useStatusFallback: Bool
    }

    private func makeColumnMatching() -> BoardColumnMatching {
        if let fieldName = board.columnFieldName, !board.columns.isEmpty {
            let normalizedField = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let useStatusFallback = shouldUseStatusForColumns(
                fieldName: normalizedField,
                columns: board.columns,
                issues: issues
            )
            let columns = board.columns.sorted { (left, right) in
                let leftOrdinal = left.ordinal ?? Int.max
                let rightOrdinal = right.ordinal ?? Int.max
                if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
            let matchers = columns.map { column in
                let matchValues = column.valueNames.isEmpty
                    ? Set([column.title.lowercased()])
                    : Set(column.valueNames.map { $0.lowercased() })
                return BoardColumnMatcher(id: column.id, title: column.title, rule: .fieldValues(matchValues))
            }
            return BoardColumnMatching(matchers: matchers, fieldName: normalizedField, useStatusFallback: useStatusFallback)
        }

        let resolved = IssueStatus.sortedUnique(issues.map(\.status))
        let fallback = resolved.isEmpty ? IssueStatus.fallbackCases : resolved
        let matchers = fallback.map { status in
            BoardColumnMatcher(id: status.rawValue, title: status.displayName, rule: .status(status))
        }
        return BoardColumnMatching(matchers: matchers, fieldName: nil, useStatusFallback: false)
    }

    fileprivate struct BoardLayout {
        struct Column: Identifiable {
            let id: String
            let title: String
            let count: Int
        }

        let columns: [Column]
        let groups: [IssueBoardGroup]
        let cells: [String: [String: [IssueSummary]]]
        let matchedIssueCount: Int
        let baseColumnCount: Int
    }

    private func makeBoardLayout() -> BoardLayout {
        let matching = makeColumnMatching()
        let groups = groupModels

        // Field values are lowercased once per issue instead of once per
        // (issue, column) match closure call.
        func matchedColumnIDs(for issue: IssueSummary) -> [String] {
            var fieldValues: Set<String>?
            if let fieldName = matching.fieldName {
                var values = issue.fieldValues(named: fieldName).map { $0.lowercased() }
                if matching.useStatusFallback, values.isEmpty {
                    values = [issue.status.displayName.lowercased(), issue.status.rawValue.lowercased()]
                }
                fieldValues = Set(values)
            }
            var ids: [String] = []
            for matcher in matching.matchers {
                switch matcher.rule {
                case .fieldValues(let targets):
                    if let fieldValues, !fieldValues.isDisjoint(with: targets) {
                        ids.append(matcher.id)
                    }
                case .status(let status):
                    if issue.status == status {
                        ids.append(matcher.id)
                    }
                }
            }
            return ids
        }

        var counts: [String: Int] = [:]
        var matchedIssueCount = 0
        var unmatchedCount = 0
        for issue in issues {
            let ids = matchedColumnIDs(for: issue)
            if ids.isEmpty {
                unmatchedCount += 1
            } else {
                matchedIssueCount += 1
            }
            for id in ids {
                counts[id, default: 0] += 1
            }
        }

        var cells: [String: [String: [IssueSummary]]] = [:]
        for group in groups {
            var byColumn: [String: [IssueSummary]] = [:]
            for issue in group.issues {
                let ids = matchedColumnIDs(for: issue)
                for id in ids {
                    byColumn[id, default: []].append(issue)
                }
                if showDiagnostics, ids.isEmpty {
                    byColumn[Self.unmatchedColumnID, default: []].append(issue)
                }
            }
            cells[group.id] = byColumn
        }

        var columns = matching.matchers.map { matcher in
            BoardLayout.Column(id: matcher.id, title: matcher.title, count: counts[matcher.id] ?? 0)
        }
        if showDiagnostics {
            columns.append(BoardLayout.Column(id: Self.unmatchedColumnID, title: "Unmatched", count: unmatchedCount))
        }
        return BoardLayout(
            columns: columns,
            groups: groups,
            cells: cells,
            matchedIssueCount: matchedIssueCount,
            baseColumnCount: matching.matchers.count
        )
    }

    private func shouldUseStatusForColumns(
        fieldName: String,
        columns: [IssueBoardColumn],
        issues: [IssueSummary]
    ) -> Bool {
        if fieldName == "state" || fieldName == "status" {
            return true
        }

        let hasFieldValues = issues.contains { issue in
            !issue.fieldValues(named: fieldName).isEmpty
        }
        if hasFieldValues {
            return false
        }

        let statusNames = Set(issues.map { $0.status.displayName.lowercased() })
        if statusNames.isEmpty {
            return false
        }

        let columnValues = columns.flatMap { column in
            column.valueNames.isEmpty ? [column.title] : column.valueNames
        }
        let columnSet = Set(columnValues.map { $0.lowercased() })
        if columnSet.isEmpty {
            return false
        }

        return !statusNames.isDisjoint(with: columnSet)
    }

    private func diagnosticsOverlay(layout: BoardLayout) -> some View {
        let matched = layout.matchedIssueCount
        let unmatched = max(0, issues.count - matched)
        let fieldName = board.columnFieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let swimlaneField = board.swimlaneSettings.fieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let issuesWithColumnValues = issuesWithColumnFieldValues
        let events = diagnosticEvents
        let displayEvents = Array(events.reversed())

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Board diagnostics")
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
                .help("Copy board diagnostics")
            }
            Text("Issues: \(issues.count)  Matched: \(matched)  Unmatched: \(unmatched)")
            Text("Column field: \(fieldName)")
            Text("Issues w/ column values: \(issuesWithColumnValues)")
            Text("Columns: \(layout.baseColumnCount)  Swimlanes: \(swimlaneField)")
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
        let layout = makeBoardLayout()
        let matched = layout.matchedIssueCount
        let unmatched = max(0, issues.count - matched)
        let fieldName = board.columnFieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let swimlaneField = board.swimlaneSettings.fieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let issuesWithColumnValues = issuesWithColumnFieldValues
        var lines: [String] = []
        lines.append("Board: \(board.name) (\(board.id))")
        lines.append("Issues: \(issues.count)  Matched: \(matched)  Unmatched: \(unmatched)")
        lines.append("Column field: \(fieldName)")
        lines.append("Issues w/ column values: \(issuesWithColumnValues)")
        lines.append("Columns: \(layout.baseColumnCount)  Swimlanes: \(swimlaneField)")
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

    private var issuesWithColumnFieldValues: Int {
        guard let fieldName = board.columnFieldName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fieldName.isEmpty
        else {
            return 0
        }
        let normalized = fieldName.lowercased()
        return issues.filter { issue in
            !issue.fieldValues(named: normalized).isEmpty
        }.count
    }

    private var groupModels: [IssueBoardGroup] {
        guard board.swimlaneSettings.isEnabled, let fieldName = board.swimlaneSettings.fieldName else {
            return [IssueBoardGroup(
                id: "all-cards",
                title: "All cards",
                issues: issues,
                iconName: "rectangle.stack",
                isUnassigned: false,
                sortIndex: 0
            )]
        }

        let normalizedField = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAssignee = normalizedField == "assignee"
        let explicitValues = board.swimlaneSettings.values
        let lookup = Dictionary(uniqueKeysWithValues: explicitValues.map { ($0.lowercased(), $0) })

        var buckets: [String: [IssueSummary]] = [:]
        var unassigned: [IssueSummary] = []
        var orderedKeys: [String] = []
        var orderedKeySet: Set<String> = []

        for issue in issues {
            let values = swimlaneValues(
                for: issue,
                fieldName: normalizedField,
                isAssignee: isAssignee,
                includeIdentifiers: !explicitValues.isEmpty
            )
            if values.isEmpty {
                unassigned.append(issue)
                continue
            }

            var matched = false
            for value in values {
                let key = value.lowercased()
                if let canonical = lookup[key] {
                    buckets[canonical, default: []].append(issue)
                    matched = true
                } else if explicitValues.isEmpty {
                    buckets[value, default: []].append(issue)
                    let normalized = value.lowercased()
                    if orderedKeySet.insert(normalized).inserted {
                        orderedKeys.append(value)
                    }
                    matched = true
                }
            }
            if !matched {
                unassigned.append(issue)
            }
        }

        var groups: [IssueBoardGroup] = []
        if !explicitValues.isEmpty {
            for (index, value) in explicitValues.enumerated() {
                let issues = buckets[value] ?? []
                groups.append(IssueBoardGroup(
                    id: value,
                    title: value,
                    issues: issues,
                    iconName: isAssignee ? "person.crop.circle.fill" : "square.stack.3d.up.fill",
                    isUnassigned: false,
                    sortIndex: index
                ))
            }
        } else {
            for (index, key) in orderedKeys.enumerated() {
                groups.append(IssueBoardGroup(
                    id: key,
                    title: key,
                    issues: buckets[key] ?? [],
                    iconName: isAssignee ? "person.crop.circle.fill" : "square.stack.3d.up.fill",
                    isUnassigned: false,
                    sortIndex: index
                ))
            }
        }

        if !unassigned.isEmpty, !board.hideOrphansSwimlane {
            let orphanGroup = IssueBoardGroup(
                id: "Unassigned",
                title: isAssignee ? "Unassigned" : "Other",
                issues: unassigned,
                iconName: isAssignee ? "person.crop.circle.badge.questionmark" : "questionmark.folder",
                isUnassigned: true,
                sortIndex: board.orphansAtTheTop ? -1 : (groups.last?.sortIndex ?? 0) + 1
            )
            if board.orphansAtTheTop {
                groups.insert(orphanGroup, at: 0)
            } else {
                groups.append(orphanGroup)
            }
        }

        if groups.isEmpty {
            return [IssueBoardGroup(
                id: "all-cards",
                title: "All cards",
                issues: issues,
                iconName: "rectangle.stack",
                isUnassigned: false,
                sortIndex: 0
            )]
        }

        return groups
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(id)
                } else {
                    collapsedGroups.insert(id)
                }
            }
        )
    }

    private func isAllCollapsed(groups: [IssueBoardGroup]) -> Bool {
        let groupIDs = Set(groups.map(\.id))
        guard !groupIDs.isEmpty else { return false }
        return groupIDs.isSubset(of: collapsedGroups)
    }

    private func toggleCollapseAll(groups: [IssueBoardGroup]) {
        let groupIDs = Set(groups.map(\.id))
        guard !groupIDs.isEmpty else { return }
        if groupIDs.isSubset(of: collapsedGroups) {
            collapsedGroups.subtract(groupIDs)
        } else {
            collapsedGroups.formUnion(groupIDs)
        }
    }

    private func swimlaneValues(
        for issue: IssueSummary,
        fieldName: String,
        isAssignee: Bool,
        includeIdentifiers: Bool
    ) -> [String] {
        if isAssignee {
            var values: [String] = []
            if let assignee = issue.assignee {
                let displayName = assignee.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                appendUnique(displayName, to: &values)
                if includeIdentifiers {
                    let remoteID = assignee.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    appendUnique(remoteID, to: &values)
                    let login = assignee.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    appendUnique(login, to: &values)
                }
            }
            if values.isEmpty {
                values = issue.fieldValues(named: fieldName)
            }
            return values
        }
        return issue.fieldValues(named: fieldName)
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        values.append(trimmed)
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

private struct IssueBoardGroup: Identifiable {
    let id: String
    let title: String
    let issues: [IssueSummary]
    let iconName: String
    let isUnassigned: Bool
    let sortIndex: Int
}

private struct IssueBoardGroupHeader: View {
    let group: IssueBoardGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.iconName)
                .foregroundStyle(.secondary)
            Text(group.title)
                .font(.headline)
            Spacer()
            Text("\(group.issues.count) cards")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IssueBoardColumnHeaderRow: View {
    let columns: [IssueBoardView.BoardLayout.Column]
    let columnWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                IssueBoardColumnHeader(
                    title: column.title,
                    count: column.count
                )
                .frame(width: columnWidth, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct IssueBoardColumnHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IssueBoardLane: View {
    let columns: [IssueBoardView.BoardLayout.Column]
    let issuesByColumn: [String: [IssueSummary]]
    let columnWidth: CGFloat
    let spacing: CGFloat
    let onSelect: (IssueSummary) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                IssueBoardColumnView(
                    issues: issuesByColumn[column.id] ?? [],
                    columnWidth: columnWidth,
                    onSelect: onSelect
                )
                .frame(width: columnWidth, alignment: .top)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct IssueBoardColumnView: View {
    let issues: [IssueSummary]
    let columnWidth: CGFloat
    let onSelect: (IssueSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(issues) { issue in
                IssueBoardCard(issue: issue)
                    .onTapGesture {
                        onSelect(issue)
                    }
            }
            Button {
                // Placeholder for "add card"
            } label: {
                Label("Add card", systemImage: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct IssueBoardCard: View {
    let issue: IssueSummary

    var body: some View {
        let isClosed = issue.status.isClosed
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.readableID)
                .font(.caption)
                .foregroundStyle(.secondary.opacity(isClosed ? 0.6 : 1.0))
                .strikethrough(isClosed, color: .secondary)
            Text(issue.title)
                .font(.subheadline.weight(isClosed ? .regular : .semibold))
                .foregroundStyle(isClosed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label(issue.projectName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                Spacer()
                UserAvatarView(person: issue.assignee, size: 18)
                if issue.priority.isTopPriority {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(Color.red.opacity(isClosed ? 0.7 : 1.0))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary.opacity(isClosed ? 0.6 : 1.0))
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
