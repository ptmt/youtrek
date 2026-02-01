import SwiftUI

struct NewIssueDialog: View {
    @EnvironmentObject private var container: AppContainer
    @Binding var state: NewIssueDialogState
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [IssueProject] = []
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []
    @State private var assigneeOptions: [IssueFieldOption] = []
    @State private var isLoadingProjects = false
    @State private var isLoadingFields = false
    @State private var isProjectPickerPresented = false
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
            statusChipLabel(
                text: state.statusOption?.displayName ?? "Status",
                color: state.statusOption.map { option in
                    option.badgeColors(fallback: IssueStatus(option: option).badgeColors).foreground
                }
            )
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
            priorityChipLabel(
                text: state.priorityOption?.displayName ?? "Priority",
                isTopPriority: state.priorityOption.map { IssuePriority(option: $0).isTopPriority } ?? false
            )
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
        Menu {
            Text("More options coming soon")
        } label: {
            metadataChipLabel(
                icon: "ellipsis",
                text: nil
            )
        }
        .menuStyle(.borderlessButton)
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

    private func statusChipLabel(text: String, color: Color?) -> some View {
        chipContainer {
            HStack(spacing: 6) {
                Circle()
                    .fill((color ?? Color.secondary).opacity(color == nil ? 0.5 : 1.0))
                    .frame(width: 6, height: 6)
                Text(text)
                    .font(.caption)
            }
        }
    }

    private func priorityChipLabel(text: String, isTopPriority: Bool) -> some View {
        chipContainer {
            HStack(spacing: 6) {
                if isTopPriority {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(Color.red)
                }
                Text(text)
                    .font(.caption)
            }
        }
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
            return
        }

        isLoadingFields = true

        let issueContext = issueContext(for: project)
        async let statusTask = container.loadStatusOptions(for: issueContext)
        async let priorityTask = container.loadPriorityOptions(for: issueContext)
        async let assigneeTask = container.searchPeople(query: nil, projectID: projectID)

        statusOptions = await statusTask
        priorityOptions = await priorityTask
        assigneeOptions = await assigneeTask

        isLoadingFields = false
    }
    private func issueContext(for project: IssueProject) -> IssueSummary {
        let nameCandidate = project.shortName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (nameCandidate?.isEmpty == false) ? nameCandidate! : project.name
        let fallbackName = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? project.id : resolvedName
        return IssueSummary(readableID: "Draft", title: "", projectName: fallbackName)
    }

    // MARK: - Actions

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
