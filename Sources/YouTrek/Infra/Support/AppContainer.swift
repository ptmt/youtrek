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

    private init(
        appState: AppState,
        issueComposer: IssueComposer,
        commandPalette: CommandPaletteCoordinator,
        router: WindowRouter,
        syncCoordinator: SyncCoordinator,
        authRepository: AuthRepository
    ) {
        self.appState = appState
        self.issueComposer = issueComposer
        self.commandPalette = commandPalette
        self.router = router
        self.syncCoordinator = syncCoordinator
        self.authRepository = authRepository
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let authRepository: AuthRepository
        let issueRepository: IssueRepository

        do {
            let configuration = try YouTrackOAuthConfiguration.loadFromEnvironment()
            let appAuthRepository = AppAuthRepository(configuration: configuration, keychain: KeychainStorage(service: "com.youtrek.auth"))
            authRepository = appAuthRepository
            let tokenProvider = YouTrackAPITokenProvider { try await appAuthRepository.currentAccessToken() }
            let apiConfiguration = YouTrackAPIConfiguration(baseURL: configuration.apiBaseURL, tokenProvider: tokenProvider)
            issueRepository = YouTrackIssueRepository(configuration: apiConfiguration)
        } catch {
            print("⚠️ Missing YouTrack OAuth configuration: \(error.localizedDescription). Falling back to preview data.")
            let previewAuth = PreviewAuthRepository()
            authRepository = previewAuth
            issueRepository = PreviewIssueRepository()
        }

        let sync = SyncCoordinator(issueRepository: issueRepository)
        let container = AppContainer(appState: state, issueComposer: composer, commandPalette: palette, router: router, syncCoordinator: sync, authRepository: authRepository)
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
        let sync = SyncCoordinator(issueRepository: issueRepository)
        return AppContainer(appState: state, issueComposer: composer, commandPalette: palette, router: router, syncCoordinator: sync, authRepository: authRepository)
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
