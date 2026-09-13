import Foundation
import CommonCrypto

public struct HLSDownloadResult: Sendable {
    public let bytes: Int64
    public let segments: Int
    public let finalURL: URL
}

/// Downloads HLS media playlists without relying on a third-party player.
/// VOD playlists are resumed using a sidecar containing the completed segment
/// count. Live playlists are intentionally rejected because they never have a
/// stable completion boundary for a file download.
public struct HLSDownloader: Sendable {
    private let client: HTTPClient
    private let source: DownloadSource

    public init(client: HTTPClient, source: DownloadSource) {
        self.client = client
        self.source = source
    }

    public func download(
        to destination: URL,
        beforeSegment: @escaping @Sendable () async throws -> Void = {},
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void = { _, _ in }
    ) async throws -> HLSDownloadResult {
        let playlist = try await fetchPlaylist(at: source.url)
        let selected = try await selectMediaPlaylist(playlist)
        guard !selected.isLive else { throw DownloadEngineError.unsupportedHLS("live playlists are not finite downloads") }
        let folder = destination.deletingLastPathComponent()
        let sidecar = destination.appendingPathExtension("hls.json")
        let state = HLSResumeState.load(from: sidecar)
        var startIndex = state?.playlistURL == selected.url.absoluteString ? min(state!.completedSegments, selected.segments.count) : 0
        if startIndex > 0 && !FileManager.default.fileExists(atPath: destination.path) { startIndex = 0 }
        if startIndex == 0 {
            try? FileManager.default.removeItem(at: destination)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        var completed = startIndex
        for index in startIndex..<selected.segments.count {
            try await beforeSegment()
            let segment = selected.segments[index]
            let segmentStart = bytes
            do {
                if segment.key == nil {
                    let (stream, response) = try await client.stream(url: segment.url, headers: source.headers)
                    guard (200..<300).contains(response.statusCode) else { throw DownloadEngineError.invalidResponse(response.statusCode) }
                    var buffer = Data(); buffer.reserveCapacity(64 * 1024)
                    for try await byte in stream {
                        try await beforeSegment()
                        buffer.append(byte)
                        if buffer.count >= 64 * 1024 {
                            try handle.write(contentsOf: buffer); bytes += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                            await onProgress(bytes, selected.totalBytes)
                        }
                    }
                    if !buffer.isEmpty { try handle.write(contentsOf: buffer); bytes += Int64(buffer.count) }
                } else if let key = segment.key {
                    // CommonCrypto's CBC operation is intentionally bounded to
                    // one encrypted segment; unencrypted segments above stream.
                    let response = try await client.request(url: segment.url, headers: source.headers)
                    guard (200..<300).contains(response.response.statusCode) else { throw DownloadEngineError.invalidResponse(response.response.statusCode) }
                    let keyResponse = try await client.request(url: key.url, headers: source.headers)
                    guard (200..<300).contains(keyResponse.response.statusCode), keyResponse.data.count == kCCBlockSizeAES128 else { throw DownloadEngineError.unsupportedHLS("AES-128 key was unavailable") }
                    let data = try decryptAES128CBC(data: response.data, key: keyResponse.data, iv: key.iv ?? Self.iv(for: index))
                    try handle.write(contentsOf: data); bytes += Int64(data.count)
                }
                completed = index + 1
                try HLSResumeState(playlistURL: selected.url.absoluteString, completedSegments: completed).save(to: sidecar)
                await onProgress(bytes, selected.totalBytes)
            } catch {
                try? handle.truncate(atOffset: UInt64(segmentStart))
                bytes = segmentStart
                throw error
            }
        }
        try? FileManager.default.removeItem(at: sidecar)
        _ = folder
        return HLSDownloadResult(bytes: bytes, segments: completed, finalURL: selected.url)
    }

    private func fetchPlaylist(at url: URL) async throws -> PlaylistDocument {
        let response = try await client.request(url: url, headers: source.headers)
        guard (200..<300).contains(response.response.statusCode), let text = String(data: response.data, encoding: .utf8) else {
            throw DownloadEngineError.invalidResponse(response.response.statusCode)
        }
        return PlaylistDocument(url: response.response.url ?? url, text: text)
    }

    private func selectMediaPlaylist(_ playlist: PlaylistDocument) async throws -> MediaPlaylist {
        let lines = playlist.text.split(whereSeparator: \ .isNewline).map(String.init)
        var variants: [(url: URL, bandwidth: Int)] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            let bandwidth = lines[index].split(separator: ",").first(where: { $0.contains("BANDWIDTH=") }).flatMap { Int($0.split(separator: "=").last ?? "0") } ?? 0
            if index + 1 < lines.count, let url = URL(string: lines[index + 1], relativeTo: playlist.url)?.absoluteURL { variants.append((url, bandwidth)) }
        }
        if let variant = variants.max(by: { $0.bandwidth < $1.bandwidth }) { return try parseMedia(try await fetchPlaylist(at: variant.url)) }
        return try parseMedia(playlist)
    }

