import Foundation
import Combine
import SwiftUI
import AppKit

struct TodoUncommittedChange: Identifiable, Equatable, Sendable {
    let id: UUID
    let summary: String
    let createdAt: Date
}

@MainActor
final class AppContainer: ObservableObject {
    let appState: AppState
    let issueComposer: IssueComposer
    let commandPalette: CommandPaletteCoordinator
    let router: WindowRouter
    var syncCoordinator: SyncCoordinator
    var issueDraftStore: IssueDraftStore
    let authRepository: AuthRepository
    let networkMonitor: NetworkRequestMonitor

    private let configurationStore: AppConfigurationStore
    private let issueRepositorySwitcher: SwitchableIssueRepository
    private let authRepositorySwitcher: SwitchableAuthRepository
    private let savedQueryRepositorySwitcher: SwitchableSavedQueryRepository
    private let boardRepositorySwitcher: SwitchableIssueBoardRepository
    private let projectRepositorySwitcher: SwitchableProjectRepository
    private let issueFieldRepositorySwitcher: SwitchableIssueFieldRepository
    private let peopleRepositorySwitcher: SwitchablePeopleRepository
    private var boardLocalStore: IssueBoardLocalStore
    private var savedQueryLocalStore: SavedQueryLocalStore
    private var todoListStore: TodoListMarkdownStore
    private var lastLoadedIssueQuery: IssueQuery?
    private var lastLoadedIssueSelection: SidebarItem?
    private var activeIssueLoadRequestID: UUID?
    private var cachedProjects: [IssueProject] = []
    private var cachedSavedQueries: [SavedQuery] = []
    private var cachedBoards: [IssueBoard] = []
    private var cachedTodoLists: [TodoListDocument] = []
    private var statusOptionsCache: [String: [IssueFieldOption]] = [:]
    private var priorityOptionsCache: [String: [IssueFieldOption]] = [:]
    private var assigneeOptionsCache: [String: [IssueFieldOption]] = [:]
    private var hasStartedBoardPrefetch = false
    private var appStateCancellable: AnyCancellable?
    private var isForwardingObjectWillChange = false
    private var draftSaveTask: Task<Void, Never>?
    private var todoUncommittedQueue: [TodoUncommittedQueueEntry] = []
    @Published private(set) var supportsBrowserAuth: Bool = false
    @Published private(set) var requiresSetup: Bool = true
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var todoUncommittedChanges: [TodoUncommittedChange] = []
    @Published private(set) var isCommittingTodoUncommittedChanges: Bool = false
    private var oauthConfiguration: YouTrackOAuthConfiguration?
    private var oauthRepository: AppAuthRepository?

    private struct TodoUncommittedQueueEntry {
        let change: TodoUncommittedChange
        let operation: TodoUncommittedOperation
    }

    private enum TodoUncommittedOperation {
        case setIssueClosed(readableID: String, isClosed: Bool)
        case createIssue(draft: IssueDraft)
    }

    private enum TodoUncommittedOperationError: LocalizedError {
        case issueNotFound(String)

