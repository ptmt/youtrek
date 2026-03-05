import SwiftUI
import AppKit
import Foundation

struct IssueDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let issue: IssueSummary
    let detail: IssueDetail?
    let isLoadingDetail: Bool
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []
    @State private var projectOptions: [IssueProject] = []
    @State private var isLoadingProjects: Bool = false
    @State private var customFields: [IssueField] = []
    @State private var isLoadingCustomFields: Bool = false
    @State private var parentIssues: [IssueSummary] = []
    @State private var isLoadingParentIssues: Bool = false
    @State private var parentIssuesError: String?
    @State private var subIssues: [IssueSummary] = []
    @State private var isLoadingSubIssues: Bool = false
    @State private var subIssuesError: String?
    @State private var commentText: String = ""
    @State private var isSubmittingComment: Bool = false
    @State private var commentError: String?
    @State private var isPickingAttachment = false
    @State private var isPickingImage = false
    @State private var isUploadingAttachments = false
    @State private var attachmentError: String?
    @State private var lastIssueCopyTimestamp: Date?
    @State private var lastIssueCopiedID: String?
    @State private var showsAllCustomFields: Bool = false
    @State private var showsCommentPreview: Bool = false
    @State private var showsInitialLoadingMessage: Bool = false
    @State private var initialLoadingTask: Task<Void, Never>?

    private let loadingIndicatorDelayNanoseconds: UInt64 = 250_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                parentIssuesSection
                Divider()
                metadata
                Divider()
                if showsInitialLoadingMessage && detail == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading issue details…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                descriptionSection
                Divider()
                attachmentsSection
                Divider()
                subIssuesSection
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
        .onAppear {
            updateInitialLoadingVisibility()
        }
        .onChange(of: isLoadingDetail) { _, _ in
            updateInitialLoadingVisibility()
        }
        .onChange(of: detail == nil) { _, _ in
            updateInitialLoadingVisibility()
        }
        .onDisappear {
            initialLoadingTask?.cancel()
            initialLoadingTask = nil
        }
        .task(id: issue.readableID) {
            statusOptions = []
            priorityOptions = []
            projectOptions = []
            customFields = []
            commentText = ""
            commentError = nil
            lastIssueCopyTimestamp = nil
            lastIssueCopiedID = nil
            showsAllCustomFields = false
            isLoadingProjects = true
            defer { isLoadingProjects = false }
            projectOptions = await container.loadProjects()
            statusOptions = await container.loadStatusOptions(for: issue)
            priorityOptions = await container.loadPriorityOptions(for: issue)
            isLoadingCustomFields = true
            customFields = await loadCustomFields()
            isLoadingCustomFields = false
        }
        .task(id: issue.readableID) {
            await loadParentIssues()
        }
        .task(id: issue.readableID) {
            await loadSubIssues()
        }
        .onChange(of: issue.projectName) { _, _ in
            Task {
                statusOptions = []
                priorityOptions = []
                statusOptions = await container.loadStatusOptions(for: issue)
                priorityOptions = await container.loadPriorityOptions(for: issue)
                isLoadingCustomFields = true
                customFields = await loadCustomFields()
                isLoadingCustomFields = false
            }
        }
        .onChange(of: container.appState.subIssueRefresh) { _, refresh in
            guard let refresh else { return }
            let trimmedParent = refresh.parentReadableID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedIssue = issue.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedParent.isEmpty,
                  trimmedParent.caseInsensitiveCompare(trimmedIssue) == .orderedSame else { return }
            Task { await loadSubIssues() }
        }
        .onChange(of: container.appState.issueDetailRefresh) { _, refresh in
            guard let refresh else { return }
            let trimmedRefresh = refresh.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedIssue = issue.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRefresh.isEmpty,
                  trimmedRefresh.caseInsensitiveCompare(trimmedIssue) == .orderedSame else { return }
            Task { await container.loadIssueDetail(for: issue) }
        }
    }

    private func updateInitialLoadingVisibility() {
        initialLoadingTask?.cancel()
        guard isLoadingDetail, detail == nil else {
            showsInitialLoadingMessage = false
            initialLoadingTask = nil
            return
        }
        initialLoadingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: loadingIndicatorDelayNanoseconds)
            guard !Task.isCancelled else { return }
            showsInitialLoadingMessage = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                issueIDLink
                Button {
                    copyIssueID()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("c", modifiers: [.command])
                .help("Copy issue ID")
            }
            Text(issue.title)
                .font(.system(size: 24, weight: .bold))
            HStack(spacing: 8) {
                statusMenu
                priorityMenu
            }
        }
    }

    @ViewBuilder
    private var issueIDLink: some View {
        if let url = container.issueWebURL(for: issue) {
            Link(destination: url) {
                Text(issue.readableID)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .underline()
            }
            .help("Open in YouTrack")
        } else {
            Text(issue.readableID)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssigneeEditor(issue: issue)
            metadataRow(systemImage: "clock") {
                Text("Updated \(IssueTimestampFormatter.label(for: issue.updatedAt))")
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if hasCustomFields {
                Button {
                    showsAllCustomFields.toggle()
                } label: {
                    metadataRow(systemImage: showsAllCustomFields ? "chevron.up" : "chevron.down") {
                        Text(customFieldsToggleLabel)
                    }
                }
                .buttonStyle(.plain)
                if showsAllCustomFields {
                    if isLoadingCustomFields {
                        metadataRow(systemImage: "square.grid.2x2") {
                            Text("Loading custom fields…")
                        }
                    }
                    let displayItems = customFieldItems.filter { !$0.values.isEmpty }
                    if displayItems.isEmpty, !isLoadingCustomFields {
                        metadataRow(systemImage: "square.grid.2x2") {
                            Text("No custom fields.")
                        }
                    } else {
                        ForEach(displayItems) { item in
                            CustomFieldEditorRow(
                                item: item,
                                initialValue: item.field.map { draftValue(for: $0, values: item.values) } ?? .none,
                                onUpdate: updateCustomField
                            )
                        }
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var customFieldRows: [IssueDetailCustomField] {
        return issue.customFieldValues.compactMap { key, values in
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmedKey.isEmpty, !excludedCustomFieldNames.contains(trimmedKey) else { return nil }
            let cleanedValues = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleanedValues.isEmpty else { return nil }
            return IssueDetailCustomField(
                id: trimmedKey,
                name: customFieldDisplayName(for: trimmedKey),
                values: cleanedValues
            )
        }
        .sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private var customFieldItems: [CustomFieldDisplayItem] {
        if customFields.isEmpty {
            return customFieldRows.map {
                CustomFieldDisplayItem(id: $0.id, name: $0.name, values: $0.values, field: nil)
            }
        }

        let valuesByKey = issue.customFieldValues
        let ordered = orderedCustomFields(customFields)
        var items: [CustomFieldDisplayItem] = ordered.map { field in
            let values = valuesByKey[field.normalizedName] ?? []
            return CustomFieldDisplayItem(
                id: field.normalizedName,
                name: field.displayName,
                values: values,
                field: field
            )
        }

        let known = Set(items.map(\.id))
        for row in customFieldRows where !known.contains(row.id) {
            items.append(CustomFieldDisplayItem(id: row.id, name: row.name, values: row.values, field: nil))
        }
        return items
    }

    private var hasCustomFields: Bool {
        customFieldItems.contains { !$0.values.isEmpty }
    }

    private var customFieldsToggleLabel: String {
        if showsAllCustomFields {
            return "Hide custom fields"
        }
        let count = customFieldItems.filter { !$0.values.isEmpty }.count
        return "Custom fields (\(count))"
    }

    private func customFieldDisplayName(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Field" }
        let spaced = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private var excludedCustomFieldNames: Set<String> {
        ["assignee", "state", "status", "priority"]
    }

    private func orderedCustomFields(_ fields: [IssueField]) -> [IssueField] {
        fields.sorted { left, right in
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private func loadCustomFields() async -> [IssueField] {
        guard let project = projectOptions.first(where: { $0.matches(identifier: issue.projectName) }) else {
            return []
        }
        let fetched = await container.loadFields(for: project.id)
        let filtered = fetched.filter { !excludedCustomFieldNames.contains($0.normalizedName) }
        guard !filtered.isEmpty else { return [] }

        let optionsByField = await fetchCustomFieldOptions(for: filtered)
        var resolved = filtered
        for index in resolved.indices {
            if let options = optionsByField[resolved[index].id] {
                resolved[index].options = options
            }
        }

        if resolved.contains(where: { $0.kind.usesPeople }) {
            let people = await container.searchPeople(query: nil, projectID: project.id)
            if !people.isEmpty {
                for index in resolved.indices where resolved[index].kind.usesPeople {
                    resolved[index].options = people
                }
            }
        }

        return orderedCustomFields(resolved)
    }

    private func fetchCustomFieldOptions(for fields: [IssueField]) async -> [String: [IssueFieldOption]] {
        var results: [String: [IssueFieldOption]] = [:]
        await withTaskGroup(of: (String, [IssueFieldOption]).self) { group in
            for field in fields {
                guard field.kind.usesOptions, let bundleID = field.bundleID else { continue }
                group.addTask {
                    let options = await container.loadBundleOptions(bundleID: bundleID, kind: field.kind)
                    return (field.id, options)
                }
            }
            for await (fieldID, options) in group {
                results[fieldID] = options
            }
        }
        return results
    }

    private func draftValue(for field: IssueField, values: [String]) -> IssueDraftFieldValue {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .none }

        switch field.kind {
        case .enumeration, .state, .version, .build, .ownedField, .user:
            let options = cleaned.map { value -> IssueFieldOption in
                if let match = option(for: value, in: field.options) {
                    return match
                }
                return IssueFieldOption(id: "", name: value, displayName: value)
            }
            if field.allowsMultiple {
                return .options(options)
            }
            return options.first.map { .option($0) } ?? .none
        case .string, .text:
            return .string(cleaned[0])
        case .integer:
            if let value = Int(cleaned[0]) {
                return .integer(value)
            }
            return .string(cleaned[0])
        case .float:
            if let value = Double(cleaned[0]) {
                return .number(value)
            }
            return .string(cleaned[0])
        case .boolean:
            if let value = parseBool(cleaned[0]) {
                return .bool(value)
            }
            return .string(cleaned[0])
        case .date, .dateTime:
            if let value = parseDate(cleaned[0]) {
                return .date(value)
            }
            return .string(cleaned[0])
        case .period:
            if let value = Int(cleaned[0]) {
                return .integer(value)
            }
            return .string(cleaned[0])
        case .unknown:
            return .string(cleaned[0])
        }
    }

    private func option(for value: String, in options: [IssueFieldOption]) -> IssueFieldOption? {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return options.first { option in
            let candidates = [
                option.displayName,
                option.name,
                option.login ?? ""
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return candidates.contains(needle)
        }
    }

    private func parseBool(_ value: String) -> Bool? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = Self.isoDateTimeFractionFormatter.date(from: trimmed) {
            return date
        }
        if let date = Self.isoDateTimeFormatter.date(from: trimmed) {
            return date
        }
        if let date = Self.isoDateFormatter.date(from: trimmed) {
            return date
        }
        for formatter in Self.fallbackDateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func updateCustomField(_ field: IssueField, value: IssueDraftFieldValue) {
        let trimmedName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        var patch = IssuePatch(title: nil, description: nil, status: nil, priority: nil)
        patch.issueReadableID = issue.readableID
        patch.customFields = [
            IssueDraftField(name: trimmedName, kind: field.kind, allowsMultiple: field.allowsMultiple, value: value)
        ]
        Task {
            await container.updateIssue(id: issue.id, patch: patch)
        }
    }

    private static let isoDateTimeFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static let fallbackDateFormatters: [DateFormatter] = {
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "MMM d, yyyy", "MMM d, yyyy h:mm a"]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

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
                MarkdownTextView(
                    text: description,
                    baseURL: markdownImageBaseURL,
                    remoteImageDataLoader: { url in
                        try await loadMarkdownImageData(from: url)
                    }
                )
            } else {
                Text(isLoadingDetail ? "Loading description…" : "No description yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachmentsSection: some View {
        let attachments = detail?.attachments ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Attachments")
                    .font(.headline)
                Spacer()
                if isUploadingAttachments {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button {
                    isPickingAttachment = true
                } label: {
                    Label("Add file", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Attach file")

                Button {
                    isPickingImage = true
                } label: {
                    Label("Add image", systemImage: "photo")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Attach image")
            }

            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if attachments.isEmpty {
                Text(isLoadingDetail ? "Loading attachments…" : "No attachments yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        IssueAttachmentRow(attachment: attachment) {
                            openAttachment(attachment)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingAttachment,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: handleAttachmentImport
        )
        .fileImporter(
            isPresented: $isPickingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleAttachmentImport
        )
    }

    private var subIssuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Sub-issues")
                    .font(.headline)
                Spacer()
                Button {
                    presentSubIssueDialog()
                } label: {
                    Label("Add sub-issue", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(issue.isDraft ? "Create the issue before adding sub-issues." : "Add a sub-issue")
                .disabled(issue.isDraft)
            }

            if issue.isDraft {
                Text("Create the issue to start linking sub-issues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isLoadingSubIssues {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading sub-issues…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let subIssuesError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(subIssuesError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") {
                        Task { await loadSubIssues() }
                    }
                    .buttonStyle(.link)
                }
            } else if subIssues.isEmpty {
                Text("No sub-issues yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(subIssues) { subIssue in
                        LinkedIssueRow(issue: subIssue) {
                            openLinkedIssue(subIssue)
                        }
                    }
                }
            }
        }
    }

    private var parentIssuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parent issues")
                .font(.headline)

            if issue.isDraft {
                Text("Create the issue to load parent issues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isLoadingParentIssues {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading parent issues…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let parentIssuesError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(parentIssuesError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") {
                        Task { await loadParentIssues() }
                    }
                    .buttonStyle(.link)
                }
            } else if parentIssues.isEmpty {
                Text("No parent issues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(parentIssues) { parentIssue in
                        LinkedIssueRow(issue: parentIssue) {
                            openLinkedIssue(parentIssue)
                        }
                    }
                }
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
                    TimelineRow(
                        entry: entry,
                        remoteImageDataLoader: { url in
                            try await loadMarkdownImageData(from: url)
                        }
                    )
                }
            }
        }
    }

    private var descriptionText: String? {
        guard let detail else { return nil }
        let trimmed = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadSubIssues() async {
        subIssues = []
        subIssuesError = nil
        guard !issue.isDraft else {
            isLoadingSubIssues = false
            return
        }
        isLoadingSubIssues = true
        defer { isLoadingSubIssues = false }
        do {
            subIssues = try await container.loadSubIssues(for: issue)
        } catch {
            subIssuesError = error.localizedDescription
        }
    }

    private func loadParentIssues() async {
        parentIssues = []
        parentIssuesError = nil
        guard !issue.isDraft else {
            isLoadingParentIssues = false
            return
        }
        isLoadingParentIssues = true
        defer { isLoadingParentIssues = false }
        do {
            parentIssues = try await container.loadParentIssues(for: issue)
        } catch {
            parentIssuesError = error.localizedDescription
        }
    }

    private func presentSubIssueDialog() {
        let parentID = issue.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parentID.isEmpty else { return }
        let priorityOption = IssueFieldOption(
            id: issue.priority.rawValue,
            name: issue.priority.displayName,
            displayName: issue.priority.displayName
        )
        let state = NewIssueDialogState(
            projectID: issue.projectName,
            parentIssueReadableID: parentID,
            parentIssueTitle: issue.title,
            title: "",
            description: "",
            statusOption: nil,
            priorityOption: priorityOption,
            assigneeOption: issue.assignee?.issueFieldOption
        )
        container.presentNewIssueDialog(state: state)
    }

    private func openLinkedIssue(_ issue: IssueSummary) {
        let isInList = container.appState.issues.contains { $0.id == issue.id }
        container.appState.selectedIssue = issue
        container.appState.selectedIssueIDs = isInList ? [issue.id] : []
        Task {
            await container.loadIssueDetail(for: issue)
        }
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            uploadAttachments(from: urls)
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    private func uploadAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let drafts = urls.map { IssueAttachmentDraft.fromFileURL($0) }
        isUploadingAttachments = true
        attachmentError = nil
        Task {
            do {
                _ = try await container.addAttachments(to: issue, attachments: drafts)
                await MainActor.run {
                    isUploadingAttachments = false
                }
            } catch {
                await MainActor.run {
                    isUploadingAttachments = false
                    attachmentError = error.localizedDescription
                }
            }
        }
    }

    private func openAttachment(_ attachment: IssueAttachment) {
        guard let url = attachment.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyIssueID() {
        let now = Date()
        let isSecondCopy: Bool
        if lastIssueCopiedID == issue.readableID,
           let lastStamp = lastIssueCopyTimestamp,
           now.timeIntervalSince(lastStamp) < 1.2 {
            isSecondCopy = true
        } else {
            isSecondCopy = false
        }
        lastIssueCopiedID = issue.readableID
        lastIssueCopyTimestamp = now

        let trimmedTitle = issue.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if isSecondCopy, !trimmedTitle.isEmpty {
            value = "\(issue.readableID) — \(trimmedTitle)"
        } else {
            value = issue.readableID
        }
        copyToPasteboard(value)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
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
                body: nil,
                markdownBaseURL: markdownImageBaseURL,
                webURL: timelineOpenURL()
            ))
        }
        if detail.createdAt == nil || detail.updatedAt > (detail.createdAt ?? .distantPast) {
            entries.append(TimelineEntry(
                id: "updated",
                title: "Updated",
                date: detail.updatedAt,
                person: nil,
                body: nil,
                markdownBaseURL: markdownImageBaseURL,
                webURL: timelineOpenURL()
            ))
        }
        for comment in detail.comments {
            let trimmed = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(TimelineEntry(
                id: "comment-\(comment.id)",
                title: "Comment",
                date: comment.createdAt,
                person: comment.author,
                body: trimmed.isEmpty ? nil : comment.text,
                markdownBaseURL: markdownImageBaseURL,
                webURL: timelineOpenURL(for: comment.id)
            ))
        }
        return entries.sorted { $0.date < $1.date }
    }

    private var markdownImageBaseURL: URL? {
        guard let issueURL = container.issueWebURL(for: issue) else { return nil }
        return issueURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func timelineOpenURL(for commentID: String? = nil) -> URL? {
        guard let issueURL = container.issueWebURL(for: issue) else { return nil }
        guard let commentID else { return issueURL }
        guard var components = URLComponents(url: issueURL, resolvingAgainstBaseURL: false) else { return issueURL }
        components.fragment = "comment-\(commentID)"
        return components.url ?? issueURL
    }

    private func loadMarkdownImageData(from url: URL) async throws -> Data {
        let attachment = IssueAttachment(
            id: UUID().uuidString,
            name: "Comment image",
            size: nil,
            mimeType: nil,
            url: url,
            createdAt: nil,
            author: nil
        )
        return try await container.fetchAttachmentData(for: attachment)
    }

    private var statusMenu: some View {
        let isClosed = issue.status.isClosed
        return Menu {
            ForEach(statusMenuOptions, id: \.stableID) { option in
                Button {
                    updateStatus(option)
                } label: {
                    let colors = statusColors(for: option)
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
                textOpacity: isClosed ? 0.62 : 0.86,
                dotOpacity: isClosed ? 0.6 : 1.0
            )
            .font(headerBadgeFont)
        }
        .menuStyle(.borderlessButton)
    }

    private var statusMenuOptions: [IssueFieldOption] {
        let base = statusOptions.isEmpty ? fallbackStatusOptions : statusOptions
        return mergedOptions(base, currentName: issue.status.displayName)
    }

    private var priorityMenu: some View {
        let isClosed = issue.status.isClosed
        return Menu {
            ForEach(priorityMenuOptions, id: \.stableID) { option in
                Button {
                    updatePriority(option)
                } label: {
                    let colors = option.badgeColors(fallback: IssuePriority(option: option).badgeColors)
                    IssuePriorityOptionRow(
                        text: option.displayName,
                        colors: colors,
                        showsSelection: true,
                        isSelected: optionMatchesPriority(option)
                    )
                }
            }
        } label: {
            IssuePriorityBadge(priority: issue.priority, isMuted: isClosed)
                .font(headerBadgeFont)
        }
        .menuStyle(.borderlessButton)
    }

    private var headerBadgeFont: Font {
        let isClosed = issue.status.isClosed
        let isUnread = container.appState.isIssueUnread(issue)
        let weight: Font.Weight = isUnread && !isClosed ? .medium : .regular
        return .caption.weight(weight)
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
                Spacer()
                if !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(showsCommentPreview ? "Edit" : "Preview") {
                        showsCommentPreview.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }
            if showsCommentPreview {
                MarkdownTextView(
                    text: commentText,
                    baseURL: markdownImageBaseURL,
                    remoteImageDataLoader: { url in
                        try await loadMarkdownImageData(from: url)
                    }
                )
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack(alignment: .topLeading) {
                    ClipboardImageMarkdownTextEditor(text: $commentText)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Comment text")
                    if commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Write a comment…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
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
            if commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               showsCommentPreview {
                showsCommentPreview = false
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
                    showsCommentPreview = false
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

private struct IssueDetailCustomField: Identifiable {
    let id: String
    let name: String
    let values: [String]
}

private struct CustomFieldDisplayItem: Identifiable {
    let id: String
    let name: String
    let values: [String]
    let field: IssueField?
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

private struct CustomFieldEditorRow: View {
    @EnvironmentObject private var container: AppContainer
    let item: CustomFieldDisplayItem
    let initialValue: IssueDraftFieldValue
    let onUpdate: (IssueField, IssueDraftFieldValue) -> Void
    @State private var isPresented = false

    var body: some View {
        if let field = item.field {
            Button {
                isPresented.toggle()
            } label: {
                rowLabel(showChevron: true)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                CustomFieldEditorPopover(
                    field: field,
                    initialValue: initialValue,
                    onSubmit: { value in
                        onUpdate(field, value)
                        isPresented = false
                    }
                )
                .environmentObject(container)
            }
        } else {
            rowLabel(showChevron: false)
        }
    }

    private func rowLabel(showChevron: Bool) -> some View {
        HStack(spacing: 8) {
            MetadataIcon(systemName: "square.grid.2x2", size: IssueDetailMetrics.metadataIconSize)
            Text("\(item.name): \(valueLabel)")
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var valueLabel: String {
        let cleaned = item.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? "None" : cleaned.joined(separator: ", ")
    }
}

private struct CustomFieldEditorPopover: View {
    let field: IssueField
    let initialValue: IssueDraftFieldValue
    let onSubmit: (IssueDraftFieldValue) -> Void

    @State private var value: IssueDraftFieldValue
    @State private var query: String = ""

    init(field: IssueField, initialValue: IssueDraftFieldValue, onSubmit: @escaping (IssueDraftFieldValue) -> Void) {
        self.field = field
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(field.displayName)
                .font(.headline)

            content

            HStack {
                if !value.isEmpty {
                    Button("Clear") {
                        value = .none
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Apply") {
                    onSubmit(value)
                }
                .buttonStyle(.borderedProminent)
                .disabled(value == initialValue)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var content: some View {
        switch field.kind {
        case .enumeration, .state, .version, .build, .ownedField, .user:
            optionEditor
        case .boolean:
            Toggle("Enabled", isOn: boolBinding)
        case .text:
            TextField("", text: stringBinding, axis: .vertical)
                .lineLimit(3...6)
        case .integer:
            TextField("", text: intBinding)
                .monospacedDigit()
        case .float:
            TextField("", text: floatBinding)
                .monospacedDigit()
        case .date, .dateTime:
            DatePicker(
                "",
                selection: dateBinding,
                displayedComponents: field.kind == .date ? .date : [.date, .hourAndMinute]
            )
            .labelsHidden()
        case .period:
            HStack(spacing: 8) {
                TextField("Minutes", text: intBinding)
                    .monospacedDigit()
                Text("min")
                    .foregroundStyle(.secondary)
            }
        case .string, .unknown:
            TextField("", text: stringBinding)
        }
    }

    @ViewBuilder
    private var optionEditor: some View {
        let options = filteredOptions
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter options", text: $query)
            if options.isEmpty {
                Text("No matching options")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if field.allowsMultiple {
                            ForEach(options, id: \.stableID) { option in
                                Toggle(isOn: toggleBinding(for: option)) {
                                    Text(option.displayName)
                                }
                                .toggleStyle(.checkbox)
                            }
                        } else {
                            ForEach(options, id: \.stableID) { option in
                                Button {
                                    value = .option(option)
                                } label: {
                                    CustomFieldOptionRow(
                                        option: option,
                                        isSelected: value.optionValue?.stableID == option.stableID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var filteredOptions: [IssueFieldOption] {
        guard !field.options.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return field.options }
        let needle = trimmed.lowercased()
        return field.options.filter { option in
            let candidates = [
                option.displayName,
                option.name,
                option.login ?? ""
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return candidates.contains { !$0.isEmpty && $0.contains(needle) }
        }
    }

    private func toggleBinding(for option: IssueFieldOption) -> Binding<Bool> {
        Binding(
            get: { value.optionValues.contains(where: { $0.stableID == option.stableID }) },
            set: { isSelected in
                var selected = value.optionValues
                if isSelected {
                    if !selected.contains(where: { $0.stableID == option.stableID }) {
                        selected.append(option)
                    }
                } else {
                    selected.removeAll { $0.stableID == option.stableID }
                }
                value = selected.isEmpty ? .none : .options(selected)
            }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                value = trimmed.isEmpty ? .none : .string($0)
            }
        )
    }

    private var intBinding: Binding<String> {
        Binding(
            get: { value.stringValue ?? value.intValue.map(String.init) ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    value = .none
                } else if let intValue = Int(trimmed) {
                    value = .integer(intValue)
                } else {
                    value = .string($0)
                }
            }
        )
    }

    private var floatBinding: Binding<String> {
        Binding(
            get: { value.stringValue ?? value.doubleValue.map { String($0) } ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    value = .none
                } else if let doubleValue = Double(trimmed) {
                    value = .number(doubleValue)
                } else {
                    value = .string($0)
                }
            }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { value.boolValue ?? false },
            set: { value = .bool($0) }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { value.dateValue ?? Date() },
            set: { value = .date($0) }
        )
    }
}

private struct CustomFieldOptionRow: View {
    let option: IssueFieldOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(option.displayName)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct ProjectEditor: View {
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
                selection: ProjectSelection(projectID: nil, projectName: issue.projectName),
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
        let selection = ProjectSelection(projectID: nil, projectName: issue.projectName)
        if let id = selection.projectID, !id.isEmpty {
            return projects.first { $0.id == id }
        }
        if let name = selection.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return projects.first { $0.matches(identifier: name) }
        }
        return nil
    }
}

struct ProjectSelection: Hashable {
    var projectID: String?
    var projectName: String?
}

struct ProjectPickerPopover: View {
    @EnvironmentObject private var container: AppContainer
    let selection: ProjectSelection
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
        if let projectID = selection.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        if let name = selection.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return projects.first { $0.matches(identifier: name) }?.id
        }
        return nil
    }

    private var queryHint: String {
        if projects.isEmpty { return "" }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Showing projects from your recent issues first. Type to search all projects."
        }
        return "Recent matches are shown first."
    }

    private var selectedProject: IssueProject? {
        guard let selectedID = selectedProjectID else { return nil }
        return projects.first { $0.id == selectedID }
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

    private var orderedProjects: [IssueProject] {
        Self.orderedProjects(
            projects: projects,
            selectedProject: selectedProject,
            recentIssues: container.appState.issues
        )
    }

    private func selectProject(_ project: IssueProject) {
        if project.id == selectedProjectID { return }
        onSelect(project)
        isPresented = false
    }

    static func orderedProjects(
        projects: [IssueProject],
        selectedProject: IssueProject?,
        recentIssues: [IssueSummary]
    ) -> [IssueProject] {
        let activeProjects = projects.filter { !$0.isArchived }
        let availableProjects: [IssueProject]
        if let selectedProject, selectedProject.isArchived {
            availableProjects = activeProjects.contains(selectedProject) ? activeProjects : [selectedProject] + activeProjects
        } else {
            availableProjects = activeProjects
        }

        var latestByID: [String: (IssueProject, Date)] = [:]
        for issue in recentIssues {
            let trimmed = issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let project = availableProjects.first(where: { $0.matches(identifier: trimmed) }) else { continue }
            let updatedAt = issue.updatedAt
            if let existing = latestByID[project.id], existing.1 >= updatedAt {
                continue
            }
            latestByID[project.id] = (project, updatedAt)
        }
        let recent = latestByID.values.sorted { left, right in
            if left.1 != right.1 {
                return left.1 > right.1
            }
            return left.0.displayName.localizedCaseInsensitiveCompare(right.0.displayName) == .orderedAscending
        }
        .map { $0.0 }

        let recentIDs = Set(recent.map(\.id))
        let remaining = availableProjects.filter { !recentIDs.contains($0.id) }
        return recent + remaining
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

private struct TimelineEntry: Identifiable {
    let id: String
    let title: String
    let date: Date
    let person: Person?
    let body: String?
    let markdownBaseURL: URL?
    let webURL: URL?
}

private struct TimelineRow: View {
    let entry: TimelineEntry
    let remoteImageDataLoader: ((URL) async throws -> Data)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UserAvatarView(person: entry.person, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                Group {
                    if let webURL = entry.webURL {
                        Link(destination: webURL) {
                            Text(entry.date.formatted(.dateTime.year().month().day().hour().minute()))
                        }
                    } else {
                        Text(entry.date.formatted(.dateTime.year().month().day().hour().minute()))
                    }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let body = entry.body {
                    MarkdownTextView(
                        text: body,
                        baseURL: entry.markdownBaseURL,
                        remoteImageDataLoader: remoteImageDataLoader
                    )
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LinkedIssueRow: View {
    let issue: IssueSummary
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                UserAvatarView(person: issue.assignee, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(issue.readableID)
                            .foregroundStyle(.secondary.opacity(secondaryOpacity))
                        IssueStatusBadge(
                            text: issue.status.displayName,
                            colors: issue.status.badgeColors,
                            textOpacity: isClosed ? 0.62 : 0.86,
                            dotOpacity: isClosed ? 0.6 : 1.0
                        )
                        .font(.caption2)
                        if !issue.priority.isNormalSemantic {
                            IssuePriorityBadge(priority: issue.priority, isMuted: isClosed)
                                .font(.caption2)
                        }
                    }
                    .font(.caption)
                    Text(issue.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                }
                Spacer()
                Text(IssueTimestampFormatter.label(for: issue.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(secondaryOpacity))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var isClosed: Bool {
        issue.status.isClosed
    }

    private var secondaryOpacity: Double {
        isClosed ? 0.65 : 1.0
    }

    private var titleColor: Color {
        isClosed ? .secondary.opacity(0.8) : .primary
    }
}
