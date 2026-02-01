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
    @State private var sortOrder: [KeyPathComparator<IssueSummary>] = [
        .init(\IssueSummary.updatedAt, order: .reverse)
    ]

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
        Table(issues, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \IssueSummary.title) { issue in
                titleCell(for: issue)
            }
            .width(min: 220, ideal: 420)
            if showAssigneeColumn {
                TableColumn("Assignee", value: \IssueSummary.assigneeDisplayName) { issue in
                    assigneeCell(for: issue)
                }
                .width(min: 160, ideal: 200)
            }
        }
        .tableStyle(.inset)
        .tableColumnHeaders(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .onAppear {
            onIssuesRendered?(issues.count)
        }
    }

    @ViewBuilder
    private func titleCell(for issue: IssueSummary) -> some View {
        let unread = isIssueUnread(issue)
        let isClosed = issue.status.isClosed
        let row = HStack(alignment: .top, spacing: 10) {
            UserAvatarView(person: issue.assignee, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.headline.weight(unread && !isClosed ? .semibold : .regular))
                    .foregroundStyle(titleColor(isUnread: unread, isClosed: isClosed))
                metadataRow(for: issue, isUnread: unread, isClosed: isClosed)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
        if let draftID = issue.draftID {
            row.contextMenu {
                Button("Delete", role: .destructive) {
                    onDeleteDraft?(draftID)
                }
            }
        } else {
            row
        }
    }

    private func assigneeCell(for issue: IssueSummary) -> some View {
        let unread = isIssueUnread(issue)
        let isClosed = issue.status.isClosed
        let baseColor: Color = issue.assignee == nil ? .secondary : .primary
        return Text(issue.assigneeDisplayName)
            .foregroundStyle(isClosed ? baseColor.opacity(0.6) : baseColor)
            .fontWeight(unread && !isClosed ? .semibold : .regular)
    }

    private func metadataRow(for issue: IssueSummary, isUnread: Bool, isClosed: Bool) -> some View {
        let secondaryOpacity = isClosed ? 0.65 : 1.0
        return HStack(spacing: 8) {
            Text(issue.readableID)
                .foregroundStyle(.secondary.opacity(secondaryOpacity))
                .strikethrough(isClosed, color: .secondary)
            IssueMetaDotLabel(
                text: issue.status.displayName,
                colors: issue.status.badgeColors,
                textOpacity: isClosed ? 0.62 : 0.86,
                dotOpacity: isClosed ? 0.6 : 1.0
            )
            if !issue.priority.isNormalSemantic {
                IssuePriorityLabel(priority: issue.priority, isMuted: isClosed)
            }
            Spacer(minLength: 0)
            Text(IssueTimestampFormatter.label(for: issue.updatedAt))
                .foregroundStyle(.secondary.opacity(secondaryOpacity))
        }
        .font(.caption.weight(isUnread && !isClosed ? .medium : .regular))
        .lineLimit(1)
    }

    private func titleColor(isUnread: Bool, isClosed: Bool) -> Color {
        if isClosed {
            return isUnread ? .secondary.opacity(0.85) : .secondary.opacity(0.65)
        }
        return isUnread ? .primary : .primary.opacity(0.74)
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

private struct IssueMetaDotLabel: View {
    let text: String
    let colors: IssueBadgeColors
    let textOpacity: Double
    let dotOpacity: Double

    init(text: String, colors: IssueBadgeColors, textOpacity: Double = 0.86, dotOpacity: Double = 1.0) {
        self.text = text
        self.colors = colors
        self.textOpacity = textOpacity
        self.dotOpacity = dotOpacity
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colors.foreground.opacity(dotOpacity))
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(Color.primary.opacity(textOpacity))
        }
    }
}

private struct IssuePriorityLabel: View {
    let priority: IssuePriority
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 5) {
            if priority.isTopPriority {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(isMuted ? 0.7 : 1.0))
            }
            Text(priority.displayName)
                .foregroundStyle(Color.primary.opacity(isMuted ? 0.55 : 0.78))
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
