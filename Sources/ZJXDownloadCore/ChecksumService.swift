import Foundation
import CryptoKit
import zlib

public enum ChecksumService {
    public static func calculate(file: URL, algorithm: String) throws -> String {
        let key = algorithm.lowercased().replacingOccurrences(of: "-", with: "")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        switch key {
        case "sha256", "sha2":
            var digest = SHA256()
            try consume(input) { digest.update(data: $0) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        case "sha512":
            var digest = SHA512()
            try consume(input) { digest.update(data: $0) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        case "sha1":
            var digest = Insecure.SHA1()
            try consume(input) { digest.update(data: $0) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        case "md5":
            var digest = Insecure.MD5()
            try consume(input) { digest.update(data: $0) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        case "crc32":
            var crc: uLong = zlib.crc32(0, nil, 0)
            try consume(input) { bytes in
                bytes.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
                    crc = zlib.crc32(crc, base, uInt(raw.count))
                }
            }
            return String(format: "%08x", UInt32(truncatingIfNeeded: crc))
        default:
            throw ValidationError("支持 SHA-256、SHA-512、SHA-1、MD5 和 CRC-32。")
        }
    }

    private static func consume(_ file: FileHandle, body: (Data) -> Void) throws {
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { return }
            body(chunk)
        }
    }
}
