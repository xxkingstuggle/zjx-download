import Foundation
import CFNetwork

public struct RemoteResourceInfo: Sendable {
    public var contentLength: Int64?
    public var supportsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var contentType: String?
    public var suggestedName: String?
    public var finalURL: URL
}

public enum DownloadEngineError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpStatus(Int)
    case missingDestination
    case sourceChanged
    case lengthMismatch(expected: Int64, actual: Int64)
    case conflict
    case invalidFileName
    case unsupportedContent(String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "下载地址不是有效的 HTTP 或 HTTPS 地址。"
        case .httpStatus(let code): "服务器返回 HTTP \(code)。请检查链接、登录状态或稍后重试。"
        case .missingDestination: "保存位置不可用。请选择一个可写文件夹后重试。"
        case .sourceChanged: "远端文件与暂停前不同。为防止拼接错误，已停止续传。"
        case .lengthMismatch(let expected, let actual): "文件长度不完整（应为 \(expected) 字节，收到 \(actual) 字节）。"
        case .conflict: "目标文件已存在，任务尚未写入该文件。"
        case .invalidFileName: "文件名为空或包含不允许的路径字符。"
        case .unsupportedContent(let reason): reason
        case .checksumMismatch(let expected, let actual): "摘要不匹配。期望 \(expected)，计算结果 \(actual)。"
        }
    }
}

private struct DownloadSessionPolicy: Sendable {
    var allowInvalidTLS: Bool
    var proxyUsername: String
    var proxyPassword: String
}

private struct ExpectedDownloadSource: Sendable {
    let generation: UInt64
    let isResuming: Bool
    let strongETag: String?
    let lastModified: String?
    let expectedLength: Int64?
}

private struct ParsedContentRange: Sendable {
    let lowerBound: Int64
    let upperBound: Int64
    let totalLength: Int64
}

private final class DownloadSessionPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: DownloadSessionPolicy] = [:]

    func set(_ value: DownloadSessionPolicy, for id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }; values[id] = value
    }

    func get(_ id: ObjectIdentifier) -> DownloadSessionPolicy? {
        lock.lock(); defer { lock.unlock() }; return values[id]
    }

    func remove(_ id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id)
    }
}

private struct DownloadProgressPacket: Sendable {
    var bytesWritten: Int64
    var totalBytesWritten: Int64
    var expectedBytes: Int64
}

/// Coalesces URLSession callbacks into one MainActor drain per active transfer.
/// Byte counts are accumulated, while progress keeps only the newest snapshot.
private final class DownloadProgressMailbox: @unchecked Sendable {
    private struct Entry {
        var generation: UInt64
        var pendingBytes: Int64 = 0
        var totalBytesWritten: Int64 = 0
        var expectedBytes: Int64 = -1
        var drainScheduled = false
    }

    private let lock = NSLock()
    private var values: [Int64: Entry] = [:]

    func begin(taskID: Int64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        values[taskID] = Entry(generation: generation)
    }

    func offer(taskID: Int64, generation: UInt64, bytesWritten: Int64,
               totalBytesWritten: Int64, expectedBytes: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = values[taskID], entry.generation == generation else { return false }
        let (sum, overflow) = entry.pendingBytes.addingReportingOverflow(max(0, bytesWritten))
        entry.pendingBytes = overflow ? Int64.max : max(0, sum)
        entry.totalBytesWritten = max(0, totalBytesWritten)
        entry.expectedBytes = expectedBytes
        let shouldSchedule = !entry.drainScheduled
        entry.drainScheduled = true
        values[taskID] = entry
        return shouldSchedule
    }

    func take(taskID: Int64, generation: UInt64) -> DownloadProgressPacket? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = values[taskID], entry.generation == generation else { return nil }
        guard entry.pendingBytes > 0 else {
            entry.drainScheduled = false
            values[taskID] = entry
            return nil
        }
        let packet = DownloadProgressPacket(bytesWritten: entry.pendingBytes,
            totalBytesWritten: entry.totalBytesWritten, expectedBytes: entry.expectedBytes)
        entry.pendingBytes = 0
        values[taskID] = entry
        return packet
    }

    func end(taskID: Int64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard values[taskID]?.generation == generation else { return }
        values.removeValue(forKey: taskID)
    }
}

