import Foundation
import LocalAuthentication
import Security

struct KeychainStorage {
    let service: String

    init(service: String) {
        self.service = service
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

    func load(account: String) throws -> Data? {
        var dataProtectionError: Error?
        do {
            if let data = try loadData(account: account, useDataProtectionKeychain: true) {
                return data
            }
        } catch {
            dataProtectionError = error
        }

        if let legacyData = try loadLegacy(account: account) {
            if dataProtectionError == nil {
                try? saveData(legacyData, account: account, useDataProtectionKeychain: true)
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
        if useDataProtectionKeychain {
            if #available(macOS 10.15, *) {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return query
    }

    private func loadData(account: String, useDataProtectionKeychain: Bool) throws -> Data? {
        var query = baseQuery(for: account, useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound, errSecInteractionNotAllowed:
            return nil
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func loadLegacy(account: String) throws -> Data? {
        var query = baseQuery(for: account, useDataProtectionKeychain: false)
        if #available(macOS 11.0, *) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        } else if #available(macOS 10.10, *) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound, errSecInteractionNotAllowed:
            return nil
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func deleteLegacy(account: String) throws {
        var query = baseQuery(for: account, useDataProtectionKeychain: false)
        if #available(macOS 11.0, *) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        } else if #available(macOS 10.10, *) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
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
        guard status == errSecSuccess else {
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
