import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    @StateObject private var aiAssistViewModel = IssueAIAssistViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("Basics") {
                    TextField("Title", text: draftTitleBinding)
                    projectRow
                    TextField("Description", text: draftDescriptionBinding, axis: .vertical)
                        .lineLimit(4...8)
                }

                Section("AI Assist") {
                    IssueAIAssistSection(
                        viewModel: aiAssistViewModel,
                        composer: container.issueComposer,
                        project: viewModel.selectedProject,
                        availableFields: viewModel.fields
                    )
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
            aiAssistViewModel.refreshAvailability()
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

struct DraftIssueDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let record: IssueDraftRecord
    @StateObject private var viewModel = NewIssueViewModel()
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("Basics") {
                    TextField("Title", text: draftTitleBinding)
                        .font(.system(size: 24, weight: .bold))
                        .focused($isTitleFocused)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            viewModel.bind(container: container)
        }
        .task(id: record.id) {
            container.selectDraft(recordID: record.id)
            viewModel.clearSelectionIfNeeded(for: container.issueComposer.draftProjectID)
            isTitleFocused = true
        }
        .onChange(of: container.issueComposer.draftTitle) { _, _ in
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftDescription) { _, _ in
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftProjectID) { _, newValue in
            viewModel.clearSelectionIfNeeded(for: newValue)
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftModule) { _, _ in
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftAssigneeID) { _, _ in
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftPriority) { _, _ in
            persistDraft()
        }
        .onChange(of: container.issueComposer.draftFields) { _, _ in
            persistDraft()
        }
    }

    private var footer: some View {
        let missingFields = viewModel.missingRequiredFields(using: container.issueComposer)
        return HStack(alignment: .center, spacing: 12) {
            if !missingFields.isEmpty {
                Text("Missing required fields: \(missingFields.map(\.displayName).joined(separator: \", \"))")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Discard Draft", role: .destructive) {
                container.discardDraft(recordID: record.id)
            }
            Button("Create") {
                container.submitDraft(recordID: record.id)
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
            set: { container.issueComposer.draftProjectID = $0 }
        )
    }

    private func persistDraft() {
        let snapshot = container.issueComposer.draftSnapshot()
        container.updateDraft(recordID: record.id, draft: snapshot)
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

struct IssueAIAssistSection: View {
    @ObservedObject var viewModel: IssueAIAssistViewModel
    @ObservedObject var composer: IssueComposer
    let project: IssueProject?
    let availableFields: [IssueField]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate a draft from short notes. Review and apply the suggestions you want.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Draft notes or requirements", text: $viewModel.promptText, axis: .vertical)
                .lineLimit(3...6)

            HStack(spacing: 12) {
                Button("Generate") {
                    viewModel.generate(context: context)
                }
                .disabled(!viewModel.canGenerate(context: context))

                if viewModel.isGenerating {
                    ProgressView()
                    Button("Stop") {
                        viewModel.cancelGeneration()
                    }
                    .buttonStyle(.link)
                } else if !viewModel.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear") {
                        viewModel.promptText = ""
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                if let suggestion = viewModel.suggestion {
                    Button("Apply All") {
                        viewModel.applySuggestion(suggestion, to: composer)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            availabilityRow

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let suggestion = viewModel.suggestion {
                suggestionsView(for: suggestion)
            }
        }
    }

    @ViewBuilder
    private var availabilityRow: some View {
        switch viewModel.availability {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking Apple Intelligence availability…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .available:
            EmptyView()
        case .unavailable(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func suggestionsView(for suggestion: IssueAISuggestion) -> some View {
        GroupBox("Suggestions") {
            VStack(alignment: .leading, spacing: 12) {
                if let title = suggestion.trimmedTitle {
                    suggestionRow(label: "Title", value: title) {
                        composer.draftTitle = title
                    }
                }

                if let summary = suggestion.trimmedSummary {
                    suggestionRow(label: "Summary", value: summary) {
                        if let composed = suggestion.composedDescription(base: summary) {
                            composer.draftDescription = composed
                        }
                    }
                }

                if let description = suggestion.trimmedDescription {
                    suggestionRow(label: "Description", value: description) {
                        if let composed = suggestion.composedDescription(base: description) {
                            composer.draftDescription = composed
                        }
                    }
                }

                if let criteriaText = suggestion.formattedAcceptanceCriteria() {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Acceptance Criteria")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(criteriaText)
                            .font(.callout)
                            .textSelection(.enabled)
                        Button("Append to description") {
                            if let composed = suggestion.composedDescription(base: composer.draftDescription) {
                                composer.draftDescription = composed
                            }
                        }
                        .buttonStyle(.link)
                    }
                }

                if let priority = suggestion.trimmedPriority {
                    suggestionRow(label: "Priority", value: priority) {
                        if let resolved = IssuePriority.from(displayName: priority) {
                            composer.draftPriority = resolved
                        }
                    }
                }

                if let assignee = suggestion.trimmedAssignee {
                    suggestionRow(label: "Assignee", value: assignee) {
                        composer.draftAssigneeID = assignee
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func suggestionRow(label: String, value: String, onApply: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Use") {
                onApply()
            }
            .buttonStyle(.bordered)
        }
    }

    private var context: IssueAIAssistContext {
        IssueAIAssistContext(
            projectName: project?.displayName,
            projectID: project?.id,
            currentTitle: composer.draftTitle,
            currentDescription: composer.draftDescription,
            availableFields: availableFields.map(\.displayName),
            availablePriorities: IssuePriority.fallbackCases.map(\.displayName)
        )
    }
}

struct IssueAIAssistContext: Sendable, Equatable {
    let projectName: String?
    let projectID: String?
    let currentTitle: String
    let currentDescription: String
    let availableFields: [String]
    let availablePriorities: [String]
}

enum IssueAIAssistAvailability: Equatable {
    case checking
    case available
    case unavailable(String)
}

struct IssueAISuggestion: Equatable, Sendable {
    var title: String?
    var summary: String?
    var description: String?
    var acceptanceCriteria: [String]?
    var priority: String?
    var assignee: String?

    var trimmedTitle: String? { title?.trimmedNonEmpty }
    var trimmedSummary: String? { summary?.trimmedNonEmpty }
    var trimmedDescription: String? { description?.trimmedNonEmpty }
    var trimmedPriority: String? { priority?.trimmedNonEmpty }
    var trimmedAssignee: String? { assignee?.trimmedNonEmpty }

    var normalizedAcceptanceCriteria: [String] {
        let trimmed = (acceptanceCriteria ?? []).compactMap { $0.trimmedNonEmpty }
        var unique: [String] = []
        for item in trimmed where !unique.contains(item) {
            unique.append(item)
        }
        return unique
    }

    func formattedAcceptanceCriteria() -> String? {
        let items = normalizedAcceptanceCriteria
        guard !items.isEmpty else { return nil }
        let bullets = items.map { "• \($0)" }.joined(separator: "\n")
        return bullets
    }

    func composedDescription(base: String?) -> String? {
        let baseText = base?.trimmedNonEmpty
        guard let criteria = formattedAcceptanceCriteria() else { return baseText }
        if let baseText {
            return "\(baseText)\n\nAcceptance Criteria:\n\(criteria)"
        }
        return "Acceptance Criteria:\n\(criteria)"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct IssueAISuggestionSchema: Sendable {
    var title: String?
    var summary: String?
    var description: String?
    var acceptanceCriteria: [String]?
    var priority: String?
    var assignee: String?
}
#endif

@MainActor
final class IssueAIAssistViewModel: ObservableObject {
    @Published var promptText: String = ""
    @Published private(set) var availability: IssueAIAssistAvailability = .checking
    @Published private(set) var isGenerating: Bool = false
    @Published private(set) var suggestion: IssueAISuggestion?
    @Published private(set) var errorMessage: String?

    private var generationTask: Task<Void, Never>?

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                self.availability = .available
            case .unavailable(let reason):
                self.availability = .unavailable(Self.unavailableMessage(for: reason))
            }
        } else {
            availability = .unavailable("AI Assist requires macOS 26 or later.")
        }
        #else
        availability = .unavailable("AI Assist is unavailable on this build.")
        #endif
    }

    func canGenerate(context: IssueAIAssistContext) -> Bool {
        guard availability == .available, !isGenerating else { return false }
        let draft = promptText.trimmedNonEmpty
        let existingTitle = context.currentTitle.trimmedNonEmpty
        let existingDescription = context.currentDescription.trimmedNonEmpty
        return draft != nil || existingTitle != nil || existingDescription != nil
    }

    func generate(context: IssueAIAssistContext) {
        guard canGenerate(context: context) else { return }
        errorMessage = nil
        suggestion = nil
        isGenerating = true

        let prompt = buildPrompt(context: context)
        generationTask?.cancel()
        generationTask = Task.detached(priority: .userInitiated) { [prompt] in
            do {
                let suggestion = try await IssueAIAssistViewModel.generateSuggestion(prompt: prompt)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.suggestion = suggestion
                    self.isGenerating = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGenerating = false
                }
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func applySuggestion(_ suggestion: IssueAISuggestion, to composer: IssueComposer) {
        if let title = suggestion.trimmedTitle {
            composer.draftTitle = title
        }

        if let description = suggestion.composedDescription(base: suggestion.trimmedDescription ?? suggestion.trimmedSummary) {
            composer.draftDescription = description
        }

        if let priority = suggestion.trimmedPriority, let resolved = IssuePriority.from(displayName: priority) {
            composer.draftPriority = resolved
        }

        if let assignee = suggestion.trimmedAssignee {
            composer.draftAssigneeID = assignee
        }
    }

    private func buildPrompt(context: IssueAIAssistContext) -> String {
        var lines: [String] = []
        lines.append("Draft notes:")
        lines.append(promptText.trimmedNonEmpty ?? "N/A")

        if let projectName = context.projectName?.trimmedNonEmpty {
            lines.append("Project: \(projectName)")
        }
        if let title = context.currentTitle.trimmedNonEmpty {
            lines.append("Current title: \(title)")
        }
        if let description = context.currentDescription.trimmedNonEmpty {
            lines.append("Current description: \(description)")
        }

        let priorities = context.availablePriorities.map { $0.trimmedNonEmpty ?? "" }.filter { !$0.isEmpty }
        if !priorities.isEmpty {
            lines.append("Allowed priorities: \(priorities.joined(separator: ", "))")
        }

        let fields = context.availableFields.map { $0.trimmedNonEmpty ?? "" }.filter { !$0.isEmpty }
        if !fields.isEmpty {
            let limited = Array(fields.prefix(12))
            lines.append("Known fields: \(limited.joined(separator: ", "))")
        }

        lines.append("Return only information supported by the schema; omit fields you cannot infer.")
        return lines.joined(separator: "\n")
    }

    private static func generateSuggestion(prompt: String) async throws -> IssueAISuggestion {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw IssueAIAssistError(message: unavailableMessage(for: reason))
            }

            let session = LanguageModelSession(model: model) {
                "You help draft YouTrack issues. Be concise, factual, and avoid inventing details."
                "Use the provided schema and omit fields you cannot infer."
            }
            let promptValue = Prompt(prompt)
            let response = try await session.respond(to: promptValue, generating: IssueAISuggestionSchema.self, includeSchemaInPrompt: true)
            return IssueAISuggestion(
                title: response.content.title,
                summary: response.content.summary,
                description: response.content.description,
                acceptanceCriteria: response.content.acceptanceCriteria,
                priority: response.content.priority,
                assignee: response.content.assignee
            )
        }
        #endif
        throw IssueAIAssistError(message: "AI Assist is unavailable on this system.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func unavailableMessage(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is disabled. Enable it in System Settings to use AI Assist."
        case .modelNotReady:
            return "Apple Intelligence is still preparing the model. Try again shortly."
        @unknown default:
            return "Apple Intelligence is unavailable right now."
        }
    }
    #else
    private static func unavailableMessage(for _: Never) -> String {
        "AI Assist is unavailable on this build."
    }
    #endif
}

struct IssueAIAssistError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
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

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
