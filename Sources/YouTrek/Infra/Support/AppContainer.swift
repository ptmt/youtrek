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
    private let projectRepositorySwitcher: SwitchableProjectRepository
    private let issueFieldRepositorySwitcher: SwitchableIssueFieldRepository
    private let peopleRepositorySwitcher: SwitchablePeopleRepository
    private let boardLocalStore: IssueBoardLocalStore
    private var lastLoadedIssueQuery: IssueQuery?
    private var cachedProjects: [IssueProject] = []
    private var cachedSavedQueries: [SavedQuery] = []
    private var cachedBoards: [IssueBoard] = []
    private var statusOptionsCache: [String: [IssueFieldOption]] = [:]
    private var priorityOptionsCache: [String: [IssueFieldOption]] = [:]
    private var hasStartedBoardPrefetch = false
    private var appStateCancellable: AnyCancellable?
    private var draftSaveTask: Task<Void, Never>?
    @Published private(set) var supportsBrowserAuth: Bool = false
    @Published private(set) var requiresSetup: Bool = true
    private var oauthConfiguration: YouTrackOAuthConfiguration?
    private var oauthRepository: AppAuthRepository?

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
        self.projectRepositorySwitcher = projectRepositorySwitcher
        self.issueFieldRepositorySwitcher = issueFieldRepositorySwitcher
        self.peopleRepositorySwitcher = peopleRepositorySwitcher
        self.boardLocalStore = boardLocalStore
        self.appStateCancellable = appState.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer()
        let palette = CommandPaletteCoordinator(router: router)
        let configurationStore = AppConfigurationStore()
        state.setCurrentUserProfile(
            displayName: configurationStore.loadUserDisplayName(),
            login: configurationStore.loadUserLogin(),
            id: configurationStore.loadUserID()
        )
        let initialSyncState = configurationStore.loadInitialSyncState()
        print("initialSyncState", initialSyncState)
        state.prefillInitialSyncState(
            issues: initialSyncState.issues,
            boards: initialSyncState.boards,
            savedSearches: initialSyncState.savedSearches
        )
        let draftStore = IssueDraftStore()
        let networkMonitor = NetworkRequestMonitor()
        let initialRequiresSetup = AppContainer.requiresSetupOnLaunch(configurationStore: configurationStore)
        let manualAuth = ManualTokenAuthRepository(configurationStore: configurationStore)
        let authSwitcher = SwitchableAuthRepository(initial: manualAuth)
        let issueSwitcher = SwitchableIssueRepository(initial: EmptyIssueRepository())
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: EmptySavedQueryRepository())
        let boardSwitcher = SwitchableIssueBoardRepository(initial: EmptyIssueBoardRepository())
        let projectSwitcher = SwitchableProjectRepository(initial: EmptyProjectRepository())
        let fieldSwitcher = SwitchableIssueFieldRepository(initial: EmptyIssueFieldRepository())
        let peopleSwitcher = SwitchablePeopleRepository(initial: EmptyPeopleRepository())
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
            projectRepositorySwitcher: projectSwitcher,
            issueFieldRepositorySwitcher: fieldSwitcher,
            peopleRepositorySwitcher: peopleSwitcher,
            boardLocalStore: boardStore
        )
        container.requiresSetup = initialRequiresSetup
        Task { await container.configureIfNeeded() }
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
        let projectSwitcher = SwitchableProjectRepository(initial: PreviewProjectRepository())
        let fieldSwitcher = SwitchableIssueFieldRepository(initial: PreviewIssueFieldRepository())
        let peopleSwitcher = SwitchablePeopleRepository(initial: PreviewPeopleRepository())
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
            projectRepositorySwitcher: projectSwitcher,
            issueFieldRepositorySwitcher: fieldSwitcher,
            peopleRepositorySwitcher: peopleSwitcher,
            boardLocalStore: boardStore
        )
    }()

    func bootstrap() async {
        LoggingService.sync.info("Bootstrap start.")
        let drafts = await issueDraftStore.loadDraftRecords(statuses: [.pending, .failed])
        await MainActor.run {
            appState.setDrafts(drafts)
        }
        let cachedBoards = await boardLocalStore.loadBoards()
        self.cachedBoards = cachedBoards
        LoggingService.sync.info("Bootstrap: cached boards loaded (\(cachedBoards.count, privacy: .public)).")
        let initialSections = buildSidebarSections(savedQueries: [], boards: cachedBoards)
        let initialPreferredSelectionID = storedSidebarSelectionID() ?? preferredSelectionID(from: [])

        appState.updateSidebar(sections: initialSections, preferredSelectionID: initialPreferredSelectionID)
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
        guard !selection.isDraft else { return }
        if !appState.hasCompletedInitialSync {
            LoggingService.sync.info("Initial sync: loading issues for \(selection.id, privacy: .public).")
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

        if let rawQuery = query.rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawQuery.isEmpty {
            recordBoardDataEvent("Issue query: \(rawQuery).", boardID: boardID)
        }
        if query == lastLoadedIssueQuery {
            recordBoardDataEvent("Load issues skipped (same query).", boardID: boardID)
            return
        }
        recordBoardDataEvent("Load issues started.", boardID: boardID)
        lastLoadedIssueQuery = query
        appState.setIssuesLoading(true)
        let shouldSeedInitialRead = await syncCoordinator.hasSeenUpdates() == false

        let board = selection.isBoard ? (resolvedBoard ?? boardForSelection(selection)) : nil
        let sprintFilter = board.map { appState.sprintFilter(for: $0) }
        if let board, let sprintFilter {
            let sprintLabel = sprintFilter.isBacklog
                ? "Backlog"
                : (board.sprintName(for: sprintFilter) ?? "Sprint \(sprintFilter.sprintID ?? "-")")
            recordBoardDataEvent("Sprint filter: \(sprintLabel).", boardID: boardID)
        }
        let sprintIssueIDs = await fetchSprintIssueIDsIfNeeded(
            board: board,
            filter: sprintFilter,
            boardID: boardID
        )

        let cachedIssues = await syncCoordinator.loadCachedIssues(for: query)
        if !cachedIssues.isEmpty {
            LoggingService.sync.info("Initial sync: loaded cached issues (\(cachedIssues.count, privacy: .public)).")
            recordBoardDataEvent("Cached issues loaded: \(cachedIssues.count).", boardID: boardID)
            let filtered = applySprintFilterIfNeeded(
                cachedIssues,
                board: board,
                filter: sprintFilter,
                sprintIssueIDs: sprintIssueIDs
            )
            if filtered != appState.issues {
                appState.replaceIssues(with: filtered)
            }
            appState.setIssuesLoading(false)
            await refreshIssueSeenUpdates(for: filtered, shouldSeedInitialRead: shouldSeedInitialRead)
        } else {
            recordBoardDataEvent("Cached issues empty.", boardID: boardID)
        }

        let syncResult = await syncCoordinator.refreshIssuesWithStatus(
            using: query,
            currentUserID: appState.currentUserID,
            currentUserLogin: appState.currentUserLogin,
            currentUserDisplayName: appState.currentUserDisplayName
        )
        if syncResult.didSyncRemote || !syncResult.issues.isEmpty {
            recordIssueSyncCompleted()
        }
        if syncResult.didSyncRemote {
            LoggingService.sync.info("Initial sync: issues synced from remote (\(syncResult.issues.count, privacy: .public)).")
            recordBoardDataEvent("Remote sync loaded: \(syncResult.issues.count) issues.", boardID: boardID)
        } else if !syncResult.issues.isEmpty {
            LoggingService.sync.info("Initial sync: issues loaded from cache (\(syncResult.issues.count, privacy: .public)).")
            let reason = AppDebugSettings.disableSyncing
                ? "Sync disabled; using cache"
                : "Remote sync unavailable; using cache"
            recordBoardDataEvent("\(reason): \(syncResult.issues.count) issues.", boardID: boardID)
        } else {
            recordBoardDataEvent("No issues returned after refresh.", boardID: boardID)
        }
        var resolvedIssues = syncResult.issues
        if resolvedIssues.isEmpty,
           let sprintIssueIDs,
           !sprintIssueIDs.isEmpty {
            let fallback = await syncCoordinator.loadIssues(readableIDs: Array(sprintIssueIDs))
            if !fallback.isEmpty {
                recordBoardDataEvent("Fallback to local sprint issues: \(fallback.count).", boardID: boardID)
                resolvedIssues = fallback
            } else {
                recordBoardDataEvent("Fallback to local sprint issues empty.", boardID: boardID)
            }
        }
        let filtered = applySprintFilterIfNeeded(
            resolvedIssues,
            board: board,
            filter: sprintFilter,
            sprintIssueIDs: sprintIssueIDs
        )
        if filtered != appState.issues {
            appState.replaceIssues(with: filtered)
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
        appState.setIssueDetailLoading(issueID, isLoading: true)
        do {
            let detail = try await syncCoordinator.fetchIssueDetail(for: issue)
            appState.updateIssueDetail(detail)
        } catch {
            // Intentionally ignored; detail view will show a placeholder.
        }
        appState.setIssueDetailLoading(issueID, isLoading: false)
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
        let sprintIssueIDs = await fetchSprintIssueIDsIfNeeded(
            board: board,
            filter: sprintFilter,
            boardID: boardID
        )
        let shouldSeedInitialRead = await syncCoordinator.hasSeenUpdates() == false
        let syncResult = await syncCoordinator.refreshIssuesWithStatus(
            using: query,
            currentUserID: appState.currentUserID,
            currentUserLogin: appState.currentUserLogin,
            currentUserDisplayName: appState.currentUserDisplayName
        )
        if syncResult.didSyncRemote || !syncResult.issues.isEmpty {
            recordIssueSyncCompleted()
        }
        if syncResult.didSyncRemote {
            recordBoardDataEvent("Refresh remote sync loaded: \(syncResult.issues.count) issues.", boardID: boardID)
        } else if !syncResult.issues.isEmpty {
            let reason = AppDebugSettings.disableSyncing
                ? "Refresh sync disabled; using cache"
                : "Refresh remote sync unavailable; using cache"
            recordBoardDataEvent("\(reason): \(syncResult.issues.count) issues.", boardID: boardID)
        } else {
            recordBoardDataEvent("Refresh returned no issues.", boardID: boardID)
        }
        if isSelected {
            var resolvedIssues = syncResult.issues
            if resolvedIssues.isEmpty,
               let sprintIssueIDs,
               !sprintIssueIDs.isEmpty {
                let fallback = await syncCoordinator.loadIssues(readableIDs: Array(sprintIssueIDs))
                if !fallback.isEmpty {
                    recordBoardDataEvent("Refresh fallback to local sprint issues: \(fallback.count).", boardID: boardID)
                    resolvedIssues = fallback
                } else {
                    recordBoardDataEvent("Refresh fallback to local sprint issues empty.", boardID: boardID)
                }
            }
            let filtered = applySprintFilterIfNeeded(
                resolvedIssues,
                board: board,
                filter: sprintFilter,
                sprintIssueIDs: sprintIssueIDs
            )
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

    func openBoardInWeb(_ item: SidebarItem) {
        guard let url = boardWebURL(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func clearCacheAndRefetch() {
        clearPersistedInitialSyncState()
        Task { [weak self] in
            guard let self else { return }
            await syncCoordinator.clearCachedIssues()
            await boardLocalStore.clearCache()
            await MainActor.run {
                appState.replaceIssues(with: [])
                appState.resetIssueSeenUpdates()
                appState.resetIssueDetails()
                appState.selectedIssue = nil
                appState.setIssuesLoading(true)
                self.lastLoadedIssueQuery = nil
                self.statusOptionsCache.removeAll()
                self.priorityOptionsCache.removeAll()
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
            print("Failed to update issue locally: \(error.localizedDescription)")
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

    func submitDraftFromDialog(_ draft: IssueDraft) {
        Task { [weak self] in
            guard let self else { return }
            let record = await issueDraftStore.saveDraft(draft)
            do {
                let created = try await syncCoordinator.enqueue(label: "Create issue") {
                    try await self.issueRepositorySwitcher.createIssue(draft: draft)
                }
                _ = await issueDraftStore.markDraftSubmitted(id: record.id)
                await MainActor.run {
                    self.appState.updateIssue(created)
                    self.markIssueSeen(created)
                }
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
                    self.appState.updateIssue(created)
                    self.markIssueSeen(created)
                }
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
                    self.appState.updateIssue(created)
                    self.appState.removeDraft(id: recordID)
                    self.issueComposer.resetDraft()
                }
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
        cachedSavedQueries = savedQueries
        cachedBoards = boards
        let sections = buildSidebarSections(savedQueries: savedQueries, boards: boards)
        let preferredSelectionID = preferredSelectionID(from: savedQueries)
        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)
    }

    func beginSignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.resetInitialSyncState()
                LoggingService.sync.info("Sign-in: starting.")
                guard let configuration = try? YouTrackOAuthConfiguration.loadFromEnvironment() else {
                    throw AuthError.configurationMissing("Missing OAuth environment configuration.")
                }
                await self.applyOAuth(
                    configuration: configuration,
                    configureRepositories: false,
                    shouldResetInitialSyncState: false
                )
                try await authRepository.signIn()
                self.updateUserProfile(from: self.authRepository.currentAccount)
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

    func cancelInitialSync() async {
        LoggingService.sync.info("Initial sync: cancel requested.")
        await signOutAndClearLocalState()
        requiresSetup = true
    }

    private func signOutAndClearLocalState() async {
        do {
            try await authRepository.signOut()
        } catch {
            print("Sign-out failed: \(error.localizedDescription)")
        }

        await syncCoordinator.clearCachedIssues()
        await boardLocalStore.clearCache()

        configurationStore.clearBaseURL()
        configurationStore.clearUserDisplayName()
        configurationStore.clearUserLogin()
        configurationStore.clearUserID()
        configurationStore.clearLastSidebarSelectionID()

        appState.setCurrentUserProfile(displayName: nil, login: nil, id: nil)
        appState.updateSyncActivity(isSyncing: false, label: nil)
        resetInitialSyncState()
        appState.resetBoardSyncState()
        appState.updateSearch(query: "")
        appState.activeConflict = nil
        appState.replaceIssues(with: [])
        appState.resetIssueSeenUpdates()
        appState.resetIssueDetails()
        appState.selectedIssue = nil
        appState.selectedIssueIDs = []
        appState.updateSidebar(sections: [], preferredSelectionID: nil)
        appState.setIssuesLoading(false)
        lastLoadedIssueQuery = nil
        statusOptionsCache.removeAll()
        priorityOptionsCache.removeAll()
    }

    func validateManualToken(baseURL: URL, token: String) async throws -> YouTrackTokenValidationUser {
        let apiBaseURL = Self.apiBaseURL(from: baseURL)
        let tokenProvider = YouTrackAPITokenProvider.constant(token)
        let configuration = YouTrackAPIConfiguration(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let client = YouTrackAPIClient(configuration: configuration, session: .shared, monitor: networkMonitor)
        let queryItems = [URLQueryItem(name: "fields", value: "id,login,name,fullName")]
        LoggingService.networking.info("Token validation: requesting users/me at \(apiBaseURL.absoluteString, privacy: .public).")
        let data = try await client.get(path: "users/me", queryItems: queryItems)
        let user = try JSONDecoder().decode(YouTrackTokenValidationUser.self, from: data)
        LoggingService.networking.info("Token validation: success for user \(user.displayName ?? "unknown", privacy: .public).")
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
        shouldResetInitialSyncState: Bool = true
    ) async -> ManualTokenSaveOutcome {
        let apiBaseURL = Self.apiBaseURL(from: baseURL)

        if shouldResetInitialSyncState {
            resetInitialSyncState()
        }
        configurationStore.save(baseURL: apiBaseURL)
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
        await bootstrap()
        return ManualTokenSaveOutcome(saved: tokenSaved, errorMessage: tokenSaveError)
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

    private func updateUserProfile(from account: Account?) {
        let trimmed = account?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            configurationStore.saveUserDisplayName(trimmed)
        }
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
        let oauthConfiguration = try? YouTrackOAuthConfiguration.loadFromEnvironment()
        let hasOAuthState = oauthConfiguration != nil && AppAuthRepository.hasSavedAuthState()

        if let oauthConfiguration {
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
        } else {
            supportsBrowserAuth = false
        }

        let baseURL = configurationStore.loadBaseURL()
        var token = configurationStore.loadToken()
        if token == nil, baseURL != nil {
            token = await MainActor.run {
                configurationStore.loadToken(allowInteraction: true)
            }
        }

        if let baseURL, let token, !token.isEmpty {
            let needsProfile = configurationStore.loadUserDisplayName() == nil
                || configurationStore.loadUserLogin() == nil
                || configurationStore.loadUserID() == nil
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
                shouldResetInitialSyncState: false
            )
            return
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
            keychain: KeychainStorage(service: "com.potomushto.youtrek.auth")
        )
        oauthRepository = appAuthRepository
        authRepositorySwitcher.replace(with: appAuthRepository)
        updateUserProfile(from: appAuthRepository.currentAccount)
        supportsBrowserAuth = true
        requiresSetup = appAuthRepository.currentAccount == nil

        guard configureRepositories, appAuthRepository.currentAccount != nil else {
            LoggingService.sync.info("OAuth: configured sign-in repository, awaiting authentication.")
            return
        }

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

private extension AppContainer {
    static func apiBaseURL(from baseURL: URL) -> URL {
        if baseURL.lastPathComponent.lowercased() == "api" {
            return baseURL
        }
        return baseURL.appendingPathComponent("api")
    }

    static func requiresSetupOnLaunch(configurationStore: AppConfigurationStore) -> Bool {
        let hasManualToken = configurationStore.loadBaseURL() != nil &&
            (configurationStore.loadToken()?.isEmpty == false)

        if (try? YouTrackOAuthConfiguration.loadFromEnvironment()) != nil {
            if AppAuthRepository.hasSavedAuthState() {
                return false
            }
            return !hasManualToken
        }

        return !hasManualToken
    }
}

private extension AppContainer {
    func refreshSidebarData() async {
        let startTime = Date()
        LoggingService.sync.info("Sidebar refresh: start.")
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
        recordSavedSearchSyncCompleted()
        let resolvedBoards = await boardsResult
        recordBoardListSyncCompleted()
        cachedSavedQueries = resolvedSavedQueries
        cachedBoards = resolvedBoards
        let duration = Date().timeIntervalSince(startTime)
        LoggingService.sync.info(
            "Sidebar refresh: savedQueries=\(resolvedSavedQueries.count, privacy: .public) boards=\(resolvedBoards.count, privacy: .public) duration=\(duration, privacy: .public)s."
        )

        let sections = buildSidebarSections(savedQueries: resolvedSavedQueries, boards: resolvedBoards)
        let preferredSelectionID = storedSidebarSelectionID() ?? preferredSelectionID(from: resolvedSavedQueries)
        let previousSelectionID = appState.selectedSidebarItem?.id

        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)

        if let selection = appState.selectedSidebarItem, selection.id != previousSelectionID {
            await loadIssues(for: selection)
        }
        await maybeStartBoardPrefetch(resolvedBoards)

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

    private func inboxSidebarItem() -> SidebarItem? {
        let items = appState.sidebarSections.flatMap(\.items)
        return items.first { item in
            item.isInbox || item.title.caseInsensitiveCompare("Inbox") == .orderedSame
        }
    }

    func rebuildSidebar(preferredSelectionID: SidebarItem.ID? = nil) {
        let sections = buildSidebarSections(savedQueries: cachedSavedQueries, boards: cachedBoards)
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
            LoggingService.sync.info("Board sync: fetching remote boards.")
            let remoteBoards = try await syncCoordinator.enqueue(label: "Sync agile boards") {
                try await self.boardRepositorySwitcher.fetchBoards()
            }
            await boardLocalStore.saveRemoteBoards(remoteBoards)
            LoggingService.sync.info("Board sync: fetched \(remoteBoards.count, privacy: .public) boards.")
            let syncDate = Date()
            for board in remoteBoards {
                appState.recordBoardSync(boardID: board.id, at: syncDate)
            }
            return await boardLocalStore.loadBoards()
        } catch {
            LoggingService.sync.error("Board sync: failed with \(error.localizedDescription, privacy: .public).")
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
        guard let boardID else { return }
        appState.recordBoardDataSourceEvent(boardID: boardID, message: message)
    }

    private func resolveBoardDetailsIfNeeded(for selection: SidebarItem) async -> IssueBoard? {
        guard selection.isBoard else { return selection.board }
        let current = selection.board
        guard boardNeedsDetail(current) else { return current }
        guard let boardID = selection.boardID ?? current?.id else { return current }

        do {
            recordBoardDataEvent("Board details fetch started.", boardID: boardID)
            let detail = try await boardRepositorySwitcher.fetchBoard(id: boardID)
            let resolved = applyingFavorite(current?.isFavorite, to: detail)
            await boardLocalStore.saveBoard(resolved)
            recordBoardDataEvent("Board details fetched.", boardID: boardID)
            return resolved
        } catch {
            recordBoardDataEvent("Board details fetch failed: \(error.localizedDescription)", boardID: boardID)
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

    private func fetchSprintIssueIDsIfNeeded(
        board: IssueBoard?,
        filter: BoardSprintFilter?,
        boardID: String?
    ) async -> Set<String>? {
        guard let board, let filter, case .sprint(let sprintID) = filter else { return nil }
        do {
            recordBoardDataEvent("Sprint issue IDs fetch started (sprintID: \(sprintID)).", boardID: boardID)
            let ids = try await issueRepositorySwitcher.fetchSprintIssueIDs(agileID: board.id, sprintID: sprintID)
            guard !ids.isEmpty else { return nil }
            recordBoardDataEvent("Sprint issue IDs fetched: \(ids.count).", boardID: boardID)
            return Set(ids)
        } catch {
            recordBoardDataEvent("Sprint issue IDs fetch failed: \(error.localizedDescription)", boardID: boardID)
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
        do {
            return try await peopleRepositorySwitcher.fetchPeople(query: query, projectID: projectID)
        } catch {
            return []
        }
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
    @Published var draftFields: [IssueDraftField] = []

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
        draftFields = []
    }

    func applyDraft(_ draft: IssueDraft) {
        draftTitle = draft.title
        draftDescription = draft.description
        draftProjectID = draft.projectID
        draftModule = draft.module ?? ""
        draftAssigneeID = draft.assigneeID ?? ""
        draftPriority = draft.priority
        draftFields = draft.customFields
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
        applyDefaultFields(draft.customFields)
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
            assigneeID: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            customFields: normalizedDraftFields(excluding: ["priority", "assignee", "subsystem", "module"])
        )
    }

    func draftSnapshot() -> IssueDraft {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = draftProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModule = draftModule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssignee = draftAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)

        return IssueDraft(
            title: trimmedTitle,
            description: trimmedDescription,
            projectID: trimmedProject,
            module: trimmedModule.isEmpty ? nil : trimmedModule,
            priority: draftPriority,
            assigneeID: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            customFields: normalizedDraftFields(excluding: ["priority", "assignee", "subsystem", "module"])
        )
    }

    func resetDraft() {
        draftTitle = ""
        draftDescription = ""
        draftProjectID = ""
        draftModule = ""
        draftAssigneeID = ""
        draftPriority = .normal
        draftFields = []
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