@MainActor
public final class DownloadEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public var onProgress: ((Int64, UInt64, Int64, Int64?) -> Void)?
    public var onFinished: ((Int64, UInt64, URL, HTTPURLResponse?) -> Void)?
    public var onFailed: ((Int64, UInt64, String) -> Void)?
    public var onPaused: ((Int64, UInt64, Data?) -> Void)?

    private var active: [Int64: URLSessionDownloadTask] = [:]
    private var sessions: [Int64: URLSession] = [:]
    private var generations: [Int64: UInt64] = [:]
    private var rateSamples: [Int64: (Date, Int64)] = [:]
    private var lastProgressEmission: [Int64: Date] = [:]
    private var progressDrainTasks: [Int64: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var rateLimits: [Int64: Int64] = [:]
    private var globalRateLimits: [Int64: Int64] = [:]
    private var hostRateLimits: [Int64: (bucket: String, limit: Int64)] = [:]
    private var expectedSources: [Int64: ExpectedDownloadSource] = [:]
    private nonisolated let sessionPolicies = DownloadSessionPolicyStore()
    private nonisolated let progressMailbox = DownloadProgressMailbox()
    private nonisolated let baseDirectory: URL
    private let delegateQueue: OperationQueue

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.name, isDirectory: true)
        delegateQueue = OperationQueue()
        delegateQueue.name = "com.zjx.download.transfer-delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    public convenience override init() {
        self.init(baseDirectory: nil)
    }

    public func probe(_ url: URL, headers: [String: String], userAgent: String, settings: AppSettings,
                      proxyPassword: String = "") async throws -> RemoteResourceInfo {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw DownloadEngineError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (name, value) in headers where name.caseInsensitiveCompare("Host") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let config = configuration(settings, proxyPassword: proxyPassword)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        sessionPolicies.set(DownloadSessionPolicy(allowInvalidTLS: settings.allowInvalidTLSCertificates,
            proxyUsername: settings.proxyUsername, proxyPassword: proxyPassword), for: ObjectIdentifier(session))
        defer { sessionPolicies.remove(ObjectIdentifier(session)); session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadEngineError.unsupportedContent("服务器没有返回有效的 HTTP 响应。") }
        guard (200..<400).contains(http.statusCode) || [403, 405, 501].contains(http.statusCode) else {
            throw DownloadEngineError.httpStatus(http.statusCode)
        }
        if [403, 405, 501].contains(http.statusCode) {
            var fallbackRequest = URLRequest(url: url, timeoutInterval: 30)
            fallbackRequest.httpMethod = "GET"
            fallbackRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !userAgent.isEmpty { fallbackRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            for (name, value) in headers where name.caseInsensitiveCompare("Host") != .orderedSame
                && name.caseInsensitiveCompare("Range") != .orderedSame {
                fallbackRequest.setValue(value, forHTTPHeaderField: name)
            }
            fallbackRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            do {
                let (bytes, fallbackResponse) = try await session.bytes(for: fallbackRequest)
                defer { bytes.task.cancel() }
                if let fallbackHTTP = fallbackResponse as? HTTPURLResponse, (200..<300).contains(fallbackHTTP.statusCode) {
                    let isPartial = fallbackHTTP.statusCode == 206
                    let length = isPartial
                        ? Self.parseContentRange(fallbackHTTP.value(forHTTPHeaderField: "Content-Range"))?.totalLength
                        : fallbackHTTP.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
                    let ranges = isPartial || fallbackHTTP.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
                    let disposition = fallbackHTTP.value(forHTTPHeaderField: "Content-Disposition")
                    let name = Self.fileName(from: disposition) ?? Self.fileName(from: fallbackHTTP.url?.absoluteString) ?? Self.fileName(from: url.absoluteString)
                    return RemoteResourceInfo(contentLength: length, supportsRanges: ranges,
                                              etag: fallbackHTTP.value(forHTTPHeaderField: "ETag"),
                                              lastModified: fallbackHTTP.value(forHTTPHeaderField: "Last-Modified"),
                                              contentType: fallbackHTTP.value(forHTTPHeaderField: "Content-Type"),
                                              suggestedName: name, finalURL: fallbackHTTP.url ?? url)
                }
            } catch {
                if error is CancellationError { throw error }
            }
            return RemoteResourceInfo(contentLength: nil, supportsRanges: false, etag: nil,
                                      lastModified: nil, contentType: nil,
                                      suggestedName: Self.fileName(from: url.absoluteString), finalURL: url)
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
        let name = Self.fileName(from: disposition) ?? Self.fileName(from: http.url?.absoluteString)
        return RemoteResourceInfo(contentLength: length, supportsRanges: ranges,
                                  etag: http.value(forHTTPHeaderField: "ETag"),
                                  lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                  contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                  suggestedName: name, finalURL: http.url ?? url)
    }

    public func start(task: DownloadRecord, generation: UInt64 = 0, headers: [String: String],
                      settings: AppSettings, resumeData: Data? = nil,
                      speedLimitBytesPerSecond: Int64 = 0, proxyPassword: String = "") throws {
        guard let url = URL(string: task.sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw DownloadEngineError.invalidURL
        }
        let config = configuration(settings, proxyPassword: proxyPassword)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        if let previous = active.removeValue(forKey: task.id) {
            let previousGeneration = generations[task.id] ?? 0
            previous.cancel()
            finishSession(taskID: task.id, generation: previousGeneration)
        }
        sessionPolicies.set(DownloadSessionPolicy(allowInvalidTLS: settings.allowInvalidTLSCertificates,
            proxyUsername: settings.proxyUsername, proxyPassword: proxyPassword), for: ObjectIdentifier(session))
        let download: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            download = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let agent = task.requestHeaders.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
                ?? (settings.userAgent.isEmpty ? nil : settings.userAgent)
            if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
            if let page = task.pageURL, !page.isEmpty { request.setValue(page, forHTTPHeaderField: "Referer") }
            for (name, value) in headers where name.caseInsensitiveCompare("Host") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: name)
            }
            download = session.downloadTask(with: request)
        }
        download.taskDescription = "\(task.id):\(generation)"
        active[task.id] = download
        generations[task.id] = generation
        sessions[task.id] = session
        expectedSources[task.id] = ExpectedDownloadSource(generation: generation,
            isResuming: resumeData?.isEmpty == false,
            strongETag: task.etag.flatMap { $0.lowercased().hasPrefix("w/") ? nil : $0 },
            lastModified: task.lastModified,
            expectedLength: task.totalBytes.flatMap { $0 >= 0 ? $0 : nil })
        progressMailbox.begin(taskID: task.id, generation: generation)
        lastProgressEmission[task.id] = .distantPast
        rateSamples[task.id] = (.now, 0)
        rateLimits[task.id] = max(0, speedLimitBytesPerSecond)
        globalRateLimits[task.id] = max(0, settings.globalSpeedLimitBytesPerSecond)
        if let url = URL(string: task.sourceURL),
           let rule = NetworkConfiguration.matchingHostRule(for: url, settings: settings),
           rule.speedLimitBytesPerSecond > 0 {
            hostRateLimits[task.id] = ("host:\(rule.pattern.lowercased())", rule.speedLimitBytesPerSecond)
        }
        download.resume()
    }

    public func pause(taskID: Int64, generation expectedGeneration: UInt64? = nil) {
        guard let generation = generations[taskID],
              expectedGeneration == nil || expectedGeneration == generation else { return }
        guard let task = active[taskID] else {
            // Preserve the legacy unguarded notification, but never let a stale
            // generation synthesize a pause for a newer or already-finished task.
            if expectedGeneration == nil { onPaused?(taskID, generation, nil) }
            return
        }
        progressDrainTasks[taskID]?.task.cancel()
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrent(taskID: taskID, generation: generation, task: task) else { return }
                self.active.removeValue(forKey: taskID)
                self.finishSession(taskID: taskID, generation: generation)
                self.onPaused?(taskID, generation, data)
            }
        })
    }

    public func updateGlobalRateLimit(taskID: Int64, limit: Int64) {
        guard active[taskID] != nil else { return }
        globalRateLimits[taskID] = max(0, limit)
    }

    public func updateRateLimits(taskID: Int64, taskLimit: Int64, globalLimit: Int64, hostRule: HostRule?) {
        guard active[taskID] != nil else { return }
        rateLimits[taskID] = max(0, taskLimit)
        globalRateLimits[taskID] = max(0, globalLimit)
        if let hostRule, hostRule.speedLimitBytesPerSecond > 0 {
            hostRateLimits[taskID] = ("host:\(hostRule.pattern.lowercased())", hostRule.speedLimitBytesPerSecond)
        } else {
            hostRateLimits.removeValue(forKey: taskID)
        }
    }

    public func cancel(taskID: Int64, generation expectedGeneration: UInt64? = nil) {
        guard let generation = generations[taskID],
              expectedGeneration == nil || expectedGeneration == generation,
              let task = active.removeValue(forKey: taskID) else { return }
        task.cancel()
        finishSession(taskID: taskID, generation: generation)
        rateLimits.removeValue(forKey: taskID)
        globalRateLimits.removeValue(forKey: taskID)
        hostRateLimits.removeValue(forKey: taskID)
    }

    public func isActive(taskID: Int64) -> Bool { active[taskID] != nil }
    public var activeTransferCount: Int { active.count }

    private func configuration(_ settings: AppSettings, proxyPassword: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(1, min(settings.defaultConnectionCount, 256))
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        NetworkConfiguration.applyProxy(settings: settings, proxyPassword: proxyPassword, to: config)
        return config
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        guard let (taskID, generation) = Self.parse(downloadTask.taskDescription) else { return }
        guard progressMailbox.offer(taskID: taskID, generation: generation, bytesWritten: bytesWritten,
                                    totalBytesWritten: totalBytesWritten,
                                    expectedBytes: totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : -1) else { return }
        Task { @MainActor [weak self] in
            self?.scheduleProgressDrain(taskID: taskID, generation: generation, task: downloadTask)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        guard let (taskID, generation) = Self.parse(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard let response, (200..<300).contains(response.statusCode) else {
            let status = response?.statusCode ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(taskID: taskID, generation: generation, task: downloadTask) else { return }
                self.active.removeValue(forKey: taskID)
                self.finishSession(taskID: taskID, generation: generation)
                self.onFailed?(taskID, generation, DownloadEngineError.httpStatus(status).localizedDescription)
            }
            return
        }
        let requestRange = downloadTask.originalRequest?.value(forHTTPHeaderField: "Range")
            ?? downloadTask.currentRequest?.value(forHTTPHeaderField: "Range")
        let staging = baseDirectory.appendingPathComponent("staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = staging.appendingPathComponent("task-\(taskID)-\(UUID().uuidString).complete")
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(taskID: taskID, generation: generation, task: downloadTask) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
                guard let expected = self.expectedSources[taskID], expected.generation == generation else {
                    try? FileManager.default.removeItem(at: staged)
                    self.active.removeValue(forKey: taskID)
                    self.finishSession(taskID: taskID, generation: generation)
                    self.onFailed?(taskID, generation, DownloadEngineError.sourceChanged.localizedDescription)
                    return
                }
                if response.statusCode == 206 {
                    guard expected.isResuming,
                          let contentRange = Self.parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                          contentRange.upperBound == contentRange.totalLength - 1,
                          expected.expectedLength.map({ $0 == contentRange.totalLength }) ?? true,
                          requestRange == nil || (Self.rangeStart(requestRange).map { $0 == contentRange.lowerBound } ?? false) else {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation, DownloadEngineError.sourceChanged.localizedDescription)
                        return
                    }
                    let responseLength = response.value(forHTTPHeaderField: "Content-Length")
                        .flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
                    let rangeLength = contentRange.upperBound - contentRange.lowerBound + 1
                    if let responseLength, responseLength != rangeLength {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation,
                            DownloadEngineError.lengthMismatch(expected: rangeLength, actual: responseLength).localizedDescription)
                        return
                    }
                    let actual = ((try? FileManager.default.attributesOfItem(atPath: staged.path)[.size]) as? NSNumber)?.int64Value ?? -1
                    guard actual == contentRange.totalLength else {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation,
                            DownloadEngineError.lengthMismatch(expected: contentRange.totalLength, actual: actual).localizedDescription)
                        return
                    }
                }
                if let etag = expected.strongETag, response.value(forHTTPHeaderField: "ETag") != etag {
                    let responseETag = response.value(forHTTPHeaderField: "ETag")
                    if expected.isResuming || (responseETag != nil && responseETag != etag) {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation, DownloadEngineError.sourceChanged.localizedDescription)
                        return
                    }
                }
                if expected.strongETag == nil, let modified = expected.lastModified,
                   response.value(forHTTPHeaderField: "Last-Modified") != modified {
                    let responseModified = response.value(forHTTPHeaderField: "Last-Modified")
                    if expected.isResuming || (responseModified != nil && responseModified != modified) {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation, DownloadEngineError.sourceChanged.localizedDescription)
                        return
                    }
                }
                if let expectedLength = expected.expectedLength {
                    let actual = ((try? FileManager.default.attributesOfItem(atPath: staged.path)[.size]) as? NSNumber)?.int64Value ?? -1
                    guard actual == expectedLength else {
                        try? FileManager.default.removeItem(at: staged)
                        self.active.removeValue(forKey: taskID)
                        self.finishSession(taskID: taskID, generation: generation)
                        self.onFailed?(taskID, generation,
                            DownloadEngineError.lengthMismatch(expected: expectedLength, actual: actual).localizedDescription)
                        return
                    }
                }
                self.active.removeValue(forKey: taskID)
                self.finishSession(taskID: taskID, generation: generation)
                self.onFinished?(taskID, generation, staged, response)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(taskID: taskID, generation: generation, task: downloadTask) else { return }
                self.active.removeValue(forKey: taskID)
                self.finishSession(taskID: taskID, generation: generation)
                self.onFailed?(taskID, generation, "无法保留已下载的临时文件：\(error.localizedDescription)")
            }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (taskID, generation) = Self.parse(task.taskDescription) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(taskID: taskID, generation: generation, task: task) else { return }
            self.active.removeValue(forKey: taskID)
            self.finishSession(taskID: taskID, generation: generation)
            self.onFailed?(taskID, generation, error.localizedDescription)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       willPerformHTTPRedirection response: HTTPURLResponse,
                                       newRequest request: URLRequest,
                                       completionHandler: @escaping (URLRequest?) -> Void) {
        var safe = request
        guard let oldURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let newURL = request.url,
              NetworkConfiguration.validate(newURL) else {
            completionHandler(nil)
            return
        }
        if oldURL.scheme?.lowercased() == "https", newURL.scheme?.lowercased() != "https" {
            completionHandler(nil)
            return
        }
        if !NetworkConfiguration.hasSameOrigin(oldURL, newURL) {
            for name in NetworkConfiguration.sensitiveHeaderNames { safe.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(safe)
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       didReceive challenge: URLAuthenticationChallenge,
                                       completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let policy = sessionPolicies.get(ObjectIdentifier(session))
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           policy?.allowInvalidTLS == true,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if challenge.protectionSpace.isProxy(), let policy, !policy.proxyUsername.isEmpty, !policy.proxyPassword.isEmpty {
            completionHandler(.useCredential, URLCredential(user: policy.proxyUsername, password: policy.proxyPassword, persistence: .forSession))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private func drainProgress(taskID: Int64, generation: UInt64, task: URLSessionDownloadTask) async {
        defer {
            if progressDrainTasks[taskID]?.generation == generation {
                progressDrainTasks.removeValue(forKey: taskID)
            }
        }
        while let packet = progressMailbox.take(taskID: taskID, generation: generation) {
            guard !Task.isCancelled else { return }
            guard isCurrent(taskID: taskID, generation: generation, task: task) else {
                progressMailbox.end(taskID: taskID, generation: generation)
                return
            }
            let now = Date.now
            let isComplete = packet.expectedBytes >= 0 && packet.totalBytesWritten >= packet.expectedBytes
            if isComplete || now.timeIntervalSince(lastProgressEmission[taskID] ?? .distantPast) >= 0.1 {
                lastProgressEmission[taskID] = now
                onProgress?(taskID, generation, packet.totalBytesWritten,
                            packet.expectedBytes >= 0 ? packet.expectedBytes : nil)
            }
            await enforceRateLimit(taskID: taskID, generation: generation, task: task,
                                   bytesWritten: packet.bytesWritten)
        }
    }

    private func scheduleProgressDrain(taskID: Int64, generation: UInt64, task: URLSessionDownloadTask) {
        guard isCurrent(taskID: taskID, generation: generation, task: task) else { return }
        if let current = progressDrainTasks[taskID], current.generation == generation { return }
        progressDrainTasks[taskID]?.task.cancel()
        let drain = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.drainProgress(taskID: taskID, generation: generation, task: task)
        }
        progressDrainTasks[taskID] = (generation, drain)
    }

    private func enforceRateLimit(taskID: Int64, generation: UInt64,
                                  task: URLSessionDownloadTask, bytesWritten: Int64) async {
        guard isCurrent(taskID: taskID, generation: generation, task: task) else { return }
        let now = Date.now
        let sample = rateSamples[taskID] ?? (now, 0)
        let elapsed = now.timeIntervalSince(sample.0)
        let (accumulated, overflow) = sample.1.addingReportingOverflow(max(0, bytesWritten))
        let safeAccumulated = overflow ? Int64.max : max(0, accumulated)
        let limit = rateLimits[taskID] ?? 0
        var taskDelay: TimeInterval = 0
        if limit > 0, elapsed > 0, Double(safeAccumulated) > Double(limit) * elapsed {
            taskDelay = max(0.05, Double(safeAccumulated) / Double(limit) - elapsed)
        } else if elapsed >= 1 {
            rateSamples[taskID] = (now, 0)
        } else {
            rateSamples[taskID] = (sample.0, safeAccumulated)
        }
        let globalLimit = globalRateLimits[taskID] ?? 0
        let globalDelay = globalLimit > 0
            ? await SharedGlobalRateLimiter.shared.reserve(bytes: bytesWritten, limit: globalLimit)
            : 0
        let host = hostRateLimits[taskID]
        let hostDelay: TimeInterval = if let host, host.limit > 0 {
            await SharedGlobalRateLimiter.shared.reserve(bytes: bytesWritten, limit: host.limit, bucket: host.bucket)
        } else { 0 }
        let delay = min(2.0, max(taskDelay, max(globalDelay, hostDelay)))
        guard delay > 0 else { return }
        task.suspend()
        var remaining = delay
        while remaining > 0 {
            let slice = min(0.25, remaining)
            do { try await Task.sleep(for: .seconds(slice)) }
            catch { return }
            guard isCurrent(taskID: taskID, generation: generation, task: task) else { return }
            let currentLimitsActive = (rateLimits[taskID] ?? 0) > 0 || (globalRateLimits[taskID] ?? 0) > 0 || (hostRateLimits[taskID]?.limit ?? 0) > 0
            if !currentLimitsActive { break }
            remaining -= slice
        }
        rateSamples[taskID] = (.now, 0)
        task.resume()
    }

    private func isCurrent(taskID: Int64, generation: UInt64, task: URLSessionTask) -> Bool {
        generations[taskID] == generation && active[taskID] === task
    }

    nonisolated private static func parse(_ value: String?) -> (Int64, UInt64)? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let taskID = Int64(parts[0]), let generation = UInt64(parts[1]) else { return nil }
        return (taskID, generation)
    }

    private static func parseContentRange(_ value: String?) -> ParsedContentRange? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }),
              trimmed[..<separator].lowercased() == "bytes" else { return nil }
        let interval = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = interval.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, let total = Int64(String(components[1])), total > 0 else { return nil }
        let bounds = components[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int64(String(bounds[0])), let upper = Int64(String(bounds[1])),
              lower >= 0, upper >= lower, upper < total else { return nil }
        return ParsedContentRange(lowerBound: lower, upperBound: upper, totalLength: total)
    }

    private static func rangeStart(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let bounds = String(trimmed.dropFirst("bytes=".count))
            .split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(String(bounds[0])), start >= 0 else { return nil }
        return start
    }

    private static func fileName(from value: String?) -> String? {
        guard let value else { return nil }
        let lowered = value.lowercased()
        if lowered.contains("filename*=") || lowered.contains("filename=") {
            let segments = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let extended = segments.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
                var raw = String(extended.dropFirst("filename*=".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if let encodingRange = raw.range(of: "''") {
                    raw = String(raw[encodingRange.upperBound...])
                }
                let decoded = raw.removingPercentEncoding ?? raw
                if !decoded.isEmpty { return decoded }
            }
            if let plain = segments.first(where: { $0.lowercased().hasPrefix("filename=") }) {
                let raw = String(plain.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !raw.isEmpty { return raw.removingPercentEncoding ?? raw }
            }
        }
        guard let components = URLComponents(string: value) else { return nil }
        let last = components.path.split(separator: "/").last.map(String.init)
        if let last, !last.isEmpty { return last.removingPercentEncoding ?? last }
        return nil
    }

    private func finishSession(taskID: Int64, generation: UInt64) {
        guard generations[taskID] == generation else { return }
        if progressDrainTasks[taskID]?.generation == generation {
            progressDrainTasks.removeValue(forKey: taskID)?.task.cancel()
        }
        rateLimits.removeValue(forKey: taskID)
        globalRateLimits.removeValue(forKey: taskID)
        hostRateLimits.removeValue(forKey: taskID)
        rateSamples.removeValue(forKey: taskID)
        lastProgressEmission.removeValue(forKey: taskID)
        expectedSources.removeValue(forKey: taskID)
        progressMailbox.end(taskID: taskID, generation: generation)
        generations.removeValue(forKey: taskID)
        guard let session = sessions.removeValue(forKey: taskID) else { return }
        sessionPolicies.remove(ObjectIdentifier(session))
        session.finishTasksAndInvalidate()
    }
}
