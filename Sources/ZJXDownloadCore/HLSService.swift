import CryptoKit
import Darwin
import Foundation

private final class HLSNetworkDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private final class StreamState {
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation
        var responseDelivered = false

        init(chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.chunkContinuation = chunkContinuation
        }
    }

    private let allowInvalidTLS: Bool
    private let proxyUsername: String
    private let proxyPassword: String
    private let streamLock = NSLock()
    private var streams: [Int: StreamState] = [:]

    init(allowInvalidTLS: Bool, proxyUsername: String, proxyPassword: String) {
        self.allowInvalidTLS = allowInvalidTLS
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
    }

    func openChunkStream(for request: URLRequest, on session: URLSession) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let dataTask = session.dataTask(with: request)
        let taskID = dataTask.taskIdentifier
        var continuationRef: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuationRef = continuation
            continuation.onTermination = { [weak self] _ in
                dataTask.cancel()
                self?.unregister(taskID: taskID)
            }
        }
        guard let chunkContinuation = continuationRef else { throw CancellationError() }
        let state = StreamState(chunkContinuation: chunkContinuation)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                streamLock.lock()
                state.responseContinuation = continuation
                streams[taskID] = state
                streamLock.unlock()
                if Task.isCancelled {
                    dataTask.cancel()
                } else {
                    dataTask.resume()
                }
            }
        } onCancel: {
            dataTask.cancel()
        }
        return (response, stream)
    }

    private func unregister(taskID: Int) {
        streamLock.lock()
        streams.removeValue(forKey: taskID)
        streamLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           allowInvalidTLS, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if challenge.protectionSpace.isProxy(), !proxyUsername.isEmpty, !proxyPassword.isEmpty {
            completionHandler(.useCredential, URLCredential(user: proxyUsername, password: proxyPassword, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var safe = request
        guard let old = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let next = request.url, NetworkConfiguration.validate(next) else {
            completionHandler(nil)
            return
        }
        if old.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
            completionHandler(nil)
            return
        }
        if !NetworkConfiguration.hasSameOrigin(old, next) {
            for name in NetworkConfiguration.sensitiveHeaderNames { safe.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(safe)
    }
}

extension HLSNetworkDelegate: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamLock.lock()
        let state = streams[dataTask.taskIdentifier]
        let continuation = state?.responseContinuation
        state?.responseContinuation = nil
        state?.responseDelivered = true
        streamLock.unlock()
        if let http = response as? HTTPURLResponse {
            continuation?.resume(returning: http)
            completionHandler(.allow)
        } else {
            let error = DownloadEngineError.unsupportedContent("服务器没有返回有效的 HTTP 响应。")
            continuation?.resume(throwing: error)
            state?.chunkContinuation.finish(throwing: error)
            unregister(taskID: dataTask.taskIdentifier)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        streamLock.lock()
        let state = streams[dataTask.taskIdentifier]
        streamLock.unlock()
        state?.chunkContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        streamLock.lock()
        let state = streams.removeValue(forKey: task.taskIdentifier)
        let continuation = state?.responseContinuation
        state?.responseContinuation = nil
        streamLock.unlock()
        if let error {
            let reported: Error = (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error
            continuation?.resume(throwing: reported)
            state?.chunkContinuation.finish(throwing: reported)
        } else {
            if let continuation {
                continuation.resume(throwing: DownloadEngineError.unsupportedContent("服务器未返回响应头即断开连接。"))
            }
            state?.chunkContinuation.finish()
        }
    }
}

private struct HLSCachedSegment: Codable, Sendable {
    var url: String
    var etag: String?
    var lastModified: String?
    var size: Int64
}

private struct HLSResumeManifest: Codable, Sendable {
    var playlistDigest: String
    var segmentURLs: [String]
    var completed: [Int: HLSCachedSegment]
}

private struct HLSResumeJournalHeader: Codable, Sendable {
    var formatVersion: Int
    var playlistDigest: String
    var segmentURLs: [String]
}

private struct HLSResumeJournalEntry: Codable, Sendable {
    var index: Int
    var segment: HLSCachedSegment
}

private actor HLSResumeStore {
    static let shared = HLSResumeStore()

    private struct State {
        var generation: UInt64
        var journalURL: URL
        var manifest: HLSResumeManifest
        var dirty = false
    }

    private var latestGeneration: [Int64: UInt64] = [:]
    private var activeGeneration: [Int64: UInt64] = [:]
    private var states: [Int64: State] = [:]

    func activate(taskID: Int64, generation: UInt64) throws {
        try Task.checkCancellation()
        if let latest = latestGeneration[taskID], generation <= latest { throw CancellationError() }
        if activeGeneration[taskID] == generation { throw DownloadEngineError.conflict }
        latestGeneration[taskID] = generation
        activeGeneration[taskID] = generation
        states.removeValue(forKey: taskID)
    }

    func prepare(taskID: Int64, generation: UInt64, root: URL, digest: String,
                 segmentURLs: [String], resetResume: Bool = false) throws -> HLSResumeManifest {
        try requireCurrent(taskID: taskID, generation: generation)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let journalURL = root.appendingPathComponent("resume.jsonl")
        let legacyURL = root.appendingPathComponent("resume.json")
        let header = HLSResumeJournalHeader(formatVersion: 1, playlistDigest: digest, segmentURLs: segmentURLs)
        var manifest: HLSResumeManifest
        if !resetResume,
           let data = Self.readBoundedResume(at: journalURL),
           let (storedHeader, entries) = Self.decodeJournal(data),
           storedHeader.formatVersion == 1,
           storedHeader.playlistDigest == digest,
           storedHeader.segmentURLs == segmentURLs {
            var completed: [Int: HLSCachedSegment] = [:]
            for entry in entries where entry.index >= 0 && entry.index < segmentURLs.count &&
                entry.segment.url == segmentURLs[entry.index] {
                completed[entry.index] = entry.segment
            }
            manifest = HLSResumeManifest(playlistDigest: digest, segmentURLs: segmentURLs, completed: completed)
        } else if !resetResume,
                  let data = Self.readBoundedResume(at: legacyURL),
                  let old = try? JSONDecoder().decode(HLSResumeManifest.self, from: data),
                  old.playlistDigest == digest, old.segmentURLs == segmentURLs {
            manifest = old
            try Self.writeJournal(header: header, manifest: manifest, to: journalURL)
        } else {
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: child)
            }
            manifest = HLSResumeManifest(playlistDigest: digest, segmentURLs: segmentURLs, completed: [:])
            try Self.writeHeader(header, to: journalURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        states[taskID] = State(generation: generation, journalURL: journalURL, manifest: manifest)
        return manifest
    }

    func isCurrent(taskID: Int64, generation: UInt64) -> Bool {
        activeGeneration[taskID] == generation && states[taskID]?.generation == generation
    }

    func cached(taskID: Int64, generation: UInt64, index: Int) -> HLSCachedSegment? {
        guard isCurrent(taskID: taskID, generation: generation) else { return nil }
        return states[taskID]?.manifest.completed[index]
    }

    func install(taskID: Int64, generation: UInt64, temporary: URL, destination: URL,
                 segment: HLSCachedSegment, index: Int) throws {
        try requireCurrent(taskID: taskID, generation: generation)
        try Task.checkCancellation()
        guard var state = states[taskID], index >= 0, index < state.manifest.segmentURLs.count,
              segment.url == state.manifest.segmentURLs[index] else { throw CancellationError() }
        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let entry = HLSResumeJournalEntry(index: index, segment: segment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let file = try FileHandle(forWritingTo: state.journalURL)
        do {
            try file.seekToEnd()
            try file.write(contentsOf: line)
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        state.manifest.completed[index] = segment
        state.dirty = true
        states[taskID] = state
    }

    func flush(taskID: Int64, generation: UInt64) throws {
        try requireCurrent(taskID: taskID, generation: generation)
        guard var state = states[taskID], state.dirty else { return }
        let file = try FileHandle(forWritingTo: state.journalURL)
        try file.synchronize()
        try file.close()
        state.dirty = false
        states[taskID] = state
    }

    func end(taskID: Int64, generation: UInt64) throws {
        guard activeGeneration[taskID] == generation else { throw CancellationError() }
        defer {
            if activeGeneration[taskID] == generation { activeGeneration.removeValue(forKey: taskID) }
            if states[taskID]?.generation == generation { states.removeValue(forKey: taskID) }
        }
        try flush(taskID: taskID, generation: generation)
    }

    func clearTask(taskID: Int64) {
        latestGeneration.removeValue(forKey: taskID)
        activeGeneration.removeValue(forKey: taskID)
        states.removeValue(forKey: taskID)
    }

    private func requireCurrent(taskID: Int64, generation: UInt64) throws {
        guard activeGeneration[taskID] == generation else { throw CancellationError() }
    }

    private static func decodeJournal(_ data: Data) -> (HLSResumeJournalHeader, [HLSResumeJournalEntry])? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let first = lines.first,
              let header = try? JSONDecoder().decode(HLSResumeJournalHeader.self, from: Data(first)) else { return nil }
        let entries = lines.dropFirst().compactMap {
            try? JSONDecoder().decode(HLSResumeJournalEntry.self, from: Data($0))
        }
        return (header, entries)
    }

    private static func writeHeader(_ header: HLSResumeJournalHeader, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(header)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeJournal(header: HLSResumeJournalHeader, manifest: HLSResumeManifest,
                                     to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DownloadEngineError.missingDestination
        }
        let file = try FileHandle(forWritingTo: url)
        do {
            try file.write(contentsOf: encoder.encode(header))
            try file.write(contentsOf: Data([0x0A]))
            for (index, segment) in manifest.completed.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try file.write(contentsOf: encoder.encode(HLSResumeJournalEntry(index: index, segment: segment)))
                try file.write(contentsOf: Data([0x0A]))
            }
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readBoundedResume(at url: URL) -> Data? {
        let maximumBytes = 64 * 1024 * 1024
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else { return nil }
        return try? Data(contentsOf: url)
    }
}

private actor HLSRateLimiter {
    private var bytesPerSecond: Double
    private var taskReservedUntil = Date.now

    init(bytesPerSecond: Int64) { self.bytesPerSecond = Double(max(0, bytesPerSecond)) }

    func update(bytesPerSecond: Int64) {
        let next = Double(max(0, bytesPerSecond))
        if next == 0 || next > self.bytesPerSecond {
            taskReservedUntil = .now
        }
        self.bytesPerSecond = next
    }

    func reserve(_ byteCount: Int) -> TimeInterval {
        guard byteCount > 0, bytesPerSecond > 0 else { return 0 }
        let now = Date.now
        let start = max(now, taskReservedUntil)
        let proposedEnd = start.addingTimeInterval(Double(byteCount) / bytesPerSecond)
        taskReservedUntil = min(proposedEnd, now.addingTimeInterval(5.0))
        return max(0, taskReservedUntil.timeIntervalSince(now))
    }
}

public actor HLSRuntimePolicy {
    private var settings: AppSettings
    private var maximumConnections: Int
    private var speedLimitBytesPerSecond: Int64
    private var taskConnectionOverride: Bool

    public init(settings: AppSettings, maximumConnections: Int, speedLimitBytesPerSecond: Int64,
                taskConnectionOverride: Bool) {
        self.settings = settings
        self.maximumConnections = max(1, min(maximumConnections, 256))
        self.speedLimitBytesPerSecond = max(0, speedLimitBytesPerSecond)
        self.taskConnectionOverride = taskConnectionOverride
    }

    public func update(settings: AppSettings, maximumConnections: Int, speedLimitBytesPerSecond: Int64,
                       taskConnectionOverride: Bool) {
        self.settings = settings
        self.maximumConnections = max(1, min(maximumConnections, 256))
        self.speedLimitBytesPerSecond = max(0, speedLimitBytesPerSecond)
        self.taskConnectionOverride = taskConnectionOverride
    }

    public func snapshot() -> (AppSettings, Int, Int64, Bool) {
        (settings, maximumConnections, speedLimitBytesPerSecond, taskConnectionOverride)
    }
}

private actor HLSProgressTracker {
    private var completedBytes: Int64 = 0
    private var inFlight: [Int: Int64] = [:]
    private var lastEmission = Date.distantPast
    private let minimumEmissionInterval: TimeInterval = 0.1

    func update(index: Int, bytes: Int64, completed: Bool = false, force: Bool = false) -> (Int64, Bool) {
        if completed {
            let (sum, overflow) = completedBytes.addingReportingOverflow(max(0, bytes))
            completedBytes = overflow ? Int64.max : max(0, sum)
            inFlight.removeValue(forKey: index)
        } else {
            inFlight[index] = max(0, bytes)
        }
        let inFlightBytes = inFlight.values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
        let (total, overflow) = completedBytes.addingReportingOverflow(inFlightBytes)
        let now = Date.now
        let shouldEmit = force || now.timeIntervalSince(lastEmission) >= minimumEmissionInterval
        if shouldEmit { lastEmission = now }
        return (overflow ? Int64.max : total, shouldEmit)
    }
}

private actor HLSConnectionPool {
    private struct Waiter {
        let id: UUID
        let limit: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]
    /// A released slot is reserved until the resumed task observes cancellation
    /// and either takes ownership or returns the slot to this actor.
    private var reservations: Set<UUID> = []

    func acquire(host: String, limit: Int) async throws {
        try Task.checkCancellation()
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if (waiters[host]?.isEmpty ?? true), active[host, default: 0] < max(1, limit) {
                        active[host, default: 0] += 1
                        reservations.insert(id)
                        continuation.resume(returning: ())
                    } else {
                        waiters[host, default: []].append(Waiter(id: id, limit: max(1, limit), continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(host: host, id: id) }
            }
            try Task.checkCancellation()
            reservations.remove(id)
        } catch {
            if reservations.remove(id) != nil { release(host: host) }
            throw error
        }
    }

    private func cancelWaiter(host: String, id: UUID) {
        guard var queue = waiters[host], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { waiters.removeValue(forKey: host) }
        else { waiters[host] = queue }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(host: String) {
        active[host] = max(0, active[host, default: 0] - 1)
        guard var queue = waiters[host], !queue.isEmpty else {
            if active[host] == 0 { active.removeValue(forKey: host) }
            return
        }
        if let index = queue.firstIndex(where: { active[host, default: 0] < $0.limit }) {
            let next = queue.remove(at: index)
            if queue.isEmpty { waiters.removeValue(forKey: host) }
            else { waiters[host] = queue }
            active[host, default: 0] += 1
            reservations.insert(next.id)
            next.continuation.resume(returning: ())
        } else {
            waiters[host] = queue
            if active[host] == 0 { active.removeValue(forKey: host) }
        }
    }

}

public struct HLSPlaylist: Sendable {
    public var segments: [URL]
    public var mediaSequence: Int
    public var totalDuration: Double?
}

public enum HLSService {
    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let cleanedText = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = cleanedText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw DownloadEngineError.unsupportedContent("HLS 清单格式无效。") }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            throw DownloadEngineError.unsupportedContent("这是多画质主清单。请在 Chrome 媒体候选中选择一个画质后再发送。")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-MAP:") || $0.hasPrefix("#EXT-X-BYTERANGE:") }) {
            throw DownloadEngineError.unsupportedContent("此 HLS 清单使用非独立 TS 文件范围，当前无法安全合并。")
        }
        guard lines.contains("#EXT-X-ENDLIST") else {
            throw DownloadEngineError.unsupportedContent("直播流或未结束的 HLS 清单不受支持；仅支持含 #EXT-X-ENDLIST 的点播 TS 清单。")
        }
        for line in lines where line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") {
            let method = line.split(separator: ",").first(where: { $0.uppercased().hasPrefix("METHOD=") })?.dropFirst(7).uppercased()
            guard let method else { throw DownloadEngineError.unsupportedContent("HLS 加密声明无法识别，已停止以免生成错误文件。") }
            if method != "NONE" { throw DownloadEngineError.unsupportedContent("加密 HLS 不受支持；应用不会获取或保存解密密钥。") }
        }
        var segments: [URL] = []
        var sequence = 0
        var duration = 0.0
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:"), let value = Int(line.split(separator: ":").last ?? "0") { sequence = value }
            if line.hasPrefix("#EXTINF:"), let value = Double(line.dropFirst(8).split(separator: ",").first ?? "") { duration += value }
            if line.hasPrefix("#") { continue }
            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
                  url.pathExtension.lowercased() == "ts" else {
                throw DownloadEngineError.unsupportedContent("此 HLS 清单包含非 TS 或非 HTTP(S) 分段。")
            }
            segments.append(url)
            guard segments.count <= 100_000 else {
                throw DownloadEngineError.unsupportedContent("HLS 清单包含超过 100,000 个分段，已停止读取。")
            }
        }
        guard !segments.isEmpty else { throw DownloadEngineError.unsupportedContent("清单中没有可下载的 TS 媒体分段。") }
        return HLSPlaylist(segments: segments, mediaSequence: sequence, totalDuration: duration > 0 ? duration : nil)
    }

    public static func download(task: DownloadRecord, headers: [String: String], settings: AppSettings,
                                proxyPassword: String = "", hostCredentials: [String: [String: String]] = [:],
                                maximumConnections: Int = 4, speedLimitBytesPerSecond: Int64 = 0,
                                runtimePolicy: HLSRuntimePolicy? = nil, generation: UInt64 = 0,
                                baseDirectory: URL? = nil,
                                resetResume: Bool = false,
                                progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        guard let url = URL(string: task.sourceURL), NetworkConfiguration.validate(url) else {
            throw DownloadEngineError.invalidURL
        }
        let store = HLSResumeStore.shared
        try await store.activate(taskID: task.id, generation: generation)
        defer { Task { try? await store.end(taskID: task.id, generation: generation) } }
        try Task.checkCancellation()
        var manifestRequest = URLRequest(url: url, timeoutInterval: 60)
        manifestRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let page = task.pageURL { manifestRequest.setValue(page, forHTTPHeaderField: "Referer") }
        for (name, value) in headers where name.caseInsensitiveCompare("Host") != .orderedSame {
            manifestRequest.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = max(1, min(maximumConnections, 256))
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        NetworkConfiguration.applyProxy(settings: settings, proxyPassword: proxyPassword, to: configuration)
        let delegate = HLSNetworkDelegate(allowInvalidTLS: settings.allowInvalidTLSCertificates,
                                          proxyUsername: settings.proxyUsername, proxyPassword: proxyPassword)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (http, manifestStream) = try await delegate.openChunkStream(for: manifestRequest, on: session)
        try Task.checkCancellation()
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadEngineError.httpStatus(http.statusCode)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var manifestData = Data()
        if http.expectedContentLength > 0 {
            let hint = min(max(0, http.expectedContentLength), 16 * 1024 * 1024)
            manifestData.reserveCapacity(Int(hint))
        }
        for try await chunk in manifestStream {
            try Task.checkCancellation()
            guard manifestData.count + chunk.count <= 16 * 1024 * 1024 else {
                throw DownloadEngineError.unsupportedContent("HLS 清单超过 16 MiB，已停止读取。")
            }
            manifestData.append(chunk)
        }
        if !mime.contains("mpegurl") && manifestData.count > 2 * 1024 * 1024 {
            throw DownloadEngineError.unsupportedContent("HLS 清单类型未知且大于 2 MiB，已拒绝解析。")
        }
        guard let text = String(data: manifestData, encoding: .utf8) else {
            throw DownloadEngineError.unsupportedContent("HLS 清单不是 UTF-8 文本。")
        }
        let finalPlaylistURL = http.url ?? url
        let playlist = try parse(text, baseURL: finalPlaylistURL)
        let segmentURLs = playlist.segments.map(\.absoluteString)
        let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.name, isDirectory: true)
        let root = base
            .appendingPathComponent("hls-\(task.id)", isDirectory: true)
        _ = try await store.prepare(taskID: task.id, generation: generation,
                                root: root, digest: digest, segmentURLs: segmentURLs, resetResume: resetResume)
        let rateLimiter = HLSRateLimiter(bytesPerSecond: speedLimitBytesPerSecond)
        let activePolicy = runtimePolicy ?? HLSRuntimePolicy(settings: settings,
            maximumConnections: maximumConnections, speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            taskConnectionOverride: task.connectionCount != nil)
        let progressTracker = HLSProgressTracker()
        let connectionPool = HLSConnectionPool()
        let staging = root.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        func reportProgress(index: Int, bytes: Int64, completed: Bool = false, force: Bool = false) async {
            let (value, shouldEmit) = await progressTracker.update(index: index, bytes: bytes,
                                                                   completed: completed, force: force)
            if shouldEmit { progress(value, nil) }
        }

        func requestHeaders(for target: URL) -> [String: String] {
            var result: [String: String] = ["Accept-Encoding": "identity"]
            if NetworkConfiguration.hasSameOrigin(target, url) {
                if let page = task.pageURL { result["Referer"] = page }
                for (name, value) in headers where name.caseInsensitiveCompare("Host") != .orderedSame {
                    result[name] = value
                }
            } else {
                if !settings.userAgent.isEmpty { result["User-Agent"] = settings.userAgent }
                if let rule = NetworkConfiguration.matchingHostRule(for: target, settings: settings) {
                    for (name, value) in rule.headers where name.caseInsensitiveCompare("Host") != .orderedSame {
                        result[name] = value
                    }
                    if let account = rule.credentialAccount, let values = hostCredentials[account] {
                        for (name, value) in values where NetworkConfiguration.sensitiveHeaderNames.contains(name.lowercased()) {
                            result[name] = value
                        }
                    }
                    if !rule.userAgent.isEmpty { result["User-Agent"] = rule.userAgent }
                }
            }
            return result
        }

        func reusableSegment(_ index: Int, at destination: URL, source: URL) async -> HLSCachedSegment? {
            guard await store.isCurrent(taskID: task.id, generation: generation),
                  let cached = await store.cached(taskID: task.id, generation: generation, index: index),
                  cached.url == source.absoluteString,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                  (attributes[.size] as? NSNumber)?.int64Value == cached.size, cached.size > 0,
                  cached.etag != nil || cached.lastModified != nil else { return nil }
            var request = URLRequest(url: source, timeoutInterval: 30)
            request.httpMethod = "HEAD"
            for (name, value) in requestHeaders(for: source) { request.setValue(value, forHTTPHeaderField: name) }
            guard let (_, response) = try? await session.data(for: request),
                  let response = response as? HTTPURLResponse, (200..<400).contains(response.statusCode) else { return nil }
            guard await store.isCurrent(taskID: task.id, generation: generation), !Task.isCancelled else { return nil }
            if let etag = cached.etag, response.value(forHTTPHeaderField: "ETag") != etag { return nil }
            if let modified = cached.lastModified, response.value(forHTTPHeaderField: "Last-Modified") != modified { return nil }
            return cached
        }

        func fetchSegment(_ index: Int) async throws -> (Int, URL, Int64) {
            let source = playlist.segments[index]
            let segmentHost = source.host?.lowercased() ?? ""
            let (activeSettings, activeConnections, activeSpeedLimit, taskConnectionOverride) = await activePolicy.snapshot()
            await rateLimiter.update(bytesPerSecond: activeSpeedLimit)
            let hostRule = NetworkConfiguration.matchingHostRule(for: source, settings: activeSettings)
            let hostConnections = taskConnectionOverride ? activeConnections : hostRule?.connectionCount ?? activeConnections
            try await connectionPool.acquire(host: segmentHost, limit: hostConnections)
            defer { Task { await connectionPool.release(host: segmentHost) } }
            try Task.checkCancellation()
            guard await store.isCurrent(taskID: task.id, generation: generation) else { throw CancellationError() }
            let destination = root.appendingPathComponent(String(format: "%06d.ts", index))
            if let cached = await reusableSegment(index, at: destination, source: source) {
                await reportProgress(index: index, bytes: cached.size, completed: true)
                return (index, destination, cached.size)
            }
            var request = URLRequest(url: source, timeoutInterval: 120)
            for (name, value) in requestHeaders(for: source) { request.setValue(value, forHTTPHeaderField: name) }
            let temporary = staging.appendingPathComponent("hls-\(task.id)-\(generation)-\(UUID().uuidString).segment.partial")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw DownloadEngineError.missingDestination
            }
            let output = try FileHandle(forWritingTo: temporary)
            var outputClosed = false
            var installed = false
            defer {
                if !outputClosed { try? output.close() }
                if !installed { try? FileManager.default.removeItem(at: temporary) }
            }
            let (http, chunkStream) = try await delegate.openChunkStream(for: request, on: session)
            try Task.checkCancellation()
            guard (200..<300).contains(http.statusCode) else {
                throw DownloadEngineError.httpStatus(http.statusCode)
            }
            let expectedLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            var size: Int64 = 0
            let hostBucket = hostRule.map { "host:\($0.pattern.lowercased())" } ?? ""
            for try await chunk in chunkStream {
                try Task.checkCancellation()
                let chunkCount = Int64(chunk.count)
                let (latestSettings, _, latestTaskLimit, _) = await activePolicy.snapshot()
                await rateLimiter.update(bytesPerSecond: latestTaskLimit)
                let globalLimit = latestSettings.globalSpeedLimitBytesPerSecond
                let globalDelay: TimeInterval = globalLimit > 0
                    ? await SharedGlobalRateLimiter.shared.reserve(bytes: chunkCount, limit: globalLimit)
                    : 0
                let activeHostLimit = NetworkConfiguration.matchingHostRule(for: source, settings: latestSettings)?.speedLimitBytesPerSecond ?? 0
                let hostDelay: TimeInterval = activeHostLimit > 0 && !hostBucket.isEmpty
                    ? await SharedGlobalRateLimiter.shared.reserve(bytes: chunkCount, limit: activeHostLimit, bucket: hostBucket)
                    : 0
                let taskDelay: TimeInterval = latestTaskLimit > 0
                    ? await rateLimiter.reserve(chunk.count)
                    : 0
                let delay = min(2.0, max(globalDelay, max(hostDelay, taskDelay)))
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
                size += chunkCount
                await reportProgress(index: index, bytes: size)
            }
            try output.close()
            outputClosed = true
            try Task.checkCancellation()
            guard size > 0 else { throw DownloadEngineError.lengthMismatch(expected: 1, actual: size) }
            if let expectedLength, expectedLength != size {
                throw DownloadEngineError.lengthMismatch(expected: expectedLength, actual: size)
            }
            let entry = HLSCachedSegment(url: source.absoluteString,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"), size: size)
            try await store.install(taskID: task.id, generation: generation, temporary: temporary,
                                    destination: destination, segment: entry, index: index)
            installed = true
            await reportProgress(index: index, bytes: size, completed: true)
            return (index, destination, size)
        }

        let segmentFiles = try await withThrowingTaskGroup(of: (Int, URL, Int64).self) { group in
            let limit = max(1, min(maximumConnections, 256))
            var nextIndex = 0
            while nextIndex < min(limit, playlist.segments.count) {
                let index = nextIndex; nextIndex += 1
                group.addTask { try await fetchSegment(index) }
            }
            var result: [(Int, URL, Int64)] = []
            for try await segment in group {
                result.append(segment)
                if nextIndex < playlist.segments.count {
                    let index = nextIndex; nextIndex += 1
                    group.addTask { try await fetchSegment(index) }
                }
            }
            return result.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        try await store.flush(taskID: task.id, generation: generation)
        guard await store.isCurrent(taskID: task.id, generation: generation) else { throw CancellationError() }
        let merged = staging.appendingPathComponent("hls-\(task.id)-\(generation)-\(UUID().uuidString).complete")
        guard FileManager.default.createFile(atPath: merged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DownloadEngineError.missingDestination
        }
        let output = try FileHandle(forWritingTo: merged)
        var mergedSuccessfully = false
        defer {
            try? output.close()
            if !mergedSuccessfully { try? FileManager.default.removeItem(at: merged) }
        }
        for (_, file, _) in segmentFiles {
            let input = try FileHandle(forReadingFrom: file)
            do {
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try output.write(contentsOf: chunk)
                }
                try input.close()
            } catch { try? input.close(); throw error }
        }
        try output.synchronize()
        try output.close()
        let (finalBytes, _) = await progressTracker.update(index: -1, bytes: 0, force: true)
        progress(finalBytes, nil)
        try await store.end(taskID: task.id, generation: generation)
        mergedSuccessfully = true
        return merged
    }

    public static func clearStoredState(taskID: Int64) async {
        await HLSResumeStore.shared.clearTask(taskID: taskID)
    }
}