        var errorDescription: String? {
            switch self {
            case .issueNotFound(let readableID):
                return "Issue \(readableID) not found"
            }
        }
    }

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
        projectRepositorySwitcher: SwitchableProjectRepository,
        issueFieldRepositorySwitcher: SwitchableIssueFieldRepository,
        peopleRepositorySwitcher: SwitchablePeopleRepository,
        boardLocalStore: IssueBoardLocalStore,
        savedQueryLocalStore: SavedQueryLocalStore,
        todoListStore: TodoListMarkdownStore
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
        self.projectRepositorySwitcher = projectRepositorySwitcher
        self.issueFieldRepositorySwitcher = issueFieldRepositorySwitcher
        self.peopleRepositorySwitcher = peopleRepositorySwitcher
        self.boardLocalStore = boardLocalStore
        self.savedQueryLocalStore = savedQueryLocalStore
        self.todoListStore = todoListStore
        // Forward AppState invalidations once per runloop turn instead of once
        // per mutation; sync bursts mutate several @Published properties in a
        // single turn and each forward re-invalidates every container observer.
        self.appStateCancellable = appState.objectWillChange.sink { [weak self] in
            guard let self, !self.isForwardingObjectWillChange else { return }
            self.isForwardingObjectWillChange = true
            Task { @MainActor in
                await Task.yield()
                self.isForwardingObjectWillChange = false
                self.objectWillChange.send()
            }
        }
        refreshAccountsFromCache()
        scheduleAccountKeychainReconcile()
    }

    static let live: AppContainer = {
        let liveInitStart = ProcessInfo.processInfo.systemUptime
        func logStartupPhase(_ message: String) {
            let elapsed = ProcessInfo.processInfo.systemUptime - liveInitStart
            let formatted = String(format: "%.2f", elapsed)
            LoggingService.general.info("Startup: \(message, privacy: .public) (+\(formatted, privacy: .public)s)")
        }

        logStartupPhase("AppContainer.live start")
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer()
        let palette = CommandPaletteCoordinator(router: router, appState: state)
        let configurationStore = AppConfigurationStore()
        logStartupPhase("Configuration store ready")
        let activeAccount = configurationStore.cachedActiveAccount()
        let activeAccountID = activeAccount?.id
        state.setCurrentUserProfile(
            displayName: activeAccount?.displayName,
            login: activeAccount?.login,
            id: activeAccount?.userID
        )
        let initialSyncState = (
            issues: activeAccount?.initialIssueSyncCompleted ?? false,
            boards: activeAccount?.initialBoardSyncCompleted ?? false,
            savedSearches: activeAccount?.initialSavedSearchSyncCompleted ?? false
        )
        state.prefillInitialSyncState(
            issues: initialSyncState.issues,
            boards: initialSyncState.boards,
            savedSearches: initialSyncState.savedSearches
        )
        let draftStore = IssueDraftStore(accountID: activeAccountID)
        let networkMonitor = NetworkRequestMonitor()
        let initialRequiresSetup = AppContainer.requiresSetupForInitialPresentation(activeAccount: activeAccount)
        logStartupPhase("Launch configuration snapshot loaded")
        let manualAuth = ManualTokenAuthRepository(configurationStore: configurationStore)
        let authSwitcher = SwitchableAuthRepository(initial: manualAuth)
        let issueSwitcher = SwitchableIssueRepository(initial: EmptyIssueRepository())
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: EmptySavedQueryRepository())
        let boardSwitcher = SwitchableIssueBoardRepository(initial: EmptyIssueBoardRepository())
        let projectSwitcher = SwitchableProjectRepository(initial: EmptyProjectRepository())
        let fieldSwitcher = SwitchableIssueFieldRepository(initial: EmptyIssueFieldRepository())
        let peopleSwitcher = SwitchablePeopleRepository(initial: EmptyPeopleRepository())
        let boardStore = IssueBoardLocalStore(accountID: activeAccountID)
        let savedQueryStore = SavedQueryLocalStore(accountID: activeAccountID)
        let todoListStore = TodoListMarkdownStore(accountID: activeAccountID)
        let issueLocalStore = IssueLocalStore(accountID: activeAccountID)
        logStartupPhase("Local stores ready")
        let syncQueue = SyncOperationQueue { [weak state] pendingCount, label in
            await MainActor.run {
                state?.updateSyncActivity(isSyncing: pendingCount > 0, label: label)
            }
        }
        let sync = SyncCoordinator(
            issueRepository: issueSwitcher,
            localStore: issueLocalStore,
            operationQueue: syncQueue,
            conflictHandler: { [weak state] conflict in
                await MainActor.run {
                    state?.presentConflict(conflict)
                }
            },
            mutationHandler: { [weak state] mutation, updatedIssue in
                let fallbackID = mutation.patch.issueReadableID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedID = updatedIssue?.readableID.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackID
                let message = resolvedID.isEmpty ? "Issue updated" : "Issue \(resolvedID) updated"
                await MainActor.run {
                    state?.showToast(message)
                    if !resolvedID.isEmpty {
                        state?.recordIssueDetailRefresh(readableID: resolvedID)
                    }
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
            projectRepositorySwitcher: projectSwitcher,
            issueFieldRepositorySwitcher: fieldSwitcher,
            peopleRepositorySwitcher: peopleSwitcher,
            boardLocalStore: boardStore,
            savedQueryLocalStore: savedQueryStore,
            todoListStore: todoListStore
        )
        container.requiresSetup = initialRequiresSetup
        Task { await container.configureIfNeeded() }
        logStartupPhase("AppContainer.live complete")
        return container
    }()

    static let preview: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer()
        let palette = CommandPaletteCoordinator(router: router, appState: state)
        let authRepository = PreviewAuthRepository()
        let issueRepository = PreviewIssueRepository()
        let store = AppConfigurationStore()
        let activeAccountID = store.cachedActiveAccount()?.id
        let draftStore = IssueDraftStore(accountID: activeAccountID)
        let networkMonitor = NetworkRequestMonitor()
        let authSwitcher = SwitchableAuthRepository(initial: authRepository)
        let issueSwitcher = SwitchableIssueRepository(initial: issueRepository)
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: PreviewSavedQueryRepository())
        let boardSwitcher = SwitchableIssueBoardRepository(initial: PreviewIssueBoardRepository())
        let projectSwitcher = SwitchableProjectRepository(initial: PreviewProjectRepository())
        let fieldSwitcher = SwitchableIssueFieldRepository(initial: PreviewIssueFieldRepository())
        let peopleSwitcher = SwitchablePeopleRepository(initial: PreviewPeopleRepository())
        let boardStore = IssueBoardLocalStore(accountID: activeAccountID)
        let savedQueryStore = SavedQueryLocalStore(accountID: activeAccountID)
        let todoListStore = TodoListMarkdownStore(accountID: activeAccountID)
        let issueLocalStore = IssueLocalStore(accountID: activeAccountID)
        let syncQueue = SyncOperationQueue { [weak state] pendingCount, label in
            await MainActor.run {
                state?.updateSyncActivity(isSyncing: pendingCount > 0, label: label)
            }
        }
        let sync = SyncCoordinator(
            issueRepository: issueSwitcher,
            localStore: issueLocalStore,
            operationQueue: syncQueue,
            conflictHandler: { [weak state] conflict in
                await MainActor.run {
                    state?.presentConflict(conflict)
                }
            },
            mutationHandler: { [weak state] mutation, updatedIssue in
                let fallbackID = mutation.patch.issueReadableID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedID = updatedIssue?.readableID.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackID
                let message = resolvedID.isEmpty ? "Issue updated" : "Issue \(resolvedID) updated"
                await MainActor.run {
                    state?.showToast(message)
                    if !resolvedID.isEmpty {
                        state?.recordIssueDetailRefresh(readableID: resolvedID)
                    }
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
            projectRepositorySwitcher: projectSwitcher,
            issueFieldRepositorySwitcher: fieldSwitcher,
            peopleRepositorySwitcher: peopleSwitcher,
            boardLocalStore: boardStore,
            savedQueryLocalStore: savedQueryStore,
            todoListStore: todoListStore
        )
    }()

    func bootstrap() async {
        LoggingService.sync.info("Bootstrap start.")
        let draftStore = issueDraftStore
        let boardStore = boardLocalStore
        let savedQueryStore = savedQueryLocalStore
        let todoStore = todoListStore
        async let draftsLoad = draftStore.loadDraftRecords(statuses: [.pending, .failed])
        async let boardsLoad = boardStore.loadBoards()
        async let savedQueriesLoad = savedQueryStore.loadSavedQueries()
        async let todoListsLoad = todoStore.listDocuments()
        let drafts = await draftsLoad
        appState.setDrafts(drafts)
        let cachedBoards = await boardsLoad
        let cachedSavedQueries = await savedQueriesLoad
        let cachedTodoLists = (try? await todoListsLoad) ?? []
        self.cachedBoards = cachedBoards
        self.cachedSavedQueries = cachedSavedQueries
        self.cachedTodoLists = cachedTodoLists
        LoggingService.sync.info("Bootstrap: cached boards loaded (\(cachedBoards.count, privacy: .public)).")
        LoggingService.sync.info("Bootstrap: cached saved searches loaded (\(cachedSavedQueries.count, privacy: .public)).")
        LoggingService.sync.info("Bootstrap: cached todo lists loaded (\(cachedTodoLists.count, privacy: .public)).")
        let initialSections = buildSidebarSections(savedQueries: cachedSavedQueries, boards: cachedBoards, todoLists: cachedTodoLists)
        let storedSelectionID = storedSidebarSelectionID()
        let initialPreferredSelectionID = storedSelectionID ?? preferredSelectionID(from: cachedSavedQueries)
        let shouldFallbackToFirstItem = storedSelectionID == nil

        appState.updateSidebar(
            sections: initialSections,
            preferredSelectionID: initialPreferredSelectionID,
            fallbackToFirstItem: shouldFallbackToFirstItem
        )
        if requiresSetup {
            LoggingService.sync.info("Bootstrap: setup required, skipping initial sync.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshCurrentUserProfileIfNeeded()
        }
        if let selection = appState.selectedSidebarItem {
            LoggingService.sync.info("Bootstrap: loading initial selection \(selection.id, privacy: .public).")
            await loadIssues(for: selection)
        }

        Task { [weak self] in
            guard let self else { return }
            LoggingService.sync.info("Bootstrap: flushing pending mutations.")
            await self.syncCoordinator.flushPendingMutations()
        }

        Task { [weak self] in
            guard let self else { return }
            guard !AppDebugSettings.disableSyncing else { return }
            let delay = AppDebugSettings.syncStartDelay
            if delay > 0 {
                LoggingService.sync.info("Bootstrap: delaying sidebar refresh by \(delay, privacy: .public)s.")
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            LoggingService.sync.info("Bootstrap: refreshing sidebar data.")
            await self.refreshSidebarData()
        }
    }

    func switchAccount(to id: UUID) async {
        guard configurationStore.activateAccount(id: id) else { return }
        refreshAccounts()
        configureStores(for: id)
        resetStateForAccountSwitch()
        let initialSyncState = configurationStore.loadInitialSyncState()
        appState.prefillInitialSyncState(
            issues: initialSyncState.issues,
            boards: initialSyncState.boards,
            savedSearches: initialSyncState.savedSearches
        )
        appState.setCurrentUserProfile(
            displayName: configurationStore.loadUserDisplayName(),
            login: configurationStore.loadUserLogin(),
            id: configurationStore.loadUserID()
        )
        await configureIfNeeded()
    }

    func startAddingAccount() {
        resetStateForAccountSwitch()
        requiresSetup = true
    }

    private func refreshAccounts() {
        let loaded = configurationStore.loadAccounts()
        let sorted = loaded.sorted(by: sortAccounts)
        accounts = sorted
        activeAccountID = configurationStore.activeAccountID()
    }

    private func refreshAccountsFromCache() {
        accounts = configurationStore.cachedAccounts().sorted(by: sortAccounts)
        activeAccountID = configurationStore.cachedActiveAccountID()
    }

    // loadAccounts() performs synchronous keychain reads, which are too slow
    // for the launch path; reconcile keychain-synced metadata off the main thread.
    private func scheduleAccountKeychainReconcile() {
        Task.detached(priority: .utility) { [weak self, configurationStore] in
            let loaded = configurationStore.loadAccounts()
            let activeID = configurationStore.activeAccountID()
            await self?.applyReconciledAccounts(loaded, activeID: activeID)
        }
    }

    private func applyReconciledAccounts(_ loaded: [StoredAccount], activeID: UUID?) {
        let sorted = loaded.sorted(by: sortAccounts)
        if accounts != sorted {
            accounts = sorted
        }
        if activeAccountID != activeID {
            activeAccountID = activeID
        }
    }

    private func sortAccounts(_ lhs: StoredAccount, _ rhs: StoredAccount) -> Bool {
        let lhsDate = lhs.lastUsedAt ?? lhs.createdAt
        let rhsDate = rhs.lastUsedAt ?? rhs.createdAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.displayTitle < rhs.displayTitle
    }

    private func configureStores(for accountID: UUID?) {
        issueDraftStore = IssueDraftStore(accountID: accountID)
        boardLocalStore = IssueBoardLocalStore(accountID: accountID)
        savedQueryLocalStore = SavedQueryLocalStore(accountID: accountID)
        todoListStore = TodoListMarkdownStore(accountID: accountID)
        let issueLocalStore = IssueLocalStore(accountID: accountID)
        let syncQueue = SyncOperationQueue { [weak appState] pendingCount, label in
            await MainActor.run {
                appState?.updateSyncActivity(isSyncing: pendingCount > 0, label: label)
            }
        }
        syncCoordinator = SyncCoordinator(
            issueRepository: issueRepositorySwitcher,
            localStore: issueLocalStore,
            operationQueue: syncQueue,
            conflictHandler: { [weak appState] conflict in
                await MainActor.run {
                    appState?.presentConflict(conflict)
                }
            }
        )
    }

    private func resetStateForAccountSwitch() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        issueComposer.resetDraft()
        appState.updateSyncActivity(isSyncing: false, label: nil)
        appState.updateSearch(query: "")
        appState.activeConflict = nil
        appState.activeNewIssueDialog = nil
        appState.activeCommandPalette = nil
        appState.replaceIssues(with: [])
        appState.resetIssueSeenUpdates()
        appState.resetIssueDetails()
        appState.selectedIssue = nil
        appState.selectedIssueIDs = []
        appState.setDrafts([])
        appState.selectedDraftID = nil
        appState.resetBoardSyncState()
        appState.resetInitialSyncState()
        appState.updateSidebar(sections: [], preferredSelectionID: nil)
        appState.setIssuesLoading(false)
        appState.updateInboxFieldUsage(from: [])
        lastLoadedIssueQuery = nil
        lastLoadedIssueSelection = nil
        activeIssueLoadRequestID = nil
        statusOptionsCache.removeAll()
        priorityOptionsCache.removeAll()
        assigneeOptionsCache.removeAll()
        cachedSavedQueries = []
        cachedBoards = []
        cachedTodoLists = []
        todoUncommittedQueue = []
        todoUncommittedChanges = []
        isCommittingTodoUncommittedChanges = false
    }

    private func recordIssueSyncCompleted() {
        appState.recordIssueSyncCompleted()
        configurationStore.saveInitialIssueSyncCompleted(true)
    }

    private func recordBoardListSyncCompleted() {
        appState.recordBoardListSyncCompleted()
        configurationStore.saveInitialBoardSyncCompleted(true)
    }

    private func recordSavedSearchSyncCompleted() {
        appState.recordSavedSearchSyncCompleted()
        configurationStore.saveInitialSavedSearchSyncCompleted(true)
    }

    private func resetInitialSyncState() {
        appState.resetInitialSyncState()
        configurationStore.clearInitialSyncState()
    }

    private func clearPersistedInitialSyncState() {
        configurationStore.clearInitialSyncState()
    }

    func loadIssues(for selection: SidebarItem) async {
        guard !selection.isDraft, !selection.isTodoList else { return }
        if !appState.hasCompletedInitialSync {
            LoggingService.syncVerbose("Initial sync: loading issues for \(selection.id).")
        }
        let resolvedBoard = await resolveBoardDetailsIfNeeded(for: selection)
        let boardID = boardIdentifier(for: selection, resolvedBoard: resolvedBoard)
        let query: IssueQuery
        if selection.isBoard {
            let page = selection.query.page
            let boardForQuery = resolvedBoard ?? boardForSelection(selection) ?? IssueBoard(
                id: selection.boardID ?? selection.id,
                name: selection.title,
                isFavorite: true,
                projectNames: []
            )
            query = boardIssueQuery(for: boardForQuery, page: page)
        } else {
            query = selection.query
        }
        if selection.isBoard,
           let resolvedBoard,
           appState.selectedSidebarItem?.id == selection.id,
           selection.board != resolvedBoard {
            appState.selectedSidebarItem = SidebarItem.board(resolvedBoard, page: selection.query.page)
        }

        let listID = selection.isBoard ? nil : selection.id
        let recordDataEvent: (String) -> Void = { [weak self] message in
            guard let self else { return }
            if selection.isBoard {
                self.recordBoardDataEvent(message, boardID: boardID)
            } else {
                self.recordIssueListDataEvent(message, listID: listID)
            }
        }
        if let queryLabel = query.diagnosticsLabel {
            recordDataEvent("Issue query: \(queryLabel).")
        }
        lastLoadedIssueSelection = selection
        if query == lastLoadedIssueQuery {
            recordDataEvent("Load issues skipped (same query).")
            return
        }
        let loadRequestID = UUID()
        activeIssueLoadRequestID = loadRequestID
        recordDataEvent("Load issues started.")
        lastLoadedIssueQuery = query
        appState.setIssuesLoading(true)
        let shouldSeedInitialRead = await syncCoordinator.hasSeenUpdates() == false

        let board = selection.isBoard ? (resolvedBoard ?? boardForSelection(selection)) : nil
        let sprintFilter = board.map { appState.sprintFilter(for: $0) }
        if let board, let sprintFilter {
            let sprintLabel = sprintFilter.isBacklog
                ? "Backlog"
                : (board.sprintName(for: sprintFilter) ?? "Sprint \(sprintFilter.sprintID ?? "-")")
            recordDataEvent("Sprint filter: \(sprintLabel).")
        }
        var sprintIssueIDs = await loadCachedSprintIssueIDsIfNeeded(
            board: board,
            filter: sprintFilter,
            boardID: boardID
        )
        let shouldFetchSprintIssueIDs = sprintIssueIDs == nil && !AppDebugSettings.disableSyncing
        async let remoteSprintIssueIDs: Set<String>? = shouldFetchSprintIssueIDs
            ? fetchSprintIssueIDsFromRemoteIfNeeded(
                board: board,
                filter: sprintFilter,
                boardID: boardID
            )
            : nil

        let cachedLoadStart = ProcessInfo.processInfo.systemUptime
        let cachedIssues = await syncCoordinator.loadCachedIssues(for: query)
        let cachedLoadDuration = durationText(since: cachedLoadStart)
        guard isCurrentIssueLoadRequest(loadRequestID, selectionID: selection.id) else {
            recordDataEvent("Load issues ignored (stale request before cache apply).")
            return
        }
        if !cachedIssues.isEmpty {
            LoggingService.syncVerbose(
                "Local DB: cached issues loaded (\(cachedIssues.count)) in \(cachedLoadDuration) for \(selection.id)."
            )
            recordDataEvent("Local DB cached issues loaded: \(cachedIssues.count) in \(cachedLoadDuration).")
            let filteredByBoard = applySprintFilterIfNeeded(
                cachedIssues,
                board: board,
                filter: sprintFilter,
                sprintIssueIDs: sprintIssueIDs
            )
            let filtered = filteredByBoard
            if filtered != appState.issues {
                appState.replaceIssues(with: filtered)
            }
            if selection.isInbox {
                appState.updateInboxFieldUsage(from: filtered)
            }
            appState.setIssuesLoading(false)
            await refreshIssueSeenUpdates(for: filtered, shouldSeedInitialRead: shouldSeedInitialRead)
        } else {
            LoggingService.syncVerbose(
                "Local DB: cached issues empty in \(cachedLoadDuration) for \(selection.id)."
            )
            recordDataEvent("Local DB cached issues empty (\(cachedLoadDuration)).")
        }
        guard isCurrentIssueLoadRequest(loadRequestID, selectionID: selection.id) else {
            recordDataEvent("Load issues ignored (stale request before refresh).")
            return
        }

        let syncStart = ProcessInfo.processInfo.systemUptime
        let syncResult = await syncCoordinator.refreshIssuesWithStatus(
            using: query,
            currentUserID: appState.currentUserID,
            currentUserLogin: appState.currentUserLogin,
            currentUserDisplayName: appState.currentUserDisplayName,
            paginate: selection.isBoard
        )
        if let remoteIDs = await remoteSprintIssueIDs {
            sprintIssueIDs = remoteIDs
        }
        guard isCurrentIssueLoadRequest(loadRequestID, selectionID: selection.id) else {
            recordDataEvent("Load issues ignored (stale request after refresh).")
            return
        }
        let syncDuration = durationText(since: syncStart)
        if syncResult.didSyncRemote || !syncResult.issues.isEmpty {
            recordIssueSyncCompleted()
        }
        if syncResult.didSyncRemote {
            LoggingService.syncVerbose(
                "Remote sync: issues synced (\(syncResult.issues.count)) in \(syncDuration)."
            )
            recordDataEvent("Remote sync loaded: \(syncResult.issues.count) issues in \(syncDuration).")
        } else if !syncResult.issues.isEmpty {
            let reason = AppDebugSettings.disableSyncing
                ? "Sync disabled; using cache"
                : "Remote sync unavailable; using cache"
            LoggingService.syncVerbose(
                "Local DB: issues loaded from cache (\(syncResult.issues.count)) in \(syncDuration) (\(reason))."
            )
            recordDataEvent("Local DB \(reason): \(syncResult.issues.count) issues in \(syncDuration).")
        } else {
            recordDataEvent("No issues returned after refresh (\(syncDuration)).")
        }
        var resolvedIssues = syncResult.issues
        if resolvedIssues.isEmpty,
           let sprintIssueIDs,
           !sprintIssueIDs.isEmpty {
            let fallbackStart = ProcessInfo.processInfo.systemUptime
            let fallback = await syncCoordinator.loadIssues(readableIDs: Array(sprintIssueIDs))
            let fallbackDuration = durationText(since: fallbackStart)
            if !fallback.isEmpty {
                LoggingService.syncVerbose(
                    "Local DB: sprint fallback issues loaded (\(fallback.count)) in \(fallbackDuration) for \(selection.id)."
                )
                recordDataEvent("Local DB sprint fallback: \(fallback.count) in \(fallbackDuration).")
                resolvedIssues = fallback
            } else {
                LoggingService.syncVerbose(
                    "Local DB: sprint fallback issues empty in \(fallbackDuration) for \(selection.id)."
                )
                recordDataEvent("Local DB sprint fallback empty (\(fallbackDuration)).")
            }
        }
        let filteredByBoard = applySprintFilterIfNeeded(
            resolvedIssues,
            board: board,
            filter: sprintFilter,
            sprintIssueIDs: sprintIssueIDs
        )
        let filtered = filteredByBoard
        if filtered != appState.issues {
            appState.replaceIssues(with: filtered)
        }
        if selection.isInbox {
            appState.updateInboxFieldUsage(from: filtered)
        }
        appState.setIssuesLoading(false)
        await refreshIssueSeenUpdates(for: filtered, shouldSeedInitialRead: shouldSeedInitialRead)
        if selection.isBoard, let boardID = selection.boardID {
            appState.recordBoardSync(boardID: boardID)
        }
        await maybeStartBoardPrefetch()
    }

    func loadIssueDetail(for issue: IssueSummary) async {
        let issueID = issue.id
        if appState.isIssueDetailLoading(issueID) {
            return
        }
        if let detail = appState.issueDetail(for: issue), detail.updatedAt >= issue.updatedAt {
            return
        }
        if let cached = await syncCoordinator.loadCachedIssueDetail(for: issue) {
            appState.updateIssueDetail(cached)
            if cached.updatedAt >= issue.updatedAt {
                return
            }
        }
        appState.setIssueDetailLoading(issueID, isLoading: true)
        do {
            let detail = try await syncCoordinator.fetchIssueDetail(for: issue)
            appState.updateIssueDetail(detail)
        } catch {
            // Intentionally ignored; detail view will show a placeholder.
        }
        appState.setIssueDetailLoading(issueID, isLoading: false)
    }

    func loadSubIssues(for issue: IssueSummary) async throws -> [IssueSummary] {
        let queries = subIssueQueryCandidates(parentReadableID: issue.readableID)
        return try await loadRelatedIssues(for: issue, queryCandidates: queries)
    }

    func loadParentIssues(for issue: IssueSummary) async throws -> [IssueSummary] {
        let queries = parentIssueQueryCandidates(childReadableID: issue.readableID)
        return try await loadRelatedIssues(for: issue, queryCandidates: queries)
    }

    private func loadRelatedIssues(
        for issue: IssueSummary,
        queryCandidates: [String]
    ) async throws -> [IssueSummary] {
        guard !issue.isDraft else { return [] }
        let trimmedID = issue.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return [] }
        let queries = queryCandidates
        guard !queries.isEmpty else { return [] }

        let page = IssueQuery.Page(size: 50, offset: 0)
        for queryString in queries {
            do {
                let query = IssueQuery.saved(queryString, page: page)
                let fetched = try await issueRepositorySwitcher.fetchIssues(query: query)
                return fetched
                    .filter { $0.id != issue.id }
                    .sorted { $0.updatedAt > $1.updatedAt }
            } catch let error as YouTrackAPIError {
                if case .http(let statusCode, _) = error, statusCode == 400 {
                    continue
                }
                throw error
            }
        }

        return []
    }

    private func subIssueQueryCandidates(parentReadableID: String) -> [String] {
        let wrapped = wrapQueryValue(parentReadableID)
        guard !wrapped.isEmpty else { return [] }
        return [
            "subtask of: \(wrapped)",
            "parent for: \(wrapped)"
        ]
    }

    private func parentIssueQueryCandidates(childReadableID: String) -> [String] {
        let wrapped = wrapQueryValue(childReadableID)
        guard !wrapped.isEmpty else { return [] }
        return [
            "parent for: \(wrapped)",
            "subtask of: \(wrapped)"
        ]
    }

    private func wrapQueryValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "{\(trimmed)}"
    }

    func refreshBoardIssues(for item: SidebarItem) async {
        guard item.isBoard else { return }
        let isSelected = appState.selectedSidebarItem?.id == item.id
        if isSelected {
            appState.setIssuesLoading(true)
        }
        let resolvedBoard = await resolveBoardDetailsIfNeeded(for: item)
        let boardID = boardIdentifier(for: item, resolvedBoard: resolvedBoard)
        let boardForQuery = resolvedBoard ?? boardForSelection(item) ?? IssueBoard(
            id: item.boardID ?? item.id,
            name: item.title,
            isFavorite: true,
            projectNames: []
        )
        let query = boardIssueQuery(for: boardForQuery, page: item.query.page)
        lastLoadedIssueSelection = item
        lastLoadedIssueQuery = query
        if isSelected,
           let resolvedBoard,
           item.board != resolvedBoard {
            appState.selectedSidebarItem = SidebarItem.board(resolvedBoard, page: item.query.page)
        }

        let board = resolvedBoard ?? boardForSelection(item)
        if let rawQuery = query.rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawQuery.isEmpty {
            recordBoardDataEvent("Issue query: \(rawQuery).", boardID: boardID)
        }
        let sprintFilter = board.map { appState.sprintFilter(for: $0) }
        if let board, let sprintFilter {
            let sprintLabel = sprintFilter.isBacklog
                ? "Backlog"
                : (board.sprintName(for: sprintFilter) ?? "Sprint \(sprintFilter.sprintID ?? "-")")
            recordBoardDataEvent("Refresh sprint filter: \(sprintLabel).", boardID: boardID)
        }
        recordBoardDataEvent("Refresh board started.", boardID: boardID)
        var sprintIssueIDs = await loadCachedSprintIssueIDsIfNeeded(
            board: board,
            filter: sprintFilter,
            boardID: boardID
        )
        let shouldFetchSprintIssueIDs = sprintIssueIDs == nil && !AppDebugSettings.disableSyncing
        async let remoteSprintIssueIDs: Set<String>? = shouldFetchSprintIssueIDs
            ? fetchSprintIssueIDsFromRemoteIfNeeded(
                board: board,
                filter: sprintFilter,
                boardID: boardID
            )
            : nil
        let shouldSeedInitialRead = await syncCoordinator.hasSeenUpdates() == false
        let syncStart = ProcessInfo.processInfo.systemUptime
        let syncResult = await syncCoordinator.refreshIssuesWithStatus(
            using: query,
            currentUserID: appState.currentUserID,
            currentUserLogin: appState.currentUserLogin,
            currentUserDisplayName: appState.currentUserDisplayName,
            paginate: item.isBoard
        )
        if let remoteIDs = await remoteSprintIssueIDs {
            sprintIssueIDs = remoteIDs
        }
        let syncDuration = durationText(since: syncStart)
        if syncResult.didSyncRemote || !syncResult.issues.isEmpty {
            recordIssueSyncCompleted()
        }
        if syncResult.didSyncRemote {
            LoggingService.syncVerbose(
                "Remote sync: refresh loaded (\(syncResult.issues.count)) in \(syncDuration)."
            )
            recordBoardDataEvent(
                "Refresh remote sync loaded: \(syncResult.issues.count) issues in \(syncDuration).",
                boardID: boardID
            )
        } else if !syncResult.issues.isEmpty {
            let reason = AppDebugSettings.disableSyncing
                ? "Refresh sync disabled; using cache"
                : "Refresh remote sync unavailable; using cache"
            LoggingService.syncVerbose(
                "Local DB: refresh loaded (\(syncResult.issues.count)) in \(syncDuration) (\(reason))."
            )
            recordBoardDataEvent(
                "Local DB \(reason): \(syncResult.issues.count) issues in \(syncDuration).",
                boardID: boardID
            )
        } else {
            recordBoardDataEvent("Refresh returned no issues (\(syncDuration)).", boardID: boardID)
        }
        if isSelected {
            var resolvedIssues = syncResult.issues
            if resolvedIssues.isEmpty,
               let sprintIssueIDs,
               !sprintIssueIDs.isEmpty {
                let fallbackStart = ProcessInfo.processInfo.systemUptime
                let fallback = await syncCoordinator.loadIssues(readableIDs: Array(sprintIssueIDs))
                let fallbackDuration = durationText(since: fallbackStart)
                if !fallback.isEmpty {
                    LoggingService.syncVerbose(
                        "Local DB: refresh sprint fallback loaded (\(fallback.count)) in \(fallbackDuration) for \(item.id)."
                    )
                    recordBoardDataEvent(
                        "Local DB refresh sprint fallback: \(fallback.count) in \(fallbackDuration).",
                        boardID: boardID
                    )
                    resolvedIssues = fallback
                } else {
                    LoggingService.syncVerbose(
                        "Local DB: refresh sprint fallback empty in \(fallbackDuration) for \(item.id)."
                    )
                    recordBoardDataEvent(
                        "Local DB refresh sprint fallback empty (\(fallbackDuration)).",
                        boardID: boardID
                    )
                }
            }
            let filteredByBoard = applySprintFilterIfNeeded(
                resolvedIssues,
                board: board,
                filter: sprintFilter,
                sprintIssueIDs: sprintIssueIDs
            )
            let filtered = filteredByBoard
            if filtered != appState.issues {
                appState.replaceIssues(with: filtered)
            }
            appState.setIssuesLoading(false)
            await refreshIssueSeenUpdates(for: filtered, shouldSeedInitialRead: shouldSeedInitialRead)
        }
        if let boardID = item.boardID {
            appState.recordBoardSync(boardID: boardID)
        }
        await maybeStartBoardPrefetch()
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

    func issueWebURL(for issue: IssueSummary) -> URL? {
        issueWebURL(readableID: issue.readableID)
    }

    func issueWebURL(readableID: String) -> URL? {
        let trimmedID = readableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }
        guard let apiBase = configurationStore.loadBaseURL() else { return nil }
        var uiBase = apiBase
        if uiBase.lastPathComponent.lowercased() == "api" {
            uiBase.deleteLastPathComponent()
        }
        uiBase.appendPathComponent("issue")
        uiBase.appendPathComponent(trimmedID)
        return uiBase
    }

    func openBoardInWeb(_ item: SidebarItem) {
        guard let url = boardWebURL(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func openIssueInWeb(_ issue: IssueSummary) {
        guard let url = issueWebURL(for: issue) else { return }
        NSWorkspace.shared.open(url)
    }

    func openIssueReadableIDInWeb(_ readableID: String) {
        guard let url = issueWebURL(readableID: readableID) else { return }
        NSWorkspace.shared.open(url)
    }

    func activateToast(_ toast: ToastNotice) {
        guard let issue = toast.issueToOpen else { return }
        appState.dismissToast()
        openIssueFromToast(issue)
    }

    func openIssueFromToast(_ issue: IssueSummary) {
        NSApp?.activate(ignoringOtherApps: true)
        presentIssueInInspector(issue)
        Task { [weak self] in
            await self?.loadIssueDetail(for: issue)
        }
    }

    func openIssueFromTodoLink(_ readableID: String) async {
        let normalized = normalizeIssueReadableID(readableID)
        guard !normalized.isEmpty else { return }
        guard let issue = await resolveIssueByReadableID(normalized) else {
            appState.showToast("Issue \(normalized) not found")
            return
        }
        presentIssueInInspector(issue)
        await loadIssueDetail(for: issue)
    }

    func setIssueClosedFromTodoLink(_ readableID: String, isClosed: Bool) async {
        let normalized = normalizeIssueReadableID(readableID)
        guard !normalized.isEmpty else { return }
        enqueueTodoUncommittedOperation(
            summary: isClosed ? "Close \(normalized)" : "Reopen \(normalized)",
            operation: .setIssueClosed(readableID: normalized, isClosed: isClosed)
        )
    }

    func commitTodoUncommittedChanges() async {
        guard !isCommittingTodoUncommittedChanges else { return }
        guard !todoUncommittedQueue.isEmpty else { return }

        isCommittingTodoUncommittedChanges = true
        defer { isCommittingTodoUncommittedChanges = false }

        let queued = todoUncommittedQueue
        todoUncommittedQueue.removeAll()
        todoUncommittedChanges = []

        var failedEntries: [TodoUncommittedQueueEntry] = []
        var committedCount = 0

        for entry in queued {
            do {
                try await runTodoUncommittedOperation(entry.operation)
                committedCount += 1
            } catch {
                failedEntries.append(entry)
                LoggingService.sync.error(
                    "Failed to commit todo change '\(entry.change.summary, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if !failedEntries.isEmpty {
            todoUncommittedQueue = failedEntries + todoUncommittedQueue
            todoUncommittedChanges = todoUncommittedQueue.map(\.change)
        }

        if failedEntries.isEmpty {
            let message = committedCount == 1 ? "Committed 1 change" : "Committed \(committedCount) changes"
            appState.showToast(message)
        } else {
            appState.showToast("Committed \(committedCount), failed \(failedEntries.count)")
        }
    }

    func loadTodoIssueStyles(readableIDs: Set<String>) async -> [String: TodoIssueInlineStyle] {
        let normalizedIDs = Set(readableIDs.map(normalizeIssueReadableID).filter { !$0.isEmpty })
        guard !normalizedIDs.isEmpty else { return [:] }
        var resolved: [String: IssueSummary] = [:]

        for issue in appState.issues {
            let key = normalizeIssueReadableID(issue.readableID)
            guard normalizedIDs.contains(key) else { continue }
            resolved[key] = issue
        }

        let unresolvedIDs = normalizedIDs.subtracting(Set(resolved.keys))
        if !unresolvedIDs.isEmpty {
            let cached = await syncCoordinator.loadIssues(readableIDs: Array(unresolvedIDs))
            for issue in cached {
                let key = normalizeIssueReadableID(issue.readableID)
                guard unresolvedIDs.contains(key) else { continue }
                resolved[key] = issue
            }
        }

        let remainingIDs = normalizedIDs.subtracting(Set(resolved.keys))
        if !remainingIDs.isEmpty {
            let page = IssueQuery.Page(size: 20, offset: 0)
            for readableID in remainingIDs {
                guard let fetched = await fetchIssueByReadableID(readableID, page: page) else { continue }
                resolved[readableID] = fetched
            }
        }

        return resolved.reduce(into: [String: TodoIssueInlineStyle]()) { partial, entry in
            partial[entry.key] = TodoIssueInlineStyle(issueID: entry.key, status: entry.value.status)
        }
    }

    private func enqueueTodoUncommittedOperation(summary: String, operation: TodoUncommittedOperation) {
        if case .setIssueClosed(let readableID, _) = operation {
            if let index = todoUncommittedQueue.lastIndex(where: {
                if case .setIssueClosed(let existingReadableID, _) = $0.operation {
                    return existingReadableID == readableID
                }
                return false
            }) {
                todoUncommittedQueue.remove(at: index)
            }
        }

        let change = TodoUncommittedChange(id: UUID(), summary: summary, createdAt: Date())
        todoUncommittedQueue.append(TodoUncommittedQueueEntry(change: change, operation: operation))
        todoUncommittedChanges = todoUncommittedQueue.map(\.change)
    }

    private func runTodoUncommittedOperation(_ operation: TodoUncommittedOperation) async throws {
        switch operation {
        case .setIssueClosed(let readableID, let isClosed):
            try await applyTodoIssueClosedState(readableID: readableID, isClosed: isClosed)
        case .createIssue(let draft):
            _ = try await createIssueFromTodoUncommittedChange(draft: draft)
        }
    }

    private func applyTodoIssueClosedState(readableID: String, isClosed: Bool) async throws {
        guard let issue = await resolveIssueByReadableID(readableID) else {
            throw TodoUncommittedOperationError.issueNotFound(readableID)
        }
        let patch = await todoChecklistStatusPatch(for: issue, isClosed: isClosed)
        await updateIssue(id: issue.id, patch: patch)
    }

    @discardableResult
    private func createIssueFromTodoUncommittedChange(draft: IssueDraft) async throws -> IssueSummary {
        let created = try await syncCoordinator.enqueue(label: "Create issue") {
            try await self.issueRepositorySwitcher.createIssue(draft: draft)
        }
        registerCreatedIssue(created, showToast: false)
        scheduleIssueListRefreshAfterCreation()
        await linkSubIssueIfNeeded(parentReadableID: draft.parentIssueReadableID, childIssue: created)
        await uploadDraftAttachmentsIfNeeded(draft: draft, issue: created)
        return created
    }

    private func queuedIssueCreationSummary(for draft: IssueDraft) -> String {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = trimmedTitle.isEmpty ? "Untitled issue" : trimmedTitle
        let shortenedTitle: String
        if baseTitle.count > 72 {
            let endIndex = baseTitle.index(baseTitle.startIndex, offsetBy: 72)
            shortenedTitle = "\(baseTitle[..<endIndex])..."
        } else {
            shortenedTitle = baseTitle
        }
        if let parent = draft.parentIssueReadableID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            return "Create sub-issue \"\(shortenedTitle)\" under \(parent)"
        }
        return "Create issue \"\(shortenedTitle)\""
    }

    func clearCacheAndRefetch() {
        clearPersistedInitialSyncState()
        Task { [weak self] in
            guard let self else { return }
            await syncCoordinator.clearCachedIssues()
            await boardLocalStore.clearCache()
            await savedQueryLocalStore.clearCache()
            await MainActor.run {
                appState.replaceIssues(with: [])
                appState.resetIssueSeenUpdates()
                appState.resetIssueDetails()
                appState.selectedIssue = nil
                appState.setIssuesLoading(true)
                self.lastLoadedIssueQuery = nil
                self.lastLoadedIssueSelection = nil
                self.activeIssueLoadRequestID = nil
                self.cachedSavedQueries = []
                self.cachedBoards = []
                self.statusOptionsCache.removeAll()
                self.priorityOptionsCache.removeAll()
                self.assigneeOptionsCache.removeAll()
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

    func markIssuesSeen(_ issues: [IssueSummary]) {
        guard !issues.isEmpty else { return }
        appState.markIssuesSeen(issues)
        Task { [weak self] in
            await self?.syncCoordinator.markIssuesSeen(issues)
        }
    }

    func markAllIssuesSeen() {
        markIssuesSeen(appState.issues)
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async {
        do {
            let updated = try await syncCoordinator.applyOptimisticUpdate(id: id, patch: patch)
            appState.updateIssue(updated)
            markIssueSeen(updated)
        } catch {
            let message = "Failed to update issue: \(error.localizedDescription)"
            print(message)
            appState.showToast(message)
        }
    }

    func addComment(to issue: IssueSummary, text: String) async throws -> IssueComment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing comment text")
        }
        let comment = try await syncCoordinator.enqueue(label: "Add comment") {
            try await self.issueRepositorySwitcher.addComment(issueReadableID: issue.readableID, text: trimmed)
        }
        appState.recordComment(comment, for: issue)
        let updatedIssue = issue.updating(updatedAt: max(issue.updatedAt, comment.createdAt))
        markIssueSeen(updatedIssue)
        return comment
    }

    func addAttachments(to issue: IssueSummary, attachments: [IssueAttachmentDraft]) async throws -> [IssueAttachment] {
        guard !attachments.isEmpty else { return [] }
        let uploaded = try await syncCoordinator.enqueue(label: "Upload attachments") {
            try await self.issueRepositorySwitcher.uploadAttachments(
                issueReadableID: issue.readableID,
                attachments: attachments
            )
        }
        appState.appendAttachments(uploaded, to: issue.id)
        return uploaded
    }

    func fetchAttachmentData(for attachment: IssueAttachment) async throws -> Data {
        guard let url = attachment.url else {
            throw AttachmentDownloadError.missingURL
        }
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = YouTrackAPIConfiguration.defaultRequestTimeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if shouldAttachToken(for: url) {
            let token = try await authRepository.currentAccessToken()
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AttachmentDownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw AttachmentDownloadError.http(statusCode: http.statusCode, body: body)
        }
        return data
    }

    func beginNewIssue(withTitle title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = IssueDraft(
            title: trimmedTitle,
            description: "",
            projectID: "",
            module: nil,
            priority: .normal,
            assigneeID: nil,
            customFields: []
        )

        Task { [weak self] in
            guard let self else { return }
            let record = await issueDraftStore.saveDraft(draft)
            await MainActor.run {
                appState.addDraft(record)
                issueComposer.applyDraft(record.draft)
                appState.selectedDraftID = record.id
                let draftSummary = IssueSummary.draft(record)
                appState.selectedIssue = draftSummary
                appState.selectedIssueIDs = [draftSummary.id]
                if let inbox = inboxSidebarItem() {
                    appState.selectedSidebarItem = inbox
                }
            }
        }
    }

    func presentNewIssueDialog(title: String = "") {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.presentNewIssueDialog(state: NewIssueDialogState(title: trimmedTitle))
    }

    func presentNewIssueDialog(fromSelectedText selectedText: String?) {
        presentNewIssueDialog(fromSelectedText: selectedText, queueAsUncommitted: false)
    }

    func presentNewIssueDialog(fromSelectedText selectedText: String?, queueAsUncommitted: Bool) {
        appState.presentNewIssueDialog(
            state: Self.newIssueDialogState(
                fromSelectedText: selectedText,
                queueAsUncommitted: queueAsUncommitted
            )
        )
    }

    func presentNewIssueDialog(state: NewIssueDialogState) {
        appState.presentNewIssueDialog(state: state)
    }

    static func newIssueDialogState(
        fromSelectedText selectedText: String?,
        queueAsUncommitted: Bool = false
    ) -> NewIssueDialogState {
        guard let normalizedSelection = normalizeSelectedText(selectedText) else {
            return NewIssueDialogState(queueAsUncommitted: queueAsUncommitted)
        }

        let title = issueTitlePrefill(from: normalizedSelection)
        if normalizedSelection.contains("\n") || normalizedSelection.count > selectedTextIssueTitleLimit {
            return NewIssueDialogState(
                queueAsUncommitted: queueAsUncommitted,
                title: title,
                description: normalizedSelection
            )
        }
        return NewIssueDialogState(
            queueAsUncommitted: queueAsUncommitted,
            title: normalizedSelection
        )
    }

    private static let selectedTextIssueTitleLimit = 120

    private static func normalizeSelectedText(_ selectedText: String?) -> String? {
        guard let selectedText else { return nil }
        let normalized = selectedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func issueTitlePrefill(from selectedText: String) -> String {
        let firstNonEmptyLine = selectedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? selectedText
        return truncateIssueTitle(firstNonEmptyLine)
    }

    private static func truncateIssueTitle(_ rawTitle: String) -> String {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.count > selectedTextIssueTitleLimit else {
            return trimmedTitle
        }
        let endIndex = trimmedTitle.index(trimmedTitle.startIndex, offsetBy: selectedTextIssueTitleLimit)
        return "\(trimmedTitle[..<endIndex])..."
    }

    private func registerCreatedIssue(
        _ created: IssueSummary,
        removeDraftID: UUID? = nil,
        resetComposer: Bool = false,
        showToast: Bool = true
    ) {
        appState.updateIssue(created)
        if let removeDraftID {
            appState.removeDraft(id: removeDraftID)
        }
        if resetComposer {
            issueComposer.resetDraft()
        }
        markIssueSeen(created)
        if showToast {
            appState.showToast("Issue \(created.readableID) created", issueToOpen: created)
        }
    }

    private func scheduleIssueListRefreshAfterCreation() {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshIssueListsAfterCreation()
        }
    }

    private func refreshIssueListsAfterCreation() async {
        guard !requiresSetup else { return }
        if let selection = appState.selectedSidebarItem,
           !selection.isDraft,
           !selection.isTodoList {
            if selection.isBoard {
                await refreshBoardIssues(for: selection)
            } else {
                await forceReloadIssues(for: selection)
            }
            return
        }

        guard let query = lastLoadedIssueQuery else { return }
        let syncResult = await syncCoordinator.refreshIssuesWithStatus(
            using: query,
            currentUserID: appState.currentUserID,
            currentUserLogin: appState.currentUserLogin,
            currentUserDisplayName: appState.currentUserDisplayName,
            paginate: lastLoadedIssueSelection?.isBoard == true
        )
        if syncResult.didSyncRemote || !syncResult.issues.isEmpty {
            recordIssueSyncCompleted()
        }
    }

    private func forceReloadIssues(for selection: SidebarItem) async {
        lastLoadedIssueQuery = nil
        await loadIssues(for: selection)
    }

    private func isCurrentIssueLoadRequest(_ requestID: UUID, selectionID: String) -> Bool {
        activeIssueLoadRequestID == requestID && appState.selectedSidebarItem?.id == selectionID
    }

    private func presentIssueInInspector(_ issue: IssueSummary) {
        appState.setInspectorVisible(true)
        appState.selectedDraftID = nil
        appState.selectedIssue = issue
        appState.selectedIssueIDs = [issue.id]
        markIssueSeen(issue)
    }

    func submitDraftFromDialog(_ draft: IssueDraft, queueAsUncommitted: Bool = false) {
        if queueAsUncommitted {
            enqueueTodoUncommittedOperation(
                summary: queuedIssueCreationSummary(for: draft),
                operation: .createIssue(draft: draft)
            )
            let pendingCount = todoUncommittedChanges.count
            let message = pendingCount == 1
                ? "Queued 1 uncommitted change"
                : "Queued \(pendingCount) uncommitted changes"
            appState.showToast(message)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let record = await issueDraftStore.saveDraft(draft)
            do {
                let created = try await syncCoordinator.enqueue(label: "Create issue") {
                    try await self.issueRepositorySwitcher.createIssue(draft: draft)
                }
                _ = await issueDraftStore.markDraftSubmitted(id: record.id)
                await MainActor.run {
                    self.registerCreatedIssue(created)
                    self.scheduleIssueListRefreshAfterCreation()
                }
                await self.linkSubIssueIfNeeded(parentReadableID: draft.parentIssueReadableID, childIssue: created)
                await self.uploadDraftAttachmentsIfNeeded(draft: draft, issue: created)
            } catch {
                _ = await issueDraftStore.markDraftFailed(id: record.id, errorDescription: error.localizedDescription)
                await MainActor.run {
                    if let failedRecord = self.appState.draftRecord(id: record.id) {
                        self.appState.updateDraft(failedRecord)
                    }
                }
            }
        }
    }

    func submitIssueDraft() {
        if let draftID = appState.selectedDraftID {
            submitDraft(recordID: draftID)
            return
        }

        guard let draft = issueComposer.makeDraft() else { return }
        issueComposer.resetDraft()

        Task { [weak self] in
            guard let self else { return }
            let record = await issueDraftStore.saveDraft(draft)
            do {
                let created = try await syncCoordinator.enqueue(label: "Create issue") {
                    try await self.issueRepositorySwitcher.createIssue(draft: draft)
                }
                _ = await issueDraftStore.markDraftSubmitted(id: record.id)
                await MainActor.run {
                    self.registerCreatedIssue(created)
                    self.scheduleIssueListRefreshAfterCreation()
                }
                await self.linkSubIssueIfNeeded(parentReadableID: draft.parentIssueReadableID, childIssue: created)
                await self.uploadDraftAttachmentsIfNeeded(draft: draft, issue: created)
            } catch {
                _ = await issueDraftStore.markDraftFailed(id: record.id, errorDescription: error.localizedDescription)
            }
        }
    }

    func selectDraft(recordID: UUID) {
        guard let record = appState.draftRecord(id: recordID) else { return }
        issueComposer.applyDraft(record.draft)
        appState.selectedDraftID = recordID
    }

    func updateDraft(recordID: UUID, draft: IssueDraft) {
        guard var record = appState.draftRecord(id: recordID) else { return }
        record.draft = draft
        record.updatedAt = Date()
        appState.updateDraft(record)

        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await self.issueDraftStore.updateDraft(id: recordID, draft: draft)
        }
    }

    func discardDraft(recordID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.issueDraftStore.deleteDraft(id: recordID)
            await MainActor.run {
                let wasSelected = appState.selectedDraftID == recordID
                appState.removeDraft(id: recordID)
                if wasSelected {
                    issueComposer.resetDraft()
                }
            }
        }
    }

    func submitDraft(recordID: UUID) {
        guard let draft = issueComposer.makeDraft() else { return }

        Task { [weak self] in
            guard let self else { return }
            _ = await issueDraftStore.updateDraft(id: recordID, draft: draft)
            do {
                let created = try await syncCoordinator.enqueue(label: "Create issue") {
                    try await self.issueRepositorySwitcher.createIssue(draft: draft)
                }
                _ = await issueDraftStore.markDraftSubmitted(id: recordID)
                await MainActor.run {
                    self.registerCreatedIssue(created, removeDraftID: recordID, resetComposer: true)
                    self.scheduleIssueListRefreshAfterCreation()
                }
                await self.linkSubIssueIfNeeded(parentReadableID: draft.parentIssueReadableID, childIssue: created)
                await self.uploadDraftAttachmentsIfNeeded(draft: draft, issue: created)
            } catch {
                let record = await issueDraftStore.markDraftFailed(id: recordID, errorDescription: error.localizedDescription)
                await MainActor.run {
                    if let record {
                        self.appState.updateDraft(record)
                    }
                }
            }
        }
    }

    private func uploadDraftAttachmentsIfNeeded(draft: IssueDraft, issue: IssueSummary) async {
        guard !draft.attachments.isEmpty else { return }
        do {
            _ = try await addAttachments(to: issue, attachments: draft.attachments)
        } catch {
            print("Failed to upload attachments: \(error.localizedDescription)")
        }
    }

    private func linkSubIssueIfNeeded(parentReadableID: String?, childIssue: IssueSummary) async {
        let trimmedParent = parentReadableID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedParent.isEmpty else { return }
        let trimmedChild = childIssue.readableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChild.isEmpty else { return }
        do {
            try await syncCoordinator.enqueue(label: "Link sub-issue") {
                try await self.issueRepositorySwitcher.linkSubIssue(
                    parentReadableID: trimmedParent,
                    childReadableID: trimmedChild
                )
            }
            await MainActor.run {
                self.appState.recordSubIssueLink(parentReadableID: trimmedParent)
            }
        } catch {
            LoggingService.sync.error(
                "Failed to link sub-issue \(trimmedChild, privacy: .public) -> \(trimmedParent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
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

        let savedQueries: [SavedQuery]
        do {
            let remote = try await syncCoordinator.enqueue(label: "Sync saved searches") {
                try await self.savedQueryRepositorySwitcher.fetchSavedQueries()
            }
            await savedQueryLocalStore.saveRemoteSavedQueries(remote)
            savedQueries = remote
        } catch {
            savedQueries = await savedQueryLocalStore.loadSavedQueries()
        }
        let boards = await boardLocalStore.loadBoards()
        cachedSavedQueries = savedQueries
        cachedBoards = boards
        let todoLists = (try? await todoListStore.listDocuments()) ?? []
        cachedTodoLists = todoLists
        let sections = buildSidebarSections(savedQueries: savedQueries, boards: boards, todoLists: todoLists)
        let preferredSelectionID = preferredSelectionID(from: savedQueries)
        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)
    }

    func createTodoList(named name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "Todo List"
        let resolvedName = trimmedName.isEmpty ? fallbackName : trimmedName
        do {
            let created = try await todoListStore.createDocument(named: resolvedName)
            await refreshTodoLists(preferredSelectionID: "todo-list:\(created.id.uuidString)")
        } catch {
            appState.showToast("Failed to create todo list")
        }
    }

    func renameTodoList(id: UUID, name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        do {
            try await todoListStore.renameDocument(id: id, to: trimmedName)
            await refreshTodoLists(preferredSelectionID: "todo-list:\(id.uuidString)")
        } catch {
            appState.showToast("Failed to rename todo list")
        }
    }

    func deleteTodoList(id: UUID) async {
        do {
            try await todoListStore.deleteDocument(id: id)
            await refreshTodoLists(preferredSelectionID: nil)
        } catch {
            appState.showToast("Failed to delete todo list")
        }
    }

    func loadTodoListMarkdown(id: UUID) async -> String {
        do {
            return try await todoListStore.loadMarkdown(id: id)
        } catch {
            return ""
        }
    }

    func saveTodoListMarkdown(id: UUID, markdown: String) async {
        do {
            try await todoListStore.saveMarkdown(id: id, markdown: markdown)
            let previousName = cachedTodoLists.first(where: { $0.id == id })?.name
            let updatedDocuments = try await todoListStore.listDocuments()
            cachedTodoLists = updatedDocuments
            let updatedName = updatedDocuments.first(where: { $0.id == id })?.name
            if previousName != updatedName {
                rebuildSidebar(preferredSelectionID: "todo-list:\(id.uuidString)")
            }
        } catch {
            appState.showToast("Failed to save todo list")
        }
    }

    func saveTodoListImageAttachment(id: UUID, data: Data, preferredFileExtension: String) async -> String? {
        do {
            return try await todoListStore.saveImageAttachment(
                id: id,
                data: data,
                preferredFileExtension: preferredFileExtension
            )
        } catch {
            appState.showToast("Failed to save pasted image")
            return nil
        }
    }

    func loadTodoListImageAttachment(id: UUID, reference: String) async -> Data? {
        try? await todoListStore.loadImageAttachment(id: id, reference: reference)
    }

    private func refreshTodoLists(preferredSelectionID: SidebarItem.ID?) async {
        let updatedDocuments = (try? await todoListStore.listDocuments()) ?? cachedTodoLists
        cachedTodoLists = updatedDocuments
        rebuildSidebar(preferredSelectionID: preferredSelectionID)
    }

    func beginSignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.resetInitialSyncState()
                LoggingService.sync.info("Sign-in: starting.")
                guard let configuration = try? YouTrackOAuthConfiguration.load() else {
                    throw AuthError.configurationMissing("Missing OAuth environment configuration.")
                }
                await self.applyOAuth(
                    configuration: configuration,
                    configureRepositories: false,
                    shouldResetInitialSyncState: false
                )
                try await authRepository.signIn()
                await self.applyOAuth(
                    configuration: configuration,
                    configureRepositories: true,
                    shouldResetInitialSyncState: false
                )
                LoggingService.sync.info("Sign-in: completed, bootstrapping.")
                await self.bootstrap()
            } catch {
                print("Sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    func signOut() async {
        await signOutAndClearLocalState(removeAccount: true)
    }

    func resyncWorkspace() async {
        await refreshSidebarData()
    }

    func cancelInitialSync() async {
        LoggingService.sync.info("Initial sync: cancel requested.")
        await signOutAndClearLocalState(removeAccount: true)
    }

    private func signOutAndClearLocalState(removeAccount: Bool) async {
        let previousAccountID = configurationStore.activeAccountID()
        do {
            try await authRepository.signOut()
        } catch {
            print("Sign-out failed: \(error.localizedDescription)")
        }

        await syncCoordinator.clearCachedIssues()
        await boardLocalStore.clearCache()
        await savedQueryLocalStore.clearCache()

        if removeAccount, let previousAccountID {
            _ = configurationStore.removeAccount(id: previousAccountID)
        }

        refreshAccounts()
        resetStateForAccountSwitch()
        appState.setCurrentUserProfile(displayName: nil, login: nil, id: nil)
        appState.resetInitialSyncState()

        guard let nextAccountID = configurationStore.activeAccountID(), nextAccountID != previousAccountID else {
            requiresSetup = true
            return
        }
        configureStores(for: nextAccountID)
        let initialSyncState = configurationStore.loadInitialSyncState()
        appState.prefillInitialSyncState(
            issues: initialSyncState.issues,
            boards: initialSyncState.boards,
            savedSearches: initialSyncState.savedSearches
        )
        appState.setCurrentUserProfile(
            displayName: configurationStore.loadUserDisplayName(),
            login: configurationStore.loadUserLogin(),
            id: configurationStore.loadUserID()
        )
        await configureIfNeeded()
    }

    func validateManualToken(baseURL: URL, token: String) async throws -> YouTrackTokenValidationUser {
        let apiBaseURL = Self.apiBaseURL(from: baseURL)
        let tokenProvider = YouTrackAPITokenProvider.constant(token)
        let configuration = YouTrackAPIConfiguration(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let client = YouTrackAPIClient(configuration: configuration, session: .shared, monitor: networkMonitor)
        let queryItems = [URLQueryItem(name: "fields", value: "id,login,name,fullName")]
        if AppDebugSettings.verboseRequestLogging {
            LoggingService.networking.debug("Token validation: requesting users/me at \(apiBaseURL.absoluteString, privacy: .public).")
        }
        let data = try await client.get(path: "users/me", queryItems: queryItems)
        let user = try JSONDecoder().decode(YouTrackTokenValidationUser.self, from: data)
        if AppDebugSettings.verboseRequestLogging {
            LoggingService.networking.debug("Token validation: success for user \(user.displayName ?? "unknown", privacy: .public).")
        }
        return user
    }

    struct ManualTokenSaveOutcome: Sendable {
        let saved: Bool
        let errorMessage: String?
    }

    func completeManualSetup(
        baseURL: URL,
        token: String,
        userProfile: YouTrackTokenValidationUser? = nil,
        allowKeychainInteraction: Bool = false,
        shouldResetInitialSyncState: Bool = true,
        shouldBootstrap: Bool = true
    ) async -> ManualTokenSaveOutcome {
        let apiBaseURL = Self.apiBaseURL(from: baseURL)

        if shouldResetInitialSyncState {
            resetInitialSyncState()
        }
        let account = configurationStore.upsertAccount(
            baseURL: apiBaseURL,
            authMethod: .token,
            displayName: userProfile?.displayName,
            login: userProfile?.login,
            userID: userProfile?.id,
            allowBaseURLOnlyMatch: true
        )
        refreshAccounts()
        configureStores(for: account.id)
        let manualAuth = ManualTokenAuthRepository(configurationStore: configurationStore)
        var tokenSaved = true
        var tokenSaveError: String?
        do {
            try manualAuth.apply(token: token, displayName: userProfile?.displayName)
        } catch {
            tokenSaved = false
            tokenSaveError = error.localizedDescription
            LoggingService.sync.error("Manual setup: failed to save token (\(error.localizedDescription, privacy: .public)).")
        }
        LoggingService.sync.info("Manual setup: repositories configured for \(apiBaseURL.absoluteString, privacy: .public).")

        authRepositorySwitcher.replace(with: manualAuth)
        storeUserProfile(userProfile)
        refreshAccounts()

        let tokenProvider = YouTrackAPITokenProvider {
            try await manualAuth.currentAccessToken()
        }
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let savedQueryRepository = YouTrackSavedQueryRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let boardRepository = YouTrackIssueBoardRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let projectRepository = YouTrackProjectRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let fieldRepository = YouTrackIssueFieldRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let peopleRepository = YouTrackPeopleRepository(configuration: apiConfiguration, monitor: networkMonitor)
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)
        await boardRepositorySwitcher.replace(with: boardRepository)
        await projectRepositorySwitcher.replace(with: projectRepository)
        await issueFieldRepositorySwitcher.replace(with: fieldRepository)
        await peopleRepositorySwitcher.replace(with: peopleRepository)

        await MainActor.run {
            requiresSetup = false
        }
        if shouldBootstrap {
            await bootstrap()
        }
        return ManualTokenSaveOutcome(saved: tokenSaved, errorMessage: tokenSaveError)
    }

    func storedConfigurationDraft() -> (baseURL: URL?, token: String?) {
        (configurationStore.loadBaseURL(), configurationStore.loadToken())
    }

    func setBaseURL(_ url: URL) {
        let apiBaseURL = Self.apiBaseURL(from: url)
        _ = configurationStore.upsertAccount(
            baseURL: apiBaseURL,
            authMethod: .oauth,
            allowBaseURLOnlyMatch: true
        )
        refreshAccounts()
    }

    func recordSidebarSelection(_ selection: SidebarItem) {
        // Saving rewrites the accounts payload (JSON + keychain mirror); skip
        // when the selection is already persisted — sidebar refreshes republish
        // the same selection routinely.
        guard configurationStore.cachedActiveAccount()?.lastSidebarSelectionID != selection.id else { return }
        configurationStore.saveLastSidebarSelectionID(selection.id)
    }

    var activeAccount: StoredAccount? {
        guard let activeID = activeAccountID else { return nil }
        return accounts.first { $0.id == activeID }
    }

    var browserAuthAvailable: Bool {
        supportsBrowserAuth
    }

    private func updateUserProfile(from account: Account?) {
        let trimmed = account?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            configurationStore.saveUserDisplayName(trimmed)
        }
        refreshAccounts()
        appState.setCurrentUserProfile(
            displayName: configurationStore.loadUserDisplayName(),
            login: configurationStore.loadUserLogin(),
            id: configurationStore.loadUserID()
        )
    }

    private func storeUserProfile(_ profile: YouTrackTokenValidationUser?) {
        guard let profile else {
            updateUserProfile(from: authRepository.currentAccount)
            return
        }
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            configurationStore.saveUserDisplayName(displayName)
        }
        if let login = profile.login?.trimmingCharacters(in: .whitespacesAndNewlines),
           !login.isEmpty {
            configurationStore.saveUserLogin(login)
        }
        if let id = profile.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            configurationStore.saveUserID(id)
        }
        refreshAccounts()
        appState.setCurrentUserProfile(
            displayName: configurationStore.loadUserDisplayName(),
            login: configurationStore.loadUserLogin(),
            id: configurationStore.loadUserID()
        )
    }

    private func refreshCurrentUserProfileIfNeeded() async {
        guard !requiresSetup else { return }
        let storedLogin = configurationStore.loadUserLogin()
        let storedID = configurationStore.loadUserID()
        if storedLogin?.isEmpty == false, storedID?.isEmpty == false {
            return
        }
        guard let baseURL = configurationStore.loadBaseURL() else { return }
        let token: String
        do {
            token = try await authRepository.currentAccessToken()
        } catch {
            LoggingService.sync.error("Failed to refresh user profile token: \(error.localizedDescription, privacy: .public)")
            return
        }
        let tokenProvider = YouTrackAPITokenProvider.constant(token)
        let configuration = YouTrackAPIConfiguration(baseURL: baseURL, tokenProvider: tokenProvider)
        let client = YouTrackAPIClient(configuration: configuration, session: .shared, monitor: networkMonitor)
        let queryItems = [URLQueryItem(name: "fields", value: "id,login,name,fullName")]
        do {
            let data = try await client.get(path: "users/me", queryItems: queryItems)
            let user = try JSONDecoder().decode(YouTrackTokenValidationUser.self, from: data)
            storeUserProfile(user)
        } catch {
            LoggingService.sync.error("Failed to refresh user profile: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureIfNeeded() async {
        // Runs on the launch path: use the UserDefaults-cached account snapshot;
        // keychain-synced metadata reconciles in the background task from init.
        refreshAccountsFromCache()
        var activeAccount = configurationStore.cachedActiveAccount()
        if activeAccount == nil {
            // Reinstall path: local defaults are empty but the keychain mirror
            // may still hold accounts; restore it (off-main) before concluding
            // that setup is required.
            let store = configurationStore
            _ = await Task.detached(priority: .userInitiated) {
                store.loadAccounts()
            }.value
            refreshAccountsFromCache()
            activeAccount = configurationStore.cachedActiveAccount()
        }
        let oauthConfiguration = try? YouTrackOAuthConfiguration.load()
        let hasOAuthState = oauthConfiguration != nil && AppAuthRepository.hasSavedAuthState()
        supportsBrowserAuth = oauthConfiguration != nil

        if let activeAccount {
            configureStores(for: activeAccount.id)
            switch activeAccount.authMethod {
            case .oauth:
                guard let oauthConfiguration else {
                    requiresSetup = true
                    return
                }
                LoggingService.sync.info("Configuration: OAuth environment detected.")
                await applyOAuth(
                    configuration: oauthConfiguration,
                    configureRepositories: hasOAuthState,
                    shouldResetInitialSyncState: false
                )
                if hasOAuthState, authRepository.currentAccount != nil {
                    await bootstrap()
                    return
                }
            case .token:
                let baseURL = activeAccount.baseURL.isEmpty ? nil : URL(string: activeAccount.baseURL)
                // The token read must hit the keychain; do it off the main thread.
                let store = configurationStore
                let token = await Task.detached(priority: .userInitiated) {
                    store.loadToken()
                }.value

                if let baseURL, let token, !token.isEmpty {
                    let needsProfile = activeAccount.displayName == nil
                        || activeAccount.login == nil
                        || activeAccount.userID == nil
                    let userProfile: YouTrackTokenValidationUser?
                    if needsProfile {
                        LoggingService.sync.info("Configuration: stored token found, validating user profile.")
                        userProfile = try? await validateManualToken(baseURL: baseURL, token: token)
                    } else {
                        userProfile = nil
                    }
                    LoggingService.sync.info("Configuration: stored token found, bootstrapping.")
                    _ = await completeManualSetup(
                        baseURL: baseURL,
                        token: token,
                        userProfile: userProfile,
                        shouldResetInitialSyncState: false,
                        shouldBootstrap: true
                    )
                    return
                }
            }
        } else if let oauthConfiguration, hasOAuthState {
            LoggingService.sync.info("Configuration: OAuth state detected without account, restoring.")
            await applyOAuth(
                configuration: oauthConfiguration,
                configureRepositories: true,
                shouldResetInitialSyncState: false
            )
            if authRepository.currentAccount != nil {
                await bootstrap()
                return
            }
        }

        if oauthConfiguration != nil {
            LoggingService.sync.info("Configuration: OAuth present but no saved auth state. Waiting for sign-in.")
            requiresSetup = true
            return
        }

        LoggingService.sync.info("Configuration: no saved credentials, setup required.")
        requiresSetup = true
    }

    @MainActor
    private func applyOAuth(
        configuration: YouTrackOAuthConfiguration,
        configureRepositories: Bool,
        shouldResetInitialSyncState: Bool = true
    ) async {
        if shouldResetInitialSyncState {
            resetInitialSyncState()
        }
        oauthConfiguration = configuration
        let appAuthRepository = oauthRepository ?? AppAuthRepository(
            configuration: configuration,
            keychain: AppAuthRepository.defaultKeychain()
        )
        oauthRepository = appAuthRepository
        authRepositorySwitcher.replace(with: appAuthRepository)
        supportsBrowserAuth = true
        requiresSetup = appAuthRepository.currentAccount == nil

        guard configureRepositories, let currentAccount = appAuthRepository.currentAccount else {
            updateUserProfile(from: appAuthRepository.currentAccount)
            LoggingService.sync.info("OAuth: configured sign-in repository, awaiting authentication.")
            return
        }

        let storedAccount = configurationStore.upsertAccount(
            baseURL: configuration.apiBaseURL,
            authMethod: .oauth,
            displayName: currentAccount.displayName,
            login: nil,
            userID: currentAccount.id.uuidString,
            allowBaseURLOnlyMatch: true
        )
        refreshAccounts()
        configureStores(for: storedAccount.id)
        updateUserProfile(from: appAuthRepository.currentAccount)
        LoggingService.sync.info("OAuth: configuring repositories.")
        let tokenProvider = YouTrackAPITokenProvider { try await appAuthRepository.currentAccessToken() }
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: configuration.apiBaseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let savedQueryRepository = YouTrackSavedQueryRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let boardRepository = YouTrackIssueBoardRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let projectRepository = YouTrackProjectRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let fieldRepository = YouTrackIssueFieldRepository(configuration: apiConfiguration, monitor: networkMonitor)
        let peopleRepository = YouTrackPeopleRepository(configuration: apiConfiguration, monitor: networkMonitor)
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)
        await boardRepositorySwitcher.replace(with: boardRepository)
        await projectRepositorySwitcher.replace(with: projectRepository)
        await issueFieldRepositorySwitcher.replace(with: fieldRepository)
        await peopleRepositorySwitcher.replace(with: peopleRepository)
        requiresSetup = false
    }
}

struct YouTrackTokenValidationUser: Decodable, Sendable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?

    var displayName: String? {
        fullName ?? name ?? login
    }
}

