import Foundation

/// Keeps credentials out of the plain text header editor while ensuring that
/// editing a task does not silently discard or leak its saved credentials.
public enum HTTPHeaderEditingPolicy {
    public static let sensitiveNames: [String] = [
        "Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie",
        "X-API-Key", "API-Key", "X-Auth-Token"
    ]

    private static let sensitiveNameSet = Set(sensitiveNames.map { $0.lowercased() })

    public static func isSensitive(_ name: String) -> Bool {
        sensitiveNameSet.contains(name.lowercased())
    }

    public static func publicHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { !isSensitive($0.key) }
    }

    public static func sensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { isSensitive($0.key) }
    }

    /// Edited secret fields retain their original values only for the same
    /// origin. When an existing task is pointed at another origin, unchanged
    /// credentials are dropped; newly entered or changed values are explicit.
    public static func merge(
        public editedPublic: [String: String],
        sensitive editedSensitive: [String: String],
        original: [String: String],
        from originalURL: URL,
        to editedURL: URL
    ) -> [String: String] {
        var result = publicHeaders(editedPublic)
        let originalSecrets = sensitiveHeaders(original)
        let sameOrigin = origin(of: originalURL) == origin(of: editedURL)

        for (name, value) in sensitiveHeaders(editedSensitive) {
            guard !value.isEmpty else { continue }
            let previous = originalSecrets.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            guard sameOrigin || previous != value else { continue }
            result[name] = value
        }
        return result
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
