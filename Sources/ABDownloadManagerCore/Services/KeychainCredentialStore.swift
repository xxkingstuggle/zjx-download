import Foundation
import Security

public enum KeychainCredentialError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))"
        case .invalidUTF8:
            "The stored Keychain value is not UTF-8 text."
        }
    }
}

/// Stores app secrets in the user's login Keychain, scoped to one profile.
public struct KeychainCredentialStore: Sendable {
    public let service: String

    public init(service: String = "com.abdownloadmanager.mac.credentials") {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainCredentialError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw KeychainCredentialError.invalidUTF8 }
        return value
    }

    public func write(_ value: String, account: String) throws {
        guard !value.isEmpty else { try remove(account: account); return }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainCredentialError.unexpectedStatus(status) }
        var item = query
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainCredentialError.unexpectedStatus(addStatus) }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainCredentialError.unexpectedStatus(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
