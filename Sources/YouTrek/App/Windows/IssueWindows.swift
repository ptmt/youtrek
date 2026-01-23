import SwiftUI

struct IssueDetailWindow: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        if let issue = container.appState.selectedIssue {
            IssueDetailView(
                issue: issue,
                detail: container.appState.issueDetail(for: issue),
                isLoadingDetail: container.appState.isIssueDetailLoading(issue.id)
            )
            .task {
                await container.loadIssueDetail(for: issue)
            }
        } else {
            ContentUnavailableView(
                "No issue selected",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Select an issue to open its dedicated window.")
            )
            .frame(minWidth: 480, minHeight: 400)
        }
    }
}

struct NewIssueWindow: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var viewModel = NewIssueViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("Basics") {
                    TextField("Title", text: draftTitleBinding)
                    projectRow
                    TextField("Description", text: draftDescriptionBinding, axis: .vertical)
                        .lineLimit(4...8)
                }

                Section("Fields") {
                    if viewModel.isLoadingFields {
                        ProgressView("Loading fields...")
                    } else if viewModel.fields.isEmpty {
                        if viewModel.selectedProject == nil {
                            ContentUnavailableView(
                                "Select a project",
                                systemImage: "folder",
                                description: Text("Choose a project to load custom fields.")
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView(
                                "No custom fields",
                                systemImage: "slider.horizontal.3",
                                description: Text("This project has no configurable fields.")
                            )
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        ForEach(viewModel.fields) { field in
                            IssueFieldRow(
                                field: field,
                                value: Binding(
                                    get: { container.issueComposer.value(for: field) },
                                    set: { container.issueComposer.setValue($0, for: field) }
                                ),
                                onPrefetchPeople: { viewModel.prefetchPeopleIfNeeded() },
                                onSearchPeople: { query in
                                    await viewModel.searchPeople(query: query, fieldID: field.id)
                                }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            viewModel.bind(container: container)
        }
    }

    private var footer: some View {
        let missingFields = viewModel.missingRequiredFields(using: container.issueComposer)
        return HStack(alignment: .center, spacing: 12) {
            if !missingFields.isEmpty {
                Text("Missing required fields: \(missingFields.map(\.displayName).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") {
                dismissWindow(id: SceneID.newIssue.rawValue)
            }
            Button("Create") {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(submitDisabled(missingFields: missingFields))
        }
    }

    private func submitDisabled(missingFields: [IssueField]) -> Bool {
        viewModel.isLoadingFields || !container.issueComposer.canSubmit || !missingFields.isEmpty
    }

    @ViewBuilder
    private var projectRow: some View {
        if viewModel.isLoadingProjects {
            LabeledContent("Project") {
                ProgressView()
            }
        } else if viewModel.projects.isEmpty {
            TextField("Project ID", text: draftProjectBinding)
        } else {
            LabeledContent("Project") {
                HStack(spacing: 8) {
                    Picker("Project", selection: projectSelectionBinding) {
                        Text("Select a project").tag(IssueProject?.none)
                        ForEach(viewModel.projects) { project in
                            Text(project.displayName).tag(Optional(project))
                        }
                    }
                    .labelsHidden()
                    Button {
                        Task { await viewModel.reloadProjects() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh projects")
                }
            }
        }
    }

    private var projectSelectionBinding: Binding<IssueProject?> {
        Binding(
            get: { viewModel.selectedProject },
            set: { viewModel.selectProject($0, composer: container.issueComposer) }
        )
    }

    private var draftTitleBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftTitle },
            set: { container.issueComposer.draftTitle = $0 }
        )
    }

    private var draftDescriptionBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftDescription },
            set: { container.issueComposer.draftDescription = $0 }
        )
    }

    private var draftProjectBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftProjectID },
            set: {
                container.issueComposer.draftProjectID = $0
                viewModel.clearSelectionIfNeeded(for: $0)
            }
        )
    }

    private func submit() {
        Task { @MainActor in
            container.submitIssueDraft()
            dismissWindow(id: SceneID.newIssue.rawValue)
        }
    }
}

@MainActor
final class NewIssueViewModel: ObservableObject {
    @Published private(set) var projects: [IssueProject] = []
    @Published private(set) var fields: [IssueField] = []
    @Published private(set) var isLoadingProjects: Bool = false
    @Published private(set) var isLoadingFields: Bool = false
    @Published var selectedProject: IssueProject?

    private weak var container: AppContainer?
    private var didBind = false
    private var loadFieldsTask: Task<Void, Never>?
    private var prefetchedPeopleProjects: Set<String> = []
    private var peopleCache: [String: [IssueFieldOption]] = [:]

    func bind(container: AppContainer) {
        guard !didBind else { return }
        didBind = true
        self.container = container
        Task { await loadProjects() }
    }

    func reloadProjects() async {
        await loadProjects()
    }

