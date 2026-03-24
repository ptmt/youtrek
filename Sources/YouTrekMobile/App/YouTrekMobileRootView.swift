import SwiftUI

private enum MobileWorkspaceTab: Hashable {
    case issues
    case boards
    case todo
    case newIssue
}

struct YouTrekMobileRootView: View {
    @StateObject private var bootstrap = YouTrekMobileBootstrap()
    @State private var selectedTab: MobileWorkspaceTab = .issues

    var body: some View {
        Group {
            if bootstrap.isSignedIn {
                TabView(selection: $selectedTab) {
                    MobileIssuesTabView(bootstrap: bootstrap)
                        .tabItem {
                            Label("Issues", systemImage: "tray.fill")
                        }
                        .tag(MobileWorkspaceTab.issues)

                    MobileBoardsTabView(bootstrap: bootstrap)
                        .tabItem {
                            Label("Boards", systemImage: "rectangle.3.group.fill")
                        }
                        .tag(MobileWorkspaceTab.boards)

                    MobileTodoTabView(bootstrap: bootstrap)
                        .tabItem {
                            Label("Todo", systemImage: "checklist.unchecked")
                        }
                        .tag(MobileWorkspaceTab.todo)

                    MobileNewIssueTabView(bootstrap: bootstrap)
                        .tabItem {
                            Label("New Issue", systemImage: "square.and.pencil")
                        }
                        .tag(MobileWorkspaceTab.newIssue)
                }
            } else {
                YouTrekMobileSetupView(bootstrap: bootstrap)
            }
        }
        .task {
            await bootstrap.bootstrap()
        }
        .onOpenURL { url in
            bootstrap.handleOpenURL(url)
        }
        .onChange(of: bootstrap.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                selectedTab = .issues
            }
        }
    }
}

