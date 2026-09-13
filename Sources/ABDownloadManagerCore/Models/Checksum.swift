import Foundation
import CryptoKit

/// Checksum algorithms supported by the original app's `FileChecksumAlgorithm`.
public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"

    public static var `default`: ChecksumAlgorithm { .sha256 }

    /// Whether CryptoKit can compute this algorithm natively. MD5 is provided
    /// by the system `Insecure` namespace; DER-based SHA variants are not
    /// available through `Insecure`, so MD5 uses a local implementation.
    var supportsStreaming: Bool { true }
}

/// An `algorithm:value` checksum pair, matching the original's
/// `FileChecksum.toString()` wire format exactly.
public struct FileChecksum: Codable, Sendable, Hashable {
    public var algorithm: String
    public var value: String

    public init(algorithm: String, value: String) {
        self.algorithm = algorithm
        self.value = value
    }

    public var description: String { "\(algorithm):\(value)" }

    /// Parses `algorithm:value`. Throws when the shape is wrong, mirroring the
    /// original's `require(segments.size == 2)`.
    public static func fromString(_ string: String) throws -> FileChecksum {
        let segments = string.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count == 2 else {
            throw ChecksumError.invalidFormat(string)
        }
        return FileChecksum(algorithm: String(segments[0]), value: String(segments[1]))
    }

    public static func fromNullableString(_ string: String?) throws -> FileChecksum? {
        guard let string else { return nil }
        return try fromString(string)
    }

    /// Case-insensitive comparison, matching the original's `equals`.
    public func matches(_ other: FileChecksum) -> Bool {
        algorithm.caseInsensitiveCompare(other.algorithm) == .orderedSame
            && value.caseInsensitiveCompare(other.value) == .orderedSame
    }

    public func matches(rawDigest: String) -> Bool {
        value.caseInsensitiveCompare(rawDigest) == .orderedSame
    }
}

public enum ChecksumError: Error, LocalizedError, Equatable {
    case invalidFormat(String)
    case unsupportedAlgorithm(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let value):
            "Invalid checksum string: \(value) it should be in format algorithm:value"
        case .unsupportedAlgorithm(let name):
            "Unsupported checksum algorithm: \(name)"
        case .unreadable(let path):
            "Cannot read file for checksum: \(path)"
        }
    }
}

/// Streaming file hashing with progress reporting, mirroring `HashUtil`.
public enum ChecksumCalculator {
    /// Default read buffer, matching `DEFAULT_BUFFER_SIZE` semantics.
    public static let bufferSize = 64 * 1024

