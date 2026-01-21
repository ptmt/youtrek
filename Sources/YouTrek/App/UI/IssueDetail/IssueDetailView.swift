import SwiftUI

struct IssueDetailView: View {
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
                BadgeLabel(text: issue.status.displayName, tint: issue.status.tint)
                BadgeLabel(text: issue.priority.displayName, tint: issue.priority.tint)
            }
        }
    }

    private var metadata: some View {
        let reporter = detail?.reporter ?? issue.reporter
        let reporterName = reporter?.displayName ?? issue.reporterDisplayName
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                UserAvatarView(person: issue.assignee, size: 22)
                Text("Assignee: \(issue.assigneeDisplayName)")
            }
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
