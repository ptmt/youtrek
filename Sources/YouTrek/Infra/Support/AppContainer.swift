import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class AppContainer: ObservableObject {
    let appState: AppState
    let issueComposer: IssueComposer
    let commandPalette: CommandPaletteCoordinator
    let router: WindowRouter
    let syncCoordinator: SyncCoordinator
    let issueDraftStore: IssueDraftStore
    let authRepository: AuthRepository
    let networkMonitor: NetworkRequestMonitor

    private let configurationStore: AppConfigurationStore
    private let issueRepositorySwitcher: SwitchableIssueRepository
    private let authRepositorySwitcher: SwitchableAuthRepository
    private let savedQueryRepositorySwitcher: SwitchableSavedQueryRepository
    private let boardRepositorySwitcher: SwitchableIssueBoardRepository
    private let boardLocalStore: IssueBoardLocalStore
    private var lastLoadedIssueQuery: IssueQuery?
    @Published private(set) var supportsBrowserAuth: Bool = false
    @Published private(set) var requiresSetup: Bool = true

    private init(
        appState: AppState,
        issueComposer: IssueComposer,
        commandPalette: CommandPaletteCoordinator,
        router: WindowRouter,
        syncCoordinator: SyncCoordinator,
        issueDraftStore: IssueDraftStore,
        authRepository: AuthRepository,
        networkMonitor: NetworkRequestMonitor,
        configurationStore: AppConfigurationStore,
        issueRepositorySwitcher: SwitchableIssueRepository,
        authRepositorySwitcher: SwitchableAuthRepository,
        savedQueryRepositorySwitcher: SwitchableSavedQueryRepository,
        boardRepositorySwitcher: SwitchableIssueBoardRepository,
        boardLocalStore: IssueBoardLocalStore
    ) {
        self.appState = appState
        self.issueComposer = issueComposer
        self.commandPalette = commandPalette
        self.router = router
        self.syncCoordinator = syncCoordinator
        self.issueDraftStore = issueDraftStore
        self.authRepository = authRepository
        self.networkMonitor = networkMonitor
        self.configurationStore = configurationStore
        self.issueRepositorySwitcher = issueRepositorySwitcher
        self.authRepositorySwitcher = authRepositorySwitcher
        self.savedQueryRepositorySwitcher = savedQueryRepositorySwitcher
        self.boardRepositorySwitcher = boardRepositorySwitcher
        self.boardLocalStore = boardLocalStore
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer()
        let palette = CommandPaletteCoordinator(router: router)
        let configurationStore = AppConfigurationStore()
        let draftStore = IssueDraftStore()
        let networkMonitor = NetworkRequestMonitor()
        let initialRequiresSetup = AppContainer.requiresSetupOnLaunch(configurationStore: configurationStore)
        let authSwitcher = SwitchableAuthRepository(initial: PreviewAuthRepository())
        let issueSwitcher = SwitchableIssueRepository(initial: EmptyIssueRepository())
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: PreviewSavedQueryRepository())
        let boardSwitcher = SwitchableIssueBoardRepository(initial: PreviewIssueBoardRepository())
        let boardStore = IssueBoardLocalStore()
        let syncQueue = SyncOperationQueue { [weak state] pendingCount, label in
            await MainActor.run {
                state?.updateSyncActivity(isSyncing: pendingCount > 0, label: label)
            }
        }
        let sync = SyncCoordinator(
            issueRepository: issueSwitcher,
            operationQueue: syncQueue,
            conflictHandler: { [weak state] conflict in
                await MainActor.run {
                    state?.presentConflict(conflict)
                }
            }
        )
        let container = AppContainer(
            appState: state,
            issueComposer: composer,
            commandPalette: palette,
            router: router,
            syncCoordinator: sync,
            issueDraftStore: draftStore,
            authRepository: authSwitcher,
            networkMonitor: networkMonitor,
            configurationStore: configurationStore,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher,
            savedQueryRepositorySwitcher: savedQuerySwitcher,
            boardRepositorySwitcher: boardSwitcher,
            boardLocalStore: boardStore
        )
        container.requiresSetup = initialRequiresSetup
        Task { await container.configureIfNeeded() }
        Task { await container.bootstrap() }
        return container
    }()

    static let preview: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer()
        let palette = CommandPaletteCoordinator(router: router)
        let authRepository = PreviewAuthRepository()
        let issueRepository = PreviewIssueRepository()
        let store = AppConfigurationStore()
        let draftStore = IssueDraftStore()
        let networkMonitor = NetworkRequestMonitor()
        let authSwitcher = SwitchableAuthRepository(initial: authRepository)
        let issueSwitcher = SwitchableIssueRepository(initial: issueRepository)
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: PreviewSavedQueryRepository())
        let boardSwitcher = SwitchableIssueBoardRepository(initial: PreviewIssueBoardRepository())
        let boardStore = IssueBoardLocalStore()
        let syncQueue = SyncOperationQueue { [weak state] pendingCount, label in
            await MainActor.run {
                state?.updateSyncActivity(isSyncing: pendingCount > 0, label: label)
            }
        }
        let sync = SyncCoordinator(
            issueRepository: issueSwitcher,
            operationQueue: syncQueue,
            conflictHandler: { [weak state] conflict in
                await MainActor.run {
                    state?.presentConflict(conflict)
                }
            }
        )
        return AppContainer(
            appState: state,
            issueComposer: composer,
            commandPalette: palette,
            router: router,
            syncCoordinator: sync,
            issueDraftStore: draftStore,
            authRepository: authSwitcher,
            networkMonitor: networkMonitor,
            configurationStore: store,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher,
            savedQueryRepositorySwitcher: savedQuerySwitcher,
            boardRepositorySwitcher: boardSwitcher,
            boardLocalStore: boardStore
        )
    }()

    func bootstrap() async {
        let cachedBoards = await boardLocalStore.loadBoards()
        let initialSections = buildSidebarSections(savedQueries: [], boards: cachedBoards)
        let initialPreferredSelectionID = storedSidebarSelectionID() ?? preferredSelectionID(from: [])

        appState.updateSidebar(sections: initialSections, preferredSelectionID: initialPreferredSelectionID)
        startBoardPrefetch(cachedBoards)
        if let selection = appState.selectedSidebarItem {
            await loadIssues(for: selection)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.syncCoordinator.flushPendingMutations()
        }

        Task { [weak self] in
            guard let self else { return }
            guard !AppDebugSettings.disableSyncing else { return }
            let delay = AppDebugSettings.syncStartDelay
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            await self.refreshSidebarData()
        }
    }

    func loadIssues(for selection: SidebarItem) async {
        let query = issueQuery(for: selection)
        guard query != lastLoadedIssueQuery else { return }
        lastLoadedIssueQuery = query
        appState.setIssuesLoading(true)

        let cachedIssues = await syncCoordinator.loadCachedIssues(for: query)
        if !cachedIssues.isEmpty {
            appState.replaceIssues(with: cachedIssues)
            appState.setIssuesLoading(false)
            await refreshIssueSeenUpdates(for: cachedIssues)
        }

        do {
            let issues = try await syncCoordinator.refreshIssues(using: query)
            appState.recordIssueSyncCompleted()
            appState.replaceIssues(with: issues)
            appState.setIssuesLoading(false)
            await refreshIssueSeenUpdates(for: issues)
        } catch {
            appState.replaceIssues(with: [])
            appState.setIssuesLoading(false)
        }
        if selection.isBoard, let boardID = selection.boardID {
            appState.recordBoardSync(boardID: boardID)
        }
    }

    func refreshBoardIssues(for item: SidebarItem) async {
        guard item.isBoard else { return }
        let isSelected = appState.selectedSidebarItem?.id == item.id
        if isSelected {
            appState.setIssuesLoading(true)
        }
        let query = issueQuery(for: item)
        do {
            let issues = try await syncCoordinator.refreshIssues(using: query)
            appState.recordIssueSyncCompleted()
            if isSelected {
                appState.replaceIssues(with: issues)
                appState.setIssuesLoading(false)
                await refreshIssueSeenUpdates(for: issues)
            }
        } catch {
            if isSelected {
                appState.replaceIssues(with: [])
                appState.setIssuesLoading(false)
            }
        }
        if let boardID = item.boardID {
            appState.recordBoardSync(boardID: boardID)
        }
    }

    func sprintFilter(for board: IssueBoard) -> BoardSprintFilter {
        appState.sprintFilter(for: board)
    }

    func updateSprintFilter(_ filter: BoardSprintFilter, for board: IssueBoard) async {
        let resolved = board.resolveSprintFilter(filter)
        appState.updateSprintFilter(resolved, for: board.id)
        if let selection = appState.selectedSidebarItem, selection.boardID == board.id {
            await loadIssues(for: selection)
        }
    }

    func boardWebURL(for item: SidebarItem) -> URL? {
        guard let boardID = item.boardID ?? item.board?.id else { return nil }
        guard let apiBase = configurationStore.loadBaseURL() else { return nil }
        var uiBase = apiBase
        if uiBase.lastPathComponent.lowercased() == "api" {
            uiBase.deleteLastPathComponent()
        }
        uiBase.appendPathComponent("agiles")
        uiBase.appendPathComponent(boardID)
        return uiBase
    }

    func openBoardInWeb(_ item: SidebarItem) {
        guard let url = boardWebURL(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func clearCacheAndRefetch() {
        Task { [weak self] in
            guard let self else { return }
            await syncCoordinator.clearCachedIssues()
            await boardLocalStore.clearCache()
            await MainActor.run {
                appState.replaceIssues(with: [])
                appState.resetIssueSeenUpdates()
                appState.selectedIssue = nil
                appState.setIssuesLoading(true)
                self.lastLoadedIssueQuery = nil
            }
            await refreshSidebarData()
            if let selection = appState.selectedSidebarItem {
                await loadIssues(for: selection)
            }
        }
    }

    func markIssueSeen(_ issue: IssueSummary) {
        appState.markIssueSeen(issue)
        Task { [weak self] in
            await self?.syncCoordinator.markIssueSeen(issue)
        }
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async {
        do {
            let updated = try await syncCoordinator.applyOptimisticUpdate(id: id, patch: patch)
            appState.updateIssue(updated)
        } catch {
            print("Failed to update issue locally: \(error.localizedDescription)")
        }
    }

    func beginNewIssue(withTitle title: String) {
        issueComposer.prepareNewIssue(title: title)
        router.openNewIssueWindow()

        Task { [weak self] in
            guard let self else { return }
            guard let defaults = await issueDraftStore.latestSubmittedDraft() else { return }
            await MainActor.run {
                self.issueComposer.applyDefaults(from: defaults)
            }
        }
    }

    func submitIssueDraft() {
        guard let draft = issueComposer.makeDraft() else { return }
        issueComposer.resetDraft()

        Task { [weak self] in
            guard let self else { return }
            let record = await issueDraftStore.saveDraft(draft)
            do {
                let created = try await syncCoordinator.enqueue(label: "Create issue") {
                    try await self.issueRepositorySwitcher.createIssue(draft: draft)
                }
                await issueDraftStore.markDraftSubmitted(id: record.id)
                await MainActor.run {
                    self.appState.updateIssue(created)
                }
            } catch {
                await issueDraftStore.markDraftFailed(id: record.id, errorDescription: error.localizedDescription)
            }
        }
    }

    func deleteSavedSearch(id: String) async {
        do {
            try await syncCoordinator.enqueue(label: "Delete saved search") {
                try await self.savedQueryRepositorySwitcher.deleteSavedQuery(id: id)
            }
        } catch {
            print("Failed to delete saved search: \(error.localizedDescription)")
            return
        }

        let savedQueries = (try? await syncCoordinator.enqueue(label: "Sync saved searches") {
            try await self.savedQueryRepositorySwitcher.fetchSavedQueries()
        }) ?? []
        let boards = await boardLocalStore.loadBoards()
        let sections = buildSidebarSections(savedQueries: savedQueries, boards: boards)
        let preferredSelectionID = preferredSelectionID(from: savedQueries)
        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)
    }

    func beginSignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await authRepository.signIn()
                await self.bootstrap()
            } catch {
                print("Sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    func completeManualSetup(baseURL: URL, token: String) async {
        // Ensure /api suffix for API calls
        let apiBaseURL: URL
        if baseURL.lastPathComponent.lowercased() == "api" {
            apiBaseURL = baseURL
        } else {
            apiBaseURL = baseURL.appendingPathComponent("api")
        }

        configurationStore.save(baseURL: apiBaseURL)
        let manualAuth = ManualTokenAuthRepository(configurationStore: configurationStore)
        do {
            try manualAuth.apply(token: token)
        } catch {
            print("Failed to save YouTrack token: \(error.localizedDescription)")
        }

        authRepositorySwitcher.replace(with: manualAuth)

        let tokenProvider = YouTrackAPITokenProvider {
            try await manualAuth.currentAccessToken()
        }
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let savedQueryRepository = YouTrackSavedQueryRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let boardRepository = YouTrackIssueBoardRepository(configuration: apiConfiguration, monitor: networkMonitor)
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)
        await boardRepositorySwitcher.replace(with: boardRepository)

        await MainActor.run {
            requiresSetup = false
        }
        await bootstrap()
    }

    func storedConfigurationDraft() -> (baseURL: URL?, token: String?) {
        (configurationStore.loadBaseURL(), configurationStore.loadToken())
    }

    func setBaseURL(_ url: URL) {
        configurationStore.save(baseURL: url)
    }

    func recordSidebarSelection(_ selection: SidebarItem) {
        configurationStore.saveLastSidebarSelectionID(selection.id)
    }

    var browserAuthAvailable: Bool {
        supportsBrowserAuth
    }

    private func configureIfNeeded() async {
        if let oauthConfiguration = try? YouTrackOAuthConfiguration.loadFromEnvironment() {
            await applyOAuth(configuration: oauthConfiguration)
            await bootstrap()
            return
        }

        if let baseURL = configurationStore.loadBaseURL(), let token = configurationStore.loadToken(), !token.isEmpty {
            await completeManualSetup(baseURL: baseURL, token: token)
        } else {
            await MainActor.run {
                requiresSetup = true
            }
        }
    }

    @MainActor
    private func applyOAuth(configuration: YouTrackOAuthConfiguration) async {
        let appAuthRepository = AppAuthRepository(configuration: configuration, keychain: KeychainStorage(service: "com.potomushto.youtrek.auth"))
        authRepositorySwitcher.replace(with: appAuthRepository)
        let tokenProvider = YouTrackAPITokenProvider { try await appAuthRepository.currentAccessToken() }
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: configuration.apiBaseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let savedQueryRepository = YouTrackSavedQueryRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let boardRepository = YouTrackIssueBoardRepository(configuration: apiConfiguration, monitor: networkMonitor)
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)
        await boardRepositorySwitcher.replace(with: boardRepository)
        supportsBrowserAuth = true
        requiresSetup = false
    }
}