    func selectProject(_ project: IssueProject?, composer: IssueComposer) {
        selectedProject = project
        composer.draftProjectID = project?.id ?? ""
        fields = []
        loadFieldsTask?.cancel()
        guard let project else { return }
        loadFieldsTask = Task { await loadFields(for: project, composer: composer) }
    }

    func clearSelectionIfNeeded(for manualID: String) {
        let trimmed = manualID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            selectedProject = nil
            fields = []
            return
        }
        guard let container else { return }
        if let match = projects.first(where: { $0.matches(identifier: trimmed) }) {
            selectProject(match, composer: container.issueComposer)
        } else {
            selectedProject = nil
            fields = []
        }
    }

    func prefetchPeopleIfNeeded() {
        guard let projectID = selectedProject?.id else { return }
        guard !prefetchedPeopleProjects.contains(projectID) else { return }
        prefetchedPeopleProjects.insert(projectID)
        guard let container else { return }

        Task {
            let results = await container.searchPeople(query: nil, projectID: projectID)
            await MainActor.run {
                peopleCache[projectID] = results
                if !results.isEmpty {
                    updateUserFields(with: results, merge: true)
                }
            }
        }
    }

    func searchPeople(query: String, fieldID: String) async {
        guard let projectID = selectedProject?.id else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let cached = peopleCache[projectID], !cached.isEmpty {
            updateFieldOptions(fieldID: fieldID, options: cached)
            return
        }
        guard let container else { return }
        let results = await container.searchPeople(query: trimmed.isEmpty ? nil : trimmed, projectID: projectID)
        if trimmed.isEmpty {
            peopleCache[projectID] = results
        }
        updateFieldOptions(fieldID: fieldID, options: results)
    }

    func missingRequiredFields(using composer: IssueComposer) -> [IssueField] {
        fields.filter { $0.isRequired && composer.value(for: $0).isEmpty }
    }

    private func loadProjects() async {
        guard let container else { return }
        isLoadingProjects = true
        let loadedProjects = await container.loadProjects().filter { !$0.isArchived }
        projects = loadedProjects
        isLoadingProjects = false

        if selectedProject == nil {
            let draftID = container.issueComposer.draftProjectID
            if !draftID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedProject = loadedProjects.first(where: { $0.matches(identifier: draftID) })
            }
        }

        if let selectedProject {
            await loadFields(for: selectedProject, composer: container.issueComposer)
        }
    }

    private func loadFields(for project: IssueProject, composer: IssueComposer) async {
        guard let container else { return }
        isLoadingFields = true
        fields = []

        let baseFields = await container.loadFields(for: project.id)
        if Task.isCancelled { return }

        let optionsByField = await fetchOptions(for: baseFields, container: container)
        if Task.isCancelled { return }

        var resolved = baseFields
        for index in resolved.indices {
            if let options = optionsByField[resolved[index].id] {
                resolved[index].options = options
            }
        }

        resolved = resolved.sorted { left, right in
            if left.isRequired != right.isRequired {
                return left.isRequired && !right.isRequired
            }
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }

        fields = resolved
        composer.updateDraftFields(using: resolved)
        applyLegacyDefaults(from: composer, to: resolved)
        isLoadingFields = false

        if resolved.contains(where: { $0.kind == .user }) {
            prefetchPeopleIfNeeded()
        }
    }

    private func fetchOptions(for fields: [IssueField], container: AppContainer) async -> [String: [IssueFieldOption]] {
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
                results[fieldID] = sortedOptions(options)
            }
        }
        return results
    }

    private func sortedOptions(_ options: [IssueFieldOption]) -> [IssueFieldOption] {
        options.sorted { left, right in
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private func updateFieldOptions(fieldID: String, options: [IssueFieldOption]) {
        guard let index = fields.firstIndex(where: { $0.id == fieldID }) else { return }
        fields[index].options = options
    }

    private func updateUserFields(with options: [IssueFieldOption], merge: Bool) {
        for index in fields.indices {
            guard fields[index].kind == .user else { continue }
            if merge {
                var combined = fields[index].options
                for option in options where !combined.contains(where: { $0.stableID == option.stableID }) {
                    combined.append(option)
                }
                fields[index].options = sortedOptions(combined)
            } else {
                fields[index].options = sortedOptions(options)
            }
        }
    }

    private func applyLegacyDefaults(from composer: IssueComposer, to fields: [IssueField]) {
        for field in fields {
            guard composer.value(for: field).isEmpty else { continue }
            switch field.normalizedName {
            case "priority":
                if let option = field.options.first(where: { IssuePriority.from(displayName: $0.displayName) == composer.draftPriority }) {
                    composer.setValue(.option(option), for: field)
                }
            case "assignee":
                let trimmed = composer.draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let option = field.options.first(where: { $0.login?.caseInsensitiveCompare(trimmed) == .orderedSame || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        composer.setValue(.option(option), for: field)
                    } else {
                        composer.setValue(.string(trimmed), for: field)
                    }
                }
            case "subsystem", "module":
                let trimmed = composer.draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    composer.setValue(.string(trimmed), for: field)
                }
            default:
                break
            }
        }
    }
}

