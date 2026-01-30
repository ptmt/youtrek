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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dialogHeader
            Divider()
            dialogContent
            Divider()
            metadataChipsRow
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
        Menu {
            if isLoadingProjects {
                Text("Loading projects...")
            } else if projects.isEmpty {
                Text("No projects available")
            } else {
                ForEach(projects) { project in
                    Button {
                        state.projectID = project.id
                    } label: {
                        HStack {
                            if let shortName = project.shortName {
                                Text(shortName)
                                    .fontWeight(.medium)
                            }
                            Text(project.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(projectChipLabel)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
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
            metadataChipLabel(
                icon: "circle.dotted",
                text: state.statusOption?.displayName ?? "Status",
                colors: state.statusOption.map { option in
                    option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
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
                        Label(priority.displayName, systemImage: priority.iconName)
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
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            metadataChipLabel(
                icon: "flag",
                text: state.priorityOption?.displayName ?? "Priority",
                colors: state.priorityOption.map { option in
                    option.badgeColors(fallback: IssuePriority(option: option).badgeColors)
                }
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
                text: state.assigneeOption?.displayName ?? "Assignee",
                colors: nil
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
                text: nil,
                colors: nil
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func metadataChipLabel(icon: String, text: String?, colors: IssueBadgeColors?) -> some View {
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
        .background(
            colors?.background.opacity(0.6) ?? Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(colors?.border ?? Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .foregroundStyle(colors?.foreground ?? .secondary)
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
        projects = loadedProjects.filter { !$0.isArchived }
        isLoadingProjects = false

        if state.projectID == nil, let first = projects.first {
            state.projectID = first.id
        }
    }

    private func loadFieldsForProject() async {
        guard let projectID = state.projectID else {
            statusOptions = []
            priorityOptions = []
            assigneeOptions = []
            return
        }

        isLoadingFields = true

        async let statusTask = loadStatusOptionsForProject(projectID)
        async let priorityTask = loadPriorityOptionsForProject(projectID)
        async let assigneeTask = container.searchPeople(query: nil, projectID: projectID)

        statusOptions = await statusTask
        priorityOptions = await priorityTask
        assigneeOptions = await assigneeTask

        isLoadingFields = false
    }

    private func loadStatusOptionsForProject(_ projectID: String) async -> [IssueFieldOption] {
        let fields = await container.loadFields(for: projectID)
        guard let statusField = findStatusField(in: fields),
              let bundleID = statusField.bundleID else {
            return []
        }
        return await container.loadBundleOptions(bundleID: bundleID, kind: statusField.kind)
    }

    private func loadPriorityOptionsForProject(_ projectID: String) async -> [IssueFieldOption] {
        let fields = await container.loadFields(for: projectID)
        guard let priorityField = findPriorityField(in: fields),
              let bundleID = priorityField.bundleID else {
            return []
        }
        return await container.loadBundleOptions(bundleID: bundleID, kind: priorityField.kind)
    }

    private func findStatusField(in fields: [IssueField]) -> IssueField? {
        fields.first { field in
            let names = [field.name, field.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return names.contains("state") || names.contains("status") || field.kind == .state
        }
    }

    private func findPriorityField(in fields: [IssueField]) -> IssueField? {
        fields.first { field in
            let names = [field.name, field.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return names.contains("priority")
        }
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
            customFields: customFields
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
