import Foundation

/// A download task as persisted on disk.
///
/// This is the single source of truth for a task's durable state. The engine
/// mutates it under a lock and the store persists snapshots; views observe it
/// read-only through the repository. Live-only values (current speed, ETA)
/// are deliberately excluded so that persistence stays cheap and deterministic.
public struct DownloadTask: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var source: DownloadSource
    /// Resolved destination directory (security-scoped bookmark is stored
    /// alongside it by `FolderBookmarkStore`).
    public var folderPath: String
    /// Final file name on disk, after conflict resolution.
    public var fileName: String
    public var status: DownloadStatus
    public var priority: DownloadPriority

    /// Total resource size once known.
    public var totalSize: Int64?
    /// Bytes across all completed parts.
    public var downloadedSize: Int64

    public var parts: [DownloadPart]
    public var validator: ResourceValidator
    /// Whether the server supports range requests for this resource. When
    /// false the task must be downloaded as a single stream.
    public var supportsRanges: Bool
    /// Number of worker connections actually used.
    public var connectionCount: Int

    public var queueID: Int64?
    public var categoryID: Int64?

    /// Expected checksum in `algorithm:value` form, verbatim from the
    /// original's `FileChecksum.toString()`.
    public var expectedChecksum: String?
    /// Computed checksum after a successful download/merge.
    public var actualChecksum: String?

    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public var errorMessage: String?
    /// Monotonic count of how many times the engine has retried this task.
    public var retryCount: Int

    /// Per-task speed limit in bytes/sec; `0` means "inherit global".
    public var speedLimit: Int64

    public var downloadPage: String?
    public var kind: DownloadKind
    public var conflictPolicy: FileConflictPolicy
    /// True only for tasks deliberately handed to the automatic scheduler.
    public var isQueued: Bool

    public init(
        id: Int64 = 0,
        source: DownloadSource,
        folderPath: String,
        fileName: String,
        status: DownloadStatus = .created,
        priority: DownloadPriority = .normal,
        totalSize: Int64? = nil,
        downloadedSize: Int64 = 0,
        parts: [DownloadPart] = [],
        validator: ResourceValidator = ResourceValidator(),
        supportsRanges: Bool = false,
        connectionCount: Int = 1,
        queueID: Int64? = nil,
        categoryID: Int64? = nil,
        expectedChecksum: String? = nil,
        actualChecksum: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0,
        speedLimit: Int64 = 0,
        downloadPage: String? = nil,
        kind: DownloadKind = .http,
        conflictPolicy: FileConflictPolicy = .rename,
        isQueued: Bool = false
    ) {
        self.id = id
        self.source = source
        self.folderPath = folderPath
        self.fileName = fileName
        self.status = status
        self.priority = priority
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.parts = parts
        self.validator = validator
        self.supportsRanges = supportsRanges
        self.connectionCount = connectionCount
        self.queueID = queueID
        self.categoryID = categoryID
        self.expectedChecksum = expectedChecksum
        self.actualChecksum = actualChecksum
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.speedLimit = speedLimit
        self.downloadPage = downloadPage
        self.kind = kind
        self.conflictPolicy = conflictPolicy
        self.isQueued = isQueued
    }

    /// Absolute path of the final merged file.
    public var filePath: String {
        (folderPath as NSString).appendingPathComponent(fileName)
    }

    /// Absolute path of the in-progress part file.
    ///
    /// The suffix is controlled by `appendExtensionToIncompleteDownloads` in
    /// the original settings; `PartFileNaming` centralises that decision so
    /// the engine and the UI agree on the location.
    public var partFilePath: String {
        filePath + PartFileNaming.incompleteSuffix
    }

    public var progress: Double {
        guard let totalSize, totalSize > 0 else { return 0 }
        return min(1.0, Double(downloadedSize) / Double(totalSize))
    }

    public var isComplete: Bool { status == .completed }
    public var canEdit: Bool { status == .created || status == .paused || status == .stopped || status == .completed }
    public var canEditRemoteSettings: Bool { canEdit && status != .completed }

    /// Recomputes `downloadedSize` from the part list. Kept as the single
    /// aggregation point so progress can never drift from the parts.
    public mutating func recomputeDownloadedSize() {
        downloadedSize = parts.reduce(0) { $0 + $1.downloaded }
    }
}

