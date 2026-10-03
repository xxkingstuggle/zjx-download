import Foundation

public enum HostOverrideError: Error, LocalizedError, Equatable { case invalidHost(String); public var errorDescription: String? { if case .invalidHost(let value) = self { return "Invalid host: \(value)" }; return nil } }

public struct HostOverride: Codable, Sendable, Hashable, Identifiable {
    public var host: String
    public var headers: [String: String]
    public var userAgent: String
    public var authUsername: String
    /// Only held in memory; AppStateStore writes this value to Keychain.
    public var authPassword: String
    public var threadCount: Int?
    public var speedLimit: Int64?
    public var defaultFolder: String?
    public var categoryID: Int64?
    public var id: String { host }
    public init(host: String, headers: [String: String] = [:], userAgent: String = "", authUsername: String = "", authPassword: String = "", threadCount: Int? = nil, speedLimit: Int64? = nil, defaultFolder: String? = nil, categoryID: Int64? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); self.headers = headers; self.userAgent = userAgent; self.authUsername = authUsername; self.authPassword = authPassword; self.threadCount = threadCount; self.speedLimit = speedLimit; self.defaultFolder = defaultFolder; self.categoryID = categoryID
    }
    public static func normalizeHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), !host.contains(" "), URL(string: "https://\(host)")?.host == host else { throw HostOverrideError.invalidHost(value) }
        return host
    }
    public init(validatingHost value: String, headers: [String: String] = [:], userAgent: String = "", authUsername: String = "", authPassword: String = "", threadCount: Int? = nil, speedLimit: Int64? = nil, defaultFolder: String? = nil, categoryID: Int64? = nil) throws {
        try self.init(host: Self.normalizeHost(value), headers: headers, userAgent: userAgent, authUsername: authUsername, authPassword: authPassword, threadCount: threadCount, speedLimit: speedLimit, defaultFolder: defaultFolder, categoryID: categoryID)
    }
    public func applies(to url: URL) -> Bool { host == url.host?.lowercased() }

    private enum CodingKeys: String, CodingKey { case host, headers, userAgent, authUsername, threadCount, speedLimit, defaultFolder, categoryID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        authUsername = try c.decodeIfPresent(String.self, forKey: .authUsername) ?? ""
        authPassword = ""
        threadCount = try c.decodeIfPresent(Int.self, forKey: .threadCount)
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit)
        defaultFolder = try c.decodeIfPresent(String.self, forKey: .defaultFolder)
        categoryID = try c.decodeIfPresent(Int64.self, forKey: .categoryID)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host); try c.encode(headers, forKey: .headers); try c.encode(userAgent, forKey: .userAgent); try c.encode(authUsername, forKey: .authUsername)
        try c.encodeIfPresent(threadCount, forKey: .threadCount); try c.encodeIfPresent(speedLimit, forKey: .speedLimit); try c.encodeIfPresent(defaultFolder, forKey: .defaultFolder); try c.encodeIfPresent(categoryID, forKey: .categoryID)
    }
}

extension DownloadCategory {
    public var acceptedExtensions: [String] {
        get { acceptedFileTypes }
        set { acceptedFileTypes = newValue }
    }
    public var acceptedHosts: [String] {
        get { acceptedURLPatterns.filter { !$0.contains("*") && !$0.contains("/") } }
        set { acceptedURLPatterns = newValue }
    }
    public var defaultFolder: String? {
        get { categoryPath }
        set { categoryPath = newValue }
    }
    public func matches(url: URL, fileName: String) -> Bool {
        guard !acceptedFileTypes.isEmpty || !acceptedURLPatterns.isEmpty else { return false }
        let extensionMatch = acceptedFileTypes.isEmpty || acceptedFileTypes.contains { fileName.lowercased().hasSuffix("." + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        let host = url.host?.lowercased() ?? ""
        let hostMatch = acceptedHosts.isEmpty || acceptedHosts.contains { host == $0.lowercased() }
        let patternMatch = acceptedURLPatterns.filter { $0.contains("*") || $0.contains("/") }.isEmpty || acceptedURLPatterns.filter { $0.contains("*") || $0.contains("/") }.contains { wildcard($0, matches: url.absoluteString) }
        return extensionMatch && hostMatch && patternMatch
    }
    private func wildcard(_ pattern: String, matches value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return false }
        var cursor = value.startIndex
        for (index, part) in parts.enumerated() {
            guard let found = value.range(of: part, options: [.caseInsensitive], range: cursor..<value.endIndex) else { return false }
            if index == 0 && found.lowerBound != value.startIndex { return false }
            cursor = found.upperBound
        }
        return !pattern.hasSuffix("*") ? cursor == value.endIndex : true
    }
}
