import Foundation
import LocalAuthentication
import Security

struct KeychainStorage {
    let service: String
    let accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func save(data: Data, account: String) throws {
        do {
            try saveData(data, account: account, useDataProtectionKeychain: true)
            try? deleteLegacy(account: account)
        } catch {
            // Fall back to the legacy keychain when data protection keychain isn't available.
            try saveData(data, account: account, useDataProtectionKeychain: false)
        }
    }

    func load(account: String, allowInteraction: Bool = false) throws -> Data? {
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
                try? saveData(
                    legacyData,
                    account: account,
                    useDataProtectionKeychain: true
                )
                try? deleteLegacy(account: account)
            }
            return legacyData
        }

        if let dataProtectionError {
            throw dataProtectionError
        }
        return nil
    }

    func delete(account: String) throws {
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

    private func baseQuery(for account: String, useDataProtectionKeychain: Bool) -> [String: Any] {
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
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return query
    }

    private func loadData(
        account: String,
        useDataProtectionKeychain: Bool,
        allowInteraction: Bool
    ) throws -> Data? {
        var query = baseQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
        if #available(macOS 10.10, *) {
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
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
            if allowInteraction {
                return nil
            }
            throw KeychainStorageError.operationFailed(status: status)
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func loadLegacy(account: String, allowInteraction: Bool) throws -> Data? {
        var query = baseQuery(for: account, useDataProtectionKeychain: false)
        if #available(macOS 10.10, *) {
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
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
            if allowInteraction {
                return nil
            }
            throw KeychainStorageError.operationFailed(status: status)
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func deleteLegacy(account: String) throws {
        var query = baseQuery(for: account, useDataProtectionKeychain: false)
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
        var query: [String: Any] = baseQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
        // Remove any existing entry first so we can perform an idempotent write.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // Ensure the keychain prompt includes a stable, non-empty label if it ever appears.
        query[kSecAttrLabel as String] = service
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateQuery = baseQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
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
        let query = baseQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
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
    private static let entitlementKey = "com.apple.security.keychain-access-groups"

    static func resolve(matchingSuffix suffix: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            entitlementKey as CFString,
            nil
        ) else {
            return nil
        }
        let groups = value as? [String]
        return groups?.first(where: { $0.hasSuffix(suffix) })
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
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            entitlementKey as CFString,
            nil
        ) else {
            return []
        }
        return value as? [String] ?? []
    }
}
