import SwiftUI

struct IssueProgressListView: View {
    @EnvironmentObject private var container: AppContainer
    let issues: [IssueSummary]
    @Binding var selection: IssueSummary?
    @Binding var selectedIDs: Set<IssueSummary.ID>
    let isIssueUnread: (IssueSummary) -> Bool

    @State private var statusOptionsByProject: [String: [IssueFieldOption]] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(issues) { issue in
                    IssueProgressRow(
                        issue: issue,
                        statusOptions: statusOptions(for: issue),
                        isSelected: selection?.id == issue.id,
                        isUnread: isIssueUnread(issue)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = issue
                        selectedIDs = [issue.id]
                    }

                    if issue.id != issues.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
            .padding(.vertical, 4)
        }
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

    private func statusOptions(for issue: IssueSummary) -> [IssueFieldOption] {
        statusOptionsByProject[projectStatusKey(for: issue)] ?? []
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

private struct IssueProgressRow: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let statusOptions: [IssueFieldOption]
    let isSelected: Bool
    let isUnread: Bool

    @State private var commentText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatarView(person: issue.assignee, size: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(issue.readableID)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(issue.title)
                        .font(.callout.weight(titleWeight))
                        .foregroundStyle(issue.status.isClosed ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer()

                    statusMenu

                    if !issue.priority.isNormalSemantic {
                        IssuePriorityBadge(priority: issue.priority, isMuted: issue.status.isClosed)
                            .font(.caption2)
                    }
                }

                if let latestComment = latestComment {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(latestComment.author?.displayName ?? "Unknown")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(IssueTimestampFormatter.label(for: latestComment.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(latestComment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.leading, 2)
                }

                HStack(spacing: 8) {
                    TextField("Report progress…", text: $commentText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .onSubmit { submitComment() }

                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            submitComment()
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Post comment")
                    }
                }

                if let error = submitError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private var titleWeight: Font.Weight {
        (isUnread && !issue.status.isClosed) ? .semibold : .medium
    }

    private var statusMenu: some View {
        let options = resolvedStatusOptions
        return Menu {
            ForEach(options, id: \.stableID) { option in
                Button {
                    updateStatus(option)
                } label: {
                    let colors = option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
                    IssueStatusOptionRow(
                        text: option.displayName,
                        colors: colors,
                        showsSelection: true,
                        isSelected: optionMatchesStatus(option)
                    )
                }
            }
        } label: {
            IssueStatusBadge(
                text: issue.status.displayName,
                colors: issue.status.badgeColors,
                textOpacity: issue.status.isClosed ? 0.62 : 0.86,
                dotOpacity: issue.status.isClosed ? 0.6 : 1.0
            )
            .font(.caption2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var resolvedStatusOptions: [IssueFieldOption] {
        let base = statusOptions.isEmpty ? fallbackOptions : statusOptions
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

    private var latestComment: IssueComment? {
        container.appState.issueDetail(for: issue)?.comments.last
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

    private func updateStatus(_ option: IssueFieldOption) {
        guard !optionMatchesStatus(option) else { return }
        var patch = IssuePatch(title: nil, description: nil, status: nil, statusOption: option, priority: nil)
        patch.issueReadableID = issue.readableID
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private func submitComment() {
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        submitError = nil
        isSubmitting = true
        Task {
            do {
                _ = try await container.addComment(to: issue, text: trimmed)
                await MainActor.run {
                    commentText = ""
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    submitError = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}
