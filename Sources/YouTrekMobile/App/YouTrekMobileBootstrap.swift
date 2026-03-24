import Foundation
import SwiftUI

struct MobileTodoListDocument: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let fileName: String
    let updatedAt: Date
}

@MainActor
final class YouTrekMobileBootstrap: ObservableObject {
    private enum Constants {
        static let issueQuery = IssueQuery(
            rawQuery: "#Unresolved sort by: updated desc",
            search: "",
            filters: [],
            sort: nil,
            page: IssueQuery.Page(size: 50, offset: 0)
        )
        static let boardIssuePage = IssueQuery.Page(size: 50, offset: 0)
    }

    struct SetupDraft: Sendable {
        let baseURL: String
        let token: String
    }

    @Published private(set) var issues: [IssueSummary] = []
    @Published private(set) var boards: [IssueBoard] = []
    @Published private(set) var todoLists: [MobileTodoListDocument] = []
    @Published private(set) var projects: [IssueProject] = []
    @Published private(set) var storedAccount: StoredAccount?
    @Published private(set) var accountName: String?
    @Published private(set) var authModeLabel: String?
    @Published private(set) var canSignIn: Bool = false
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var isLoadingCache: Bool = false
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isLoadingProjects: Bool = false
    @Published private(set) var isSubmittingIssue: Bool = false
    @Published private(set) var lastRefreshAt: Date?
    @Published var errorMessage: String?
    @Published var warningMessage: String?
    @Published var configurationMessage: String?

    private let configurationStore: AppConfigurationStore
    private let networkMonitor: NetworkRequestMonitor
    private var manualAuthRepository: ManualTokenAuthRepository
    private let oauthConfiguration: YouTrackOAuthConfiguration?
    private let oauthRepository: AppAuthRepository?
    private var boardStore: IssueBoardLocalStore
    private var todoStore: MobileTodoListStore
    private var configuredAccountID: UUID?
    private var projectsLoadedForAccountID: UUID?
    private var hasBootstrapped = false

    init(
        configurationStore: AppConfigurationStore = AppConfigurationStore(),
        networkMonitor: NetworkRequestMonitor? = nil
    ) {
        self.configurationStore = configurationStore
        self.networkMonitor = networkMonitor ?? NetworkRequestMonitor()
        self.manualAuthRepository = ManualTokenAuthRepository(configurationStore: configurationStore)
        self.oauthConfiguration = try? YouTrackOAuthConfiguration.load()
        if let oauthConfiguration {
            self.oauthRepository = AppAuthRepository(configuration: oauthConfiguration)
        } else {
            self.oauthRepository = nil
        }

        let activeAccountID = configurationStore.activeAccountID()
        self.boardStore = IssueBoardLocalStore(accountID: activeAccountID)
        self.todoStore = MobileTodoListStore(accountID: activeAccountID)
        self.configuredAccountID = activeAccountID
        refreshSessionState()
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await reloadSession(runRemoteRefresh: true)
    }

    func refresh() async {
        await reloadSession(runRemoteRefresh: true)
    }