private extension AppContainer {
    static func requiresSetupOnLaunch(configurationStore: AppConfigurationStore) -> Bool {
        if (try? YouTrackOAuthConfiguration.loadFromEnvironment()) != nil {
            return false
        }

        guard configurationStore.loadBaseURL() != nil,
              let token = configurationStore.loadToken(),
              !token.isEmpty else {
            return true
        }
        return false
    }
}

private extension AppContainer {
    func refreshSidebarData() async {
        async let savedQueriesResult: [SavedQuery] = {
            do {
                return try await syncCoordinator.enqueue(label: "Sync saved searches") {
                    try await self.savedQueryRepositorySwitcher.fetchSavedQueries()
                }
            } catch {
                return []
            }
        }()
        async let boardsResult: [IssueBoard] = loadBoardsForSidebar()

        let resolvedSavedQueries = await savedQueriesResult
        let resolvedBoards = await boardsResult

        let sections = buildSidebarSections(savedQueries: resolvedSavedQueries, boards: resolvedBoards)
        let preferredSelectionID = storedSidebarSelectionID() ?? preferredSelectionID(from: resolvedSavedQueries)
        let previousSelectionID = appState.selectedSidebarItem?.id

        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)

        if let selection = appState.selectedSidebarItem, selection.id != previousSelectionID {
            await loadIssues(for: selection)
        }

    }

    func buildSidebarSections(savedQueries: [SavedQuery], boards: [IssueBoard]) -> [SidebarSection] {
        let visibleSavedQueries = limitedSavedQueries(from: savedQueries)
        let page = IssueQuery.Page(size: 50, offset: 0)
        let savedInbox = visibleSavedQueries.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }

        var smartItems: [SidebarItem] = []
        if savedInbox == nil {
            smartItems.append(.inbox(page: page))
        }
        smartItems.append(.assignedToMe(page: page))
        smartItems.append(.createdByMe(page: page))

        let savedItems = visibleSavedQueries.map { SidebarItem.savedSearch($0, page: page) }
        let favoriteBoards = boards.filter(\.isFavorite)
        let boardItems = favoriteBoards.map { SidebarItem.board($0, page: page) }

        var sections: [SidebarSection] = []
        if !smartItems.isEmpty {
            sections.append(SidebarSection(id: "smart", title: "Smart Filters", items: smartItems))
        }
        let boardEmptyMessage = appState.hasCompletedBoardSync ? "No favorite boards" : nil
        sections.append(
            SidebarSection(
                id: "boards",
                title: "Agile Boards",
                items: boardItems,
                emptyMessage: boardEmptyMessage
            )
        )
        if !savedItems.isEmpty {
            sections.append(SidebarSection(id: "saved", title: "Saved Searches", items: savedItems))
        }
        return sections
    }

    func storedSidebarSelectionID() -> SidebarItem.ID? {
        configurationStore.loadLastSidebarSelectionID()
    }

    func preferredSelectionID(from savedQueries: [SavedQuery]) -> SidebarItem.ID? {
        let visibleSavedQueries = limitedSavedQueries(from: savedQueries)
        if let inbox = visibleSavedQueries.first(where: { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }) {
            return "saved:\(inbox.id)"
        }
        return "smart:inbox"
    }

    func limitedSavedQueries(from savedQueries: [SavedQuery]) -> [SavedQuery] {
        let limit = 7
        guard savedQueries.count > limit else { return savedQueries }
        return Array(savedQueries.prefix(limit))
    }

    func loadBoardsForSidebar() async -> [IssueBoard] {
        let cachedBoards = await boardLocalStore.loadBoards()
        do {
            let remoteBoards = try await syncCoordinator.enqueue(label: "Sync agile boards") {
                try await self.boardRepositorySwitcher.fetchBoards()
            }
            appState.recordBoardListSyncCompleted()
            await boardLocalStore.saveRemoteBoards(remoteBoards)
            let syncDate = Date()
            for board in remoteBoards {
                appState.recordBoardSync(boardID: board.id, at: syncDate)
            }
            startBoardPrefetch(remoteBoards)
            return await boardLocalStore.loadBoards()
        } catch {
            startBoardPrefetch(cachedBoards)
            return cachedBoards
        }
    }

    func startBoardPrefetch(_ boards: [IssueBoard]) {
        let page = IssueQuery.Page(size: 50, offset: 0)
        let queries = boards
            .filter(\.isFavorite)
            .map { boardIssueQuery(for: $0, page: page) }
        guard !queries.isEmpty else { return }
        let coordinator = syncCoordinator
        Task.detached(priority: .background) {
            for query in queries {
                _ = try? await coordinator.refreshIssues(using: query)
            }
        }
    }

    private func issueQuery(for selection: SidebarItem) -> IssueQuery {
        guard selection.isBoard else { return selection.query }
        let page = selection.query.page
        let board = selection.board ?? IssueBoard(
            id: selection.boardID ?? selection.id,
            name: selection.title,
            isFavorite: true,
            projectNames: []
        )
        return boardIssueQuery(for: board, page: page)
    }

    private func boardIssueQuery(for board: IssueBoard, page: IssueQuery.Page) -> IssueQuery {
        let filter = appState.sprintFilter(for: board)
        let resolved = board.resolveSprintFilter(filter)
        if resolved != filter {
            appState.updateSprintFilter(resolved, for: board.id)
        }
        let sprintName = board.sprintName(for: resolved)
        let rawQuery = IssueQuery.boardQuery(boardName: board.name, sprintName: sprintName)
        return IssueQuery(
            rawQuery: rawQuery,
            search: "",
            filters: [],
            sort: .updated(descending: true),
            page: page
        )
    }

    func refreshIssueSeenUpdates(for issues: [IssueSummary]) async {
        guard !issues.isEmpty else { return }
        let updates = await syncCoordinator.loadIssueSeenUpdates(for: issues.map(\.id))
        appState.updateIssueSeenUpdates(updates)
    }
}

