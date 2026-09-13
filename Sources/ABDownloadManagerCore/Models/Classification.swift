import Foundation

public enum HostOverrideError: Error, LocalizedError, Equatable { case invalidHost(String); public var errorDescription: String? { if case .invalidHost(let value) = self { return "Invalid host: \(value)" }; return nil } }

public struct HostOverride: Codable, Sendable, Hashable, Identifiable {
    public var host: String
    public var headers: [String: String]
    public var threadCount: Int?
    public var speedLimit: Int64?
    public var defaultFolder: String?
    public var categoryID: Int64?
    public var id: String { host }
    public init(host: String, headers: [String: String] = [:], threadCount: Int? = nil, speedLimit: Int64? = nil, defaultFolder: String? = nil, categoryID: Int64? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); self.headers = headers; self.threadCount = threadCount; self.speedLimit = speedLimit; self.defaultFolder = defaultFolder; self.categoryID = categoryID
    }
    public static func normalizeHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), !host.contains(" "), URL(string: "https://\(host)")?.host == host else { throw HostOverrideError.invalidHost(value) }
        return host
    }
    public init(validatingHost value: String, headers: [String: String] = [:], threadCount: Int? = nil, speedLimit: Int64? = nil, defaultFolder: String? = nil, categoryID: Int64? = nil) throws {
        try self.init(host: Self.normalizeHost(value), headers: headers, threadCount: threadCount, speedLimit: speedLimit, defaultFolder: defaultFolder, categoryID: categoryID)
    }
    public func applies(to url: URL) -> Bool { host == url.host?.lowercased() }
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
