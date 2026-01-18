import Foundation
import Combine
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    let appState: AppState
    let issueComposer: IssueComposer
    let commandPalette: CommandPaletteCoordinator
    let router: WindowRouter
    let syncCoordinator: SyncCoordinator
    let authRepository: AuthRepository
    let networkMonitor: NetworkRequestMonitor

    private let configurationStore: AppConfigurationStore
    private let issueRepositorySwitcher: SwitchableIssueRepository
    private let authRepositorySwitcher: SwitchableAuthRepository
    private let savedQueryRepositorySwitcher: SwitchableSavedQueryRepository
    private var lastLoadedSidebarID: SidebarItem.ID?
    @Published private(set) var supportsBrowserAuth: Bool = false
    @Published private(set) var requiresSetup: Bool = true

    private init(
        appState: AppState,
        issueComposer: IssueComposer,
        commandPalette: CommandPaletteCoordinator,
        router: WindowRouter,
        syncCoordinator: SyncCoordinator,
        authRepository: AuthRepository,
        networkMonitor: NetworkRequestMonitor,
        configurationStore: AppConfigurationStore,
        issueRepositorySwitcher: SwitchableIssueRepository,
        authRepositorySwitcher: SwitchableAuthRepository,
        savedQueryRepositorySwitcher: SwitchableSavedQueryRepository
    ) {
        self.appState = appState
        self.issueComposer = issueComposer
        self.commandPalette = commandPalette
        self.router = router
        self.syncCoordinator = syncCoordinator
        self.authRepository = authRepository
        self.networkMonitor = networkMonitor
        self.configurationStore = configurationStore
        self.issueRepositorySwitcher = issueRepositorySwitcher
        self.authRepositorySwitcher = authRepositorySwitcher
        self.savedQueryRepositorySwitcher = savedQueryRepositorySwitcher
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let configurationStore = AppConfigurationStore()
        let networkMonitor = NetworkRequestMonitor()
        let authSwitcher = SwitchableAuthRepository(initial: PreviewAuthRepository())
        let issueSwitcher = SwitchableIssueRepository(initial: EmptyIssueRepository())
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: PreviewSavedQueryRepository())
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
            authRepository: authSwitcher,
            networkMonitor: networkMonitor,
            configurationStore: configurationStore,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher,
            savedQueryRepositorySwitcher: savedQuerySwitcher
        )
        Task { await container.configureIfNeeded() }
        Task { await container.bootstrap() }
        return container
    }()

    static let preview: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let authRepository = PreviewAuthRepository()
        let issueRepository = PreviewIssueRepository()
        let store = AppConfigurationStore()
        let networkMonitor = NetworkRequestMonitor()
        let authSwitcher = SwitchableAuthRepository(initial: authRepository)
        let issueSwitcher = SwitchableIssueRepository(initial: issueRepository)
        let savedQuerySwitcher = SwitchableSavedQueryRepository(initial: PreviewSavedQueryRepository())
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
            authRepository: authSwitcher,
            networkMonitor: networkMonitor,
            configurationStore: store,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher,
            savedQueryRepositorySwitcher: savedQuerySwitcher
        )
    }()

    func bootstrap() async {
        let savedQueries = (try? await syncCoordinator.enqueue(label: "Sync saved searches") {
            try await self.savedQueryRepositorySwitcher.fetchSavedQueries()
        }) ?? []
        let sections = buildSidebarSections(savedQueries: savedQueries)
        let preferredSelectionID = preferredSelectionID(from: savedQueries)

        appState.updateSidebar(sections: sections, preferredSelectionID: preferredSelectionID)
        if let selection = appState.selectedSidebarItem {
            await loadIssues(for: selection)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.syncCoordinator.flushPendingMutations()
        }

        let queriesToPrefetch = sections.flatMap(\.items).map(\.query)
        Task { [weak self] in
            guard let self else { return }
            for query in queriesToPrefetch {
                _ = try? await self.syncCoordinator.refreshIssues(using: query)
            }
        }
    }

    func loadIssues(for selection: SidebarItem) async {
        guard selection.id != lastLoadedSidebarID else { return }
        lastLoadedSidebarID = selection.id
        appState.setIssuesLoading(true)

        let cachedIssues = await syncCoordinator.loadCachedIssues(for: selection.query)
        if !cachedIssues.isEmpty {
            appState.replaceIssues(with: cachedIssues)
            appState.setIssuesLoading(false)
        }

        let issues = (try? await syncCoordinator.refreshIssues(using: selection.query)) ?? []
        appState.replaceIssues(with: issues)
        appState.setIssuesLoading(false)
    }

    func updateIssue(id: IssueSummary.ID, patch: IssuePatch) async {
        do {
            let updated = try await syncCoordinator.applyOptimisticUpdate(id: id, patch: patch)
            appState.updateIssue(updated)
        } catch {
            print("Failed to update issue locally: \(error.localizedDescription)")
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
        let sections = buildSidebarSections(savedQueries: savedQueries)
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
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)

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
        await issueRepositorySwitcher.replace(with: issueRepository)
        await savedQueryRepositorySwitcher.replace(with: savedQueryRepository)
        supportsBrowserAuth = true
        requiresSetup = false
    }
}

private extension AppContainer {
    func buildSidebarSections(savedQueries: [SavedQuery]) -> [SidebarSection] {
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

        var sections: [SidebarSection] = []
        if !smartItems.isEmpty {
            sections.append(SidebarSection(id: "smart", title: "Smart Filters", items: smartItems))
        }
        if !savedItems.isEmpty {
            sections.append(SidebarSection(id: "saved", title: "Saved Searches", items: savedItems))
        }
        return sections
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

    private let router: WindowRouter

    init(router: WindowRouter) {
        self.router = router
    }

    func beginNewIssue(withTitle title: String) {
        draftTitle = title
        draftDescription = ""
        router.openNewIssueWindow()
    }

    func submitDraft() {
        // TODO: Feed into IssueRepository once mutations are wired.
        draftTitle = ""
        draftDescription = ""
        router.consumeNewIssueWindowFlag()
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
