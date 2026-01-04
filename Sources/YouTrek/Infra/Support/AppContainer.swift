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

    private let configurationStore: AppConfigurationStore
    private let issueRepositorySwitcher: SwitchableIssueRepository
    private let authRepositorySwitcher: SwitchableAuthRepository
    @Published private(set) var supportsBrowserAuth: Bool = false
    @Published private(set) var requiresSetup: Bool = true

    private init(
        appState: AppState,
        issueComposer: IssueComposer,
        commandPalette: CommandPaletteCoordinator,
        router: WindowRouter,
        syncCoordinator: SyncCoordinator,
        authRepository: AuthRepository,
        configurationStore: AppConfigurationStore,
        issueRepositorySwitcher: SwitchableIssueRepository,
        authRepositorySwitcher: SwitchableAuthRepository
    ) {
        self.appState = appState
        self.issueComposer = issueComposer
        self.commandPalette = commandPalette
        self.router = router
        self.syncCoordinator = syncCoordinator
        self.authRepository = authRepository
        self.configurationStore = configurationStore
        self.issueRepositorySwitcher = issueRepositorySwitcher
        self.authRepositorySwitcher = authRepositorySwitcher
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let configurationStore = AppConfigurationStore()
        let authSwitcher = SwitchableAuthRepository(initial: PreviewAuthRepository())
        let issueSwitcher = SwitchableIssueRepository(initial: PreviewIssueRepository())
        let sync = SyncCoordinator(issueRepository: issueSwitcher)
        let container = AppContainer(
            appState: state,
            issueComposer: composer,
            commandPalette: palette,
            router: router,
            syncCoordinator: sync,
            authRepository: authSwitcher,
            configurationStore: configurationStore,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher
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
        let authSwitcher = SwitchableAuthRepository(initial: authRepository)
        let issueSwitcher = SwitchableIssueRepository(initial: issueRepository)
        let sync = SyncCoordinator(issueRepository: issueSwitcher)
        return AppContainer(
            appState: state,
            issueComposer: composer,
            commandPalette: palette,
            router: router,
            syncCoordinator: sync,
            authRepository: authSwitcher,
            configurationStore: store,
            issueRepositorySwitcher: issueSwitcher,
            authRepositorySwitcher: authSwitcher
        )
    }()

    func bootstrap() async {
        let query = IssueQuery(
            search: "",
            filters: [],
            sort: .updated(descending: true),
            page: .init(size: 50, offset: 0)
        )

        guard let issues = try? await syncCoordinator.refreshIssues(using: query) else { return }
        appState.replaceIssues(with: issues)
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
        configurationStore.save(baseURL: baseURL)
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
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: baseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration)
        await issueRepositorySwitcher.replace(with: issueRepository)

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
        let appAuthRepository = AppAuthRepository(configuration: configuration, keychain: KeychainStorage(service: "com.youtrek.auth"))
        authRepositorySwitcher.replace(with: appAuthRepository)
        let tokenProvider = YouTrackAPITokenProvider { try await appAuthRepository.currentAccessToken() }
        let apiConfiguration = YouTrackAPIConfiguration(baseURL: configuration.apiBaseURL, tokenProvider: tokenProvider)
        let issueRepository = YouTrackIssueRepository(configuration: apiConfiguration)
        await issueRepositorySwitcher.replace(with: issueRepository)
        supportsBrowserAuth = true
        requiresSetup = false
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