    func signIn() async {
        guard let oauthRepository, let oauthConfiguration else {
            configurationMessage = "Set YOUTRACK_CLIENT_ID in the iOS target build settings to enable browser sign-in."
            return
        }

        errorMessage = nil
        warningMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await oauthRepository.signIn()
            let currentAccount = oauthRepository.currentAccount
            _ = configurationStore.upsertAccount(
                baseURL: oauthConfiguration.apiBaseURL,
                authMethod: .oauth,
                displayName: currentAccount?.displayName,
                login: nil,
                userID: currentAccount?.id.uuidString,
                allowBaseURLOnlyMatch: true
            )
            await reloadSession(runRemoteRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithToken(baseURLString: String, token: String) async {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedURL), baseURL.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter a valid YouTrack URL including https://"
            return
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Paste a valid YouTrack permanent token."
            return
        }

        errorMessage = nil
        warningMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let userProfile = try await validateManualToken(baseURL: baseURL, token: trimmedToken)
            let apiBaseURL = Self.apiBaseURL(from: baseURL)
            let account = configurationStore.upsertAccount(
                baseURL: apiBaseURL,
                authMethod: .token,
                displayName: userProfile.displayName,
                login: userProfile.login,
                userID: userProfile.id,
                allowBaseURLOnlyMatch: true
            )
            configureStoresIfNeeded(for: account.id)
            manualAuthRepository = ManualTokenAuthRepository(configurationStore: configurationStore)
            do {
                try manualAuthRepository.apply(token: trimmedToken, displayName: userProfile.displayName)
            } catch {
                warningMessage = tokenSaveWarningMessage(error: error.localizedDescription)
            }
            await reloadSession(runRemoteRefresh: true)
        } catch {
            errorMessage = validationErrorMessage(for: error)
        }
    }

    func signOut() async {
        errorMessage = nil
        warningMessage = nil

        if storedAccount?.authMethod == .token {
            try? await manualAuthRepository.signOut()
            try? configurationStore.clearToken()
        }
        if let oauthRepository {
            try? await oauthRepository.signOut()
        }
        manualAuthRepository = ManualTokenAuthRepository(configurationStore: configurationStore)

        issues = []
        boards = []
        projects = []
        todoLists = []
        lastRefreshAt = nil
        projectsLoadedForAccountID = nil

        refreshSessionState()
        await reloadTodoLists()
    }

    func handleOpenURL(_ url: URL) {
        guard let oauthRepository, oauthRepository.resumeExternalUserAgentFlow(with: url) else {
            return
        }
    }

    func setupDraft() -> SetupDraft {
        let baseURL: String
        if let storedBaseURL = configurationStore.loadBaseURL() {
            var displayURL = storedBaseURL
            if displayURL.lastPathComponent.lowercased() == "api" {
                displayURL.deleteLastPathComponent()
            }
            baseURL = displayURL.absoluteString
        } else if let configuredBaseURL = oauthConfiguration?.apiBaseURL {
            var displayURL = configuredBaseURL
            if displayURL.lastPathComponent.lowercased() == "api" {
                displayURL.deleteLastPathComponent()
            }
            baseURL = displayURL.absoluteString
        } else {
            baseURL = ""
        }

        return SetupDraft(
            baseURL: baseURL,
            token: configurationStore.loadToken() ?? ""
        )
    }

    func reloadTodoLists() async {
        guard configurationStore.activeAccountID() != nil else {
            todoLists = []
            return
        }

        do {
            todoLists = try await todoStore.listDocuments()
        } catch {
            todoLists = []
        }
    }

    func createTodoList(named name: String = "Todo List") async throws -> MobileTodoListDocument {
        let created = try await todoStore.createDocument(named: name)
        await reloadTodoLists()
        return created
    }

    func loadTodoMarkdown(id: UUID) async -> String {
        (try? await todoStore.loadMarkdown(id: id)) ?? ""
    }

    func saveTodoMarkdown(id: UUID, markdown: String) async throws {
        try await todoStore.saveMarkdown(id: id, markdown: markdown)
        await reloadTodoLists()
    }

    func loadProjectsIfNeeded() async throws {
        guard let context = activeAPIContext() else {
            projects = []
            projectsLoadedForAccountID = nil
            return
        }
        guard projectsLoadedForAccountID != context.account.id else { return }
        guard !isLoadingProjects else { return }

        isLoadingProjects = true
        defer { isLoadingProjects = false }

        let repository = YouTrackProjectRepository(
            configuration: context.apiConfiguration,
            monitor: networkMonitor
        )
        let fetched = try await repository.fetchProjects().filter { !$0.isArchived }
        projects = fetched
        projectsLoadedForAccountID = context.account.id
    }

    func createIssue(title: String, description: String, projectIdentifier: String) async throws -> IssueSummary {
        guard let context = activeAPIContext() else {
            throw AuthError.notSignedIn
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProjectIdentifier = projectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedProjectIdentifier.isEmpty else {
            throw YouTrackAPIError.http(statusCode: 400, body: "Missing required issue fields.")
        }

        isSubmittingIssue = true
        defer { isSubmittingIssue = false }

        let repository = YouTrackIssueRepository(
            configuration: context.apiConfiguration,
            monitor: networkMonitor
        )
        let created = try await repository.createIssue(
            draft: IssueDraft(
                title: trimmedTitle,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                projectID: trimmedProjectIdentifier,
                module: nil,
                priority: .normal,
                assigneeID: nil
            )
        )

        issues.removeAll { $0.id == created.id }
        issues.insert(created, at: 0)
        lastRefreshAt = Date()
        return created
    }

    func fetchBoardIssues(for board: IssueBoard) async throws -> [IssueSummary] {
        guard let context = activeAPIContext() else {
            throw AuthError.notSignedIn
        }

        let repository = YouTrackIssueRepository(
            configuration: context.apiConfiguration,
            monitor: networkMonitor
        )
        return try await repository.fetchIssues(query: boardIssueQuery(for: board))
    }

    var networkStatusText: String? {
        guard let entry = networkMonitor.entries.first else { return nil }
        let prefix = entry.isPending ? "Request" : "Last request"
        return "\(prefix): \(entry.method) \(entry.endpoint)"
    }

    private struct APIContext {
        let account: StoredAccount
        let apiConfiguration: YouTrackAPIConfiguration
    }

    private func reloadSession(runRemoteRefresh: Bool) async {
        refreshSessionState()
        await loadCachedWorkspace()
        guard runRemoteRefresh, isSignedIn else { return }
        await syncWorkspaceInBackground()
    }

    private func refreshSessionState() {
        ensureStoredOAuthAccountIfNeeded()
        storedAccount = configurationStore.activeAccount()
        configureStoresIfNeeded(for: storedAccount?.id)
        canSignIn = oauthRepository != nil

        if let oauthRepository, let currentAccount = oauthRepository.currentAccount {
            isSignedIn = true
            accountName = currentAccount.displayName
            authModeLabel = "OAuth"
            configurationMessage = nil
            return
        }

        if let currentAccount = manualAuthRepository.currentAccount {
            isSignedIn = true
            accountName = currentAccount.displayName
            authModeLabel = "Token"
            configurationMessage = nil
            return
        }

        isSignedIn = false
        accountName = storedAccount?.displayTitle
        authModeLabel = nil
        if canSignIn {
            configurationMessage = nil
        } else {
            configurationMessage = "Set YOUTRACK_CLIENT_ID in the iOS target build settings to enable browser sign-in."
        }
    }

    private func ensureStoredOAuthAccountIfNeeded() {
        guard configurationStore.activeAccount() == nil,
              let oauthRepository,
              let oauthConfiguration,
              let oauthAccount = oauthRepository.currentAccount
        else {
            return
        }

        _ = configurationStore.upsertAccount(
            baseURL: oauthConfiguration.apiBaseURL,
            authMethod: .oauth,
            displayName: oauthAccount.displayName,
            login: nil,
            userID: oauthAccount.id.uuidString,
            allowBaseURLOnlyMatch: true
        )
    }

    private func configureStoresIfNeeded(for accountID: UUID?) {
        guard configuredAccountID != accountID else { return }
        configuredAccountID = accountID
        boardStore = IssueBoardLocalStore(accountID: accountID)
        todoStore = MobileTodoListStore(accountID: accountID)
        boards = []
        todoLists = []
        projects = []
        projectsLoadedForAccountID = nil
    }

    private func loadCachedWorkspace() async {
        isLoadingCache = true
        await loadCachedIssues()
        await loadCachedBoards()
        await reloadTodoLists()
        isLoadingCache = false
    }

    private func loadCachedIssues() async {
        guard let accountID = configurationStore.activeAccountID() else {
            issues = []
            return
        }

        let issueStore = IssueLocalStore(accountID: accountID)
        issues = await issueStore.loadIssues(for: Constants.issueQuery)
    }

    private func loadCachedBoards() async {
        guard configurationStore.activeAccountID() != nil else {
            boards = []
            return
        }
        boards = await boardStore.loadFavoriteBoards()
    }

    private func syncWorkspaceInBackground() async {
        guard let context = activeAPIContext() else {
            return
        }

        errorMessage = nil
        isSyncing = true
        defer { isSyncing = false }

        let syncedIssues = await syncIssues(using: context)
        let syncedBoards = await syncBoards(using: context)

        issues = syncedIssues
        boards = syncedBoards
        lastRefreshAt = Date()
    }

    private func syncIssues(using context: APIContext) async -> [IssueSummary] {
        let repository = YouTrackIssueRepository(
            configuration: context.apiConfiguration,
            monitor: networkMonitor
        )
        let issueStore = IssueLocalStore(accountID: context.account.id)
        let coordinator = SyncCoordinator(
            issueRepository: repository,
            localStore: issueStore
        )
        let result = await coordinator.refreshIssuesWithStatus(
            using: Constants.issueQuery,
            currentUserID: configurationStore.loadUserID(),
            currentUserLogin: configurationStore.loadUserLogin(),
            currentUserDisplayName: configurationStore.loadUserDisplayName()
        )
        return result.issues
    }

    private func syncBoards(using context: APIContext) async -> [IssueBoard] {
        let repository = YouTrackIssueBoardRepository(
            configuration: context.apiConfiguration,
            monitor: networkMonitor
        )

        do {
            let remoteBoards = try await repository.fetchBoards()
            await boardStore.saveRemoteBoards(remoteBoards)
            return await boardStore.loadFavoriteBoards()
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
            return await boardStore.loadFavoriteBoards()
        }
    }

    private func activeAuthRepository() -> AuthRepository? {
        if let oauthRepository, oauthRepository.currentAccount != nil {
            return oauthRepository
        }
        if manualAuthRepository.currentAccount != nil {
            return manualAuthRepository
        }
        return nil
    }

    private func activeAPIContext() -> APIContext? {
        guard let account = configurationStore.activeAccount(),
              let baseURL = account.apiBaseURL,
              let authRepository = activeAuthRepository()
        else {
            return nil
        }

        let tokenProvider = YouTrackAPITokenProvider {
            try await authRepository.currentAccessToken()
        }
        let apiConfiguration = YouTrackAPIConfiguration(
            baseURL: Self.apiBaseURL(from: baseURL),
            tokenProvider: tokenProvider
        )
        return APIContext(account: account, apiConfiguration: apiConfiguration)
    }

    private func boardIssueQuery(for board: IssueBoard) -> IssueQuery {
        let sprintName = board.sprintName(for: board.defaultSprintFilter)
        return IssueQuery(
            rawQuery: IssueQuery.boardQuery(boardName: board.name, sprintName: sprintName),
            search: "",
            filters: [],
            sort: .updated(descending: true),
            page: Constants.boardIssuePage
        )
    }

    private func validateManualToken(baseURL: URL, token: String) async throws -> YouTrackTokenValidationUser {
        let apiBaseURL = Self.apiBaseURL(from: baseURL)
        let tokenProvider = YouTrackAPITokenProvider.constant(token)
        let configuration = YouTrackAPIConfiguration(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let client = YouTrackAPIClient(configuration: configuration, session: .shared, monitor: networkMonitor)
        let queryItems = [URLQueryItem(name: "fields", value: "id,login,name,fullName")]
        let data = try await client.get(path: "users/me", queryItems: queryItems)
        return try JSONDecoder().decode(YouTrackTokenValidationUser.self, from: data)
    }

    private func validationErrorMessage(for error: Error) -> String {
        if let apiError = error as? YouTrackAPIError {
            switch apiError {
            case .http(let statusCode, _):
                if statusCode == 401 || statusCode == 403 {
                    return "Token was rejected by YouTrack. Make sure it is a permanent token with access to this instance."
                }
            default:
                break
            }
            return apiError.localizedDescription
        }
        return "Token validation failed: \(error.localizedDescription)"
    }

    private func tokenSaveWarningMessage(error: String?) -> String {
        let detail = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty {
            return "Could not save token to keychain: \(detail). You may need to sign in again after relaunching."
        }
        return "Could not save token to keychain. You may need to sign in again after relaunching."
    }

    private static func apiBaseURL(from baseURL: URL) -> URL {
        if baseURL.lastPathComponent.lowercased() == "api" {
            return baseURL
        }
        return baseURL.appendingPathComponent("api")
    }
}

private struct YouTrackTokenValidationUser: Decodable, Sendable {
    let id: String?
    let login: String?
    let name: String?
    let fullName: String?

    var displayName: String? {
        fullName ?? name ?? login
    }
}

actor MobileTodoListStore {
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

    func listDocuments() throws -> [MobileTodoListDocument] {
        try ensureDirectoryExists()
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let markdownURLs = fileURLs.filter { $0.pathExtension.lowercased() == "md" }
        return markdownURLs
            .compactMap(document(from:))
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func createDocument(named name: String) throws -> MobileTodoListDocument {
        try ensureDirectoryExists()
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Todo List" : name
        let id = UUID()
        let fileURL = documentURL(for: id)
        let markdown = "# \(resolvedName)\n\n"
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        guard let document = document(from: fileURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
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

    private func documentURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    private func document(from url: URL) -> MobileTodoListDocument? {
        let baseName = url.deletingPathExtension().lastPathComponent
        guard let id = UUID(uuidString: baseName) else { return nil }
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let name = parsedName(from: markdown, fallbackID: id)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let updatedAt = values?.contentModificationDate ?? .distantPast
        return MobileTodoListDocument(id: id, name: name, fileName: url.lastPathComponent, updatedAt: updatedAt)
    }

    private func parsedName(from markdown: String, fallbackID: UUID) -> String {
        let lines = markdown.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" || $0.isWhitespace }
                let resolved = String(heading).trimmingCharacters(in: .whitespacesAndNewlines)
                if !resolved.isEmpty {
                    return resolved
                }
            }
            return trimmed
        }
        return "Todo \(fallbackID.uuidString.prefix(6))"
    }
}