@MainActor
final class WindowRouter: ObservableObject {
    @Published var pendingIssueToOpen: IssueSummary?
    @Published var shouldOpenNewIssueWindow: Bool = false

    func openIssueDetail(issue: IssueSummary) {
        pendingIssueToOpen = issue
    }

    func openNewIssueWindow() {
        shouldOpenNewIssueWindow = true
    }

    func consumeNewIssueWindowFlag() {
        shouldOpenNewIssueWindow = false
    }
}

@MainActor
final class IssueComposer: ObservableObject {
    @Published var draftTitle: String = ""
    @Published var draftDescription: String = ""
    @Published var draftProjectID: String = ""
    @Published var draftModule: String = ""
    @Published var draftAssigneeID: String = ""
    @Published var draftPriority: IssuePriority = .normal

    var canSubmit: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepareNewIssue(title: String) {
        draftTitle = title
        draftDescription = ""
        draftProjectID = ""
        draftModule = ""
        draftAssigneeID = ""
        draftPriority = .normal
    }

    func applyDefaults(from draft: IssueDraft) {
        if draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftProjectID = draft.projectID
        }
        if draftModule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftModule = draft.module ?? ""
        }
        if draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftAssigneeID = draft.assigneeID ?? ""
        }
        if draftPriority == .normal {
            draftPriority = draft.priority
        }
    }

    func makeDraft() -> IssueDraft? {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedProject.isEmpty else { return nil }

        let trimmedDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModule = draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssignee = draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)

        return IssueDraft(
            title: trimmedTitle,
            description: trimmedDescription,
            projectID: trimmedProject,
            module: trimmedModule.isEmpty ? nil : trimmedModule,
            priority: draftPriority,
            assigneeID: trimmedAssignee.isEmpty ? nil : trimmedAssignee
        )
    }

    func resetDraft() {
        draftTitle = ""
        draftDescription = ""
        draftProjectID = ""
        draftModule = ""
        draftAssigneeID = ""
        draftPriority = .normal
    }
}

