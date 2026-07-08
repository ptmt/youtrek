import Foundation

// @unchecked: UserDefaults is documented thread-safe but not Sendable-annotated
// in the current SDK; all other stored state is immutable value types.
struct AppConfigurationStore: @unchecked Sendable {
    private enum Keys {
        static let accounts = "com.potomushto.youtrek.config.accounts"
        static let activeAccountID = "com.potomushto.youtrek.config.active-account-id"
        static let syncedAccounts = "com.potomushto.youtrek.config.synced-accounts"
        static let syncedActiveAccountID = "com.potomushto.youtrek.config.synced-active-account-id"
        static let baseURL = "com.potomushto.youtrek.config.base-url"
        static let tokenAccount = "com.potomushto.youtrek.config.token"
        static let lastSidebarSelectionID = "com.potomushto.youtrek.config.last-sidebar-selection"
        static let userDisplayName = "com.potomushto.youtrek.config.user-display-name"
        static let userLogin = "com.potomushto.youtrek.config.user-login"
        static let userID = "com.potomushto.youtrek.config.user-id"
        static let initialIssueSyncCompleted = "com.potomushto.youtrek.config.initial-sync-issues"
        static let initialBoardSyncCompleted = "com.potomushto.youtrek.config.initial-sync-boards"
        static let initialSavedSearchSyncCompleted = "com.potomushto.youtrek.config.initial-sync-saved-searches"
    }

    private static let sharedSuiteName = "group.com.potomushto.youtrek.shared"
    private static let legacySharedSuiteNames = ["com.potomushto.youtrek.shared"]
    private static let sharedKeychainGroupSuffix = "com.potomushto.youtrek.shared"
    private static let configKeychainGroupSuffix = "com.potomushto.youtrek.config"
    private static let legacyKeychainGroupSuffixes = [
        "com.potomushto.youtrek.macos",
        "com.potomushto.youtrek"
    ]

    private let defaults: UserDefaults
    private let keychain: KeychainStorage

    init(
        defaults: UserDefaults = AppConfigurationStore.defaultDefaults(),
        keychain: KeychainStorage = AppConfigurationStore.defaultKeychain(service: "com.potomushto.youtrek.config")
    ) {
        self.defaults = defaults
        self.keychain = keychain
        migrateLegacyAccountsIfNeeded()
    }

    private static func defaultDefaults() -> UserDefaults {
        let start = ProcessInfo.processInfo.systemUptime
        let standardDefaults = UserDefaults.standard
        if hasStoredAccounts(in: standardDefaults) {
            logStartupTiming("defaultDefaults using standard domain", start: start)
            return standardDefaults
        }

        if let sharedDefaults = UserDefaults(suiteName: sharedSuiteName) {
            migrateDefaultsIfNeeded(from: sharedDefaults, to: standardDefaults)
            if hasStoredAccounts(in: standardDefaults) {
                logStartupTiming("defaultDefaults migrated from shared suite", start: start)
                return standardDefaults
            }
        }

        for legacySuiteName in legacySharedSuiteNames {
            if let legacyDefaults = UserDefaults(suiteName: legacySuiteName) {
                migrateDefaultsIfNeeded(from: legacyDefaults, to: standardDefaults)
                if hasStoredAccounts(in: standardDefaults) {
                    logStartupTiming("defaultDefaults migrated from legacy suite \(legacySuiteName)", start: start)
                    return standardDefaults
                }
            }
        }

        logStartupTiming("defaultDefaults using standard fallback", start: start)
        return standardDefaults
    }

    static func sharedDefaultsSuiteName() -> String {
        sharedSuiteName
    }

    private static func hasStoredAccounts(in defaults: UserDefaults) -> Bool {
        defaults.data(forKey: Keys.accounts) != nil
    }

    static func sharedAccessGroup() -> String? {
        resolveAccessGroup()
    }

    static func defaultKeychain(
        service: String,
        prefersDataProtectionKeychain: Bool = false
    ) -> KeychainStorage {
        let start = ProcessInfo.processInfo.systemUptime
        let accessGroup = sharedAccessGroup()
        logStartupTiming("defaultKeychain resolved access group for \(service)", start: start)
        return KeychainStorage(
            service: service,
            accessGroup: accessGroup,
            synchronizable: true,
            prefersDataProtectionKeychain: prefersDataProtectionKeychain
        )
    }

