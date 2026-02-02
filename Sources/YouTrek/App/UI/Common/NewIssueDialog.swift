import SwiftUI

struct NewIssueDialog: View {
    @EnvironmentObject private var container: AppContainer
    @Binding var state: NewIssueDialogState
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [IssueProject] = []
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []
    @State private var assigneeOptions: [IssueFieldOption] = []
    @State private var customFields: [IssueField] = []
    @State private var isLoadingProjects = false
    @State private var isLoadingFields = false
    @State private var isLoadingCustomFields = false
    @State private var isProjectPickerPresented = false
    @State private var isMoreOptionsPresented = false
    @State private var showsAllCustomFields = false
    @FocusState private var isTitleFocused: Bool

    private var selectedProject: IssueProject? {
        projects.first { $0.id == state.projectID }
    }

    private var projectChipLabel: String {
        if let project = selectedProject {
            return project.shortName ?? project.name
        }
        return "Project"
    }

    private var projectSelection: ProjectSelection {
        ProjectSelection(
            projectID: state.projectID,
            projectName: selectedProject?.name ?? selectedProject?.shortName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dialogHeader
            Divider()
            dialogContent
            Divider()
            metadataChipsRow
            Divider()
            attachmentsSection
            Divider()
            dialogFooter
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 720)
        .frame(minHeight: 400, idealHeight: 480)
        .background(.regularMaterial)
        .task {
            await loadInitialData()
            isTitleFocused = true
        }
        .task(id: state.projectID) {
            await loadFieldsForProject()
        }
    }

    // MARK: - Header