@MainActor
final class CommandPaletteCoordinator {
    private let router: WindowRouter

    init(router: WindowRouter) {
        self.router = router
    }

    func open() {
        print("Command palette requested")
    }
}

@MainActor
private final class PreviewAuthRepository: AuthRepository {
    private(set) var currentAccount: Account?

    func signIn() async throws {
        currentAccount = Account(id: UUID(), displayName: "Preview User", avatarURL: nil)
    }

    func signOut() async throws {
        currentAccount = nil
    }

    func currentAccessToken() async throws -> String {
        throw AuthError.notSignedIn
    }
}

private struct PreviewIssueRepository: IssueRepository {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        AppStatePlaceholder.sampleIssues()
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }
}

private struct EmptyIssueRepository: IssueRepository {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        []
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }
}

private struct PreviewSavedQueryRepository: SavedQueryRepository {
    func fetchSavedQueries() async throws -> [SavedQuery] {
        [
            SavedQuery(id: "preview-1", name: "My Team's Bugs", query: "project: YT Type: Bug"),
            SavedQuery(id: "preview-2", name: "Blocked", query: "State: Blocked")
        ]
    }

    func deleteSavedQuery(id: String) async throws {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support deletions")
    }
}

private struct PreviewIssueBoardRepository: IssueBoardRepository {
    func fetchBoards() async throws -> [IssueBoard] {
        [
            IssueBoard(
                id: "preview-board-1",
                name: "Growth Sprint Board",
                isFavorite: true,
                projectNames: ["YT"],
                columnFieldName: "State",
                columns: [
                    IssueBoardColumn(id: "preview-col-1", title: "Open", valueNames: ["Open"]),
                    IssueBoardColumn(id: "preview-col-2", title: "In Progress", valueNames: ["In Progress"]),
                    IssueBoardColumn(id: "preview-col-3", title: "Review", valueNames: ["In Review"]),
                    IssueBoardColumn(id: "preview-col-4", title: "Done", valueNames: ["Done"])
                ],
                swimlaneSettings: IssueBoardSwimlaneSettings(kind: .attribute, isEnabled: true, fieldName: "Assignee", values: []),
                orphansAtTheTop: true,
                hideOrphansSwimlane: false
            ),
            IssueBoard(
                id: "preview-board-2",
                name: "Bug Triage",
                isFavorite: true,
                projectNames: ["YT"],
                columnFieldName: "State",
                columns: [
                    IssueBoardColumn(id: "preview-col-5", title: "Open", valueNames: ["Open"]),
                    IssueBoardColumn(id: "preview-col-6", title: "Investigating", valueNames: ["Investigating"]),
                    IssueBoardColumn(id: "preview-col-7", title: "Fixed", valueNames: ["Fixed"])
                ],
                swimlaneSettings: IssueBoardSwimlaneSettings(kind: .none, isEnabled: false, fieldName: nil, values: []),
                orphansAtTheTop: false,
                hideOrphansSwimlane: true
            ),
            IssueBoard(
                id: "preview-board-3",
                name: "Internal Roadmap",
                isFavorite: false,
                projectNames: ["YT"],
                columnFieldName: nil,
                columns: [],
                swimlaneSettings: .disabled,
                orphansAtTheTop: false,
                hideOrphansSwimlane: false
            )
        ]
    }
}