    private static func migrateDefaultsIfNeeded(from source: UserDefaults, to target: UserDefaults) {
        if target.data(forKey: Keys.accounts) == nil,
           let accounts = source.data(forKey: Keys.accounts) {
            target.set(accounts, forKey: Keys.accounts)
        }
        if target.string(forKey: Keys.activeAccountID) == nil,
           let activeAccountID = source.string(forKey: Keys.activeAccountID),
           !activeAccountID.isEmpty {
            target.set(activeAccountID, forKey: Keys.activeAccountID)
        }
        if target.string(forKey: Keys.baseURL) == nil,
           let baseURL = source.string(forKey: Keys.baseURL),
           !baseURL.isEmpty {
            target.set(baseURL, forKey: Keys.baseURL)
        }
        if target.string(forKey: Keys.userDisplayName) == nil,
           let name = source.string(forKey: Keys.userDisplayName),
           !name.isEmpty {
            target.set(name, forKey: Keys.userDisplayName)
        }
        if target.string(forKey: Keys.userLogin) == nil,
           let login = source.string(forKey: Keys.userLogin),
           !login.isEmpty {
            target.set(login, forKey: Keys.userLogin)
        }
        if target.string(forKey: Keys.userID) == nil,
           let id = source.string(forKey: Keys.userID),
           !id.isEmpty {
            target.set(id, forKey: Keys.userID)
        }
        if target.string(forKey: Keys.lastSidebarSelectionID) == nil,
           let selection = source.string(forKey: Keys.lastSidebarSelectionID),
           !selection.isEmpty {
            target.set(selection, forKey: Keys.lastSidebarSelectionID)
        }
        if target.object(forKey: Keys.initialIssueSyncCompleted) == nil,
           let value = source.object(forKey: Keys.initialIssueSyncCompleted) as? Bool {
            target.set(value, forKey: Keys.initialIssueSyncCompleted)
        }
        if target.object(forKey: Keys.initialBoardSyncCompleted) == nil,
           let value = source.object(forKey: Keys.initialBoardSyncCompleted) as? Bool {
            target.set(value, forKey: Keys.initialBoardSyncCompleted)
        }
        if target.object(forKey: Keys.initialSavedSearchSyncCompleted) == nil,
           let value = source.object(forKey: Keys.initialSavedSearchSyncCompleted) as? Bool {
            target.set(value, forKey: Keys.initialSavedSearchSyncCompleted)
        }
    }

    func loadAccounts() -> [StoredAccount] {
        refreshSyncedMetadataIfNeeded()
        let accounts = loadStoredAccounts()
        _ = ensureActiveAccountID(in: accounts)
        return accounts
    }

    func activeAccountID() -> UUID? {
        refreshSyncedMetadataIfNeeded()
        let accounts = loadStoredAccounts()
        return ensureActiveAccountID(in: accounts)
    }

    func activeAccount() -> StoredAccount? {
        let accounts = loadAccounts()
        guard let activeID = defaults.string(forKey: Keys.activeAccountID).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return accounts.first { $0.id == activeID }
    }

    func cachedActiveAccount() -> StoredAccount? {
        let accounts = loadStoredAccounts()
        guard let activeID = cachedActiveAccountID(in: accounts) else { return nil }
        return accounts.first { $0.id == activeID }
    }

    // Cached variants read UserDefaults only, skipping the keychain-synced
    // metadata refresh; use on launch-critical paths.
    func cachedAccounts() -> [StoredAccount] {
        loadStoredAccounts()
    }

    func cachedActiveAccountID() -> UUID? {
        cachedActiveAccountID(in: loadStoredAccounts())
    }

    @discardableResult
    func activateAccount(id: UUID) -> Bool {
        refreshSyncedMetadataIfNeeded()
        var accounts = loadStoredAccounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        accounts[index].lastUsedAt = Date()
        saveStoredAccounts(accounts)
        saveActiveAccountID(id)
        return true
    }

    func setActiveAccountID(_ id: UUID?) {
        guard let id else {
            saveActiveAccountID(nil)
            return
        }
        _ = activateAccount(id: id)
    }

