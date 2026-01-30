import Foundation
import LocalAuthentication
import Security

struct KeychainStorage {
    let service: String
    let accessGroup: String?
    // When false, skip the data-protection keychain to use the legacy keychain store.
    let prefersDataProtectionKeychain: Bool

    init(service: String, accessGroup: String? = nil, prefersDataProtectionKeychain: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.prefersDataProtectionKeychain = prefersDataProtectionKeychain
    }

    func save(data: Data, account: String) throws {
        guard prefersDataProtectionKeychain else {
            try saveData(data, account: account, useDataProtectionKeychain: false)
            return
        }
        do {
            try saveData(data, account: account, useDataProtectionKeychain: true)
            let readback = try? loadData(
                account: account,
                useDataProtectionKeychain: true,
                allowInteraction: false
            )
            if readback != nil {
                try? deleteLegacy(account: account)
            } else {
                try saveData(data, account: account, useDataProtectionKeychain: false)
            }
        } catch {
            // Fall back to the legacy keychain when data protection keychain isn't available.
            try saveData(data, account: account, useDataProtectionKeychain: false)
        }
    }

    func load(account: String, allowInteraction: Bool = false) throws -> Data? {
        if !prefersDataProtectionKeychain {
            return try loadLegacy(account: account, allowInteraction: allowInteraction)
        }
        var dataProtectionError: Error?
        do {
            if let data = try loadData(
                account: account,
                useDataProtectionKeychain: true,
                allowInteraction: allowInteraction
            ) {
                return data
            }
        } catch {
            dataProtectionError = error
        }

        if let legacyData = try loadLegacy(account: account, allowInteraction: allowInteraction) {
            if dataProtectionError == nil {
                do {
                    try saveData(
                        legacyData,
                        account: account,
                        useDataProtectionKeychain: true
                    )
                    try deleteLegacy(account: account)
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
        if !prefersDataProtectionKeychain {
            try deleteLegacy(account: account)
            return
        }
        var dataProtectionError: Error?
        do {
            try deleteData(account: account, useDataProtectionKeychain: true)
        } catch {
            dataProtectionError = error
        }
        do {
            try deleteLegacy(account: account)
        } catch {
            if dataProtectionError == nil {
                throw error
            }
        }
    }

    private func identityQuery(for account: String, useDataProtectionKeychain: Bool) -> [String: Any] {
        // Keep identity keys minimal so reads/updates match what was written.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if useDataProtectionKeychain {
            if #available(macOS 10.15, *) {
                query[kSecUseDataProtectionKeychain as String] = true
            }
        }
        return query
    }

    private func addQuery(
        for account: String,
        data: Data,
        useDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query = identityQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
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
        allowInteraction: Bool
    ) throws -> Data? {
        var query = identityQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
        if #available(macOS 10.10, *) {
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

    private func loadLegacy(account: String, allowInteraction: Bool) throws -> Data? {
        var query = identityQuery(for: account, useDataProtectionKeychain: false)
        if #available(macOS 10.10, *) {
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

    private func deleteLegacy(account: String) throws {
        var query = identityQuery(for: account, useDataProtectionKeychain: false)
        if #available(macOS 10.10, *) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func saveData(_ data: Data, account: String, useDataProtectionKeychain: Bool) throws {
        let insertQuery = addQuery(for: account, data: data, useDataProtectionKeychain: useDataProtectionKeychain)
        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateQuery = identityQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
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

    private func deleteData(account: String, useDataProtectionKeychain: Bool) throws {
        let query = identityQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError.operationFailed(status: status)
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

    static func resolve(matchingSuffix suffix: String) -> String? {
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
    }
}