/// Central definition of the temporary/incomplete file suffix.
public enum PartFileNaming {
    /// Suffix appended to the destination while a download is incomplete.
    public static let incompleteSuffix = ".abpart"
}

extension DownloadTask {
    private enum CodingKeys: String, CodingKey {
        case id, source, folderPath, fileName, status, priority, totalSize, downloadedSize, parts, validator, supportsRanges, connectionCount, queueID, categoryID, expectedChecksum, actualChecksum, createdAt, startedAt, completedAt, errorMessage, retryCount, speedLimit, downloadPage, kind, conflictPolicy, isQueued
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id); source = try c.decode(DownloadSource.self, forKey: .source)
        folderPath = try c.decode(String.self, forKey: .folderPath); fileName = try c.decode(String.self, forKey: .fileName)
        status = try c.decode(DownloadStatus.self, forKey: .status); priority = try c.decode(DownloadPriority.self, forKey: .priority)
        totalSize = try c.decodeIfPresent(Int64.self, forKey: .totalSize); downloadedSize = try c.decode(Int64.self, forKey: .downloadedSize)
        parts = try c.decode([DownloadPart].self, forKey: .parts); validator = try c.decode(ResourceValidator.self, forKey: .validator)
        supportsRanges = try c.decode(Bool.self, forKey: .supportsRanges); connectionCount = try c.decode(Int.self, forKey: .connectionCount)
        queueID = try c.decodeIfPresent(Int64.self, forKey: .queueID); categoryID = try c.decodeIfPresent(Int64.self, forKey: .categoryID)
        expectedChecksum = try c.decodeIfPresent(String.self, forKey: .expectedChecksum); actualChecksum = try c.decodeIfPresent(String.self, forKey: .actualChecksum)
        createdAt = try c.decode(Date.self, forKey: .createdAt); startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt); completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage); retryCount = try c.decode(Int.self, forKey: .retryCount); speedLimit = try c.decode(Int64.self, forKey: .speedLimit)
        downloadPage = try c.decodeIfPresent(String.self, forKey: .downloadPage); kind = try c.decodeIfPresent(DownloadKind.self, forKey: .kind) ?? .http; conflictPolicy = try c.decodeIfPresent(FileConflictPolicy.self, forKey: .conflictPolicy) ?? .rename; isQueued = try c.decodeIfPresent(Bool.self, forKey: .isQueued) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(source, forKey: .source); try c.encode(folderPath, forKey: .folderPath); try c.encode(fileName, forKey: .fileName)
        try c.encode(status, forKey: .status); try c.encode(priority, forKey: .priority); try c.encodeIfPresent(totalSize, forKey: .totalSize); try c.encode(downloadedSize, forKey: .downloadedSize); try c.encode(parts, forKey: .parts); try c.encode(validator, forKey: .validator); try c.encode(supportsRanges, forKey: .supportsRanges); try c.encode(connectionCount, forKey: .connectionCount); try c.encodeIfPresent(queueID, forKey: .queueID); try c.encodeIfPresent(categoryID, forKey: .categoryID); try c.encodeIfPresent(expectedChecksum, forKey: .expectedChecksum); try c.encodeIfPresent(actualChecksum, forKey: .actualChecksum); try c.encode(createdAt, forKey: .createdAt); try c.encodeIfPresent(startedAt, forKey: .startedAt); try c.encodeIfPresent(completedAt, forKey: .completedAt); try c.encodeIfPresent(errorMessage, forKey: .errorMessage); try c.encode(retryCount, forKey: .retryCount); try c.encode(speedLimit, forKey: .speedLimit); try c.encodeIfPresent(downloadPage, forKey: .downloadPage); try c.encode(kind, forKey: .kind); try c.encode(conflictPolicy, forKey: .conflictPolicy); try c.encode(isQueued, forKey: .isQueued)
    }
}