    @discardableResult
    func upsertAccount(
        baseURL: URL,
        authMethod: StoredAccount.AuthMethod,
        displayName: String? = nil,
        login: String? = nil,
        userID: String? = nil,
        allowBaseURLOnlyMatch: Bool = false
    ) -> StoredAccount {
        migrateLegacyAccountsIfNeeded()
        var accounts = loadStoredAccounts()
        let normalizedBaseURL = normalizeBaseURL(baseURL)
        let trimmedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = matchAccountIndex(
            in: accounts,
            baseURL: normalizedBaseURL,
            userID: trimmedUserID,
            login: trimmedLogin,
            allowBaseURLOnlyMatch: allowBaseURLOnlyMatch
        )

        let now = Date()
        let resolvedAccount: StoredAccount
        if let index {
            var account = accounts[index]
            account.baseURL = normalizedBaseURL
            if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                account.displayName = name
            }
            if let login = trimmedLogin, !login.isEmpty {
                account.login = login
            }
            if let userID = trimmedUserID, !userID.isEmpty {
                account.userID = userID
            }
            account.authMethod = authMethod
            account.lastUsedAt = now
            accounts[index] = account
            resolvedAccount = account
        } else {
            let account = StoredAccount(
                baseURL: normalizedBaseURL,
                displayName: displayName,
                login: trimmedLogin,
                userID: trimmedUserID,
                authMethod: authMethod,
                createdAt: now,
                lastUsedAt: now
            )
            accounts.append(account)
            resolvedAccount = account
        }

