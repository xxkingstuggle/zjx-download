import Foundation

public enum NativeHostProtocol {
    /// Project input limit for Chrome Native Messaging requests (4 MiB).
    public static let maximumRequestFrameSize = 4 * 1024 * 1024
    /// Native host replies are limited to 1 MiB by Chrome Native Messaging.
    public static let maximumReplyFrameSize = 1024 * 1024

    public static func readFrame(from handle: FileHandle) throws -> Data? {
        let header = try readExactly(4, from: handle)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw ValidationError("Native Messaging 长度头不完整。") }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, Int(length) <= maximumRequestFrameSize else {
            throw ValidationError("Native Messaging 请求帧超出本项目的 4 MiB 限制。")
        }
        let body = try readExactly(Int(length), from: handle)
        guard body.count == Int(length) else { throw ValidationError("Native Messaging 消息不完整。") }
        return body
    }

    public static func writeFrame(_ data: Data, to handle: FileHandle) throws {
        guard !data.isEmpty, data.count <= maximumReplyFrameSize else {
            throw ValidationError("Native Messaging 回复超出 Chrome 的 1 MiB 限制。")
        }
        var length = UInt32(data.count).littleEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        var frame = header
        frame.append(data)
        try handle.write(contentsOf: frame)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else { break }
            result.append(part)
        }
        return result
    }
}