    /// Computes the digest of a file, reporting integer percent progress.
    public static func hash(
        algorithm: ChecksumAlgorithm,
        fileURL: URL,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ChecksumError.unreadable(fileURL.path)
        }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return try hash(
            algorithm: algorithm,
            chunks: { try handle.read(upToCount: bufferSize) ?? nil },
            totalSize: totalSize,
            onProgress: onProgress
        )
    }

    /// Computes the digest of an in-memory buffer. Used by tests and by the
    /// REST integration for small payloads.
    public static func hash(algorithm: ChecksumAlgorithm, data: Data) throws -> String {
        var offset = 0
        return try hash(
            algorithm: algorithm,
            chunks: {
                guard offset < data.count else { return nil }
                let end = min(offset + bufferSize, data.count)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            },
            totalSize: Int64(data.count),
            onProgress: { _ in }
        )
    }

    /// Shared streaming driver so every algorithm reports progress identically.
    static func hash(
        algorithm: ChecksumAlgorithm,
        chunks: () throws -> Data?,
        totalSize: Int64,
        onProgress: (Int) -> Void
    ) throws -> String {
        var hasher = try makeHasher(algorithm)
        var processed: Int64 = 0
        var lastPercent = 0

        while true {
            guard let chunk = try chunks(), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            processed += Int64(chunk.count)
            let percent = percentOf(processed, totalSize)
            if percent != lastPercent {
                onProgress(percent)
                lastPercent = percent
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func percentOf(_ processed: Int64, _ total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int((processed * 100) / total)
    }

    static func makeHasher(_ algorithm: ChecksumAlgorithm) throws -> ChecksumHasher {
        switch algorithm {
        case .md5: MD5Hasher()
        case .sha1: SHAHasher(.sha1)
        case .sha256: SHAHasher(.sha256)
        case .sha512: SHAHasher(.sha512)
        }
    }

    enum SHAVariant { case sha1, sha256, sha512 }
}

/// Minimal streaming digest interface so algorithms with different CryptoKit
/// types share one driver.
protocol ChecksumHasher {
    mutating func update(data: Data)
    mutating func finalize() -> Data
}

struct SHAHasher: ChecksumHasher {
    private enum Storage {
        case sha1(Insecure.SHA1)
        case sha256(SHA256)
        case sha512(SHA512)
    }
    private var storage: Storage

    init(_ variant: ChecksumCalculator.SHAVariant) {
        switch variant {
        case .sha1: storage = .sha1(Insecure.SHA1())
        case .sha256: storage = .sha256(SHA256())
        case .sha512: storage = .sha512(SHA512())
        }
    }

    mutating func update(data: Data) {
        switch storage {
        case .sha1(var h): h.update(data: data); storage = .sha1(h)
        case .sha256(var h): h.update(data: data); storage = .sha256(h)
        case .sha512(var h): h.update(data: data); storage = .sha512(h)
        }
    }

    mutating func finalize() -> Data {
        switch storage {
        case .sha1(let h): Data(h.finalize())
        case .sha256(let h): Data(h.finalize())
        case .sha512(let h): Data(h.finalize())
        }
    }
}

/// MD5 is not exposed by CryptoKit; this is the RFC 1321 implementation used
/// solely to reproduce the original app's MD5 checksum option.
struct MD5Hasher: ChecksumHasher {
    private var a0: UInt32 = 0x6745_2301
    private var b0: UInt32 = 0xefcd_ab89
    private var c0: UInt32 = 0x98ba_dcfe
    private var d0: UInt32 = 0x1032_5476

    private var buffer = Data()
    private var totalBytes: UInt64 = 0

    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let constants: [UInt32] = (0..<64).map { i in
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4_294_967_296.0))
    }

    mutating func update(data: Data) {
        totalBytes += UInt64(data.count)
        buffer.append(data)
        while buffer.count >= 64 {
            processBlock(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> Data {
        let bitLength = totalBytes &* 8
        var padding: [UInt8] = [0x80]
        let remainder = Int((totalBytes &+ 1) % 64)
        let padCount = remainder <= 56 ? 56 - remainder : 120 - remainder
        padding.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        for i in 0..<8 {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> (8 &* UInt64(i))))
        }
        buffer.append(contentsOf: padding)
        while buffer.count >= 64 {
            processBlock(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }

        var digest = Data()
        for value in [a0, b0, c0, d0] {
            for i in 0..<4 {
                digest.append(UInt8(truncatingIfNeeded: value >> (8 &* UInt32(i))))
            }
        }
        return digest
    }

    private mutating func processBlock(_ block: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            words[i] = UInt32(block[i * 4])
                | (UInt32(block[i * 4 + 1]) << 8)
                | (UInt32(block[i * 4 + 2]) << 16)
                | (UInt32(block[i * 4 + 3]) << 24)
        }

        var (a, b, c, d) = (a0, b0, c0, d0)

        for i in 0..<64 {
            let (f, g): (UInt32, Int)
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }
            let rotated = a &+ f &+ Self.constants[i] &+ words[g]
            let shift = Self.shifts[i]
            let temp = d
            d = c
            c = b
            b = b &+ ((rotated << shift) | (rotated >> (32 - shift)))
            a = temp
        }

        a0 &+= a
        b0 &+= b
        c0 &+= c
        d0 &+= d
    }
}