struct IssueFieldRow: View {
    let field: IssueField
    @Binding var value: IssueDraftFieldValue
    let onPrefetchPeople: () -> Void
    let onSearchPeople: @Sendable (String) async -> Void

    var body: some View {
        switch field.kind {
        case .boolean:
            Toggle(isOn: boolBinding) {
                Text(fieldLabel)
            }
        case .text:
            LabeledContent(fieldLabel) {
                TextField("", text: stringBinding, axis: .vertical)
                    .lineLimit(3...6)
            }
        case .enumeration, .state, .version, .build, .ownedField:
            optionField
        case .user:
            LabeledContent(fieldLabel) {
                PeoplePickerView(
                    options: field.options,
                    allowsMultiple: field.allowsMultiple,
                    value: $value,
                    onPrefetch: onPrefetchPeople,
                    onSearch: onSearchPeople
                )
            }
        case .integer:
            LabeledContent(fieldLabel) {
                TextField("", text: intBinding)
                    .monospacedDigit()
            }
        case .float:
            LabeledContent(fieldLabel) {
                TextField("", text: floatBinding)
                    .monospacedDigit()
            }
        case .date, .dateTime:
            LabeledContent(fieldLabel) {
                HStack(spacing: 8) {
                    DatePicker("", selection: dateBinding, displayedComponents: field.kind == .date ? .date : [.date, .hourAndMinute])
                        .labelsHidden()
                    if !value.isEmpty {
                        Button("Clear") {
                            value = .none
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        case .period:
            LabeledContent(fieldLabel) {
                HStack(spacing: 8) {
                    TextField("Minutes", text: intBinding)
                        .monospacedDigit()
                    Text("min")
                        .foregroundStyle(.secondary)
                }
            }
        case .string, .unknown:
            LabeledContent(fieldLabel) {
                TextField("", text: stringBinding)
            }
        }
    }

    private var fieldLabel: String {
        field.displayName + (field.isRequired ? " *" : "")
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

    @ViewBuilder
    private var optionField: some View {
        if field.options.isEmpty {
            LabeledContent(fieldLabel) {
                Text("No options available")
                    .foregroundStyle(.secondary)
            }
        } else if field.allowsMultiple {
            LabeledContent(fieldLabel) {
                OptionMultiSelectList(options: field.options, value: $value)
            }
        } else {
            LabeledContent(fieldLabel) {
                Picker("", selection: optionSelection) {
                    Text("None").tag(IssueFieldOption?.none)
                    ForEach(field.options, id: \.stableID) { option in
                        Text(option.displayName).tag(Optional(option))
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var optionSelection: Binding<IssueFieldOption?> {
        Binding(
            get: { value.optionValue },
            set: { newValue in
                value = newValue.map { .option($0) } ?? .none
            }
        )
    }
}

struct OptionMultiSelectList: View {
    let options: [IssueFieldOption]
    @Binding var value: IssueDraftFieldValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.stableID) { option in
                Toggle(isOn: toggleBinding(for: option)) {
                    Text(option.displayName)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func toggleBinding(for option: IssueFieldOption) -> Binding<Bool> {
        Binding(
            get: { isSelected(option) },
            set: { newValue in
                var selected = value.optionValues
                if newValue {
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

    private func isSelected(_ option: IssueFieldOption) -> Bool {
        value.optionValues.contains(where: { $0.stableID == option.stableID })
    }
}

struct PeoplePickerView: View {
    let options: [IssueFieldOption]
    let allowsMultiple: Bool
    @Binding var value: IssueDraftFieldValue
    let onPrefetch: () -> Void
    let onSearch: @Sendable (String) async -> Void

    @State private var query: String = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search people", text: $query)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }

            if options.isEmpty {
                Text("No people loaded")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(options, id: \.stableID) { option in
                            if allowsMultiple {
                                Toggle(isOn: toggleBinding(for: option)) {
                                    PersonRow(option: option, isSelected: isSelected(option))
                                }
                                .toggleStyle(.checkbox)
                            } else {
                                Button {
                                    value = .option(option)
                                } label: {
                                    PersonRow(option: option, isSelected: isSelected(option))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !value.isEmpty {
                Button("Clear selection") {
                    value = .none
                }
                .buttonStyle(.link)
            }
        }
        .onAppear {
            onPrefetch()
        }
    }

    private func scheduleSearch(_ newValue: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await onSearch(newValue)
        }
    }

    private func toggleBinding(for option: IssueFieldOption) -> Binding<Bool> {
        Binding(
            get: { isSelected(option) },
            set: { newValue in
                var selected = value.optionValues
                if newValue {
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

    private func isSelected(_ option: IssueFieldOption) -> Bool {
        value.optionValues.contains(where: { $0.stableID == option.stableID })
            || value.optionValue?.stableID == option.stableID
    }
}

struct PersonRow: View {
    let option: IssueFieldOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            UserAvatarView(person: Person(displayName: option.displayName, avatarURL: option.avatarURL), size: 20)
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
