import SwiftUI

struct IssueBoardView: View {
    let board: IssueBoard
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    let isLoading: Bool
    let sprintFilter: BoardSprintFilter
    let onSelectSprint: (BoardSprintFilter) -> Void

    @State private var collapsedGroups: Set<String> = []

    private let columnWidth: CGFloat = 260
    private let columnSpacing: CGFloat = 12

    var body: some View {
        Group {
            if isLoading && issues.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading board…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                ContentUnavailableView(
                    "No cards on this board",
                    systemImage: "rectangle.3.group",
                    description: Text("Sync or adjust your filters to pull the latest cards.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                boardContent
            }
        }
    }

    private var boardContent: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 16) {
                boardHeader
                IssueBoardColumnHeaderRow(
                    columns: columnDescriptors,
                    issues: issues,
                    columnWidth: columnWidth,
                    spacing: columnSpacing
                )
                ForEach(groupModels) { group in
                    DisclosureGroup(isExpanded: binding(for: group.id)) {
                        IssueBoardLane(
                            group: group,
                            columns: columnDescriptors,
                            columnWidth: columnWidth,
                            spacing: columnSpacing,
                            onSelect: { selection = $0 }
                        )
                    } label: {
                        IssueBoardGroupHeader(group: group)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.visible)
    }

    private var boardHeader: some View {
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
            Spacer()
        }
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

    private var columnDescriptors: [IssueBoardColumnDescriptor] {
        if let fieldName = board.columnFieldName, !board.columns.isEmpty {
            let normalizedField = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let columns = board.columns.sorted { (left, right) in
                let leftOrdinal = left.ordinal ?? Int.max
                let rightOrdinal = right.ordinal ?? Int.max
                if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
            return columns.map { column in
                let matchValues = column.valueNames.map { $0.lowercased() }
                return IssueBoardColumnDescriptor(
                    id: column.id,
                    title: column.title,
                    match: { issue in
                        let values = issue.fieldValues(named: normalizedField).map { $0.lowercased() }
                        if matchValues.isEmpty {
                            let title = column.title.lowercased()
                            return values.contains(title)
                        }
                        return values.contains(where: { matchValues.contains($0) })
                    }
                )
            }
        }

        let fallback: [IssueStatus] = [.open, .blocked, .inProgress, .inReview, .done]
        return fallback.map { status in
            IssueBoardColumnDescriptor(
                id: status.rawValue,
                title: status.displayName,
                match: { issue in issue.status == status }
            )
        }
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

        for issue in issues {
            let values = swimlaneValues(for: issue, fieldName: normalizedField, isAssignee: isAssignee)
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
            let sortedKeys = buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            for (index, key) in sortedKeys.enumerated() {
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

    private func swimlaneValues(for issue: IssueSummary, fieldName: String, isAssignee: Bool) -> [String] {
        if isAssignee {
            return issue.assignee.map { [$0.displayName] } ?? []
        }
        return issue.fieldValues(named: fieldName)
    }
}

private struct IssueBoardColumnDescriptor: Identifiable {
    let id: String
    let title: String
    let match: (IssueSummary) -> Bool
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
    }
}

private struct IssueBoardColumnHeaderRow: View {
    let columns: [IssueBoardColumnDescriptor]
    let issues: [IssueSummary]
    let columnWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                IssueBoardColumnHeader(
                    title: column.title,
                    count: issues.filter(column.match).count
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
    let group: IssueBoardGroup
    let columns: [IssueBoardColumnDescriptor]
    let columnWidth: CGFloat
    let spacing: CGFloat
    let onSelect: (IssueSummary) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                IssueBoardColumnView(
                    issues: group.issues.filter(column.match),
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
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.readableID)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(issue.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label(issue.projectName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                Spacer()
                Image(systemName: issue.priority.iconName)
                    .foregroundStyle(issue.priority.tint)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