    private var dialogHeader: some View {
        HStack(spacing: 8) {
            projectChip
            Text("›")
                .foregroundStyle(.tertiary)
            Text("New issue")
                .font(.headline)
            Spacer()
            Button {
                container.router.openNewIssueWindow()
                dismiss()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Open in separate window")

            Button {
                dismiss()
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

    private var projectChip: some View {
        Button {
            isProjectPickerPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(projectChipLabel)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
            ProjectPickerPopover(
                selection: projectSelection,
                projects: projects,
                isLoading: isLoadingProjects,
                isPresented: $isProjectPickerPresented,
                onSelect: { project in
                    state.projectID = project.id
                }
            )
            .environmentObject(container)
        }
    }

    // MARK: - Content

    private var dialogContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Issue title", text: $state.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.medium))
                .focused($isTitleFocused)

            ZStack(alignment: .topLeading) {
                if state.description.isEmpty {
                    Text("Add description...")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.description)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 120)
            }
        }
        .padding(16)
    }

    // MARK: - Metadata Chips

    private var metadataChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusChip
                priorityChip
                assigneeChip
                moreChip
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var attachmentsSection: some View {
        DraftAttachmentPicker(attachments: $state.attachments, showEmptyState: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private var statusChip: some View {
        Menu {
            if statusOptions.isEmpty {
                Text("No status options")
            } else {
                Button("None") {
                    state.statusOption = nil
                }
                Divider()
                ForEach(statusOptions, id: \.stableID) { option in
                    Button {
                        state.statusOption = option
                    } label: {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            chipContainer {
                IssueStatusBadge(
                    text: state.statusOption?.displayName ?? "Status",
                    colors: statusChipColors,
                    textOpacity: state.statusOption == nil ? 0.6 : 0.86,
                    dotOpacity: state.statusOption == nil ? 0.5 : 1.0
                )
                .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var priorityChip: some View {
        Menu {
            if priorityOptions.isEmpty {
                ForEach(IssuePriority.allCases, id: \.rawValue) { priority in
                    Button {
                        state.priorityOption = IssueFieldOption(
                            id: priority.rawValue,
                            name: priority.rawValue,
                            displayName: priority.displayName
                        )
                    } label: {
                        priorityMenuLabel(title: priority.displayName, isTopPriority: priority.isTopPriority)
                    }
                }
            } else {
                Button("None") {
                    state.priorityOption = nil
                }
                Divider()
                ForEach(priorityOptions, id: \.stableID) { option in
                    Button {
                        state.priorityOption = option
                    } label: {
                        let isTop = IssuePriority(option: option).isTopPriority
                        priorityMenuLabel(title: option.displayName, isTopPriority: isTop)
                    }
                }
            }
        } label: {
            chipContainer {
                IssuePriorityBadge(
                    text: state.priorityOption?.displayName ?? "Priority",
                    isTopPriority: state.priorityOption.map { IssuePriority(option: $0).isTopPriority } ?? false,
                    isMuted: state.priorityOption == nil
                )
                .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var assigneeChip: some View {
        Menu {
            Button("Unassigned") {
                state.assigneeOption = nil
            }
            Divider()
            if assigneeOptions.isEmpty && !isLoadingFields {
                Text("No assignees loaded")
            } else {
                ForEach(assigneeOptions, id: \.stableID) { option in
                    Button {
                        state.assigneeOption = option
                    } label: {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            metadataChipLabel(
                icon: "person",
                text: state.assigneeOption?.displayName ?? "Assignee"
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var moreChip: some View {
        Button {
            isMoreOptionsPresented.toggle()
        } label: {
            metadataChipLabel(
                icon: "ellipsis",
                text: nil
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isMoreOptionsPresented, arrowEdge: .bottom) {
            moreOptionsPopover
        }
    }

    private var moreOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("More options")
                    .font(.headline)
                Spacer()
                if isLoadingCustomFields {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if displayCustomFields.isEmpty {
                Text(isLoadingCustomFields ? "Loading fields…" : "No additional fields yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !showsAllCustomFields {
                    Text("Suggested from Inbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(displayCustomFields) { field in
                            IssueFieldRow(
                                field: field,
                                value: draftFieldBinding(for: field),
                                onPrefetchPeople: prefetchPeopleIfNeeded,
                                onSearchPeople: { query in
                                    await searchPeople(query: query, fieldID: field.id)
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }

            if shouldShowCustomFieldToggle {
                Button(customFieldsToggleLabel) {
                    showsAllCustomFields.toggle()
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func metadataChipLabel(icon: String, text: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            if let text {
                Text(text)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .foregroundStyle(.secondary)
    }

    private func chipContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(.secondary)
    }

    private func priorityMenuLabel(title: String, isTopPriority: Bool) -> some View {
        HStack(spacing: 6) {
            if isTopPriority {
                Image(systemName: "flag.fill")
                    .foregroundStyle(Color.red)
            }
            Text(title)
        }
    }

    private var statusChipColors: IssueBadgeColors {
        if let option = state.statusOption {
            return option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
        }
        return IssueBadgeColors(background: .clear, foreground: .secondary, border: .clear)
    }

    private var displayCustomFields: [IssueField] {
        let base = showsAllCustomFields ? orderedCustomFields(customFields) : suggestedCustomFields
        return base.map { field in
            var resolved = field
            resolved.options = orderedOptions(for: field, options: field.options)
            return resolved
        }
    }

    private var suggestedCustomFields: [IssueField] {
        let ordered = orderedCustomFields(customFields)
        let required = ordered.filter { $0.isRequired }
        let usageSorted = ordered.filter { !$0.isRequired && fieldUsageScore($0) > 0 }
        let topUsage = usageSorted.prefix(6)
        var combined: [IssueField] = []
        for field in required + topUsage {
            if !combined.contains(where: { $0.id == field.id }) {
                combined.append(field)
            }
        }
        return combined
    }

    private var shouldShowCustomFieldToggle: Bool {
        let ordered = orderedCustomFields(customFields)
        return ordered.count > suggestedCustomFields.count
    }

    private var customFieldsToggleLabel: String {
        showsAllCustomFields ? "Show suggested fields" : "Show all fields"
    }

    private func orderedCustomFields(_ fields: [IssueField]) -> [IssueField] {
        fields.sorted { left, right in
            if left.isRequired != right.isRequired {
                return left.isRequired && !right.isRequired
            }
            let leftScore = fieldUsageScore(left)
            let rightScore = fieldUsageScore(right)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private func orderedOptions(for field: IssueField, options: [IssueFieldOption]) -> [IssueFieldOption] {
        guard !options.isEmpty else { return options }
        let usage = fieldUsageCounts(field)
        guard !usage.isEmpty else { return options }
        let normalizedUsage = usage.reduce(into: [String: Int]()) { partial, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            partial[key] = entry.value
        }

        func score(for option: IssueFieldOption) -> Int {
            let candidates = [
                option.displayName,
                option.name
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return candidates.compactMap { normalizedUsage[$0] }.max() ?? 0
        }

        return options.sorted { left, right in
            let leftScore = score(for: left)
            let rightScore = score(for: right)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private func fieldUsageScore(_ field: IssueField) -> Int {
        container.appState.inboxFieldUsageScore(for: field.normalizedName)
    }

    private func fieldUsageCounts(_ field: IssueField) -> [String: Int] {
        container.appState.inboxFieldUsageCounts(for: field.normalizedName)
    }

    private var excludedCustomFieldNames: Set<String> {
        ["assignee", "state", "status", "priority"]
    }

    // MARK: - Footer

    private var dialogFooter: some View {
        HStack(spacing: 12) {
            Button {
                // Attachment action - placeholder for future implementation
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .help("Add attachment")

            Spacer()

            Toggle("Create more", isOn: $state.createMore)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Button("Create issue") {
                createIssue()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canCreate: Bool {
        !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        state.projectID != nil
    }

    // MARK: - Data Loading

    private func loadInitialData() async {
        isLoadingProjects = true
        let loadedProjects = await container.loadProjects()
        projects = loadedProjects
        isLoadingProjects = false

        if state.projectID == nil {
            let ordered = ProjectPickerPopover.orderedProjects(
                projects: projects,
                selectedProject: nil,
                recentIssues: container.appState.issues
            )
            if let first = ordered.first {
                state.projectID = first.id
            }
        }
    }

    private func loadFieldsForProject() async {
        guard let projectID = state.projectID,
              let project = projects.first(where: { $0.id == projectID }) else {
            statusOptions = []
            priorityOptions = []
            assigneeOptions = []
            customFields = []
            return
        }

        isLoadingFields = true
        isLoadingCustomFields = true
        showsAllCustomFields = false
        state.customFields = []

        let issueContext = issueContext(for: project)
        async let statusTask = container.loadStatusOptions(for: issueContext)
        async let priorityTask = container.loadPriorityOptions(for: issueContext)
        async let assigneeTask = container.searchPeople(query: nil, projectID: projectID)
        async let customFieldsTask = loadCustomFields(for: project)

        statusOptions = await statusTask
        priorityOptions = await priorityTask
        assigneeOptions = await assigneeTask
        customFields = await customFieldsTask

        isLoadingFields = false
        isLoadingCustomFields = false
    }

    private func loadCustomFields(for project: IssueProject) async -> [IssueField] {
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

        return resolved
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

    private func prefetchPeopleIfNeeded() {
        guard let projectID = state.projectID else { return }
        Task {
            let options = await container.searchPeople(query: nil, projectID: projectID)
            await MainActor.run {
                updateUserFieldOptions(options)
            }
        }
    }

    private func searchPeople(query: String, fieldID: String) async {
        guard let projectID = state.projectID else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = await container.searchPeople(query: trimmed.isEmpty ? nil : trimmed, projectID: projectID)
        await MainActor.run {
            updateFieldOptions(fieldID: fieldID, options: options)
        }
    }

    private func updateUserFieldOptions(_ options: [IssueFieldOption]) {
        guard !options.isEmpty else { return }
        for index in customFields.indices where customFields[index].kind.usesPeople {
            customFields[index].options = options
        }
    }

    private func updateFieldOptions(fieldID: String, options: [IssueFieldOption]) {
        guard let index = customFields.firstIndex(where: { $0.id == fieldID }) else { return }
        customFields[index].options = options
    }

    private func issueContext(for project: IssueProject) -> IssueSummary {
        let nameCandidate = project.shortName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (nameCandidate?.isEmpty == false) ? nameCandidate! : project.name
        let fallbackName = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? project.id : resolvedName
        return IssueSummary(readableID: "Draft", title: "", projectName: fallbackName)
    }

    // MARK: - Actions

    private func draftFieldBinding(for field: IssueField) -> Binding<IssueDraftFieldValue> {
        Binding(
            get: {
                state.customFields.first(where: { $0.normalizedName == field.normalizedName })?.value ?? .none
            },
            set: { newValue in
                updateDraftField(field, value: newValue)
            }
        )
    }

    private func updateDraftField(_ field: IssueField, value: IssueDraftFieldValue) {
        let normalized = field.normalizedName
        if value.isEmpty {
            state.customFields.removeAll { $0.normalizedName == normalized }
            return
        }
        let draftField = IssueDraftField(
            name: field.name,
            kind: field.kind,
            allowsMultiple: field.allowsMultiple,
            value: value
        )
        if let index = state.customFields.firstIndex(where: { $0.normalizedName == normalized }) {
            state.customFields[index] = draftField
        } else {
            state.customFields.append(draftField)
        }
    }

    private func normalizedCustomFields(from fields: [IssueDraftField]) -> [IssueDraftField] {
        let excluded = excludedCustomFieldNames
        var seen: Set<String> = []
        var resolved: [IssueDraftField] = []
        for field in fields where !field.value.isEmpty {
            let normalized = field.normalizedName
            guard !normalized.isEmpty, !excluded.contains(normalized) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            resolved.append(field)
        }
        return resolved
    }

    private func createIssue() {
        let trimmedTitle = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let projectID = state.projectID else { return }

        var customFields: [IssueDraftField] = []

        if let statusOption = state.statusOption {
            customFields.append(IssueDraftField(
                name: "State",
                kind: .state,
                allowsMultiple: false,
                value: .option(statusOption)
            ))
        }

        customFields.append(contentsOf: normalizedCustomFields(from: state.customFields))

        let priority: IssuePriority
        if let priorityOption = state.priorityOption {
            priority = IssuePriority(option: priorityOption)
        } else {
            priority = .normal
        }

        let assigneeID: String?
        if let assigneeOption = state.assigneeOption {
            assigneeID = assigneeOption.login ?? assigneeOption.name
        } else {
            assigneeID = nil
        }

        let draft = IssueDraft(
            title: trimmedTitle,
            description: state.description.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: projectID,
            module: nil,
            priority: priority,
            assigneeID: assigneeID,
            customFields: customFields,
            attachments: state.attachments
        )

        container.submitDraftFromDialog(draft)

        if state.createMore {
            state = NewIssueDialogState(
                projectID: projectID,
                createMore: true
            )
            isTitleFocused = true
        } else {
            dismiss()
        }
    }
}