        saveStoredAccounts(accounts)
        saveActiveAccountID(resolvedAccount.id)
        return resolvedAccount
    }

    @discardableResult
    func removeAccount(id: UUID) -> UUID? {
        migrateLegacyAccountsIfNeeded()
        var accounts = loadStoredAccounts()
        accounts.removeAll { $0.id == id }
        saveStoredAccounts(accounts)
        guard !accounts.isEmpty else {
            saveActiveAccountID(nil)
            return nil
        }
        let next = accounts.sorted(by: accountSortPredicate).first
        if let next {
            saveActiveAccountID(next.id)
            return next.id
        }
        saveActiveAccountID(nil)
        return nil
    }

    func loadBaseURL() -> URL? {
        guard let stored = activeAccount()?.baseURL, !stored.isEmpty else {
            return nil
        }
        return URL(string: stored)
    }

    func save(baseURL: URL) {
        if activeAccountID() == nil {
            _ = upsertAccount(baseURL: baseURL, authMethod: .token, allowBaseURLOnlyMatch: true)
            return
        }
        updateActiveAccount { account in
            account.baseURL = normalizeBaseURL(baseURL)
        }
    }

    func clearBaseURL() {
        updateActiveAccount { account in
            account.baseURL = ""
        }
    }

    func loadToken(allowInteraction: Bool = false) -> String? {
        loadTokenResult(allowInteraction: allowInteraction).token
    }

    func loadTokenResult(allowInteraction: Bool = false) -> (token: String?, error: String?) {
        guard let accountID = activeAccountID() else { return (nil, nil) }
        let tokenKey = tokenAccountKey(for: accountID)
        let tokenData: Data?
        do {
            tokenData = try loadTokenData(account: tokenKey, allowInteraction: allowInteraction)
        } catch {
            let message = error.localizedDescription
            LoggingService.sync.error("Keychain: failed to load token (\(message, privacy: .public)).")
            return (nil, message)
        }
        if let unwrapped = tokenData {
            guard let token = String(data: unwrapped, encoding: .utf8) else {
                return (nil, "Unable to decode token data.")
            }
            return (token, nil)
        }
        do {
            if let legacyData = try loadTokenData(account: Keys.tokenAccount, allowInteraction: allowInteraction) {
                try? keychain.save(data: legacyData, account: tokenKey)
                if let token = String(data: legacyData, encoding: .utf8) {
                    return (token, nil)
                }
            }
        } catch {
            let message = error.localizedDescription
            LoggingService.sync.error("Keychain: failed to load legacy token (\(message, privacy: .public)).")
            return (nil, message)
        }
        return (nil, nil)
    }

    func save(token: String) throws {
        guard let accountID = activeAccountID() else { return }
        let data = Data(token.utf8)
        let tokenKey = tokenAccountKey(for: accountID)
        try keychain.save(data: data, account: tokenKey)
        if keychain.accessGroup != nil || keychain.synchronizable {
            try? KeychainStorage(
                service: "com.potomushto.youtrek.config",
                prefersDataProtectionKeychain: false
            )
            .save(data: data, account: tokenKey)
        }
    }

    func clearToken() throws {
        guard let accountID = activeAccountID() else { return }
        let tokenKey = tokenAccountKey(for: accountID)
        try keychain.delete(account: tokenKey)
        if keychain.accessGroup != nil || keychain.synchronizable {
            try? KeychainStorage(
                service: "com.potomushto.youtrek.config",
                prefersDataProtectionKeychain: false
            )
            .delete(account: tokenKey)
        }
    }

    func loadUserDisplayName() -> String? {
        activeAccount()?.displayName
    }

    func saveUserDisplayName(_ name: String) {
        updateActiveAccount { account in
            account.displayName = name
        }
    }

    func clearUserDisplayName() {
        updateActiveAccount { account in
            account.displayName = nil
        }
    }

    func loadUserLogin() -> String? {
        activeAccount()?.login
    }

    func saveUserLogin(_ login: String) {
        updateActiveAccount { account in
            account.login = login
        }
    }

    func clearUserLogin() {
        updateActiveAccount { account in
            account.login = nil
        }
    }

    func loadUserID() -> String? {
        activeAccount()?.userID
    }

    func saveUserID(_ id: String) {
        updateActiveAccount { account in
            account.userID = id
        }
    }

    func clearUserID() {
        updateActiveAccount { account in
            account.userID = nil
        }
    }

    func loadLastSidebarSelectionID() -> String? {
        activeAccount()?.lastSidebarSelectionID
    }

    func saveLastSidebarSelectionID(_ id: String) {
        updateActiveAccount { account in
            account.lastSidebarSelectionID = id
        }
    }

    func clearLastSidebarSelectionID() {
        updateActiveAccount { account in
            account.lastSidebarSelectionID = nil
        }
    }

    func loadInitialSyncState() -> (issues: Bool, boards: Bool, savedSearches: Bool) {
        guard let account = activeAccount() else {
            return (issues: false, boards: false, savedSearches: false)
        }
        return (
            issues: account.initialIssueSyncCompleted,
            boards: account.initialBoardSyncCompleted,
            savedSearches: account.initialSavedSearchSyncCompleted
        )
    }

    func saveInitialIssueSyncCompleted(_ value: Bool) {
        updateActiveAccount { account in
            account.initialIssueSyncCompleted = value
        }
    }

    func saveInitialBoardSyncCompleted(_ value: Bool) {
        updateActiveAccount { account in
            account.initialBoardSyncCompleted = value
        }
    }

    func saveInitialSavedSearchSyncCompleted(_ value: Bool) {
        updateActiveAccount { account in
            account.initialSavedSearchSyncCompleted = value
        }
    }

    func clearInitialSyncState() {
        updateActiveAccount { account in
            account.initialIssueSyncCompleted = false
            account.initialBoardSyncCompleted = false
            account.initialSavedSearchSyncCompleted = false
        }
    }

    private static func resolveAccessGroup() -> String? {
        let start = ProcessInfo.processInfo.systemUptime
        if let infoPrefix = appIdentifierPrefixFromBundle() {
            let group = infoPrefix + sharedKeychainGroupSuffix
            logStartupTiming("resolveAccessGroup using prefix \(group)", start: start)
            return group
        }
        let preferredSuffixes = [sharedKeychainGroupSuffix, configKeychainGroupSuffix]
            + legacyKeychainGroupSuffixes
        if let match = KeychainAccessGroupResolver.resolve(matchingSuffixes: preferredSuffixes) {
            logStartupTiming("resolveAccessGroup matched entitlement \(match)", start: start)
            return match
        }
        let availableGroups = KeychainAccessGroupResolver.availableGroups().sorted()
        let group = availableGroups.first
        logStartupTiming(
            "resolveAccessGroup fallback available groups count=\(availableGroups.count)",
            start: start
        )
        return group
    }

    private static func appIdentifierPrefixFromBundle(bundle: Bundle = .main) -> String? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let raw = bundle.object(forInfoDictionaryKey: "APP_IDENTIFIER_PREFIX") as? String else {
            let prefix = KeychainAccessGroupResolver.appIdentifierPrefix()
            logStartupTiming("appIdentifierPrefixFromBundle resolved via entitlements", start: start)
            return prefix
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            logStartupTiming("appIdentifierPrefixFromBundle resolved via Info.plist", start: start)
            return trimmed
        }
        let prefix = KeychainAccessGroupResolver.appIdentifierPrefix()
        logStartupTiming("appIdentifierPrefixFromBundle resolved empty Info.plist fallback", start: start)
        return prefix
    }

    private static func logStartupTiming(_ message: String, start: TimeInterval) {
#if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let formatted = String(format: "%.2f", elapsed)
        LoggingService.general.info(
            "Startup detail: AppConfigurationStore \(message, privacy: .public) (+\(formatted, privacy: .public)s)"
        )
#endif
    }

    private func loadFromAlternateAccessGroups(allowInteraction: Bool) throws -> Data? {
        guard let currentGroup = keychain.accessGroup else { return nil }
        let availableGroups = KeychainAccessGroupResolver.availableGroups()
        let candidates = availableGroups.filter { $0 != currentGroup }
        guard !candidates.isEmpty else { return nil }
        for group in candidates {
            let alternate = KeychainStorage(
                service: keychain.service,
                accessGroup: group,
                synchronizable: keychain.synchronizable,
                prefersDataProtectionKeychain: keychain.prefersDataProtectionKeychain
            )
            if let data = try alternate.load(
                account: Keys.tokenAccount,
                allowInteraction: allowInteraction
            ) {
                try? keychain.save(data: data, account: Keys.tokenAccount)
                return data
            }
        }
        return nil
    }

    private func loadFromAlternateAccessGroups(account: String, allowInteraction: Bool) throws -> Data? {
        guard let currentGroup = keychain.accessGroup else { return nil }
        let availableGroups = KeychainAccessGroupResolver.availableGroups()
        let candidates = availableGroups.filter { $0 != currentGroup }
        guard !candidates.isEmpty else { return nil }
        for group in candidates {
            let alternate = KeychainStorage(
                service: keychain.service,
                accessGroup: group,
                synchronizable: keychain.synchronizable,
                prefersDataProtectionKeychain: keychain.prefersDataProtectionKeychain
            )
            if let data = try alternate.load(
                account: account,
                allowInteraction: allowInteraction
            ) {
                try? keychain.save(data: data, account: account)
                return data
            }
        }
        return nil
    }

    private func loadTokenData(account: String, allowInteraction: Bool) throws -> Data? {
        if let data = try keychain.load(account: account, allowInteraction: allowInteraction) {
            return data
        }
        if keychain.accessGroup != nil,
           let migrated = try loadFromAlternateAccessGroups(account: account, allowInteraction: allowInteraction) {
            return migrated
        }
        let legacyKeychain = KeychainStorage(
            service: "com.potomushto.youtrek.config",
            prefersDataProtectionKeychain: false
        )
        if let legacyData = try legacyKeychain.load(account: account, allowInteraction: allowInteraction) {
            try? keychain.save(data: legacyData, account: account)
            return legacyData
        }
        return nil
    }

    private func migrateLegacyAccountsIfNeeded() {
        guard defaults.data(forKey: Keys.accounts) == nil else { return }

        let legacyBaseURL = defaults.string(forKey: Keys.baseURL)
        let legacyDisplayName = defaults.string(forKey: Keys.userDisplayName)
        let legacyLogin = defaults.string(forKey: Keys.userLogin)
        let legacyUserID = defaults.string(forKey: Keys.userID)
        let legacySelection = defaults.string(forKey: Keys.lastSidebarSelectionID)
        let legacyIssueSync = defaults.bool(forKey: Keys.initialIssueSyncCompleted)
        let legacyBoardSync = defaults.bool(forKey: Keys.initialBoardSyncCompleted)
        let legacySavedSync = defaults.bool(forKey: Keys.initialSavedSearchSyncCompleted)

        let legacyDataExists = [legacyBaseURL, legacyDisplayName, legacyLogin, legacyUserID, legacySelection]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

        let legacyTokenExists = (try? loadTokenData(account: Keys.tokenAccount, allowInteraction: false)) != nil
        guard legacyDataExists || legacyTokenExists else { return }

        let resolvedBaseURL = legacyBaseURL ?? ""
        let account = StoredAccount(
            baseURL: resolvedBaseURL,
            displayName: legacyDisplayName,
            login: legacyLogin,
            userID: legacyUserID,
            lastSidebarSelectionID: legacySelection,
            initialIssueSyncCompleted: legacyIssueSync,
            initialBoardSyncCompleted: legacyBoardSync,
            initialSavedSearchSyncCompleted: legacySavedSync,
            authMethod: .token,
            createdAt: Date(),
            lastUsedAt: Date()
        )
        saveStoredAccounts([account])
        saveActiveAccountID(account.id)

        if let legacyData = try? loadTokenData(account: Keys.tokenAccount, allowInteraction: false) {
            try? keychain.save(data: legacyData, account: tokenAccountKey(for: account.id))
        }
    }

    private func loadStoredAccounts() -> [StoredAccount] {
        guard let data = defaults.data(forKey: Keys.accounts) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredAccount].self, from: data)) ?? []
    }

    private func saveStoredAccounts(_ accounts: [StoredAccount]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(accounts) else { return }
        saveStoredAccountsData(data)
    }

    private func ensureActiveAccountID(in accounts: [StoredAccount]) -> UUID? {
        if accounts.isEmpty {
            defaults.removeObject(forKey: Keys.activeAccountID)
            return nil
        }
        if let raw = defaults.string(forKey: Keys.activeAccountID),
           let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            return id
        }
        let sorted = accounts.sorted(by: accountSortPredicate)
        guard let fallback = sorted.first else { return nil }
        saveActiveAccountID(fallback.id)
        return fallback.id
    }

    private func cachedActiveAccountID(in accounts: [StoredAccount]) -> UUID? {
        guard !accounts.isEmpty else { return nil }
        if let raw = defaults.string(forKey: Keys.activeAccountID),
           let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            return id
        }
        return accounts.sorted(by: accountSortPredicate).first?.id
    }

    private func updateActiveAccount(_ update: (inout StoredAccount) -> Void) {
        migrateLegacyAccountsIfNeeded()
        var accounts = loadStoredAccounts()
        guard let activeID = ensureActiveAccountID(in: accounts) else { return }
        guard let index = accounts.firstIndex(where: { $0.id == activeID }) else { return }
        update(&accounts[index])
        accounts[index].lastUsedAt = Date()
        saveStoredAccounts(accounts)
    }

    private func matchAccountIndex(
        in accounts: [StoredAccount],
        baseURL: String,
        userID: String?,
        login: String?,
        allowBaseURLOnlyMatch: Bool
    ) -> Int? {
        if let userID, !userID.isEmpty {
            return accounts.firstIndex(where: { $0.baseURL == baseURL && $0.userID == userID })
        }
        if let login, !login.isEmpty {
            return accounts.firstIndex(where: { $0.baseURL == baseURL && $0.login == login })
        }
        guard allowBaseURLOnlyMatch else { return nil }
        return accounts.firstIndex(where: { $0.baseURL == baseURL })
    }

    private func accountSortPredicate(_ lhs: StoredAccount, _ rhs: StoredAccount) -> Bool {
        let lhsDate = lhs.lastUsedAt ?? lhs.createdAt
        let rhsDate = rhs.lastUsedAt ?? rhs.createdAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.displayTitle < rhs.displayTitle
    }

    private func normalizeBaseURL(_ url: URL) -> String {
        var resolved = url
        if resolved.lastPathComponent.isEmpty {
            resolved.deleteLastPathComponent()
        }
        return resolved.absoluteString
    }

    private func tokenAccountKey(for accountID: UUID) -> String {
        "\(Keys.tokenAccount).\(accountID.uuidString)"
    }

    private func refreshSyncedMetadataIfNeeded() {
        migrateLegacyAccountsIfNeeded()

        let localAccountsData = defaults.data(forKey: Keys.accounts)
        if let syncedAccountsData = loadSyncedAccounts() {
            if syncedAccountsData != localAccountsData {
                defaults.set(syncedAccountsData, forKey: Keys.accounts)
            }
        } else if let localAccountsData {
            saveSyncedAccountsData(localAccountsData)
        }

        let localActiveID = defaults.string(forKey: Keys.activeAccountID).flatMap(UUID.init(uuidString:))
        if let syncedActiveID = loadSyncedActiveAccountID() {
            if localActiveID != syncedActiveID {
                defaults.set(syncedActiveID.uuidString, forKey: Keys.activeAccountID)
            }
        } else if let localActiveID {
            saveSyncedActiveAccountID(localActiveID)
        }
    }

    private func saveStoredAccountsData(_ data: Data) {
        defaults.set(data, forKey: Keys.accounts)
        saveSyncedAccountsData(data)
    }

    private func saveSyncedAccountsData(_ data: Data) {
        try? keychain.save(data: data, account: Keys.syncedAccounts)
    }

    private func loadSyncedAccounts() -> Data? {
        try? keychain.load(account: Keys.syncedAccounts, allowInteraction: false)
    }

    private func saveActiveAccountID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: Keys.activeAccountID)
            try? keychain.delete(account: Keys.syncedActiveAccountID)
            return
        }
        defaults.set(id.uuidString, forKey: Keys.activeAccountID)
        saveSyncedActiveAccountID(id)
    }

    private func saveSyncedActiveAccountID(_ id: UUID) {
        try? keychain.save(data: Data(id.uuidString.utf8), account: Keys.syncedActiveAccountID)
    }

    private func loadSyncedActiveAccountID() -> UUID? {
        guard let data = try? keychain.load(account: Keys.syncedActiveAccountID, allowInteraction: false),
              let raw = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return UUID(uuidString: raw)
    }
}

