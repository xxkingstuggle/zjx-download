import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case invalidData
    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作失败（\(status)）"
        case .invalidData: "钥匙串内容格式无效。"
        }
    }
}

public struct CredentialStore: Sendable {
    public let service: String
    public init(service: String = ProductIdentity.bundleID + ".credentials") { self.service = service }

    public func readData(account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw CredentialStoreError.keychainStatus(status) }
        return data
    }

    public func read(account: String) throws -> String? {
        guard let data = try readData(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw CredentialStoreError.invalidData }
        return value
    }

    public func writeData(_ data: Data?, account: String) throws {
        let query = base(account)
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychainStatus(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CredentialStoreError.keychainStatus(update) }
        var item = query
        item.merge(attributes) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    }

    public func write(_ value: String?, account: String) throws {
        try writeData(value.map { Data($0.utf8) }, account: account)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

public enum DirectoryAccess {
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