private enum AttachmentDownloadError: LocalizedError {
    case missingURL
    case invalidResponse
    case http(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Missing attachment URL."
        case .invalidResponse:
            return "Received an invalid response while downloading the attachment."
        case .http(let statusCode, let body):
            if let body, !body.isEmpty {
                return "Attachment download failed with status \(statusCode): \(body)."
            }
            return "Attachment download failed with status \(statusCode)."
        }
    }
}

private extension AppContainer {
    static func apiBaseURL(from baseURL: URL) -> URL {
        if baseURL.lastPathComponent.lowercased() == "api" {
            return baseURL
        }
        return baseURL.appendingPathComponent("api")
    }

    static func requiresSetupForInitialPresentation(activeAccount: StoredAccount?) -> Bool {
        guard let activeAccount else { return true }
        switch activeAccount.authMethod {
        case .oauth:
            return false
        case .token:
            return activeAccount.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func requiresSetupOnLaunch(
        configurationStore: AppConfigurationStore,
        activeAccount: StoredAccount? = nil
    ) -> Bool {
        if let activeAccount = activeAccount ?? configurationStore.activeAccount() {
            switch activeAccount.authMethod {
            case .oauth:
                return !AppAuthRepository.hasSavedAuthState()
            case .token:
                let hasBaseURL = !activeAccount.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return !hasBaseURL ||
                    (configurationStore.loadToken()?.isEmpty != false)
            }
        }

        let hasManualToken = configurationStore.loadBaseURL() != nil &&
            (configurationStore.loadToken()?.isEmpty == false)

        if (try? YouTrackOAuthConfiguration.load()) != nil {
            if AppAuthRepository.hasSavedAuthState() {
                return false
            }
            return !hasManualToken
        }

        return !hasManualToken
    }
}

private extension AppContainer {
    func shouldAttachToken(for url: URL) -> Bool {
        guard let baseHost = configurationStore.loadBaseURL()?.host else {
            return false
        }
        return baseHost == url.host
    }

    func loadSavedQueriesForSidebar() async -> (queries: [SavedQuery], didSyncRemote: Bool) {
        do {
            let remote = try await syncCoordinator.enqueue(label: "Sync saved searches") {
                try await self.savedQueryRepositorySwitcher.fetchSavedQueries()
            }
            await savedQueryLocalStore.saveRemoteSavedQueries(remote)
            return (remote, true)
        } catch {
            let cached = await savedQueryLocalStore.loadSavedQueries()
            return (cached, false)
        }
    }
}

extension AppContainer {
    func refreshSidebarData() async {
        await refreshSidebarDataInternal()
    }
}

private extension AppContainer {
    func refreshSidebarDataInternal() async {
        let startTime = Date()
        LoggingService.sync.info("Sidebar refresh: start.")
        async let savedQueriesResult = loadSavedQueriesForSidebar()
        async let boardsResult: [IssueBoard] = loadBoardsForSidebar()

        let savedQueriesOutcome = await savedQueriesResult
        if savedQueriesOutcome.didSyncRemote {
            recordSavedSearchSyncCompleted()
        }
        let resolvedSavedQueries = savedQueriesOutcome.queries
        let resolvedBoards = await boardsResult
        recordBoardListSyncCompleted()
        cachedSavedQueries = resolvedSavedQueries
        cachedBoards = resolvedBoards
        let duration = Date().timeIntervalSince(startTime)
        LoggingService.sync.info(
            "Sidebar refresh: savedQueries=\(resolvedSavedQueries.count, privacy: .public) boards=\(resolvedBoards.count, privacy: .public) duration=\(duration, privacy: .public)s."
        )

        let resolvedTodoLists = (try? await todoListStore.listDocuments()) ?? cachedTodoLists
        cachedTodoLists = resolvedTodoLists
        let sections = buildSidebarSections(savedQueries: resolvedSavedQueries, boards: resolvedBoards, todoLists: resolvedTodoLists)
        let preferredSelectionID = storedSidebarSelectionID() ?? preferredSelectionID(from: resolvedSavedQueries)
        let previousSelectionID = appState.selectedSidebarItem?.id

        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)

        if let selection = appState.selectedSidebarItem, selection.id != previousSelectionID {
            await loadIssues(for: selection)
        }
        await maybeStartBoardPrefetch(resolvedBoards)

    }

    func buildSidebarSections(savedQueries: [SavedQuery], boards: [IssueBoard], todoLists: [TodoListDocument]) -> [SidebarSection] {
        let visibleSavedQueries = limitedSavedQueries(from: savedQueries)
        let listPage = IssueQuery.Page(size: 50, offset: 0)
        let boardPage = IssueQuery.Page(size: 0, offset: 0)
        let savedInbox = visibleSavedQueries.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }

        var smartItems: [SidebarItem] = []
        if savedInbox == nil {
            smartItems.append(.inbox(page: listPage))
        }
        smartItems.append(.assignedToMe(page: listPage))
        smartItems.append(.createdByMe(page: listPage))
        let todoItems = todoLists.map { SidebarItem.todoList($0, page: listPage) }

        let savedItems = visibleSavedQueries.map { SidebarItem.savedSearch($0, page: listPage) }
        let favoriteBoards = boards.filter(\.isFavorite)
        let boardItems = favoriteBoards.map { SidebarItem.board($0, page: boardPage) }

        var sections: [SidebarSection] = []
        if !smartItems.isEmpty {
            sections.append(SidebarSection(id: "smart", title: "Smart Filters", items: smartItems))
        }
        if !todoItems.isEmpty {
            sections.append(SidebarSection(id: "todo", title: "Todo Lists", items: todoItems))
        } else {
            sections.append(SidebarSection(id: "todo", title: "Todo Lists", items: [], emptyMessage: "No todo lists yet"))
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

    private func inboxSidebarItem() -> SidebarItem? {
        let items = appState.sidebarSections.flatMap(\.items)
        return items.first { item in
            item.isInbox || item.title.caseInsensitiveCompare("Inbox") == .orderedSame
        }
    }

    func rebuildSidebar(preferredSelectionID: SidebarItem.ID? = nil) {
        let sections = buildSidebarSections(savedQueries: cachedSavedQueries, boards: cachedBoards, todoLists: cachedTodoLists)
        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)
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
        defer {
            recordBoardListSyncCompleted()
        }
        do {
            LoggingService.syncVerbose("Board sync: fetching remote boards.")
            let remoteBoards = try await syncCoordinator.enqueue(label: "Sync agile boards") {
                try await self.boardRepositorySwitcher.fetchBoards()
            }
            let mergedBoards = mergeBoardSummaries(remoteBoards: remoteBoards, cachedBoards: cachedBoards)
            await boardLocalStore.saveRemoteBoards(mergedBoards)
            LoggingService.syncVerbose("Board sync: fetched \(remoteBoards.count) boards.")
            let syncDate = Date()
            for board in mergedBoards {
                appState.recordBoardSync(boardID: board.id, at: syncDate)
            }
            return await boardLocalStore.loadBoards()
        } catch {
            LoggingService.sync.error("Board sync: failed with \(error.localizedDescription, privacy: .public).")
            return cachedBoards
        }
    }

    func startBoardPrefetch(_ boards: [IssueBoard]) {
        let page = IssueQuery.Page(size: 0, offset: 0)
        let queries = boards
            .filter(\.isFavorite)
            .map { boardIssueQuery(for: $0, page: page) }
        guard !queries.isEmpty else { return }
        let coordinator = syncCoordinator
        let currentUserID = appState.currentUserID
        let currentUserLogin = appState.currentUserLogin
        let currentUserDisplayName = appState.currentUserDisplayName
        Task.detached(priority: .background) {
            for query in queries {
                _ = await coordinator.refreshIssuesWithStatus(
                    using: query,
                    currentUserID: currentUserID,
                    currentUserLogin: currentUserLogin,
                    currentUserDisplayName: currentUserDisplayName,
                    paginate: true
                )
            }
        }
    }

    func maybeStartBoardPrefetch(_ boards: [IssueBoard]? = nil) async {
        guard appState.hasCompletedInitialSync, !hasStartedBoardPrefetch else { return }
        hasStartedBoardPrefetch = true
        let resolvedBoards: [IssueBoard]
        if let boards {
            resolvedBoards = boards
        } else {
            resolvedBoards = await boardLocalStore.loadBoards()
        }
        startBoardPrefetch(resolvedBoards)
    }

    private func issueQuery(for selection: SidebarItem) -> IssueQuery {
        guard selection.isBoard else { return selection.query }
        let page = selection.query.page
        let board = boardForSelection(selection) ?? IssueBoard(
            id: selection.boardID ?? selection.id,
            name: selection.title,
            isFavorite: true,
            projectNames: []
        )
        return boardIssueQuery(for: board, page: page)
    }

    private func boardNeedsDetail(_ board: IssueBoard?) -> Bool {
        guard let board else { return true }
        let columnField = board.columnFieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needsColumns = board.columns.isEmpty || columnField.isEmpty
        let needsProjects = board.projectNames.isEmpty
        let needsSwimlaneField = board.swimlaneSettings.isEnabled &&
            (board.swimlaneSettings.fieldName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return needsColumns || needsProjects || needsSwimlaneField
    }

    private func mergeBoardSummaries(
        remoteBoards: [IssueBoard],
        cachedBoards: [IssueBoard]
    ) -> [IssueBoard] {
        guard !cachedBoards.isEmpty else { return remoteBoards }
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedBoards.map { ($0.id, $0) })

        return remoteBoards.map { remote in
            guard let cached = cachedByID[remote.id] else { return remote }
            let detailSource = boardNeedsDetail(cached) ? remote : cached
            return IssueBoard(
                id: remote.id,
                name: remote.name,
                isFavorite: remote.isFavorite,
                projectNames: detailSource.projectNames,
                sprints: detailSource.sprints,
                currentSprintID: detailSource.currentSprintID,
                sprintFieldName: detailSource.sprintFieldName,
                columnFieldName: detailSource.columnFieldName,
                columns: detailSource.columns,
                swimlaneSettings: detailSource.swimlaneSettings,
                orphansAtTheTop: detailSource.orphansAtTheTop,
                hideOrphansSwimlane: detailSource.hideOrphansSwimlane
            )
        }
    }

    private func applyingFavorite(_ isFavorite: Bool?, to board: IssueBoard) -> IssueBoard {
        guard let isFavorite, isFavorite != board.isFavorite else { return board }
        return IssueBoard(
            id: board.id,
            name: board.name,
            isFavorite: isFavorite,
            projectNames: board.projectNames,
            sprints: board.sprints,
            currentSprintID: board.currentSprintID,
            sprintFieldName: board.sprintFieldName,
            columnFieldName: board.columnFieldName,
            columns: board.columns,
            swimlaneSettings: board.swimlaneSettings,
            orphansAtTheTop: board.orphansAtTheTop,
            hideOrphansSwimlane: board.hideOrphansSwimlane
        )
    }

    private func boardIdentifier(for selection: SidebarItem, resolvedBoard: IssueBoard? = nil) -> String? {
        resolvedBoard?.id ?? selection.boardID ?? selection.board?.id
    }

    private func recordBoardDataEvent(_ message: String, boardID: String?) {
        // Recording mutates @Published state on AppState; skip entirely unless the
        // diagnostics overlay is enabled so routine loads don't invalidate every observer.
        guard AppDebugSettings.showBoardDiagnostics, let boardID else { return }
        appState.recordBoardDataSourceEvent(boardID: boardID, message: message)
    }

    private func recordIssueListDataEvent(_ message: String, listID: String?) {
        guard AppDebugSettings.showIssueListDiagnostics, let listID else { return }
        appState.recordIssueListDataSourceEvent(listID: listID, message: message)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int(duration * 1000)) ms"
        }
        return String(format: "%.2f s", duration)
    }

    private func durationText(since start: TimeInterval) -> String {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
        return formattedDuration(elapsed)
    }

    private func resolveBoardDetailsIfNeeded(for selection: SidebarItem) async -> IssueBoard? {
        guard selection.isBoard else { return selection.board }
        let current = selection.board
        guard boardNeedsDetail(current) else { return current }
        guard let boardID = selection.boardID ?? current?.id else { return current }

        let fetchStart = ProcessInfo.processInfo.systemUptime
        do {
            recordBoardDataEvent("Board details fetch started.", boardID: boardID)
            let detail = try await boardRepositorySwitcher.fetchBoard(id: boardID)
            let resolved = applyingFavorite(current?.isFavorite, to: detail)
            await boardLocalStore.saveBoard(resolved)
            let durationLabel = durationText(since: fetchStart)
            recordBoardDataEvent("Board details fetched in \(durationLabel).", boardID: boardID)
            return resolved
        } catch {
            let durationLabel = durationText(since: fetchStart)
            recordBoardDataEvent(
                "Board details fetch failed in \(durationLabel): \(error.localizedDescription)",
                boardID: boardID
            )
            return current
        }
    }

    private func boardForSelection(_ selection: SidebarItem) -> IssueBoard? {
        guard selection.isBoard else { return nil }
        if let board = selection.board {
            return board
        }
        return IssueBoard(
            id: selection.boardID ?? selection.id,
            name: selection.title,
            isFavorite: true,
            projectNames: []
        )
    }

    private func loadCachedSprintIssueIDsIfNeeded(
        board: IssueBoard?,
        filter: BoardSprintFilter?,
        boardID: String?
    ) async -> Set<String>? {
        guard let board, let filter, case .sprint(let sprintID) = filter else { return nil }
        let loadStart = ProcessInfo.processInfo.systemUptime
        if let cached = await syncCoordinator.loadCachedSprintIssueIDs(agileID: board.id, sprintID: sprintID) {
            let durationLabel = durationText(since: loadStart)
            LoggingService.syncVerbose(
                "Local DB: sprint issue IDs loaded (\(cached.count)) in \(durationLabel) for \(board.id)."
            )
            recordBoardDataEvent(
                "Local DB sprint issue IDs loaded: \(cached.count) in \(durationLabel).",
                boardID: boardID
            )
            return Set(cached)
        }
        let durationLabel = durationText(since: loadStart)
        LoggingService.syncVerbose(
            "Local DB: sprint issue IDs cache miss in \(durationLabel) for \(board.id)."
        )
        recordBoardDataEvent("Local DB sprint issue IDs cache miss (\(durationLabel)).", boardID: boardID)
        return nil
    }

    private func fetchSprintIssueIDsFromRemoteIfNeeded(
        board: IssueBoard?,
        filter: BoardSprintFilter?,
        boardID: String?
    ) async -> Set<String>? {
        guard let board, let filter, case .sprint(let sprintID) = filter else { return nil }
        let fetchStart = ProcessInfo.processInfo.systemUptime
        do {
            recordBoardDataEvent("Sprint issue IDs fetch started (sprintID: \(sprintID)).", boardID: boardID)
            let ids = try await issueRepositorySwitcher.fetchSprintIssueIDs(agileID: board.id, sprintID: sprintID)
            await syncCoordinator.saveSprintIssueIDs(agileID: board.id, sprintID: sprintID, issueIDs: ids)
            guard !ids.isEmpty else {
                let durationLabel = durationText(since: fetchStart)
                recordBoardDataEvent("Sprint issue IDs fetched: 0 in \(durationLabel).", boardID: boardID)
                return Set<String>()
            }
            let durationLabel = durationText(since: fetchStart)
            recordBoardDataEvent("Sprint issue IDs fetched: \(ids.count) in \(durationLabel).", boardID: boardID)
            return Set(ids)
        } catch {
            let durationLabel = durationText(since: fetchStart)
            recordBoardDataEvent(
                "Sprint issue IDs fetch failed in \(durationLabel): \(error.localizedDescription)",
                boardID: boardID
            )
            return nil
        }
    }

    private func applySprintFilterIfNeeded(
        _ issues: [IssueSummary],
        board: IssueBoard?,
        filter: BoardSprintFilter?,
        sprintIssueIDs: Set<String>?
    ) -> [IssueSummary] {
        guard let board, let filter else { return issues }
        switch filter {
        case .backlog:
            return board.filteredIssues(issues, sprintFilter: filter)
        case .sprint:
            if let sprintIssueIDs {
                return issues.filter { sprintIssueIDs.contains($0.readableID) }
            }
            return board.filteredIssues(issues, sprintFilter: filter)
        }
    }

    private func boardIssueQuery(for board: IssueBoard, page: IssueQuery.Page) -> IssueQuery {
        let filter = appState.sprintFilter(for: board)
        let resolved = board.resolveSprintFilter(filter)
        if resolved != filter {
            appState.updateSprintFilter(resolved, for: board.id)
        }
        let rawQuery = IssueQuery.boardQuery(boardName: board.name, sprintName: nil)
        return IssueQuery(
            rawQuery: rawQuery,
            search: "",
            filters: [],
            sort: .updated(descending: true),
            page: page
        )
    }

    func refreshIssueSeenUpdates(for issues: [IssueSummary], shouldSeedInitialRead: Bool = false) async {
        guard !issues.isEmpty else { return }
        let updates = await syncCoordinator.loadIssueSeenUpdates(for: issues.map(\.id))
        appState.updateIssueSeenUpdates(updates)
        if shouldSeedInitialRead {
            markIssuesSeen(issues)
        }
    }

    private func resolveIssueByReadableID(_ readableID: String) async -> IssueSummary? {
        let normalized = normalizeIssueReadableID(readableID)
        guard !normalized.isEmpty else { return nil }
        if let inMemory = appState.issues.first(where: { normalizeIssueReadableID($0.readableID) == normalized }) {
            return inMemory
        }

        let cached = await syncCoordinator.loadIssues(readableIDs: [normalized])
        if let match = cached.first(where: { normalizeIssueReadableID($0.readableID) == normalized }) {
            return match
        }

        let page = IssueQuery.Page(size: 20, offset: 0)
        return await fetchIssueByReadableID(normalized, page: page)
    }

    private func fetchIssueByReadableID(_ readableID: String, page: IssueQuery.Page) async -> IssueSummary? {
        let queryCandidates: [IssueQuery] = [
            IssueQuery.saved("id: {\(readableID)}", page: page),
            IssueQuery.saved(readableID, page: page)
        ]
        for query in queryCandidates {
            guard let fetched = try? await issueRepositorySwitcher.fetchIssues(query: query),
                  !fetched.isEmpty else {
                continue
            }
            if let exactMatch = fetched.first(where: { normalizeIssueReadableID($0.readableID) == readableID }) {
                return exactMatch
            }
            if let first = fetched.first {
                return first
            }
        }
        return nil
    }

    private func normalizeIssueReadableID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func todoChecklistStatusPatch(for issue: IssueSummary, isClosed: Bool) async -> IssuePatch {
        if let option = await preferredStatusOption(for: issue, isClosed: isClosed) {
            return IssuePatch(
                title: nil,
                description: nil,
                status: nil,
                statusOption: option,
                priority: nil,
                issueReadableID: issue.readableID
            )
        }

        return IssuePatch(
            title: nil,
            description: nil,
            status: isClosed ? .done : .open,
            priority: nil,
            issueReadableID: issue.readableID
        )
    }

    private func preferredStatusOption(for issue: IssueSummary, isClosed: Bool) async -> IssueFieldOption? {
        let options = await loadStatusOptions(for: issue)
        guard !options.isEmpty else { return nil }

        let normalizedCurrent = normalizeTodoStatusName(issue.status.displayName)
        if isClosed, isClosedStatusName(normalizedCurrent) {
            return nil
        }
        if !isClosed, isOpenStatusName(normalizedCurrent) {
            return nil
        }

        let scored = options.map { option in
            (option, todoStatusScore(for: option, isClosed: isClosed))
        }

        if let exact = scored.first(where: { $0.1 == 3 })?.0 {
            return exact
        }
        if let strong = scored.first(where: { $0.1 == 2 })?.0 {
            return strong
        }
        return scored.first(where: { $0.1 == 1 })?.0
    }

    private func todoStatusScore(for option: IssueFieldOption, isClosed: Bool) -> Int {
        let candidates = [option.displayName, option.name].map(normalizeTodoStatusName)
        if candidates.contains(where: { isClosed ? isClosedStatusName($0) : isOpenStatusName($0) }) {
            return 3
        }
        if candidates.contains(where: { isClosed ? containsClosedStatusHint($0) : containsOpenStatusHint($0) }) {
            return 2
        }
        return 0
    }

    private func normalizeTodoStatusName(_ value: String) -> String {
        let lowered = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowered.isEmpty else { return "" }
        return lowered.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isClosedStatusName(_ normalized: String) -> Bool {
        [
            "done",
            "closed",
            "resolved",
            "fixed",
            "completed",
            "complete"
        ].contains(normalized)
    }

    private func isOpenStatusName(_ normalized: String) -> Bool {
        [
            "open",
            "to do",
            "todo",
            "backlog",
            "new",
            "submitted"
        ].contains(normalized)
    }

    private func containsClosedStatusHint(_ normalized: String) -> Bool {
        let hints = ["done", "close", "resolv", "fix", "complete"]
        return hints.contains(where: { normalized.contains($0) })
    }

    private func containsOpenStatusHint(_ normalized: String) -> Bool {
        let hints = ["open", "todo", "to do", "backlog", "new", "submit", "in progress"]
        return hints.contains(where: { normalized.contains($0) })
    }

}

