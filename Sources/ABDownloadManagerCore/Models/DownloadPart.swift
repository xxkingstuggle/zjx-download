import Foundation

/// Lifecycle state of a download task.
///
/// Mirrors the status set of the original `downloader/core` module. Every
/// transition is owned by `DownloadEngine`; views only read this value.
public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case created
    case downloading
    case paused
    case completed
    case failed
    case stopped
    case cancelled
    case merging

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled: true
        default: false
        }
    }

    public var isActive: Bool {
        switch self {
        case .downloading, .merging: true
        default: false
        }
    }

    public var isResumable: Bool {
        switch self {
        case .paused, .failed, .stopped, .created: true
        default: false
        }
    }
}

/// Connection/queue priority hint, preserved from the original model.
public enum DownloadPriority: String, Codable, Sendable, CaseIterable {
    case low
    case normal
    case high
}

/// Describes a parsed and validated download source.
public struct DownloadSource: Codable, Sendable, Hashable {
    /// Fully resolved URL that will actually be requested.
    public var url: URL
    /// Optional page the user copied the link from; used as the `Referer`
    /// when the server requires one.
    public var downloadPage: String?
    /// User supplied request headers. Keys are matched case-insensitively.
    public var headers: [String: String]
    /// Filename suggested by the origin (Content-Disposition or URL path).
    public var suggestedName: String?

    public init(
        url: URL,
        downloadPage: String? = nil,
        headers: [String: String] = [:],
        suggestedName: String? = nil
    ) {
        self.url = url
        self.downloadPage = downloadPage
        self.headers = headers
        self.suggestedName = suggestedName
    }
}

/// A single byte range owned by one worker connection.
public struct DownloadPart: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Inclusive start offset.
    public var from: Int64
    /// Inclusive end offset. `nil` while the total size is unknown and the
    /// part is still being discovered.
    public var to: Int64?
    /// Bytes confirmed written to the part file.
    public var downloaded: Int64
    /// Server validator captured when this part started, used to guarantee
    /// the resource did not change before we resume into it.
    public var validator: ResourceValidator?
    /// Number of consecutive failures, drives the retry backoff.
    public var failureCount: Int

    public init(
        id: UUID = UUID(),
        from: Int64,
        to: Int64?,
        downloaded: Int64 = 0,
        validator: ResourceValidator? = nil,
        failureCount: Int = 0
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.downloaded = downloaded
        self.validator = validator
        self.failureCount = failureCount
    }

    public var length: Int64? {
        guard let to else { return nil }
        return to - from + 1
    }

    public var isComplete: Bool {
        guard let length else { return false }
        return downloaded >= length
    }

    /// Absolute offset the next request for this part must start at.
    public var nextOffset: Int64 { from + downloaded }
}

extension DownloadPart {
    /// Byte range used when resuming this part, or `nil` when nothing has
    /// been fetched yet (in which case we must not send a `Range` header at
    /// all for a single-part download).
    public var resumeRange: ClosedRange<Int64>? {
        guard let to, downloaded > 0, downloaded <= to - from else { return nil }
        return (from + downloaded)...to
    }
}