    private func parseMedia(_ playlist: PlaylistDocument) throws -> MediaPlaylist {
        let lines = playlist.text.split(whereSeparator: \ .isNewline).map(String.init)
        guard lines.contains("#EXTM3U") else { throw DownloadEngineError.unsupportedHLS("missing EXTM3U header") }
        let isLive = !lines.contains("#EXT-X-ENDLIST")
        var segments: [HLSSegment] = []
        var total: Int64 = 0
        var currentKey: HLSKey?
        var pendingDuration: Double?
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = try parseKey(line, relativeTo: playlist.url)
            } else if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "0")
            } else if !line.hasPrefix("#"), let url = URL(string: line, relativeTo: playlist.url)?.absoluteURL {
                segments.append(HLSSegment(url: url, duration: pendingDuration ?? 0, key: currentKey))
                pendingDuration = nil
            }
        }
        guard !segments.isEmpty else { throw DownloadEngineError.unsupportedHLS("playlist has no media segments") }
        for segment in segments { _ = segment.duration; total += 0 }
        return MediaPlaylist(url: playlist.url, segments: segments, isLive: isLive, totalBytes: nil)
    }

    private func parseKey(_ line: String, relativeTo base: URL) throws -> HLSKey? {
        let attributes = line.dropFirst("#EXT-X-KEY:".count).split(separator: ",")
        var method = "NONE", uri: URL?, iv: Data?
        for attribute in attributes {
            let pair = attribute.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "METHOD": method = pair[1]
            case "URI": uri = URL(string: pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")), relativeTo: base)?.absoluteURL
            case "IV":
                var value = pair[1].replacingOccurrences(of: "0x", with: "")
                if value.count % 2 != 0 { value = "0" + value }
                var data = Data()
                var index = value.startIndex
                while index < value.endIndex { let end = value.index(index, offsetBy: 2); if let byte = UInt8(value[index..<end], radix: 16) { data.append(byte) }; index = end }
                iv = data
            default: break
            }
        }
        if method == "NONE" { return nil }
        guard method == "AES-128", let uri else { throw DownloadEngineError.unsupportedHLS("encryption method \(method)") }
        return HLSKey(url: uri, iv: iv)
    }

    private static func iv(for sequence: Int) -> Data {
        var data = Data(repeating: 0, count: kCCBlockSizeAES128)
        var value = UInt64(sequence + 1)
        for index in stride(from: 15, through: 8, by: -1) { data[index] = UInt8(value & 0xff); value >>= 8 }
        return data
    }

    private func decryptAES128CBC(data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBuffer.baseAddress, key.count, ivBuffer.baseAddress, dataBuffer.baseAddress, data.count, outputBuffer.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadEngineError.unsupportedHLS("AES-128 decryption failed") }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

private struct PlaylistDocument { let url: URL; let text: String }
private struct HLSKey { let url: URL; let iv: Data? }
private struct HLSSegment { let url: URL; let duration: Double; let key: HLSKey? }
private struct MediaPlaylist { let url: URL; let segments: [HLSSegment]; let isLive: Bool; let totalBytes: Int64? }
private struct HLSResumeState: Codable { let playlistURL: String; let completedSegments: Int
    static func load(from url: URL) -> HLSResumeState? { guard let data = try? Data(contentsOf: url) else { return nil }; return try? JSONDecoder().decode(Self.self, from: data) }
    func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
}