extension AppContainer {
    func loadProjects() async -> [IssueProject] {
        do {
            let projects = try await projectRepositorySwitcher.fetchProjects()
            cachedProjects = projects
            return projects
        } catch {
            return []
        }
    }

    func loadFields(for projectID: String) async -> [IssueField] {
        do {
            return try await issueFieldRepositorySwitcher.fetchFields(projectID: projectID)
        } catch {
            return []
        }
    }

    func loadBundleOptions(bundleID: String, kind: IssueFieldKind) async -> [IssueFieldOption] {
        do {
            return try await issueFieldRepositorySwitcher.fetchBundleOptions(bundleID: bundleID, kind: kind)
        } catch {
            return []
        }
    }

    func searchPeople(query: String?, projectID: String?) async -> [IssueFieldOption] {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedProjectID.isEmpty {
            let projectPeople: [IssueFieldOption]
            if let cached = assigneeOptionsCache[trimmedProjectID] {
                projectPeople = cached
            } else {
                do {
                    let fetched = try await peopleRepositorySwitcher.fetchPeople(query: nil, projectID: trimmedProjectID)
                    let sorted = sortPeopleOptions(fetched)
                    assigneeOptionsCache[trimmedProjectID] = sorted
                    projectPeople = sorted
                } catch {
                    return []
                }
            }

            if trimmedQuery.isEmpty {
                return projectPeople
            }
            return filterPeopleOptions(projectPeople, matching: trimmedQuery)
        }

        do {
            return try await peopleRepositorySwitcher.fetchPeople(
                query: trimmedQuery.isEmpty ? nil : trimmedQuery,
                projectID: nil
            )
        } catch {
            return []
        }
    }

