import Foundation

public enum BatchPatternError: Error, LocalizedError, Equatable {
    case missingWildcard
    case invalidRange
    case rangeTooLarge(maximum: Int)
    case invalidURL
    public var errorDescription: String? {
        switch self { case .missingWildcard: "The URL pattern must contain *."; case .invalidRange: "The numeric range is invalid."; case .rangeTooLarge(let maximum): "The range cannot contain more than \(maximum) links."; case .invalidURL: "The generated URL is invalid." }
    }
}

/// Expands the legacy `*` numeric batch syntax with the same zero-padding
/// behavior as the original WildcardString component.
public struct BatchURLPattern: Sendable, Equatable {
    public let pattern: String
    public let start: Int
    public let end: Int
    public let wildcardLength: Int?
    public let maximumCount: Int
    public init(pattern: String, start: Int, end: Int, wildcardLength: Int? = nil, maximumCount: Int = 1_000) throws {
        guard pattern.contains("*") else { throw BatchPatternError.missingWildcard }
        guard start >= 0, end >= start else { throw BatchPatternError.invalidRange }
        guard end - start + 1 <= maximumCount else { throw BatchPatternError.rangeTooLarge(maximum: maximumCount) }
        self.pattern = pattern; self.start = start; self.end = end; self.wildcardLength = wildcardLength; self.maximumCount = maximumCount
    }
    public var count: Int { end - start + 1 }
    public func link(at value: Int) throws -> URL {
        guard (start...end).contains(value) else { throw BatchPatternError.invalidRange }
        let minimum = max(String(start).count, String(end).count)
        let text: String
        if let wildcardLength { text = String(value).leftPadded(to: max(minimum, wildcardLength)) }
        else { text = String(value).leftPadded(to: minimum) }
        guard let url = URL(string: pattern.replacingOccurrences(of: "*", with: text)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw BatchPatternError.invalidURL }
        return url
    }
    public func allLinks() throws -> [URL] { try (start...end).map(link(at:)) }

    /// Builds one request per generated link while preserving every shared
    /// option from the batch form.
    public func downloadRequests(
        folderPath: String?,
        headers: [String: String],
        expectedChecksum: String?,
        speedLimit: Int64,
        connectionCountOverride: Int?,
        queueID: Int64?,
        categoryID: Int64?,
        conflictPolicy: FileConflictPolicy,
        startImmediately: Bool
    ) throws -> [DownloadRequest] {
        try allLinks().map { url in
            DownloadRequest(
                source: DownloadSource(url: url, headers: headers),
                folderPath: folderPath,
                queueID: queueID,
                categoryID: categoryID,
                kind: url.pathExtension.lowercased() == "m3u8" ? .hls : .http,
                startImmediately: startImmediately,
                conflictPolicy: conflictPolicy,
                expectedChecksum: expectedChecksum,
                speedLimit: speedLimit,
                connectionCountOverride: connectionCountOverride
            )
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}
