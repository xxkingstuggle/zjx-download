import Foundation

/// The strong/weak validators a server can hand back to make range requests
/// safe. Mirrors the ETag / Last-Modified handling of the original engine.
public struct ResourceValidator: Codable, Sendable, Hashable {
    public var etag: String?
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    public var isEmpty: Bool { etag == nil && lastModified == nil }

    /// A validator that can be replayed with `If-Range`.
    ///
    /// ETag wins over Last-Modified per RFC 9110 §13.1.5 because it is the
    /// stronger validator. Weak ETags (`W/"..."`) are rejected: a weak
    /// validator does not guarantee byte-for-byte equality, so resuming
    /// against one could silently splice two different resources together.
    public var ifRangeValue: String? {
        if let etag, !etag.hasPrefix("W/") { return etag }
        if let lastModified { return lastModified }
        return nil
    }

    /// Whether two validators describe the same resource version.
    public func matches(_ other: ResourceValidator) -> Bool {
        if let etag, let otherEtag = other.etag {
            return etag == otherEtag
        }
        if let lastModified, let otherLastModified = other.lastModified {
            return lastModified == otherLastModified
        }
        return false
    }
}

/// Result of probing a URL with a lightweight request before downloading.
public struct ResourceInfo: Codable, Sendable, Hashable {
    public var contentLength: Int64?
    /// True when the server advertised `Accept-Ranges: bytes` **or** answered
    /// a range probe with `206 Partial Content`.
    public var supportsRanges: Bool
    public var validator: ResourceValidator
    public var contentType: String?
    public var suggestedFilename: String?
    /// Final URL after redirects.
    public var finalURL: URL
    /// Raw `Content-Disposition` value when present.
    public var contentDisposition: String?

    public init(
        contentLength: Int64? = nil,
        supportsRanges: Bool = false,
        validator: ResourceValidator = ResourceValidator(),
        contentType: String? = nil,
        suggestedFilename: String? = nil,
        finalURL: URL,
        contentDisposition: String? = nil
    ) {
        self.contentLength = contentLength
        self.supportsRanges = supportsRanges
        self.validator = validator
        self.contentType = contentType
        self.suggestedFilename = suggestedFilename
        self.finalURL = finalURL
        self.contentDisposition = contentDisposition
    }
}
