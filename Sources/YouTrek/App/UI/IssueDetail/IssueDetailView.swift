import SwiftUI

struct IssueDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let detail: IssueDetail?
    let isLoadingDetail: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                metadata
                Divider()
                if isLoadingDetail && detail == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading issue details…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                descriptionSection
                Divider()
                timelineSection
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.readableID)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(issue.title)
                .font(.system(size: 24, weight: .bold))
            HStack(spacing: 8) {
                statusMenu
                priorityMenu
            }
        }
    }

    private var metadata: some View {
        let reporter = detail?.reporter ?? issue.reporter
        let reporterName = reporter?.displayName ?? issue.reporterDisplayName
        return VStack(alignment: .leading, spacing: 6) {
            AssigneeEditor(issue: issue)
            HStack(spacing: 8) {
                UserAvatarView(person: reporter, size: 22)
                Text("Created by \(reporterName)")
            }
            Label("Updated \(issue.updatedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
            Label("Project: \(issue.projectName)", systemImage: "folder")
            if !issue.tags.isEmpty {
                Label("Tags: \(issue.tags.joined(separator: ", "))", systemImage: "tag")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            if let description = descriptionText {
                MarkdownTextView(text: description)
            } else {
                Text(isLoadingDetail ? "Loading description…" : "No description yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline")
                .font(.headline)
            if timelineEntries.isEmpty {
                Text(isLoadingDetail ? "Loading activity…" : "No activity yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timelineEntries) { entry in
                    TimelineRow(entry: entry)
                }
            }
        }
    }

    private var descriptionText: String? {
        guard let detail else { return nil }
        let trimmed = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var timelineEntries: [TimelineEntry] {
        guard let detail else { return [] }
        var entries: [TimelineEntry] = []
        if let createdAt = detail.createdAt {
            entries.append(TimelineEntry(
                id: "created",
                title: "Created",
                date: createdAt,
                person: detail.reporter,
                body: nil
            ))
        }
        if detail.createdAt == nil || detail.updatedAt > (detail.createdAt ?? .distantPast) {
            entries.append(TimelineEntry(
                id: "updated",
                title: "Updated",
                date: detail.updatedAt,
                person: nil,
                body: nil
            ))
        }
        for comment in detail.comments {
            let trimmed = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(TimelineEntry(
                id: "comment-\(comment.id)",
                title: "Comment",
                date: comment.createdAt,
                person: comment.author,
                body: trimmed.isEmpty ? nil : trimmed
            ))
        }
        return entries.sorted { $0.date < $1.date }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(IssueStatus.allCases, id: \.self) { status in
                Button {
                    updateStatus(status)
                } label: {
                    if status == issue.status {
                        Label(status.displayName, systemImage: "checkmark")
                    } else {
                        Text(status.displayName)
                    }
                }
            }
        } label: {
            BadgeLabel(text: issue.status.displayName, tint: issue.status.tint)
        }
        .menuStyle(.borderlessButton)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(IssuePriority.allCases, id: \.self) { priority in
                Button {
                    updatePriority(priority)
                } label: {
                    if priority == issue.priority {
                        Label(priority.displayName, systemImage: "checkmark")
                    } else {
                        Text(priority.displayName)
                    }
                }
            }
        } label: {
            BadgeLabel(text: issue.priority.displayName, tint: issue.priority.tint)
        }
        .menuStyle(.borderlessButton)
    }

    private func updateStatus(_ status: IssueStatus) {
        guard status != issue.status else { return }
        var patch = IssuePatch(title: nil, description: nil, status: status, priority: nil)
        patch.issueReadableID = issue.readableID
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private func updatePriority(_ priority: IssuePriority) {
        guard priority != issue.priority else { return }
        var patch = IssuePatch(title: nil, description: nil, status: nil, priority: priority)
        patch.issueReadableID = issue.readableID
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }
}

private struct AssigneeEditor: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                UserAvatarView(person: issue.assignee, size: 22)
                Text("Assignee: \(issue.assigneeDisplayName)")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AssigneePickerPopover(issue: issue, isPresented: $isPresented)
                .environmentObject(container)
        }
    }
}

private struct AssigneePickerPopover: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var remoteOptions: [IssueFieldOption] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign to")
                .font(.headline)
            TextField("Search people", text: $query)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Button {
                        selectAssignee(nil)
                    } label: {
                        UnassignedRow(isSelected: issue.assignee == nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(mergedOptions, id: \.stableID) { option in
                        Button {
                            selectAssignee(option)
                        } label: {
                            AssigneeOptionRow(option: option, isSelected: option.stableID == selectedStableID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)

            Text(localHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var selectedStableID: String? {
        issue.assignee?.issueFieldOption?.stableID
    }

    private var localHint: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Showing people you've already worked with. Type to search the directory."
            : "Local matches are shown first. Keep typing to refine the list."
    }

    private var mergedOptions: [IssueFieldOption] {
        let local = localOptions
        var seen = Set(local.map(\.stableID))
        var merged = local
        for option in remoteOptions where !seen.contains(option.stableID) {
            merged.append(option)
            seen.insert(option.stableID)
        }
        return merged
    }

    private var localOptions: [IssueFieldOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var latestByID: [String: (IssueFieldOption, Date)] = [:]
        for issue in container.appState.issues {
            guard let option = issue.assignee?.issueFieldOption else { continue }
            if !needle.isEmpty {
                let haystack = [option.displayName, option.login].compactMap { $0 }.joined(separator: " ").lowercased()
                guard haystack.contains(needle) else { continue }
            }
            let updatedAt = issue.updatedAt
            if let existing = latestByID[option.stableID], existing.1 >= updatedAt {
                continue
            }
            latestByID[option.stableID] = (option, updatedAt)
        }
        return latestByID.values.sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
        }
        .map { $0.0 }
    }

    private func scheduleSearch(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            remoteOptions = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runSearch(query: trimmed)
        }
    }

    private func runSearch(query: String) async {
        await MainActor.run {
            isSearching = true
        }
        let results = await container.searchPeople(query: query, projectID: nil)
        if Task.isCancelled { return }
        await MainActor.run {
            isSearching = false
            remoteOptions = results
        }
    }

    private func selectAssignee(_ option: IssueFieldOption?) {
        var patch = IssuePatch(title: nil, description: nil, status: nil, priority: nil)
        patch.issueReadableID = issue.readableID
        if let option {
            if option.stableID == selectedStableID { return }
            patch.assignee = .set(option)
        } else {
            guard issue.assignee != nil else { return }
            patch.assignee = .clear
        }
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
        isPresented = false
    }
}

private struct AssigneeOptionRow: View {
    let option: IssueFieldOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            UserAvatarView(person: Person.from(option: option), size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                if let login = option.login, !login.isEmpty {
                    Text(login)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct UnassignedRow: View {
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
            Text("Unassigned")
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct BadgeLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct MarkdownTextView: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) {
            Text(attributed)
                .font(.callout)
        } else {
            Text(text)
                .font(.callout)
        }
    }
}

private struct TimelineEntry: Identifiable {
    let id: String
    let title: String
    let date: Date
    let person: Person?
    let body: String?
}

private struct TimelineRow: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UserAvatarView(person: entry.person, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.date.formatted(.dateTime.year().month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let body = entry.body {
                    MarkdownTextView(text: body)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
