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

    private init(
        appState: AppState,
        issueComposer: IssueComposer,
        commandPalette: CommandPaletteCoordinator,
        router: WindowRouter,
        syncCoordinator: SyncCoordinator
    ) {
        self.appState = appState
        self.issueComposer = issueComposer
        self.commandPalette = commandPalette
        self.router = router
        self.syncCoordinator = syncCoordinator
    }

    static let live: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let sync = SyncCoordinator()
        let container = AppContainer(appState: state, issueComposer: composer, commandPalette: palette, router: router, syncCoordinator: sync)
        Task { await container.bootstrap() }
        return container
    }()

    static let preview: AppContainer = {
        let state = AppState()
        let router = WindowRouter()
        let composer = IssueComposer(router: router)
        let palette = CommandPaletteCoordinator(router: router)
        let sync = SyncCoordinator()
        return AppContainer(appState: state, issueComposer: composer, commandPalette: palette, router: router, syncCoordinator: sync)
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
