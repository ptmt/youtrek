import Foundation
import LocalAuthentication
import Security

struct KeychainStorage: Sendable {
    let service: String
    let accessGroup: String?
    let synchronizable: Bool
    // When false, skip the data-protection keychain to use the legacy keychain store.
    let prefersDataProtectionKeychain: Bool

    init(
        service: String,
        accessGroup: String? = nil,
        synchronizable: Bool = false,
        prefersDataProtectionKeychain: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
        self.prefersDataProtectionKeychain = prefersDataProtectionKeychain
    }

    func save(data: Data, account: String) throws {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else {
            throw KeychainStorageError.operationFailed(status: errSecParam)
        }
        guard prefersDataProtectionKeychain else {
            try savePreferredData(data, account: trimmedAccount, useDataProtectionKeychain: false)
            return
        }
        do {
            try savePreferredData(data, account: trimmedAccount, useDataProtectionKeychain: true)
            let readback = try? loadPreferredData(
                account: trimmedAccount,
                useDataProtectionKeychain: true,
                allowInteraction: false
            )
            if readback != nil {
                try? deleteLegacy(account: trimmedAccount)
            } else {
                try savePreferredData(data, account: trimmedAccount, useDataProtectionKeychain: false)
            }
        } catch {
            // Fall back to the legacy keychain when data protection keychain isn't available.
            try savePreferredData(data, account: trimmedAccount, useDataProtectionKeychain: false)
        }
    }

    func load(account: String, allowInteraction: Bool = false) throws -> Data? {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return nil }
        if !prefersDataProtectionKeychain {
            return try loadPreferredData(
                account: trimmedAccount,
                useDataProtectionKeychain: false,
                allowInteraction: allowInteraction
            )
        }
        var dataProtectionError: Error?
        do {
            if let data = try loadPreferredData(
                account: trimmedAccount,
                useDataProtectionKeychain: true,
                allowInteraction: allowInteraction
            ) {
                return data
            }
        } catch {
            dataProtectionError = error
        }

        if let legacyData = try loadLegacy(account: trimmedAccount, allowInteraction: allowInteraction) {
            if dataProtectionError == nil {
                do {
                    try savePreferredData(
                        legacyData,
                        account: trimmedAccount,
                        useDataProtectionKeychain: true
                    )
                    try deleteLegacy(account: trimmedAccount)
                } catch {
                    // Ignore migration failures; legacy data is still available.
                }
            }
            return legacyData
        }

        if let dataProtectionError {
            throw dataProtectionError
        }
        return nil
    }

    func delete(account: String) throws {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else {
            throw KeychainStorageError.operationFailed(status: errSecParam)
        }
        if !prefersDataProtectionKeychain {
            try deletePreferredData(account: trimmedAccount, useDataProtectionKeychain: false)
            return
        }
        var dataProtectionError: Error?
        do {
            try deletePreferredData(account: trimmedAccount, useDataProtectionKeychain: true)
        } catch {
            dataProtectionError = error
        }
        do {
            try deleteLegacy(account: trimmedAccount)
        } catch {
            if dataProtectionError == nil {
                throw error
            }
        }
    }

    private func identityQuery(
        for account: String,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) -> [String: Any] {
        // Keep identity keys minimal so reads/updates match what was written.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if useDataProtectionKeychain {
            if #available(iOS 13.0, macOS 10.15, *) {
                query[kSecUseDataProtectionKeychain as String] = true
            }
        }
        return query
    }

    private func addQuery(
        for account: String,
        data: Data,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) -> [String: Any] {
        var query = identityQuery(
            for: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: synchronizable
        )
        query[kSecValueData as String] = data
        // Ensure the keychain prompt includes a stable, non-empty label if it ever appears.
        query[kSecAttrLabel as String] = service
        if useDataProtectionKeychain {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return query
    }

    private func loadData(
        account: String,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool,
        allowInteraction: Bool
    ) throws -> Data? {
        var query = identityQuery(
            for: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: synchronizable
        )
        if #available(iOS 9.0, macOS 10.10, *) {
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
            if allowInteraction {
                context.localizedReason = "Allow YouTrek to access your saved token."
            }
            query[kSecUseAuthenticationContext as String] = context
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            ensureLabel(
                account: account,
                useDataProtectionKeychain: useDataProtectionKeychain,
                synchronizable: synchronizable
            )
            return item as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if !allowInteraction {
                return nil
            }
            fallthrough
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func loadPreferredData(
        account: String,
        useDataProtectionKeychain: Bool,
        allowInteraction: Bool
    ) throws -> Data? {
        if synchronizable {
            if let data = try loadData(
                account: account,
                useDataProtectionKeychain: useDataProtectionKeychain,
                synchronizable: true,
                allowInteraction: allowInteraction
            ) {
                return data
            }
            if let legacyData = try loadData(
                account: account,
                useDataProtectionKeychain: useDataProtectionKeychain,
                synchronizable: false,
                allowInteraction: allowInteraction
            ) {
                do {
                    try saveData(
                        legacyData,
                        account: account,
                        useDataProtectionKeychain: useDataProtectionKeychain,
                        synchronizable: true
                    )
                    try deleteData(
                        account: account,
                        useDataProtectionKeychain: useDataProtectionKeychain,
                        synchronizable: false
                    )
                } catch {
                    // Ignore migration failures; the legacy item is still available.
                }
                return legacyData
            }
            return nil
        }

        return try loadData(
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: false,
            allowInteraction: allowInteraction
        )
    }

    private func loadLegacy(account: String, allowInteraction: Bool) throws -> Data? {
        try loadPreferredData(
            account: account,
            useDataProtectionKeychain: false,
            allowInteraction: allowInteraction
        )
    }

    private func savePreferredData(
        _ data: Data,
        account: String,
        useDataProtectionKeychain: Bool
    ) throws {
        let preferredSynchronizable = synchronizable
        try saveData(
            data,
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: preferredSynchronizable
        )
        guard preferredSynchronizable else { return }
        try? deleteData(
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: false
        )
    }

    private func deletePreferredData(account: String, useDataProtectionKeychain: Bool) throws {
        var firstError: Error?
        let variants = synchronizable ? [true, false] : [false]
        for variant in variants {
            do {
                try deleteData(
                    account: account,
                    useDataProtectionKeychain: useDataProtectionKeychain,
                    synchronizable: variant
                )
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func deleteLegacy(account: String) throws {
        try deletePreferredData(account: account, useDataProtectionKeychain: false)
    }

    private func saveData(
        _ data: Data,
        account: String,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) throws {
        let insertQuery = addQuery(
            for: account,
            data: data,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: synchronizable
        )
        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateQuery = identityQuery(
                for: account,
                useDataProtectionKeychain: useDataProtectionKeychain,
                synchronizable: synchronizable
            )
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrLabel as String: service
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStorageError.operationFailed(status: updateStatus)
            }
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func deleteData(
        account: String,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) throws {
        var query = identityQuery(
            for: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: synchronizable
        )
        if #available(iOS 9.0, macOS 10.10, *) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func ensureLabel(account: String, useDataProtectionKeychain: Bool, synchronizable: Bool) {
        let query = identityQuery(
            for: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            synchronizable: synchronizable
        )
        let attributes: [String: Any] = [kSecAttrLabel as String: service]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return
        }
    }
}

struct KeychainStorageError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if #available(macOS 11.3, *) {
            return SecCopyErrorMessageString(status, nil) as String?
        } else {
            return "Keychain operation failed with status \(status)."
        }
    }

    static func operationFailed(status: OSStatus) -> KeychainStorageError {
        KeychainStorageError(status: status)
    }
}

