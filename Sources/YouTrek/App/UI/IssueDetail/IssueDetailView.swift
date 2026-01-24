import SwiftUI

struct IssueDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let detail: IssueDetail?
    let isLoadingDetail: Bool
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []
    @State private var projectOptions: [IssueProject] = []
    @State private var isLoadingProjects: Bool = false
    @State private var commentText: String = ""
    @State private var isSubmittingComment: Bool = false
    @State private var commentError: String?

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
                Divider()
                commentComposer
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
        .task(id: issue.readableID) {
            statusOptions = []
            priorityOptions = []
            projectOptions = []
            commentText = ""
            commentError = nil
            isLoadingProjects = true
            defer { isLoadingProjects = false }
            projectOptions = await container.loadProjects()
            statusOptions = await container.loadStatusOptions(for: issue)
            priorityOptions = await container.loadPriorityOptions(for: issue)
        }
        .onChange(of: issue.projectName) { _, _ in
            Task {
                statusOptions = []
                priorityOptions = []
                statusOptions = await container.loadStatusOptions(for: issue)
                priorityOptions = await container.loadPriorityOptions(for: issue)
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            AssigneeEditor(issue: issue)
            metadataRow(systemImage: "clock") {
                Text("Updated \(issue.updatedAt.formatted(.relative(presentation: .named)))")
            }
            ProjectEditor(
                issue: issue,
                projects: projectOptions,
                isLoading: isLoadingProjects,
                onSelect: updateProject
            )
            if !issue.tags.isEmpty {
                metadataRow(systemImage: "tag") {
                    Text("Tags: \(issue.tags.joined(separator: ", "))")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func updateProject(_ project: IssueProject) {
        let currentProjectID = projectOptions.first { $0.matches(identifier: issue.projectName) }?.id
        guard project.id != currentProjectID else { return }
        let trimmedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = IssuePatch(title: nil, description: nil, status: nil, priority: nil)
        patch.issueReadableID = issue.readableID
        patch.projectID = project.id
        patch.projectName = trimmedName.isEmpty ? project.displayName : trimmedName
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private func metadataRow<Content: View>(systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            MetadataIcon(systemName: systemImage, size: IssueDetailMetrics.metadataIconSize)
            content()
        }
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
            ForEach(statusMenuOptions, id: \.stableID) { option in
                Button {
                    updateStatus(option)
                } label: {
                    let colors = statusColors(for: option)
                    menuRow(
                        title: option.displayName,
                        colors: colors,
                        isSelected: optionMatchesStatus(option)
                    )
                }
            }
        } label: {
            BadgeLabel(
                text: issue.status.displayName,
                colors: issue.status.badgeColors,
                showsPile: true
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var statusMenuOptions: [IssueFieldOption] {
        let base = statusOptions.isEmpty ? fallbackStatusOptions : statusOptions
        return mergedOptions(base, currentName: issue.status.displayName)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(priorityMenuOptions, id: \.stableID) { option in
                Button {
                    updatePriority(option)
                } label: {
                    let colors = priorityColors(for: option)
                    menuRow(
                        title: option.displayName,
                        colors: colors,
                        isSelected: optionMatchesPriority(option)
                    )
                }
            }
        } label: {
            BadgeLabel(
                text: issue.priority.displayName,
                colors: issue.priority.badgeColors,
                showsPile: true
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var priorityMenuOptions: [IssueFieldOption] {
        let base = priorityOptions.isEmpty ? fallbackPriorityOptions : priorityOptions
        return mergedOptions(base, currentName: issue.priority.displayName)
    }

    private var fallbackStatusOptions: [IssueFieldOption] {
        IssueStatus.fallbackCases.map { status in
            IssueFieldOption(id: "", name: status.displayName, displayName: status.displayName)
        }
    }

    private var fallbackPriorityOptions: [IssueFieldOption] {
        IssuePriority.fallbackCases.map { priority in
            IssueFieldOption(id: "", name: priority.displayName, displayName: priority.displayName)
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

    private func statusColors(for option: IssueFieldOption) -> IssueBadgeColors {
        option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
    }

    private func priorityColors(for option: IssueFieldOption) -> IssueBadgeColors {
        option.badgeColors(fallback: IssuePriority(option: option).badgeColors)
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

    private func optionMatchesStatus(_ option: IssueFieldOption) -> Bool {
        optionMatches(option, name: issue.status.displayName)
    }

    private func optionMatchesPriority(_ option: IssueFieldOption) -> Bool {
        optionMatches(option, name: issue.priority.displayName)
    }

    private func menuRow(title: String, colors: IssueBadgeColors, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(colors.border, lineWidth: 1)
                )
                .frame(width: 18, height: 12)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updateStatus(_ option: IssueFieldOption) {
        guard !optionMatchesStatus(option) else { return }
        var patch = IssuePatch(title: nil, description: nil, status: nil, statusOption: option, priority: nil)
        patch.issueReadableID = issue.readableID
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private func updatePriority(_ option: IssueFieldOption) {
        guard !optionMatchesPriority(option) else { return }
        var patch = IssuePatch(title: nil, description: nil, status: nil, priority: nil, priorityOption: option)
        patch.issueReadableID = issue.readableID
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Add comment")
                    .font(.headline)
                if isSubmittingComment {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $commentText)
                    .frame(minHeight: 120)
                    .font(.callout)
                    .accessibilityLabel("Comment text")
                if commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write a comment…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                        .padding(.leading, 5)
                }
            }
            HStack(spacing: 12) {
                if let commentError {
                    Text(commentError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Post Comment") {
                    submitComment()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingComment)
            }
        }
        .onChange(of: commentText) { _, _ in
            if commentError != nil {
                commentError = nil
            }
        }
    }

    private func submitComment() {
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingComment else { return }
        commentError = nil
        isSubmittingComment = true
        Task {
            do {
                _ = try await container.addComment(to: issue, text: trimmed)
                await MainActor.run {
                    commentText = ""
                    isSubmittingComment = false
                }
            } catch {
                await MainActor.run {
                    commentError = error.localizedDescription
                    isSubmittingComment = false
                }
            }
        }
    }
}

private enum IssueDetailMetrics {
    static let metadataIconSize: CGFloat = 22
    static let assigneeOptionAvatarSize: CGFloat = 20
}

private struct MetadataIcon: View {
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.55, weight: .semibold))
            .frame(width: size, height: size)
    }
}

private struct ProjectEditor: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let projects: [IssueProject]
    let isLoading: Bool
    let onSelect: (IssueProject) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if isLoading && projects.isEmpty {
                HStack(spacing: 8) {
                    MetadataIcon(systemName: "folder", size: IssueDetailMetrics.metadataIconSize)
                    Text("Project: Loading…")
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    MetadataIcon(systemName: "folder", size: IssueDetailMetrics.metadataIconSize)
                    Text("Project: \(projectDisplayName)")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectPickerPopover(
                issue: issue,
                projects: projects,
                isLoading: isLoading,
                isPresented: $isPresented,
                onSelect: onSelect
            )
            .environmentObject(container)
        }
    }

    private var projectDisplayName: String {
        if let project = currentProject {
            let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            let short = project.shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !short.isEmpty {
                return short
            }
        }
        let trimmed = issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown Project" : trimmed
    }

    private var currentProject: IssueProject? {
        projects.first { $0.matches(identifier: issue.projectName) }
    }
}

private struct ProjectPickerPopover: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let projects: [IssueProject]
    let isLoading: Bool
    @Binding var isPresented: Bool
    let onSelect: (IssueProject) -> Void
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project")
                .font(.headline)
            TextField("Search projects", text: $query)
            if isLoading && projects.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filteredProjects.isEmpty {
                        Text(queryHint.isEmpty ? "No projects available." : "No matching projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(filteredProjects) { project in
                            Button {
                                selectProject(project)
                            } label: {
                                ProjectOptionRow(project: project, isSelected: project.id == selectedProjectID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            if !queryHint.isEmpty {
                Text(queryHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var selectedProjectID: String? {
        projects.first { $0.matches(identifier: issue.projectName) }?.id
    }

    private var queryHint: String {
        if projects.isEmpty { return "" }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Showing projects from your recent issues first. Type to search all projects."
        }
        return "Recent matches are shown first."
    }

    private var availableProjects: [IssueProject] {
        let activeProjects = projects.filter { !$0.isArchived }
        guard let current = projects.first(where: { $0.matches(identifier: issue.projectName) }),
              current.isArchived else {
            return activeProjects
        }
        if activeProjects.contains(current) { return activeProjects }
        return [current] + activeProjects
    }

    private var recentProjects: [IssueProject] {
        var latestByID: [String: (IssueProject, Date)] = [:]
        for issue in container.appState.issues {
            let trimmed = issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let project = availableProjects.first(where: { $0.matches(identifier: trimmed) }) else { continue }
            let updatedAt = issue.updatedAt
            if let existing = latestByID[project.id], existing.1 >= updatedAt {
                continue
            }
            latestByID[project.id] = (project, updatedAt)
        }
        return latestByID.values.sorted { left, right in
            if left.1 != right.1 {
                return left.1 > right.1
            }
            return left.0.displayName.localizedCaseInsensitiveCompare(right.0.displayName) == .orderedAscending
        }
        .map { $0.0 }
    }

    private var orderedProjects: [IssueProject] {
        let recent = recentProjects
        let recentIDs = Set(recent.map(\.id))
        let remaining = availableProjects.filter { !recentIDs.contains($0.id) }
        return recent + remaining
    }

    private var filteredProjects: [IssueProject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return orderedProjects }
        let needle = trimmed.lowercased()
        return orderedProjects.filter { project in
            let parts = [
                project.displayName,
                project.name,
                project.shortName ?? ""
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return parts.contains { !$0.isEmpty && $0.contains(needle) }
        }
    }

    private func selectProject(_ project: IssueProject) {
        if project.id == selectedProjectID { return }
        onSelect(project)
        isPresented = false
    }
}

private struct ProjectOptionRow: View {
    let project: IssueProject
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            MetadataIcon(systemName: "folder", size: IssueDetailMetrics.assigneeOptionAvatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name.isEmpty ? project.displayName : project.name)
                if let shortName = project.shortName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !shortName.isEmpty,
                   shortName.caseInsensitiveCompare(project.name) != .orderedSame {
                    Text(shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if project.isArchived {
                    Text("Archived")
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

private struct AssigneeEditor: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                UserAvatarView(person: issue.assignee, size: IssueDetailMetrics.metadataIconSize)
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
            UserAvatarView(person: Person.from(option: option), size: IssueDetailMetrics.assigneeOptionAvatarSize)
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
                .font(.system(size: IssueDetailMetrics.assigneeOptionAvatarSize * 0.6, weight: .semibold))
                .frame(width: IssueDetailMetrics.assigneeOptionAvatarSize, height: IssueDetailMetrics.assigneeOptionAvatarSize)
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
    let colors: IssueBadgeColors
    let showsPile: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsPile {
                Capsule()
                    .fill(colors.background.opacity(0.8))
                    .offset(x: 2, y: 2)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(colors.foreground)
                    .frame(width: 6, height: 6)
                Text(text)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(colors.foreground)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(colors.background, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(colors.border, lineWidth: 1)
            )
        }
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
