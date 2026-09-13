import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public let taskID: Int64
    public let downloaded: Int64
    public let total: Int64?
    public let bytesPerSecond: Double
    public let eta: TimeInterval?
    public init(taskID: Int64, downloaded: Int64, total: Int64?, bytesPerSecond: Double, eta: TimeInterval?) {
        self.taskID = taskID; self.downloaded = downloaded; self.total = total
        self.bytesPerSecond = bytesPerSecond; self.eta = eta
    }
}

/// Actor-isolated HTTP engine. Parts are independently retried and written to
/// deterministic sidecar files, so an interruption never requires restarting
/// completed ranges. The final move is atomic.
public actor DownloadEngine {
    public let store: AppStateStore
    private let bookmarkStore: FolderBookmarkStore?
    private let settingsProvider: @Sendable () async -> AppSettings
    private var running: [Int64: Task<Void, Never>] = [:]
    private var controls: [Int64: Control] = [:]
    private var subscribers: [UUID: AsyncStream<DownloadProgress>.Continuation] = [:]
    private var samples: [Int64: (date: ContinuousClock.Instant, bytes: Int64)] = [:]
    private let globalLimiter = SpeedLimiter()

    private enum Control: Sendable { case running, paused, cancelled }

    public init(store: AppStateStore, bookmarkStore: FolderBookmarkStore? = nil, settingsProvider: @escaping @Sendable () async -> AppSettings = { AppSettings() }) {
        self.store = store
        self.bookmarkStore = bookmarkStore
        self.settingsProvider = settingsProvider
    }

    public func progressStream() -> AsyncStream<DownloadProgress> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    public func start(taskID: Int64) async throws {
        if running[taskID] != nil {
            controls[taskID] = .running
            if var resumed = await store.task(id: taskID), resumed.status == .paused {
                resumed.status = .downloading
                try await store.updateTask(resumed)
            }
            return
        }
        guard var task = await store.task(id: taskID) else { throw DownloadEngineError.missingTask }
        let snapshot = await store.snapshot()
        let activeCount = snapshot.tasks.filter { $0.status == .downloading || $0.status == .merging }.count
        guard activeCount < snapshot.settings.maxConcurrentDownloads else { throw DownloadEngineError.concurrencyLimitReached }
        task.status = .downloading
        task.isQueued = false
        task.errorMessage = nil
        task.startedAt = task.startedAt ?? Date()
        try await store.updateTask(task)
        controls[taskID] = .running
        let job = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: taskID)
        }
        running[taskID] = job
    }

    public func pause(taskID: Int64) async throws {
        guard running[taskID] != nil else {
            if var task = await store.task(id: taskID), task.status.isResumable { task.status = .paused; try await store.updateTask(task) }
            return
        }
        controls[taskID] = .paused
        if var task = await store.task(id: taskID), task.status == .downloading { task.status = .paused; task.isQueued = false; try await store.updateTask(task) }
    }

    public func cancel(taskID: Int64, deletePartial: Bool? = nil) async throws {
        controls[taskID] = .cancelled
        running[taskID]?.cancel()
        let shouldDelete: Bool
        if let deletePartial { shouldDelete = deletePartial } else { shouldDelete = (await settingsProvider()).deletePartialFileOnDownloadCancellation }
        if let task = await store.task(id: taskID), shouldDelete {
            cleanupPartialFiles(task)
        }
        if var task = await store.task(id: taskID) {
            task.status = .cancelled; task.completedAt = Date(); try await store.updateTask(task); try await store.appendHistory(for: task)
        }
    }

    public func retry(taskID: Int64) async throws {
        guard let task = await store.task(id: taskID), task.status == .failed || task.status == .stopped else { return }
        if var updated = await store.task(id: taskID) { updated.retryCount += 1; updated.status = .created; updated.errorMessage = nil; try await store.updateTask(updated) }
        try await start(taskID: taskID)
    }

    public func stopAll() async {
        for id in running.keys { controls[id] = .paused }
    }

    private func run(taskID: Int64) async {
        var scopedFolder: URL?
        defer {
            scopedFolder?.stopAccessingSecurityScopedResource()
            running.removeValue(forKey: taskID); controls.removeValue(forKey: taskID); samples.removeValue(forKey: taskID)
        }
        do {
            guard let original = await store.task(id: taskID) else { throw DownloadEngineError.missingTask }
            let settings = await settingsProvider()
            let client = HTTPClient(settings: settings)
            guard original.source.url.scheme?.lowercased() == "http" || original.source.url.scheme?.lowercased() == "https" else { throw DownloadEngineError.invalidURL }
            let info: ResourceInfo
            if original.kind == .hls || original.source.url.pathExtension.lowercased() == "m3u8" {
                info = ResourceInfo(finalURL: original.source.url)
            } else {
                info = try await client.probe(source: original.source)
            }
            guard var task = await store.task(id: taskID) else { throw DownloadEngineError.missingTask }
            if !task.validator.isEmpty && !info.validator.isEmpty && !task.validator.matches(info.validator) { throw DownloadEngineError.resourceChanged }
            task.validator = info.validator
            task.totalSize = info.contentLength
            task.supportsRanges = info.supportsRanges
            task.connectionCount = task.kind == .hls ? 1 : max(1, min(settings.threadCount, info.supportsRanges ? settings.threadCount : 1))
            if let suggested = info.suggestedFilename, task.fileName == task.source.url.lastPathComponent { task.fileName = try FileUtilities.sanitizedFileName(suggested) }
            try await store.updateTask(task)
            let folder: URL
            if let bookmarkStore, await bookmarkStore.contains(path: task.folderPath) {
                folder = try await bookmarkStore.resolve(path: task.folderPath)
                scopedFolder = folder
            } else {
                folder = URL(fileURLWithPath: task.folderPath, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let finalURL = try FileUtilities.containedURL(folder: folder, fileName: task.fileName)
            if let total = info.contentLength, let available = FileUtilities.availableCapacity(at: folder), available < total - task.downloadedSize { throw DownloadEngineError.insufficientDiskSpace }
            let target = finalURL.appendingPathExtension("abpart")
            if task.kind == .hls || task.source.url.pathExtension.lowercased() == "m3u8" {
                let result = try await HLSDownloader(client: client, source: task.source).download(to: target, beforeSegment: { [weak self] in
                    try await self?.waitUntilRunning(taskID: taskID)
                }) { [weak self] bytes, total in
                    await self?.recordProgress(taskID: taskID, bytes: bytes, total: total)
                }
                task = await store.task(id: taskID) ?? task
                task.downloadedSize = result.bytes
                task.totalSize = result.bytes
                task.parts = [DownloadPart(from: 0, to: max(0, result.bytes - 1), downloaded: result.bytes)]
            } else if info.supportsRanges, let total = info.contentLength, total > 0 {
                if task.parts.isEmpty || task.parts.reduce(0, { $0 + ($1.length ?? 0) }) != total {
                    task.parts = Self.makeParts(total: total, count: task.connectionCount)
                    try await store.updateTask(task)
                }
                try await downloadRanges(task: task, client: client, settings: settings)
                task = await store.task(id: taskID) ?? task
            } else {
                try await downloadSingle(task: task, client: client, target: target, settings: settings)
                task = await store.task(id: taskID) ?? task
            }
            guard controls[taskID] != .cancelled else { throw DownloadEngineError.cancelled }
            while controls[taskID] == .paused { try? await Task.sleep(for: .milliseconds(100)) }
            task.status = .merging
            try await store.updateTask(task)
            let resolved = try FileUtilities.resolveConflict(at: finalURL, policy: task.conflictPolicy)
            try merge(task: task, target: target, destination: resolved)
            task.fileName = resolved.lastPathComponent
            task.downloadedSize = task.totalSize ?? task.downloadedSize
            if let expected = task.expectedChecksum {
                let checksum = try FileChecksum.fromString(expected)
                let actual = try ChecksumCalculator.hash(algorithm: ChecksumAlgorithm(rawValue: checksum.algorithm.uppercased()) ?? .sha256, fileURL: resolved)
                task.actualChecksum = "\(checksum.algorithm):\(actual)"
                guard checksum.matches(rawDigest: actual) else { throw DownloadEngineError.checksumMismatch(expected: expected, actual: actual) }
            }
            task.status = .completed; task.completedAt = Date(); task.errorMessage = nil
            try await store.updateTask(task); try await store.appendHistory(for: task)
            publish(taskID: task.id, downloaded: task.downloadedSize, total: task.totalSize, speed: 0)
        } catch is CancellationError {
            await markFailure(taskID: taskID, error: DownloadEngineError.cancelled)
        } catch {
            await markFailure(taskID: taskID, error: error)
        }
    }

    private func downloadRanges(task: DownloadTask, client: HTTPClient, settings: AppSettings) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for part in task.parts where !part.isComplete {
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.downloadPart(taskID: task.id, part: part, client: client, settings: settings)
                }
            }
            try await group.waitForAll()
        }
    }

    private func downloadPart(taskID: Int64, part: DownloadPart, client: HTTPClient, settings: AppSettings) async throws {
        guard let task = await store.task(id: taskID) else { throw DownloadEngineError.missingTask }
        let folder = URL(fileURLWithPath: task.folderPath, isDirectory: true)
        let path = folder.appendingPathComponent(".\(task.fileName).abpart.\(part.id.uuidString)")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
        var part = part
        let trustedBytes = max(0, part.downloaded)
        let actualBytes = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
        if actualBytes > trustedBytes {
            try handle.truncate(atOffset: UInt64(trustedBytes))
        } else if actualBytes < trustedBytes {
            part.downloaded = actualBytes
            try await updatePart(taskID: taskID, part: part)
        }
        try handle.seekToEnd()
        let length = part.length ?? 0
        let chunkSize: Int64 = 1_048_576
        while !part.isComplete {
            try await waitUntilRunning(taskID: taskID)
            let end = min(part.from + length - 1, part.nextOffset + chunkSize - 1)
            var requestHeaders = task.source.headers
            if let validator = task.validator.ifRangeValue { requestHeaders["If-Range"] = validator }
            var received: Data?
            var lastError: Error?
            for attempt in 0...max(0, settings.maxDownloadRetryCount) {
                do {
                    let response = try await client.request(url: task.source.url, headers: requestHeaders, range: part.nextOffset...end)
                    guard response.response.statusCode == 206 else { throw DownloadEngineError.rangeNotHonored }
                    let expected = end - part.nextOffset + 1
                    guard Int64(response.data.count) <= expected else { throw DownloadEngineError.unexpectedLength(expected: expected, actual: Int64(response.data.count)) }
                    received = response.data; break
                } catch {
                    lastError = error
                    if attempt < settings.maxDownloadRetryCount { try await Task.sleep(for: .milliseconds(Int64(min(30_000, 500 * (1 << min(attempt, 6)))))) }
                }
            }
            guard let data = received else { throw lastError ?? DownloadEngineError.invalidResponse(-1) }
            try handle.write(contentsOf: data)
            part.downloaded += Int64(data.count)
            guard !data.isEmpty else { throw DownloadEngineError.unexpectedLength(expected: 1, actual: 0) }
            try await updatePart(taskID: taskID, part: part)
            await throttle(bytes: data.count, settings: settings, task: task)
        }
    }

    private func downloadSingle(task: DownloadTask, client: HTTPClient, target: URL, settings: AppSettings) async throws {
        var lastError: Error?
        for attempt in 0...max(0, settings.maxDownloadRetryCount) {
            do {
                // HTTP servers without Range support cannot safely resume a
                // partial response. Restart the temporary stream per attempt.
                try? FileManager.default.removeItem(at: target)
                let (bytes, response) = try await client.stream(url: task.source.url, headers: task.source.headers)
                guard (200..<300).contains(response.statusCode) else { throw DownloadEngineError.invalidResponse(response.statusCode) }
                FileManager.default.createFile(atPath: target.path, contents: nil)
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                var written: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1024)
                for try await byte in bytes {
                    try await waitUntilRunning(taskID: task.id)
                    buffer.append(byte)
                    if buffer.count >= 64 * 1024 {
                        try handle.write(contentsOf: buffer)
                        written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                        var current = await store.task(id: task.id) ?? task
                        current.downloadedSize = written
                        current.parts = [DownloadPart(from: 0, to: max(0, (current.totalSize ?? written) - 1), downloaded: written)]
                        try await store.updateTask(current)
                        await throttle(bytes: 64 * 1024, settings: settings, task: task)
                        publish(taskID: task.id, downloaded: written, total: current.totalSize, speed: sample(taskID: task.id, bytes: written))
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer); written += Int64(buffer.count)
                }
                var current = await store.task(id: task.id) ?? task
                current.downloadedSize = written
                current.parts = [DownloadPart(from: 0, to: max(0, written - 1), downloaded: written)]
                try await store.updateTask(current)
                publish(taskID: task.id, downloaded: written, total: current.totalSize, speed: sample(taskID: task.id, bytes: written))
                return
            } catch {
                lastError = error
                if attempt < settings.maxDownloadRetryCount { try await Task.sleep(for: .milliseconds(Int64(500 * (1 << min(attempt, 6))))) }
            }
        }
        throw lastError ?? DownloadEngineError.invalidResponse(-1)
    }

    private func waitUntilRunning(taskID: Int64) async throws {
        while controls[taskID] == .paused { try await Task.sleep(for: .milliseconds(100)) }
        if controls[taskID] == .cancelled { throw DownloadEngineError.cancelled }
    }

    private func updatePart(taskID: Int64, part: DownloadPart) async throws {
        guard var task = await store.task(id: taskID) else { throw DownloadEngineError.missingTask }
        if let index = task.parts.firstIndex(where: { $0.id == part.id }) { task.parts[index] = part }
        task.recomputeDownloadedSize()
        try await store.updateTask(task)
        let speed = sample(taskID: taskID, bytes: task.downloadedSize)
        let remaining = task.totalSize.map { max(0, $0 - task.downloadedSize) }
        publish(taskID: taskID, downloaded: task.downloadedSize, total: task.totalSize, speed: speed, remaining: remaining)
    }

    private func recordProgress(taskID: Int64, bytes: Int64, total: Int64?) async {
        guard var task = await store.task(id: taskID) else { return }
        task.downloadedSize = bytes; task.totalSize = total
        try? await store.updateTask(task)
        publish(taskID: taskID, downloaded: bytes, total: total, speed: sample(taskID: taskID, bytes: bytes))
    }

    private func sample(taskID: Int64, bytes: Int64) -> Double {
        let now = ContinuousClock.now
        defer { samples[taskID] = (now, bytes) }
        guard let old = samples[taskID] else { return 0 }
        let seconds = max(0.001, Double(old.date.duration(to: now).components.attoseconds) / 1e18 + Double(old.date.duration(to: now).components.seconds))
        return Double(max(0, bytes - old.bytes)) / seconds
    }

    private func throttle(bytes: Int, settings: AppSettings, task: DownloadTask) async {
        if settings.speedLimit > 0 {
            await globalLimiter.acquire(bytes: bytes, limit: settings.speedLimit)
        }
        if task.speedLimit > 0 {
            let seconds = Double(bytes) / Double(task.speedLimit)
            if seconds > 0 { try? await Task.sleep(for: .milliseconds(Int64(seconds * 1000))) }
        }
    }

    private func merge(task: DownloadTask, target: URL, destination: URL) throws {
        let temporary = destination.appendingPathExtension("merge")
        try? FileManager.default.removeItem(at: temporary)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        if task.parts.count <= 1 && FileManager.default.fileExists(atPath: target.path) {
            let input = try FileHandle(forReadingFrom: target); defer { try? input.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
        } else {
            let folder = URL(fileURLWithPath: task.folderPath, isDirectory: true)
            for part in task.parts.sorted(by: { $0.from < $1.from }) {
                let partURL = folder.appendingPathComponent(".\(task.fileName).abpart.\(part.id.uuidString)")
                let input = try FileHandle(forReadingFrom: partURL); defer { try? input.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
                try? FileManager.default.removeItem(at: partURL)
            }
        }
        try output.close(); try FileUtilities.atomicReplace(source: temporary, destination: destination, overwrite: task.conflictPolicy == .overwrite)
        try? FileManager.default.removeItem(at: target)
    }

    private func cleanupPartialFiles(_ task: DownloadTask) {
        let folder = URL(fileURLWithPath: task.folderPath)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(task.fileName).abpart"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(task.fileName).abpart.hls.json"))
        for part in task.parts { try? FileManager.default.removeItem(at: folder.appendingPathComponent(".\(task.fileName).abpart.\(part.id.uuidString)")) }
    }

    private func markFailure(taskID: Int64, error: Error) async {
        guard var task = await store.task(id: taskID) else { return }
        if case DownloadEngineError.cancelled = error { task.status = .cancelled } else if controls[taskID] == .paused { task.status = .paused } else { task.status = .failed }
        task.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        task.completedAt = task.status == .cancelled ? Date() : nil
        try? await store.updateTask(task)
        if task.status == .cancelled || task.status == .failed { try? await store.appendHistory(for: task) }
    }

    private func publish(taskID: Int64, downloaded: Int64, total: Int64?, speed: Double, remaining: Int64? = nil) {
        let eta = total.flatMap { speed > 0 ? Double(max(0, $0 - downloaded)) / speed : nil }
        let event = DownloadProgress(taskID: taskID, downloaded: downloaded, total: total, bytesPerSecond: speed, eta: eta)
        for continuation in subscribers.values { continuation.yield(event) }
        _ = remaining
    }

    private static func makeParts(total: Int64, count: Int) -> [DownloadPart] {
        let actualCount = max(1, min(count, Int(total)))
        let width = max(1, total / Int64(actualCount))
        return (0..<actualCount).map { index in
            let from = Int64(index) * width
            let to = index == actualCount - 1 ? total - 1 : min(total - 1, from + width - 1)
            return DownloadPart(from: from, to: to)
        }
    }
}