private struct MobileIssuesTabView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap

    var body: some View {
        NavigationStack {
            Group {
                if bootstrap.issues.isEmpty {
                    ContentUnavailableView(
                        bootstrap.isSyncing || bootstrap.isLoadingCache ? "Loading Issues" : "No Issues",
                        systemImage: bootstrap.isSyncing || bootstrap.isLoadingCache ? "arrow.triangle.2.circlepath" : "tray",
                        description: Text(bootstrap.isSyncing || bootstrap.isLoadingCache ? "Pull to refresh or wait for the initial sync to finish." : "Your default unresolved issue list is empty.")
                    )
                } else {
                    List(bootstrap.issues) { issue in
                        MobileIssueRow(issue: issue)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Issues")
            .toolbar {
                MobileWorkspaceToolbar(bootstrap: bootstrap, refreshAction: { await bootstrap.refresh() })
            }
            .refreshable {
                await bootstrap.refresh()
            }
            .safeAreaInset(edge: .top) {
                MobileWorkspaceStatusView(bootstrap: bootstrap)
            }
        }
    }
}

private struct MobileBoardsTabView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap

    var body: some View {
        NavigationStack {
            Group {
                if bootstrap.boards.isEmpty {
                    ContentUnavailableView(
                        "No Favorite Boards",
                        systemImage: "rectangle.3.group",
                        description: Text("Favorite boards from the sidebar show up here after sync.")
                    )
                } else {
                    List(bootstrap.boards) { board in
                        NavigationLink(value: board) {
                            MobileBoardRow(board: board)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Boards")
            .navigationDestination(for: IssueBoard.self) { board in
                MobileBoardIssuesView(bootstrap: bootstrap, board: board)
            }
            .toolbar {
                MobileWorkspaceToolbar(bootstrap: bootstrap, refreshAction: { await bootstrap.refresh() })
            }
            .refreshable {
                await bootstrap.refresh()
            }
            .safeAreaInset(edge: .top) {
                MobileWorkspaceStatusView(bootstrap: bootstrap)
            }
        }
    }
}

private struct MobileBoardIssuesView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap
    let board: IssueBoard

    @State private var issues: [IssueSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if issues.isEmpty {
                ContentUnavailableView(
                    isLoading ? "Loading Board" : "No Issues",
                    systemImage: isLoading ? "arrow.triangle.2.circlepath" : "rectangle.3.group",
                    description: Text(isLoading ? "Fetching issues for this board." : "This board does not currently expose any issues in the default sprint scope.")
                )
            } else {
                List(issues) { issue in
                    MobileIssueRow(issue: issue)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                MobileInlineMessage(text: errorMessage, tone: .error)
            }
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            issues = try await bootstrap.fetchBoardIssues(for: board)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MobileTodoTabView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap
    @State private var path: [MobileTodoListDocument] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if bootstrap.todoLists.isEmpty {
                    ContentUnavailableView(
                        "No Todo Lists",
                        systemImage: "checklist",
                        description: Text("Create a todo list to mirror the desktop sidebar section.")
                    )
                } else {
                    List(bootstrap.todoLists) { document in
                        NavigationLink(value: document) {
                            MobileTodoRow(document: document)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Todo")
            .navigationDestination(for: MobileTodoListDocument.self) { document in
                MobileTodoEditorView(bootstrap: bootstrap, document: document)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await createTodoList()
                        }
                    } label: {
                        Label("New Todo", systemImage: "plus")
                    }
                }
                MobileWorkspaceToolbar(
                    bootstrap: bootstrap,
                    allowsRefresh: false,
                    refreshAction: { await bootstrap.reloadTodoLists() }
                )
            }
            .refreshable {
                await bootstrap.reloadTodoLists()
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage {
                    MobileInlineMessage(text: errorMessage, tone: .error)
                }
            }
        }
    }

    private func createTodoList() async {
        do {
            let created = try await bootstrap.createTodoList()
            path.append(created)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MobileTodoEditorView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap
    let document: MobileTodoListDocument

    @State private var markdown: String = ""
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoaded {
                TextEditor(text: $markdown)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 4)
            } else {
                ProgressView("Loading todo list...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                }
            }
        }
        .task {
            markdown = await bootstrap.loadTodoMarkdown(id: document.id)
            isLoaded = true
        }
        .task(id: markdown) {
            guard isLoaded else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                isSaving = true
                defer { isSaving = false }
                try await bootstrap.saveTodoMarkdown(id: document.id, markdown: markdown)
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                MobileInlineMessage(text: errorMessage, tone: .error)
            }
        }
    }
}

private struct MobileNewIssueTabView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var selectedProjectIdentifier: String = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let successMessage {
                    Section {
                        MobileInlineMessage(text: successMessage, tone: .success)
                    }
                    .listRowBackground(Color.clear)
                }

                if let errorMessage {
                    Section {
                        MobileInlineMessage(text: errorMessage, tone: .error)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Project") {
                    if bootstrap.isLoadingProjects {
                        ProgressView("Loading projects...")
                    } else if bootstrap.projects.isEmpty {
                        Text("No projects available for issue creation.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $selectedProjectIdentifier) {
                            ForEach(bootstrap.projects) { project in
                                Text(project.displayName)
                                    .tag(projectIdentifier(for: project))
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField("Issue title", text: $title, axis: .vertical)
                        .lineLimit(2...4)

                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(6...12)
                }

                Section {
                    Button {
                        Task {
                            await createIssue()
                        }
                    } label: {
                        if bootstrap.isSubmittingIssue {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Create Issue")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canCreateIssue)
                }
            }
            .navigationTitle("New Issue")
            .toolbar {
                MobileWorkspaceToolbar(bootstrap: bootstrap, refreshAction: { await bootstrap.refresh() })
            }
            .task {
                await loadProjects()
            }
            .safeAreaInset(edge: .top) {
                MobileWorkspaceStatusView(bootstrap: bootstrap)
            }
        }
    }

    private var canCreateIssue: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedProjectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bootstrap.isSubmittingIssue
    }

    private func loadProjects() async {
        do {
            try await bootstrap.loadProjectsIfNeeded()
            if selectedProjectIdentifier.isEmpty, let first = bootstrap.projects.first {
                selectedProjectIdentifier = projectIdentifier(for: first)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createIssue() async {
        do {
            let issue = try await bootstrap.createIssue(
                title: title,
                description: description,
                projectIdentifier: selectedProjectIdentifier
            )
            title = ""
            description = ""
            successMessage = "Created \(issue.readableID)"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func projectIdentifier(for project: IssueProject) -> String {
        let shortName = project.shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shortName.isEmpty ? project.id : shortName
    }
}

private struct YouTrekMobileSetupView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap

    private enum FocusField: Hashable {
        case baseURL
        case token
    }

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    @State private var didPreload = false
    @FocusState private var focusedField: FocusField?

    private var primaryTextColor: Color { .white }
    private var secondaryTextColor: Color { .white.opacity(0.72) }
    private var tertiaryTextColor: Color { .white.opacity(0.5) }
    private var accentColor: Color { Color(red: 0.56, green: 0.84, blue: 1.0).opacity(0.85) }
    private var inputFillColor: Color { .white.opacity(0.08) }
    private var inputStrokeColor: Color { .white.opacity(0.18) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MobileSetupBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YouTrek")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Set up the iOS workspace with the same direct token flow the desktop setup window uses.")
                            .font(.callout)
                            .foregroundStyle(secondaryTextColor)
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://youtrack.jetbrains.com", text: $baseURLString, prompt: Text("YouTrack base URL"))
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                            .tint(accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .modifier(
                                MobileSetupInputChrome(
                                    isFocused: focusedField == .baseURL,
                                    fill: inputFillColor,
                                    stroke: inputStrokeColor,
                                    focus: accentColor.opacity(0.9)
                                )
                            )
                            .focused($focusedField, equals: .baseURL)

                        ZStack(alignment: .topLeading) {
                            if token.isEmpty && focusedField != .token {
                                Text("Paste your YouTrack token")
                                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                                    .foregroundStyle(tertiaryTextColor)
                                    .padding(.leading, 5)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $token)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .foregroundStyle(primaryTextColor)
                                .tint(accentColor)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.top, 8)
                                .scrollContentBackground(.hidden)
                                .focused($focusedField, equals: .token)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .frame(minHeight: 96, maxHeight: 132)
                        .modifier(
                            MobileSetupInputChrome(
                                isFocused: focusedField == .token,
                                fill: inputFillColor,
                                stroke: inputStrokeColor,
                                focus: accentColor.opacity(0.9)
                            )
                        )

                        if let tokenPortalURL {
                            Link("How to create a personal token", destination: tokenPortalURL)
                                .font(.callout)
                                .foregroundStyle(accentColor)
                                .underline()
                        }
                    }

                    Button {
                        Task {
                            await bootstrap.signInWithToken(baseURLString: baseURLString, token: token)
                        }
                    } label: {
                        if bootstrap.isAuthenticating {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accentColor)
                    .disabled(!canSubmitToken || bootstrap.isAuthenticating)

                    if bootstrap.canSignIn {
                        Button("Sign In with Browser") {
                            Task {
                                await bootstrap.signIn()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(accentColor)
                        .disabled(bootstrap.isAuthenticating)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if bootstrap.isAuthenticating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Connecting to YouTrack...")
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(secondaryTextColor)
                        }

                        if let warningMessage = bootstrap.warningMessage {
                            MobileInlineMessage(text: warningMessage, tone: .warning)
                        }

                        if let errorMessage = bootstrap.errorMessage {
                            MobileInlineMessage(text: errorMessage, tone: .error)
                        }

                        if let configurationMessage = bootstrap.configurationMessage, !configurationMessage.isEmpty {
                            Text(configurationMessage)
                                .font(.footnote)
                                .foregroundStyle(secondaryTextColor)
                        }

                        if let networkStatusText = bootstrap.networkStatusText {
                            Text(networkStatusText)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            preloadIfNeeded()
        }
    }

    private var canSubmitToken: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tokenPortalURL: URL? {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiURL = URL(string: trimmedURL), apiURL.scheme?.hasPrefix("http") == true else {
            return nil
        }

        var uiBase = apiURL
        if uiBase.lastPathComponent.lowercased() == "api" {
            uiBase.deleteLastPathComponent()
        }
        if let host = uiBase.host?.lowercased(), host.hasSuffix(".youtrack.cloud") {
            if var components = URLComponents(url: uiBase, resolvingAgainstBaseURL: false) {
                components.path = ""
                if let cleaned = components.url {
                    uiBase = cleaned
                }
            }
        }

        uiBase.appendPathComponent("users")
        uiBase.appendPathComponent("me")
        var components = URLComponents(url: uiBase, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tab", value: "account-security")]
        return components?.url
    }

    private func preloadIfNeeded() {
        guard !didPreload else { return }
        didPreload = true
        let draft = bootstrap.setupDraft()
        baseURLString = draft.baseURL
        token = draft.token
    }
}

private struct MobileIssueRow: View {
    let issue: IssueSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(issue.readableID)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(issue.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(issue.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(issue.projectName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(issue.status.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(issue.status.isClosed ? .secondary : .primary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MobileBoardRow: View {
    let board: IssueBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(board.name)
                .font(.body.weight(.medium))

            if let sprintName = board.sprintName(for: board.defaultSprintFilter) {
                Text(sprintName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !board.projectNames.isEmpty {
                Text(board.projectNames.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Favorite board")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MobileTodoRow: View {
    let document: MobileTodoListDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.name)
                .font(.body.weight(.medium))
            Text(document.updatedAt, style: .relative)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MobileWorkspaceToolbar: ToolbarContent {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap
    let allowsRefresh: Bool
    let refreshAction: () async -> Void

    init(
        bootstrap: YouTrekMobileBootstrap,
        allowsRefresh: Bool = true,
        refreshAction: @escaping () async -> Void
    ) {
        self.bootstrap = bootstrap
        self.allowsRefresh = allowsRefresh
        self.refreshAction = refreshAction
    }

    var body: some ToolbarContent {
        if allowsRefresh {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refreshAction()
                    }
                } label: {
                    if bootstrap.isSyncing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(bootstrap.isSyncing)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let accountName = bootstrap.accountName {
                    Text(accountName)
                }
                if let subtitle = bootstrap.storedAccount?.subtitle {
                    Text(subtitle)
                }
                if let authModeLabel = bootstrap.authModeLabel {
                    Text("Auth: \(authModeLabel)")
                }
                Divider()
                Button("Sign Out") {
                    Task {
                        await bootstrap.signOut()
                    }
                }
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }
}

private struct MobileWorkspaceStatusView: View {
    @ObservedObject var bootstrap: YouTrekMobileBootstrap

    var body: some View {
        if let errorMessage = bootstrap.errorMessage {
            MobileInlineMessage(text: errorMessage, tone: .error)
                .padding(.top, 4)
        } else if let warningMessage = bootstrap.warningMessage {
            MobileInlineMessage(text: warningMessage, tone: .warning)
                .padding(.top, 4)
        } else if let lastRefreshAt = bootstrap.lastRefreshAt, !bootstrap.isSyncing {
            MobileInlineMessage(
                text: "Last refresh \(lastRefreshAt.formatted(date: .abbreviated, time: .shortened))",
                tone: .info
            )
            .padding(.top, 4)
        }
    }
}

private struct MobileInlineMessage: View {
    enum Tone {
        case info
        case success
        case warning
        case error

        var fill: Color {
            switch self {
            case .info:
                return Color.blue.opacity(0.12)
            case .success:
                return Color.green.opacity(0.14)
            case .warning:
                return Color.orange.opacity(0.16)
            case .error:
                return Color.red.opacity(0.16)
            }
        }

        var stroke: Color {
            switch self {
            case .info:
                return Color.blue.opacity(0.28)
            case .success:
                return Color.green.opacity(0.3)
            case .warning:
                return Color.orange.opacity(0.32)
            case .error:
                return Color.red.opacity(0.32)
            }
        }

        var foreground: Color {
            switch self {
            case .info:
                return .blue
            case .success:
                return .green
            case .warning:
                return .orange
            case .error:
                return .red
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tone.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tone.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tone.stroke, lineWidth: 1)
            )
            .padding(.horizontal, 16)
    }
}

private struct MobileSetupBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.12),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                    Color(red: 0.02, green: 0.02, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.58, green: 0.82, blue: 1.0).opacity(0.18),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 320
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 260
            )
            .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

private struct MobileSetupInputChrome: ViewModifier {
    let isFocused: Bool
    let fill: Color
    let stroke: Color
    let focus: Color

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? focus : stroke, lineWidth: 1)
            )
    }
}

#Preview {
    YouTrekMobileRootView()
}
