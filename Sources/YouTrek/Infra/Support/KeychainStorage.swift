import Foundation
import Security

struct KeychainStorage {
    let service: String

    init(service: String) {
        self.service = service
    }

    func save(data: Data, account: String) throws {
        var query: [String: Any] = baseQuery(for: account)
        // Remove any existing entry first so we can perform an idempotent write.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    func load(account: String) throws -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    func delete(account: String) throws {
        let query = baseQuery(for: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError.operationFailed(status: status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
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
