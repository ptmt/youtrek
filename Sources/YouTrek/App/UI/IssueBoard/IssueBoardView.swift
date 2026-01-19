import SwiftUI

struct IssueBoardView: View {
    let boardTitle: String
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    let isLoading: Bool

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
                    statuses: columns,
                    issues: issues,
                    columnWidth: columnWidth,
                    spacing: columnSpacing
                )
                ForEach(groupModels) { group in
                    DisclosureGroup(isExpanded: binding(for: group.id)) {
                        IssueBoardLane(
                            group: group,
                            statuses: columns,
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
    }

    private var boardHeader: some View {
        HStack(spacing: 8) {
            Text("Agile boards")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(boardTitle)
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    private var columns: [IssueStatus] {
        [.open, .blocked, .inProgress, .inReview, .done]
    }

    private var groupModels: [IssueBoardGroup] {
        let grouped = Dictionary(grouping: issues, by: { $0.assigneeDisplayName })
        let groups = grouped.map { IssueBoardGroup(id: $0.key, title: $0.key, issues: $0.value) }
        return groups.sorted { left, right in
            if left.isUnassigned != right.isUnassigned {
                return !left.isUnassigned
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
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
}

private struct IssueBoardGroup: Identifiable {
    let id: String
    let title: String
    let issues: [IssueSummary]

    var isUnassigned: Bool { title == "Unassigned" }
}

private struct IssueBoardGroupHeader: View {
    let group: IssueBoardGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.isUnassigned ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
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
    let statuses: [IssueStatus]
    let issues: [IssueSummary]
    let columnWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(statuses, id: \.self) { status in
                IssueBoardColumnHeader(
                    title: status.displayName,
                    count: issues.filter { $0.status == status }.count
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
    let statuses: [IssueStatus]
    let columnWidth: CGFloat
    let spacing: CGFloat
    let onSelect: (IssueSummary) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(statuses, id: \.self) { status in
                IssueBoardColumn(
                    issues: group.issues.filter { $0.status == status },
                    columnWidth: columnWidth,
                    onSelect: onSelect
                )
                .frame(width: columnWidth, alignment: .top)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct IssueBoardColumn: View {
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