enum KeychainAccessGroupResolver {
    private static let entitlementKeys = [
        "keychain-access-groups",
        "com.apple.security.keychain-access-groups"
    ]

    static func appIdentifierPrefix() -> String? {
        let start = ProcessInfo.processInfo.systemUptime
        #if os(macOS)
        if let applicationIdentifier = entitlementString(for: "com.apple.application-identifier") {
            let trimmed = applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let components = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            guard let prefix = components.first, !prefix.isEmpty else { return nil }
            let resolved = "\(prefix)."
            logTiming("appIdentifierPrefix application identifier", start: start)
            return resolved
        }
        if let teamIdentifier = entitlementString(for: "com.apple.developer.team-identifier") {
            let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let resolved = "\(trimmed)."
            logTiming("appIdentifierPrefix team identifier", start: start)
            return resolved
        }
        #endif
        logTiming("appIdentifierPrefix unavailable", start: start)
        return nil
    }

    static func resolve(matchingSuffix suffix: String) -> String? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        for key in entitlementKeys {
            guard let value = SecTaskCopyValueForEntitlement(
                task,
                key as CFString,
                nil
            ) else {
                continue
            }
            guard let groups = value as? [String] else { continue }
            if let match = groups.first(where: { $0.hasSuffix(suffix) }) {
                return match
            }
        }
        #endif
        return nil
    }

    static func resolve(matchingSuffixes suffixes: [String]) -> String? {
        for suffix in suffixes {
            if let match = resolve(matchingSuffix: suffix) {
                return match
            }
        }
        return nil
    }

    static func availableGroups() -> [String] {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        var groups: [String] = []
        for key in entitlementKeys {
            guard let value = SecTaskCopyValueForEntitlement(
                task,
                key as CFString,
                nil
            ) else {
                continue
            }
            if let values = value as? [String] {
                groups.append(contentsOf: values)
            }
        }
        return Array(Set(groups))
        #else
        return []
        #endif
    }

    private static func entitlementString(for key: String) -> String? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else {
            logTiming("entitlement \(key) unavailable", start: start)
            return nil
        }
        logTiming("entitlement \(key) loaded", start: start)
        return value as? String
    }

    private static func logTiming(_ message: String, start: TimeInterval) {
#if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let formatted = String(format: "%.2f", elapsed)
        LoggingService.general.info(
            "Startup detail: KeychainAccessGroupResolver \(message, privacy: .public) (+\(formatted, privacy: .public)s)"
        )
#endif
    }
}