    func resolveProjectID(named name: String) async -> String? {
        await resolveProject(named: name)?.id
    }

    func loadStatusOptions(for issue: IssueSummary) async -> [IssueFieldOption] {
        let trimmedProject = issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProject.isEmpty else { return [] }
        if let project = await resolveProject(named: trimmedProject) {
            return await loadStatusOptions(for: project)
        }
        return []
    }

    func loadStatusOptions(for issues: [IssueSummary]) async -> [IssueFieldOption] {
        guard !issues.isEmpty else { return [] }
        let projectNames = Set(issues.map { $0.projectName.trimmingCharacters(in: .whitespacesAndNewlines) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var combined: [IssueFieldOption] = []
        for name in projectNames where !name.isEmpty {
            if let project = await resolveProject(named: name) {
                let options = await loadStatusOptions(for: project)
                combined.append(contentsOf: options)
            }
        }
        return combined
    }

    func loadPriorityOptions(for issue: IssueSummary) async -> [IssueFieldOption] {
        let trimmedProject = issue.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProject.isEmpty else { return [] }
        if let project = await resolveProject(named: trimmedProject) {
            return await loadPriorityOptions(for: project)
        }
        return []
    }

    func loadPriorityOptions(for issues: [IssueSummary]) async -> [IssueFieldOption] {
        guard !issues.isEmpty else { return [] }
        let projectNames = Set(issues.map { $0.projectName.trimmingCharacters(in: .whitespacesAndNewlines) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var combined: [IssueFieldOption] = []
        for name in projectNames where !name.isEmpty {
            if let project = await resolveProject(named: name) {
                let options = await loadPriorityOptions(for: project)
                combined.append(contentsOf: options)
            }
        }
        return combined
    }

}

private extension AppContainer {
    func resolveProject(named name: String) async -> IssueProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cachedProjects.first(where: { projectMatches($0, name: trimmed) }) {
            return cached
        }

        do {
            let projects = try await projectRepositorySwitcher.fetchProjects()
            cachedProjects = projects
            return projects.first(where: { projectMatches($0, name: trimmed) })
        } catch {
            return nil
        }
    }

    func sortedOptions(_ options: [IssueFieldOption]) -> [IssueFieldOption] {
        options.sorted { left, right in
            let leftOrdinal = left.ordinal ?? Int.max
            let rightOrdinal = right.ordinal ?? Int.max
            if leftOrdinal != rightOrdinal {
                return leftOrdinal < rightOrdinal
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    func sortPeopleOptions(_ options: [IssueFieldOption]) -> [IssueFieldOption] {
        options.sorted { left, right in
            left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    func filterPeopleOptions(_ options: [IssueFieldOption], matching query: String) -> [IssueFieldOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return options }

        return options.filter { option in
            [option.displayName, option.name, option.login ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    func loadStatusOptions(for project: IssueProject) async -> [IssueFieldOption] {
        if let cached = statusOptionsCache[project.id] {
            return cached
        }

        let fields = (try? await issueFieldRepositorySwitcher.fetchFields(projectID: project.id)) ?? []
        guard let statusField = findStatusField(in: fields),
              let bundleID = statusField.bundleID,
              statusField.kind.usesOptions else {
            return []
        }

        let options = (try? await issueFieldRepositorySwitcher.fetchBundleOptions(bundleID: bundleID, kind: statusField.kind)) ?? []
        let sorted = sortedOptions(options)
        statusOptionsCache[project.id] = sorted
        return sorted
    }

    func findStatusField(in fields: [IssueField]) -> IssueField? {
        let namedMatches = fields.filter { field in
            let names = [field.name, field.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return names.contains("state") || names.contains("status")
        }

        if let stateMatch = namedMatches.first(where: { $0.kind == .state }) {
            return stateMatch
        }
        if let namedMatch = namedMatches.first {
            return namedMatch
        }
        return fields.first(where: { $0.kind == .state })
    }

    func loadPriorityOptions(for project: IssueProject) async -> [IssueFieldOption] {
        if let cached = priorityOptionsCache[project.id] {
            return cached
        }

        let fields = (try? await issueFieldRepositorySwitcher.fetchFields(projectID: project.id)) ?? []
        guard let priorityField = findPriorityField(in: fields),
              let bundleID = priorityField.bundleID,
              priorityField.kind.usesOptions else {
            return []
        }

        let options = (try? await issueFieldRepositorySwitcher.fetchBundleOptions(bundleID: bundleID, kind: priorityField.kind)) ?? []
        let sorted = sortedOptions(options)
        priorityOptionsCache[project.id] = sorted
        return sorted
    }

    func findPriorityField(in fields: [IssueField]) -> IssueField? {
        let namedMatches = fields.filter { field in
            let names = [field.name, field.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return names.contains("priority")
        }

        if let match = namedMatches.first(where: { $0.kind == .enumeration }) {
            return match
        }
        return namedMatches.first
    }

    func projectMatches(_ project: IssueProject, name: String) -> Bool {
        if let shortName = project.shortName,
           shortName.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        return project.name.caseInsensitiveCompare(name) == .orderedSame
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
    @Published var draftParentIssueReadableID: String = ""
    @Published var draftFields: [IssueDraftField] = []
    @Published var draftAttachments: [IssueAttachmentDraft] = []

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
        draftParentIssueReadableID = ""
        draftFields = []
        draftAttachments = []
    }

    func applyDraft(_ draft: IssueDraft) {
        draftTitle = draft.title
        draftDescription = draft.description
        draftProjectID = draft.projectID
        draftModule = draft.module ?? ""
        draftAssigneeID = draft.assigneeID ?? ""
        draftPriority = draft.priority
        draftParentIssueReadableID = draft.parentIssueReadableID ?? ""
        draftFields = draft.customFields
        draftAttachments = draft.attachments
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
        if draftParentIssueReadableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftParentIssueReadableID = draft.parentIssueReadableID ?? ""
        }
        applyDefaultFields(draft.customFields)
    }

    func makeDraft() -> IssueDraft? {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedProject.isEmpty else { return nil }

        let trimmedDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModule = draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssignee = draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = draftParentIssueReadableID.trimmingCharacters(in: .whitespacesAndNewlines)

        return IssueDraft(
            title: trimmedTitle,
            description: trimmedDescription,
            projectID: trimmedProject,
            module: trimmedModule.isEmpty ? nil : trimmedModule,
            priority: draftPriority,
            assigneeID: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            parentIssueReadableID: trimmedParent.isEmpty ? nil : trimmedParent,
            customFields: normalizedDraftFields(excluding: ["priority", "assignee", "subsystem", "module"]),
            attachments: draftAttachments
        )
    }

    func draftSnapshot() -> IssueDraft {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModule = draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssignee = draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = draftParentIssueReadableID.trimmingCharacters(in: .whitespacesAndNewlines)

        return IssueDraft(
            title: trimmedTitle,
            description: trimmedDescription,
            projectID: trimmedProject,
            module: trimmedModule.isEmpty ? nil : trimmedModule,
            priority: draftPriority,
            assigneeID: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            parentIssueReadableID: trimmedParent.isEmpty ? nil : trimmedParent,
            customFields: normalizedDraftFields(excluding: ["priority", "assignee", "subsystem", "module"]),
            attachments: draftAttachments
        )
    }

    func resetDraft() {
        draftTitle = ""
        draftDescription = ""
        draftProjectID = ""
        draftModule = ""
        draftAssigneeID = ""
        draftPriority = .normal
        draftParentIssueReadableID = ""
        draftFields = []
        draftAttachments = []
    }

    func updateDraftFields(using fields: [IssueField]) {
        let existingByName = Dictionary(uniqueKeysWithValues: draftFields.map { ($0.normalizedName, $0) })
        var updated: [IssueDraftField] = []
        updated.reserveCapacity(fields.count)

        for field in fields {
            if let existing = existingByName[field.normalizedName] {
                updated.append(IssueDraftField(name: field.name, kind: field.kind, allowsMultiple: field.allowsMultiple, value: existing.value))
            } else {
                updated.append(IssueDraftField(name: field.name, kind: field.kind, allowsMultiple: field.allowsMultiple, value: .none))
            }
        }
        draftFields = updated
    }

    func value(for field: IssueField) -> IssueDraftFieldValue {
        if let existing = draftFields.first(where: { $0.normalizedName == field.normalizedName }) {
            return existing.value
        }
        if field.normalizedName == "priority" {
            return .string(draftPriority.displayName)
        }
        if field.normalizedName == "assignee" {
            let trimmed = draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .string(trimmed)
            }
        }
        if field.normalizedName == "subsystem" || field.normalizedName == "module" {
            let trimmed = draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .string(trimmed)
            }
        }
        return .none
    }

    func setValue(_ value: IssueDraftFieldValue, for field: IssueField) {
        if field.normalizedName == "priority" {
            if case let .option(option) = value {
                draftPriority = IssuePriority.from(displayName: option.displayName) ?? draftPriority
            } else if case let .string(raw) = value {
                draftPriority = IssuePriority.from(displayName: raw) ?? draftPriority
            }
        }
        if field.normalizedName == "assignee" {
            if case let .option(option) = value {
                draftAssigneeID = option.login ?? option.name
            } else if case let .string(raw) = value {
                draftAssigneeID = raw
            }
        }
        if field.normalizedName == "subsystem" || field.normalizedName == "module" {
            if case let .string(raw) = value {
                draftModule = raw
            } else if case let .option(option) = value {
                draftModule = option.displayName
            }
        }

        if let index = draftFields.firstIndex(where: { $0.normalizedName == field.normalizedName }) {
            draftFields[index] = IssueDraftField(name: field.name, kind: field.kind, allowsMultiple: field.allowsMultiple, value: value)
        } else {
            draftFields.append(IssueDraftField(name: field.name, kind: field.kind, allowsMultiple: field.allowsMultiple, value: value))
        }
    }

    private func applyDefaultFields(_ fields: [IssueDraftField]) {
        guard !fields.isEmpty else { return }
        var current = draftFields
        for field in fields {
            if let index = current.firstIndex(where: { $0.normalizedName == field.normalizedName }) {
                if current[index].value.isEmpty {
                    current[index] = field
                }
            } else {
                current.append(field)
            }
        }
        draftFields = current
    }

    private func normalizedDraftFields(excluding excludedNames: [String]) -> [IssueDraftField] {
        let excluded = Set(excludedNames.map { $0.lowercased() })
        return draftFields.filter { !excluded.contains($0.normalizedName) && !$0.value.isEmpty }
    }
}

@MainActor
final class CommandPaletteCoordinator {
    private let router: WindowRouter
    private let appState: AppState

    init(router: WindowRouter, appState: AppState) {
        self.router = router
        self.appState = appState
    }

    func open() {
        appState.presentCommandPalette()
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

extension AppContainer: TodoListMarkdownStoring, TodoIssueLinkHandling, TodoListManaging {}

private struct PreviewIssueRepository: IssueRepository {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        AppStatePlaceholder.sampleIssues()
    }

    func fetchSprintIssueIDs(agileID: String, sprintID: String) async throws -> [String] {
        []
    }

    func fetchIssueDetail(issue: IssueSummary) async throws -> IssueDetail {
        let comment = IssueComment(
            id: "preview-comment-1",
            author: issue.reporter,
            createdAt: issue.updatedAt.addingTimeInterval(-1800),
            text: "Preview comment for **\(issue.readableID)**."
        )
        return IssueDetail(
            id: issue.id,
            readableID: issue.readableID,
            title: issue.title,
            description: "This is a _preview_ description rendered as markdown.",
            reporter: issue.reporter,
            createdAt: issue.updatedAt.addingTimeInterval(-7200),
            updatedAt: issue.updatedAt,
            comments: [comment]
        )
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }

    func addComment(issueReadableID: String, text: String) async throws -> IssueComment {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }

    func uploadAttachments(issueReadableID: String, attachments: [IssueAttachmentDraft]) async throws -> [IssueAttachment] {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }

    func linkSubIssue(parentReadableID: String, childReadableID: String) async throws {
        throw YouTrackAPIError.http(statusCode: 501, body: "Preview repository does not support mutations")
    }
}

private struct EmptyIssueRepository: IssueRepository {
    func fetchIssues(query: IssueQuery) async throws -> [IssueSummary] {
        []
    }

    func fetchSprintIssueIDs(agileID: String, sprintID: String) async throws -> [String] {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func fetchIssueDetail(issue: IssueSummary) async throws -> IssueDetail {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func createIssue(draft: IssueDraft) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async throws -> IssueSummary {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func addComment(issueReadableID: String, text: String) async throws -> IssueComment {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func uploadAttachments(issueReadableID: String, attachments: [IssueAttachmentDraft]) async throws -> [IssueAttachment] {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }

    func linkSubIssue(parentReadableID: String, childReadableID: String) async throws {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue repository is not configured")
    }
}

private struct EmptyProjectRepository: ProjectRepository {
    func fetchProjects() async throws -> [IssueProject] {
        []
    }
}

private struct EmptyIssueFieldRepository: IssueFieldRepository {
    func fetchFields(projectID: String) async throws -> [IssueField] {
        []
    }

    func fetchBundleOptions(bundleID: String, kind: IssueFieldKind) async throws -> [IssueFieldOption] {
        []
    }
}

private struct EmptyPeopleRepository: PeopleRepository {
    func fetchPeople(query: String?, projectID: String?) async throws -> [IssueFieldOption] {
        []
    }
}

private struct EmptySavedQueryRepository: SavedQueryRepository {
    func fetchSavedQueries() async throws -> [SavedQuery] {
        []
    }

    func deleteSavedQuery(id: String) async throws {
        throw YouTrackAPIError.http(statusCode: 503, body: "Saved query repository is not configured")
    }
}

private struct EmptyIssueBoardRepository: IssueBoardRepository {
    func fetchBoards() async throws -> [IssueBoard] {
        []
    }

    func fetchBoard(id: String) async throws -> IssueBoard {
        throw YouTrackAPIError.http(statusCode: 503, body: "Issue board repository is not configured")
    }
}

private struct PreviewProjectRepository: ProjectRepository {
    func fetchProjects() async throws -> [IssueProject] {
        [
            IssueProject(id: "0-0", name: "YouTrek", shortName: "YT", isArchived: false),
            IssueProject(id: "0-1", name: "Mobile App", shortName: "MOB", isArchived: false)
        ]
    }
}

private struct PreviewIssueFieldRepository: IssueFieldRepository {
    func fetchFields(projectID: String) async throws -> [IssueField] {
        [
            IssueField(
                id: "priority",
                name: "Priority",
                localizedName: nil,
                kind: .enumeration,
                isRequired: true,
                allowsMultiple: false,
                bundleID: nil,
                options: [
                    IssueFieldOption(id: "p1", name: "Critical"),
                    IssueFieldOption(id: "p2", name: "High"),
                    IssueFieldOption(id: "p3", name: "Normal"),
                    IssueFieldOption(id: "p4", name: "Low")
                ],
                ordinal: 1
            ),
            IssueField(
                id: "assignee",
                name: "Assignee",
                localizedName: nil,
                kind: .user,
                isRequired: false,
                allowsMultiple: false,
                bundleID: nil,
                options: [
                    IssueFieldOption(id: "u1", name: "taylor", displayName: "Taylor Atkins"),
                    IssueFieldOption(id: "u2", name: "morgan", displayName: "Morgan Chan"),
                    IssueFieldOption(id: "u3", name: "ola", displayName: "Ola Svensson")
                ],
                ordinal: 2
            ),
            IssueField(
                id: "type",
                name: "Type",
                localizedName: nil,
                kind: .enumeration,
                isRequired: true,
                allowsMultiple: false,
                bundleID: nil,
                options: [
                    IssueFieldOption(id: "t1", name: "Bug"),
                    IssueFieldOption(id: "t2", name: "Task"),
                    IssueFieldOption(id: "t3", name: "Feature")
                ],
                ordinal: 3
            ),
            IssueField(
                id: "estimate",
                name: "Story Points",
                localizedName: nil,
                kind: .integer,
                isRequired: false,
                allowsMultiple: false,
                bundleID: nil,
                options: [],
                ordinal: 4
            ),
            IssueField(
                id: "due",
                name: "Due Date",
                localizedName: nil,
                kind: .date,
                isRequired: false,
                allowsMultiple: false,
                bundleID: nil,
                options: [],
                ordinal: 5
            )
        ]
    }

    func fetchBundleOptions(bundleID: String, kind: IssueFieldKind) async throws -> [IssueFieldOption] {
        []
    }
}

private struct PreviewPeopleRepository: PeopleRepository {
    func fetchPeople(query: String?, projectID: String?) async throws -> [IssueFieldOption] {
        [
            IssueFieldOption(id: "u1", name: "taylor", displayName: "Taylor Atkins"),
            IssueFieldOption(id: "u2", name: "morgan", displayName: "Morgan Chan"),
            IssueFieldOption(id: "u3", name: "ola", displayName: "Ola Svensson"),
            IssueFieldOption(id: "u4", name: "priya", displayName: "Priya Desai")
        ]
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

    func fetchBoard(id: String) async throws -> IssueBoard {
        let boards = try await fetchBoards()
        if let match = boards.first(where: { $0.id == id }) {
            return match
        }
        throw YouTrackAPIError.invalidResponse
    }
}

actor TodoListMarkdownStore {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(accountID: UUID?, fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        let resolvedBaseDirectory: URL
        if let baseDirectory {
            resolvedBaseDirectory = baseDirectory
        } else if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedBaseDirectory = appSupportDirectory
        } else {
            resolvedBaseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        var directory = resolvedBaseDirectory
            .appendingPathComponent("YouTrek", isDirectory: true)
            .appendingPathComponent("TodoLists", isDirectory: true)
        directory.appendPathComponent(accountID?.uuidString ?? "default", isDirectory: true)
        self.directoryURL = directory
    }

    func listDocuments() throws -> [TodoListDocument] {
        try ensureDirectoryExists()
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let markdownURLs = fileURLs.filter { $0.pathExtension.lowercased() == "md" }
        let documents = markdownURLs.compactMap { document(from: $0) }
        return documents.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func createDocument(named name: String) throws -> TodoListDocument {
        try ensureDirectoryExists()
        let id = UUID()
        let fileURL = documentURL(for: id)
        let markdown = "# \(name)\n\n"
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        guard let document = document(from: fileURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    func renameDocument(id: UUID, to name: String) throws {
        let markdown = (try? loadMarkdown(id: id)) ?? ""
        let updated = replacingTopLevelTitle(in: markdown, with: name)
        try saveMarkdown(id: id, markdown: updated)
    }

    func deleteDocument(id: UUID) throws {
        let fileURL = documentURL(for: id)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        let attachmentsDirectory = attachmentsDirectoryURL(for: id)
        if fileManager.fileExists(atPath: attachmentsDirectory.path) {
            try fileManager.removeItem(at: attachmentsDirectory)
        }
    }

    func loadMarkdown(id: UUID) throws -> String {
        let fileURL = documentURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func saveMarkdown(id: UUID, markdown: String) throws {
        try ensureDirectoryExists()
        let fileURL = documentURL(for: id)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func saveImageAttachment(id: UUID, data: Data, preferredFileExtension: String) throws -> String {
        try ensureDirectoryExists()
        let extensionValue = normalizedAttachmentFileExtension(preferredFileExtension)
        let fileName = "\(UUID().uuidString).\(extensionValue)"
        let attachmentsDirectory = attachmentsDirectoryURL(for: id)
        if !fileManager.fileExists(atPath: attachmentsDirectory.path) {
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }
        let fileURL = attachmentsDirectory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileName
    }

    func loadImageAttachment(id: UUID, reference: String) throws -> Data? {
        let normalizedReference = normalizedAttachmentReference(reference)
        guard !normalizedReference.isEmpty else { return nil }
        let fileURL = attachmentsDirectoryURL(for: id).appendingPathComponent(normalizedReference, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    private func documentURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    private func attachmentsDirectoryURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).assets", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func document(from url: URL) -> TodoListDocument? {
        let baseName = url.deletingPathExtension().lastPathComponent
        guard let id = UUID(uuidString: baseName) else { return nil }
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let name = parsedName(from: markdown, fallbackID: id)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let updatedAt = values?.contentModificationDate ?? Date.distantPast
        return TodoListDocument(id: id, name: name, fileName: url.lastPathComponent, updatedAt: updatedAt)
    }

    private func parsedName(from markdown: String, fallbackID: UUID) -> String {
        let lines = markdown.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" || $0.isWhitespace }.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }
            break
        }
        return "Todo \(fallbackID.uuidString.prefix(4))"
    }

    private func replacingTopLevelTitle(in markdown: String, with name: String) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return markdown }
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("#") {
                lines[index] = "# \(normalizedName)"
                return lines.joined(separator: "\n")
            }
            break
        }
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "# \(normalizedName)\n\n"
        }
        return "# \(normalizedName)\n\n\(markdown)"
    }

    private func normalizedAttachmentReference(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let raw: String
        if trimmed.hasPrefix("todo-attachment://") {
            raw = String(trimmed.dropFirst("todo-attachment://".count))
        } else if trimmed.hasPrefix("todo-attachment:") {
            raw = String(trimmed.dropFirst("todo-attachment:".count))
        } else {
            raw = trimmed
        }
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/")
        return cleaned.split(separator: "/").last.map(String.init) ?? cleaned
    }

    private func normalizedAttachmentFileExtension(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { allowed.contains($0) }
        return normalized.isEmpty ? "png" : normalized
    }
}
