import Foundation

public enum FileConflictPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case rename
    case overwrite
    case skip
    public var id: String { rawValue }
}

public enum DownloadKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case http
    case hls
    public var id: String { rawValue }
}

public struct DownloadRequest: Codable, Sendable, Hashable {
    public var source: DownloadSource
    public var folderPath: String?
    public var fileName: String?
    public var queueID: Int64?
    public var categoryID: Int64?
    public var kind: DownloadKind
    public var startImmediately: Bool
    public var conflictPolicy: FileConflictPolicy
    public var expectedChecksum: String?
    public var speedLimit: Int64
    public var enqueue: Bool

    public init(
        source: DownloadSource,
        folderPath: String? = nil,
        fileName: String? = nil,
        queueID: Int64? = nil,
        categoryID: Int64? = nil,
        kind: DownloadKind = .http,
        startImmediately: Bool = false,
        conflictPolicy: FileConflictPolicy = .rename,
        expectedChecksum: String? = nil,
        speedLimit: Int64 = 0,
        enqueue: Bool = false
    ) {
        self.source = source
        self.folderPath = folderPath
        self.fileName = fileName
        self.queueID = queueID
        self.categoryID = categoryID
        self.kind = kind
        self.startImmediately = startImmediately
        self.conflictPolicy = conflictPolicy
        self.expectedChecksum = expectedChecksum
        self.speedLimit = max(0, speedLimit)
        self.enqueue = enqueue
    }
}

public enum DownloadEngineError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidFileName
    case pathTraversal
    case resourceChanged
    case rangeNotHonored
    case invalidResponse(Int)
    case unexpectedLength(expected: Int64, actual: Int64)
    case conflictSkipped
    case insufficientDiskSpace
    case checksumMismatch(expected: String, actual: String)
    case unsupportedHLS(String)
    case cancelled
    case missingTask
    case concurrencyLimitReached

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The download URL is invalid."
        case .invalidFileName: "The file name is invalid."
        case .pathTraversal: "The destination would escape the selected folder."
        case .resourceChanged: "The remote resource changed while resuming."
        case .rangeNotHonored: "The server did not honor the requested byte range."
        case .invalidResponse(let code): "The server returned HTTP status \(code)."
        case .unexpectedLength(let expected, let actual): "Expected \(expected) bytes but received \(actual)."
        case .conflictSkipped: "A file with this name already exists."
        case .insufficientDiskSpace: "There is not enough free disk space."
        case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), received \(actual)."
        case .unsupportedHLS(let reason): "Unsupported HLS playlist: \(reason)"
        case .cancelled: "The download was cancelled."
        case .missingTask: "The download no longer exists."
        case .concurrencyLimitReached: "The global concurrent download limit has been reached."
        }
    }
}