enum AppDebugSettings {
    enum Keys {
        static let simulateSlowResponses = "com.potomushto.youtrek.debug.simulate-slow-responses"
        static let showNetworkFooter = "com.potomushto.youtrek.debug.show-network-footer"
        static let verboseRequestLogging = "com.potomushto.youtrek.debug.verbose-request-logging"
        static let disableSyncing = "com.potomushto.youtrek.debug.disable-syncing"
        static let showBoardDiagnostics = "com.potomushto.youtrek.debug.show-board-diagnostics"
        static let showIssueListDiagnostics = "com.potomushto.youtrek.debug.show-issue-list-diagnostics"
    }

    static var simulateSlowResponses: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.simulateSlowResponses)
        #else
        return false
        #endif
    }

    static var showNetworkFooter: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showNetworkFooter)
        #else
        return false
        #endif
    }

    static var verboseRequestLogging: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.verboseRequestLogging)
        #else
        return false
        #endif
    }

    static var disableSyncing: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.disableSyncing)
        #else
        return false
        #endif
    }

    static var showBoardDiagnostics: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showBoardDiagnostics)
        #else
        return false
        #endif
    }

    static var showIssueListDiagnostics: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: Keys.showIssueListDiagnostics)
        #else
        return false
        #endif
    }

    static func setSimulateSlowResponses(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.simulateSlowResponses)
        #endif
    }

    static func setShowNetworkFooter(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.showNetworkFooter)
        #endif
    }

    static func setVerboseRequestLogging(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.verboseRequestLogging)
        #endif
    }

    static func setDisableSyncing(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.disableSyncing)
        #endif
    }

    static func setShowBoardDiagnostics(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.showBoardDiagnostics)
        #endif
    }

    static func setShowIssueListDiagnostics(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: Keys.showIssueListDiagnostics)
        #endif
    }

    static let slowResponseDelay: TimeInterval = 5
    static let syncStartDelay: TimeInterval = 2.0 // we postpone syncing to make sure we fetch first from offline

    static func applySlowResponseIfNeeded() async throws {
        guard simulateSlowResponses else { return }
        let nanoseconds = UInt64(slowResponseDelay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
