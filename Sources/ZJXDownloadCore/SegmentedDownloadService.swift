import Foundation
import CFNetwork
import Darwin

public struct DownloadSegmentProgress: Identifiable, Sendable {
    public let index: Int
    public let lowerBound: Int64
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public let status: String
    public var id: Int { index }
}

private struct SegmentedSessionPolicy: Sendable {
    let allowInvalidTLS: Bool
    let proxyUsername: String
    let proxyPassword: String
}

private final class SegmentedSessionPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: SegmentedSessionPolicy] = [:]

    func set(_ policy: SegmentedSessionPolicy, for id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }; values[id] = policy
    }
    func get(_ id: ObjectIdentifier) -> SegmentedSessionPolicy? {
        lock.lock(); defer { lock.unlock() }; return values[id]
    }
    func remove(_ id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id)
    }
}

private struct SegmentedProgressPacket: Sendable {
    var bytesWritten: Int64
    var latestByRange: [Int: Int64]
}

private final class SegmentedProgressMailbox: @unchecked Sendable {
    private struct Entry {
        var generation: UInt64
        var pendingBytes: Int64 = 0
        var latestByRange: [Int: Int64] = [:]
        var drainScheduled = false
    }

    private let lock = NSLock()
    private var values: [Int64: Entry] = [:]

    func begin(taskID: Int64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        values[taskID] = Entry(generation: generation)
    }

    func offer(taskID: Int64, generation: UInt64, rangeIndex: Int,
               bytesWritten: Int64, totalBytesWritten: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = values[taskID], entry.generation == generation else { return false }
        let (sum, overflow) = entry.pendingBytes.addingReportingOverflow(max(0, bytesWritten))
        entry.pendingBytes = overflow ? Int64.max : max(0, sum)
        entry.latestByRange[rangeIndex] = max(0, totalBytesWritten)
        let shouldSchedule = !entry.drainScheduled
        entry.drainScheduled = true
        values[taskID] = entry
        return shouldSchedule
    }

    func take(taskID: Int64, generation: UInt64) -> SegmentedProgressPacket? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = values[taskID], entry.generation == generation else { return nil }
        guard entry.pendingBytes > 0 else {
            entry.drainScheduled = false
            values[taskID] = entry
            return nil
        }
        let packet = SegmentedProgressPacket(bytesWritten: entry.pendingBytes, latestByRange: entry.latestByRange)
        entry.pendingBytes = 0
        entry.latestByRange.removeAll(keepingCapacity: true)
        values[taskID] = entry
        return packet
    }

    func end(taskID: Int64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard values[taskID]?.generation == generation else { return }
        values.removeValue(forKey: taskID)
    }
}

private final class SegmentedDirectoryLocks: @unchecked Sendable {
    static let shared = SegmentedDirectoryLocks()
    // Keep lock state bounded as task IDs accumulate; collisions only serialize
    // unrelated checkpoint work briefly.
    private let locks = (0..<64).map { _ in NSLock() }

    func withLock<T>(directory: URL, _ operation: () throws -> T) rethrows -> T {
        let pathHash = UInt(bitPattern: directory.standardizedFileURL.path.hashValue)
        let lock = locks[Int(pathHash % UInt(locks.count))]
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

/// A bounded Range worker. Completed ranges are committed to an app-private
/// checkpoint directory so a process restart never depends on URLSession's
/// opaque resume blob for a parallel transfer.
@MainActor
public final class SegmentedDownloadService: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public var onProgress: ((Int64, UInt64, Int64, Int64?) -> Void)?
    public var onFinished: ((Int64, UInt64, URL) -> Void)?
    public var onFailed: ((Int64, UInt64, String) -> Void)?
    public var onPaused: ((Int64, UInt64, Int64?) -> Void)?
    public var onRangeUnsupported: ((Int64, UInt64) -> Void)?

    private struct ByteRange: Codable, Sendable {
        var index: Int
        var lower: Int64
        var upper: Int64
        var length: Int64 { upper - lower + 1 }
    }

    private struct Manifest: Codable, Sendable {
        var sourceURL: String
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [ByteRange]
    }

    private struct Prepared: Sendable {
        var manifest: Manifest
        var completed: Set<Int>
    }

    private final class Transfer {
        let record: DownloadRecord
        let generation: UInt64
        var manifest: Manifest
        let directory: URL
        let headers: [String: String]
        var settings: AppSettings
        var speedLimit: Int64
        var connectionLimit: Int
        var session: URLSession?
        var running: [Int: URLSessionDownloadTask] = [:]
        var completed: Set<Int> = []
        var received: [Int: Int64] = [:]
        var pausing = false
        var cancelling = false
        var failing = false
        var merging = false
        var lastProgressEmission = Date.distantPast

        init(record: DownloadRecord, generation: UInt64, manifest: Manifest, directory: URL, headers: [String: String],
             settings: AppSettings, speedLimit: Int64) {
            self.record = record; self.generation = generation; self.manifest = manifest; self.directory = directory
            self.headers = headers; self.settings = settings; self.speedLimit = speedLimit
            self.connectionLimit = max(1, min(settings.defaultConnectionCount, 256))
        }
    }

    private var transfers: [Int64: Transfer] = [:]
    private var preparingGenerations: [Int64: UInt64] = [:]
    private var requestedGenerations: [Int64: UInt64] = [:]
    private var setupTasks: [Int64: (generation: UInt64, task: Task<Prepared, Error>)] = [:]
    private var mergeTasks: [Int64: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var cleanupTasks: [Int64: (token: UUID, task: Task<Void, Never>)] = [:]
    private var progressDrainTasks: [Int64: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private nonisolated let sessionPolicies = SegmentedSessionPolicyStore()
    private nonisolated let progressMailbox = SegmentedProgressMailbox()
    private nonisolated let baseDirectory: URL
    private var rateSamples: [Int64: (Date, Int64)] = [:]
    private let delegateQueue: OperationQueue

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.name, isDirectory: true)
        delegateQueue = OperationQueue()
        delegateQueue.name = "com.zjx.download.range-delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    public var activeTransferCount: Int { transfers.count }
    public func isActive(taskID: Int64) -> Bool { transfers[taskID] != nil }

    public func progressSegments(taskID: Int64) -> [DownloadSegmentProgress] {
        guard let transfer = transfers[taskID] else { return [] }
        return transfer.manifest.ranges.sorted { $0.lower < $1.lower }.map { range in
            let done = transfer.completed.contains(range.index)
            let running = transfer.running[range.index] != nil
            return DownloadSegmentProgress(index: range.index, lowerBound: range.lower,
                                           receivedBytes: done ? range.length : (transfer.received[range.index] ?? 0),
                                           totalBytes: range.length,
                                           status: done ? "完成" : (running ? "下载中" : "等待"))
        }
    }

    public func committedBytes(for task: DownloadRecord) -> Int64? {
        guard let total = task.totalBytes, total > 0 else { return nil }
        let directory = checkpointDirectory(task.id)
        return SegmentedDirectoryLocks.shared.withLock(directory: directory) {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let stored = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: stored),
                  manifest.sourceURL == task.sourceURL,
                  manifest.etag == task.etag,
                  manifest.lastModified == task.lastModified,
                  manifest.total == total,
                  manifest.ranges.first?.lower == 0,
                  manifest.ranges.last?.upper == total - 1,
                  Self.hasContiguousRanges(manifest.ranges, total: total) else { return nil }
            var completedTotal: Int64 = 0
            for range in manifest.ranges {
                let file = Self.segmentURL(directory, range.index)
                let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
                if size == range.length { completedTotal += range.length }
            }
            return min(total, completedTotal)
        }
    }

    public func updateSettings(taskID: Int64, settings: AppSettings, speedLimit: Int64, connectionLimit: Int) {
        guard let transfer = transfers[taskID] else { return }
        transfer.settings = settings
        transfer.speedLimit = max(0, speedLimit)
        transfer.connectionLimit = max(1, min(connectionLimit, 256))
        if transfer.running.count > transfer.connectionLimit {
            let lowerByIndex = Dictionary(uniqueKeysWithValues: transfer.manifest.ranges.map { ($0.index, $0.lower) })
            let excess = transfer.running.keys.sorted { (lowerByIndex[$0] ?? 0) > (lowerByIndex[$1] ?? 0) }
                .prefix(transfer.running.count - transfer.connectionLimit)
            for index in excess { transfer.running[index]?.cancel() }
        }
        rebalancePendingRanges(taskID)
        schedule(taskID)
    }

    public func start(task: DownloadRecord, generation: UInt64 = 0, headers: [String: String],
                      settings: AppSettings, speedLimit: Int64, proxyPassword: String = "") async throws {
        guard let url = URL(string: task.sourceURL), NetworkConfiguration.validate(url),
              let total = task.totalBytes, total > 0,
              task.supportsRanges == true else { throw DownloadEngineError.unsupportedContent("此文件不适合并行 Range 下载。") }
        if let active = transfers[task.id] {
            if generation < active.generation { throw CancellationError() }
            if generation == active.generation { return }
        }
        let strongETag = task.etag.flatMap { $0.lowercased().hasPrefix("w/") ? nil : $0 }
        guard strongETag != nil || task.lastModified != nil else {
            if let onRangeUnsupported {
                onRangeUnsupported(task.id, generation)
                throw CancellationError()
            }
            throw DownloadEngineError.unsupportedContent("服务器没有 ETag 或 Last-Modified，不能安全并行合并；请使用单连接下载。")
        }
        if let requested = requestedGenerations[task.id] {
            if generation < requested { throw CancellationError() }
            if generation == requested { throw DownloadEngineError.conflict }
        }
        requestedGenerations[task.id] = generation
        defer {
            if requestedGenerations[task.id] == generation { requestedGenerations.removeValue(forKey: task.id) }
        }
        if let active = transfers[task.id] {
            cancel(taskID: task.id, generation: active.generation, deletePartial: false)
        }
        let directory = checkpointDirectory(task.id)
        while let cleanup = cleanupTasks.removeValue(forKey: task.id) {
            await cleanup.task.value
            guard requestedGenerations[task.id] == generation else { throw CancellationError() }
        }
        if let pending = setupTasks[task.id], pending.generation != generation {
            pending.task.cancel()
            _ = try? await pending.task.value
            if setupTasks[task.id]?.generation == pending.generation { setupTasks.removeValue(forKey: task.id) }
            if preparingGenerations[task.id] == pending.generation { preparingGenerations.removeValue(forKey: task.id) }
        }
        guard requestedGenerations[task.id] == generation else { throw CancellationError() }
        guard preparingGenerations[task.id] == nil else {
            throw DownloadEngineError.conflict
        }
        preparingGenerations[task.id] = generation
        let worker = Task.detached(priority: .utility) {
            try Self.prepareTransfer(task: task, generation: generation, settings: settings, directory: directory)
        }
        setupTasks[task.id] = (generation, worker)
        let prepared: Prepared
        do {
            prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            if setupTasks[task.id]?.generation == generation { setupTasks.removeValue(forKey: task.id) }
            if preparingGenerations[task.id] == generation { preparingGenerations.removeValue(forKey: task.id) }
            throw error
        }
        if setupTasks[task.id]?.generation == generation { setupTasks.removeValue(forKey: task.id) }
        guard !Task.isCancelled, preparingGenerations[task.id] == generation,
              requestedGenerations[task.id] == generation else {
            if preparingGenerations[task.id] == generation { preparingGenerations.removeValue(forKey: task.id) }
            throw CancellationError()
        }
        if let active = transfers[task.id], active.generation != generation {
            cancel(taskID: task.id, generation: active.generation, deletePartial: false)
            while let cleanup = cleanupTasks.removeValue(forKey: task.id) {
                await cleanup.task.value
                guard requestedGenerations[task.id] == generation else { throw CancellationError() }
            }
        }
        guard requestedGenerations[task.id] == generation,
              transfers[task.id] == nil || transfers[task.id]?.generation == generation else {
            if preparingGenerations[task.id] == generation { preparingGenerations.removeValue(forKey: task.id) }
            throw CancellationError()
        }
        let transfer = Transfer(record: task, generation: generation, manifest: prepared.manifest,
            directory: directory, headers: headers, settings: settings, speedLimit: max(0, speedLimit))
        transfer.completed = prepared.completed
        let configuration = Self.makeConfiguration(settings, proxyPassword: proxyPassword)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        transfer.session = session
        sessionPolicies.set(SegmentedSessionPolicy(allowInvalidTLS: settings.allowInvalidTLSCertificates,
                                                   proxyUsername: settings.proxyUsername,
                                                   proxyPassword: proxyPassword), for: ObjectIdentifier(session))
        transfers[task.id] = transfer
        preparingGenerations.removeValue(forKey: task.id)
        progressMailbox.begin(taskID: task.id, generation: generation)
        rateSamples[task.id] = (.now, 0)
        reportProgress(transfer, force: true)
        schedule(task.id)
    }

    public func pause(taskID: Int64, generation: UInt64? = nil) {
        if let pending = setupTasks[taskID], generation == nil || pending.generation == generation {
            pending.task.cancel()
            if preparingGenerations[taskID] == pending.generation { preparingGenerations.removeValue(forKey: taskID) }
            if requestedGenerations[taskID] == pending.generation { requestedGenerations.removeValue(forKey: taskID) }
            return
        }
        guard let transfer = transfers[taskID], generation == nil || transfer.generation == generation else {
            return
        }
        transfer.pausing = true
        progressDrainTasks[taskID]?.task.cancel()
        if let merge = mergeTasks[taskID], merge.generation == transfer.generation {
            merge.task.cancel()
            return
        }
        let tasks = Array(transfer.running.values)
        tasks.forEach { $0.cancel() }
        if tasks.isEmpty { finishPause(taskID) }
    }

    public func cancel(taskID: Int64, generation: UInt64? = nil, deletePartial: Bool) {
        let pending = setupTasks[taskID].flatMap { generation == nil || $0.generation == generation ? $0 : nil }
        if let pending {
            pending.task.cancel()
            if preparingGenerations[taskID] == pending.generation { preparingGenerations.removeValue(forKey: taskID) }
        }
        if let requested = requestedGenerations[taskID], generation == nil || requested == generation {
            requestedGenerations.removeValue(forKey: taskID)
        }
        guard let transfer = transfers[taskID], generation == nil || transfer.generation == generation else {
            let oldMerge = mergeTasks[taskID].flatMap { generation == nil || $0.generation == generation ? $0 : nil }
            oldMerge?.task.cancel()
            if let pending {
                let directory = checkpointDirectory(taskID)
                registerCleanup(taskID: taskID) {
                    _ = try? await pending.task.value
                    if let oldMerge { await oldMerge.task.value }
                    if deletePartial { Self.removeDirectory(directory, generation: pending.generation) }
                }
            } else if let oldMerge {
                let directory = checkpointDirectory(taskID)
                registerCleanup(taskID: taskID) {
                    await oldMerge.task.value
                    if deletePartial { Self.removeDirectory(directory, generation: oldMerge.generation) }
                }
            } else if deletePartial, transfers[taskID] == nil, setupTasks[taskID] == nil, mergeTasks[taskID] == nil {
                let directory = checkpointDirectory(taskID)
                let expected = Self.readGenerationMarker(directory)
                registerCleanup(taskID: taskID) {
                    Self.removeDirectory(directory, generation: expected)
                }
            }
            return
        }
        transfer.cancelling = true
        transfers.removeValue(forKey: taskID)
        transfer.running.values.forEach { $0.cancel() }
        if let session = transfer.session {
            sessionPolicies.remove(ObjectIdentifier(session))
            session.invalidateAndCancel()
        }
        rateSamples.removeValue(forKey: taskID)
        progressMailbox.end(taskID: taskID, generation: transfer.generation)
        if progressDrainTasks[taskID]?.generation == transfer.generation {
            progressDrainTasks.removeValue(forKey: taskID)?.task.cancel()
        }
        let merge = mergeTasks[taskID].flatMap { $0.generation == transfer.generation ? $0.task : nil }
        merge?.cancel()
        if deletePartial || pending != nil || merge != nil {
            let directory = transfer.directory
            let expectedGeneration = transfer.generation
            registerCleanup(taskID: taskID) {
                if let pending { _ = try? await pending.task.value }
                if let merge { await merge.value }
                if deletePartial { Self.removeDirectory(directory, generation: expectedGeneration) }
            }
        }
    }

    /// Removes segmented checkpoint artifacts only after the caller has durably
    /// committed the final target file to its destination.
    public func cleanupCompletedArtifacts(taskID: Int64, generation: UInt64) {
        let directory = checkpointDirectory(taskID)
        registerCleanup(taskID: taskID) {
            Self.removeDirectory(directory, generation: generation)
        }
    }

    private func schedule(_ taskID: Int64) {
        guard let transfer = transfers[taskID], !transfer.pausing, !transfer.cancelling,
              !transfer.failing, !transfer.merging else { return }
        rebalancePendingRanges(taskID)
        guard let transfer = transfers[taskID] else { return }
        let limit = transfer.connectionLimit
        while transfer.running.count < limit {
            guard let range = transfer.manifest.ranges.first(where: { !transfer.completed.contains($0.index) && transfer.running[$0.index] == nil }) else { break }
            guard let session = transfer.session, let url = URL(string: transfer.record.sourceURL) else { break }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("bytes=\(range.lower)-\(range.upper)", forHTTPHeaderField: "Range")
            let strongETag = transfer.manifest.etag.flatMap { $0.lowercased().hasPrefix("w/") ? nil : $0 }
            let validator = strongETag ?? transfer.manifest.lastModified
            if let validator, !validator.isEmpty { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let page = transfer.record.pageURL { request.setValue(page, forHTTPHeaderField: "Referer") }
            for (name, value) in transfer.headers where name.caseInsensitiveCompare("Host") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let download = session.downloadTask(with: request)
            download.taskDescription = "\(taskID):\(transfer.generation):\(range.index)"
            transfer.running[range.index] = download
            transfer.received[range.index] = 0
            download.resume()
        }
        reportProgress(transfer)
        if transfer.completed.count == transfer.manifest.ranges.count { merge(taskID) }
    }

    private func rebalancePendingRanges(_ taskID: Int64) {
        guard let transfer = transfers[taskID], transfer.settings.dynamicSegmentation else { return }
        let minimum = max(1_024, min(transfer.settings.minimumSegmentSizeBytes, 2 * 1_024 * 1_024 * 1_024))
        let freeWorkers = max(0, transfer.connectionLimit - transfer.running.count)
        guard freeWorkers > 0 else { return }
        var ranges = transfer.manifest.ranges
        var nextIndex = (ranges.map(\.index).max() ?? -1) + 1
        var changed = false
        let targetPending = freeWorkers * 4

        while ranges.count < 256 {
            let pending = ranges.filter { !transfer.completed.contains($0.index) && transfer.running[$0.index] == nil }
            guard pending.count < targetPending else { break }
            let candidate = pending.filter { $0.length >= minimum * 2 }.max { $0.length < $1.length }
            guard let range = candidate,
                  let position = ranges.firstIndex(where: { $0.index == range.index }) else { break }
            let leftLength = range.length / 2
            let rightLength = range.length - leftLength
            guard leftLength >= minimum, rightLength >= minimum else { break }
            let middle = range.lower + leftLength
            ranges.remove(at: position)
            ranges.append(ByteRange(index: nextIndex, lower: range.lower, upper: middle - 1))
            ranges.append(ByteRange(index: nextIndex + 1, lower: middle, upper: range.upper))
            nextIndex += 2
            changed = true
        }

        guard changed else { return }
        ranges.sort { $0.lower < $1.lower }
        transfer.manifest.ranges = ranges
        do {
            let data = try JSONEncoder().encode(transfer.manifest)
            let directory = transfer.directory
            try SegmentedDirectoryLocks.shared.withLock(directory: directory) {
                let manifestURL = directory.appendingPathComponent("manifest.json")
                try data.write(to: manifestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            }
        } catch {
            fail(taskID, "无法保存动态 Range 分片计划：\(error.localizedDescription)")
        }
    }

    nonisolated private static func prepareTransfer(task: DownloadRecord, generation: UInt64,
                                                    settings: AppSettings, directory: URL) throws -> Prepared {
        guard let url = URL(string: task.sourceURL), let total = task.totalBytes, total > 0 else {
            throw DownloadEngineError.invalidURL
        }
        return try SegmentedDirectoryLocks.shared.withLock(directory: directory) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let marker = directory.appendingPathComponent("active-generation")
            try Data(String(generation).utf8).write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

            let manifestURL = directory.appendingPathComponent("manifest.json")
            let minimum = max(1_024, min(settings.minimumSegmentSizeBytes, 2 * 1_024 * 1_024 * 1_024))
            let proposed = Manifest(sourceURL: url.absoluteString, etag: task.etag, lastModified: task.lastModified,
                total: total, ranges: makeRanges(total: total, minimum: minimum,
                    connections: max(1, min(settings.defaultConnectionCount, 256)),
                    dynamic: settings.dynamicSegmentation))
            let storedManifest = try? Data(contentsOf: manifestURL)
            let old = storedManifest.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            let manifest: Manifest
            if let old, old.sourceURL == proposed.sourceURL, old.etag == proposed.etag,
               old.lastModified == proposed.lastModified, old.total == proposed.total,
               old.ranges.first?.lower == 0, old.ranges.last?.upper == total - 1,
               hasContiguousRanges(old.ranges, total: total) {
                manifest = old
            } else {
                for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    try FileManager.default.removeItem(at: child)
                }
                try Data(String(generation).utf8).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                manifest = proposed
                try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            }

            try Task.checkCancellation()
            try prepareMergeOutput(directory: directory, total: total, sparse: settings.sparseFiles)
            var completed: Set<Int> = []
            for range in manifest.ranges {
                try Task.checkCancellation()
                let file = segmentURL(directory, range.index)
                let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
                if size == range.length { completed.insert(range.index) }
                else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            try Task.checkCancellation()
            return Prepared(manifest: manifest, completed: completed)
        }
    }

    nonisolated private static func removeDirectory(_ directory: URL, generation: UInt64?) {
        SegmentedDirectoryLocks.shared.withLock(directory: directory) {
            let marker = directory.appendingPathComponent("active-generation")
            if let generation, let stored = try? String(contentsOf: marker, encoding: .utf8),
               stored != String(generation) { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated private static func readGenerationMarker(_ directory: URL) -> UInt64? {
        let marker = directory.appendingPathComponent("active-generation")
        return (try? String(contentsOf: marker, encoding: .utf8)).flatMap(UInt64.init)
    }

    nonisolated private static func hasContiguousRanges(_ ranges: [ByteRange], total: Int64) -> Bool {
        guard !ranges.isEmpty, ranges.count <= 256 else { return false }
        let ordered = ranges.sorted { $0.lower < $1.lower }
        guard Set(ordered.map(\.index)).count == ordered.count else { return false }
        var nextLower: Int64 = 0
        for range in ordered {
            guard range.lower == nextLower, range.upper >= range.lower, range.upper < total else { return false }
            nextLower = range.upper + 1
        }
        return nextLower == total
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        guard let (id, generation, index) = Self.parse(downloadTask.taskDescription),
              progressMailbox.offer(taskID: id, generation: generation, rangeIndex: index,
                                    bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten) else { return }
        Task { @MainActor [weak self] in
            self?.scheduleProgressDrain(taskID: id, generation: generation)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        guard let (id, generation, index) = Self.parse(downloadTask.taskDescription),
              let http = downloadTask.response as? HTTPURLResponse else { return }
        let staging = baseDirectory.appendingPathComponent("staging", isDirectory: true)
        let transient = staging.appendingPathComponent("range-\(id)-\(generation)-\(index)-\(UUID().uuidString).partial")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try FileManager.default.moveItem(at: location, to: transient)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transient.path)
        } catch {
            try? FileManager.default.removeItem(at: transient)
            Task { @MainActor [weak self] in
                guard let self, let transfer = self.transfers[id], transfer.generation == generation,
                      transfer.running[index] === downloadTask else { return }
                self.fail(id, "无法保留 Range 分段：\(error.localizedDescription)")
            }
            return
        }
        let status = http.statusCode
        let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        let responseETag = http.value(forHTTPHeaderField: "ETag")
        Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(at: transient) }
            guard let self, let transfer = self.transfers[id], transfer.generation == generation,
                  transfer.running[index] === downloadTask,
                  let range = transfer.manifest.ranges.first(where: { $0.index == index }) else { return }
            if status == 200 {
                self.fallbackToSingle(id)
                return
            }
            guard status == 206,
                  let parsedRange = Self.parseContentRange(contentRange),
                  parsedRange.lower == range.lower,
                  parsedRange.upper == range.upper,
                  parsedRange.total == transfer.manifest.total else {
                self.fail(id, "服务器没有返回与请求一致的 Content-Range（HTTP \(status)）。")
                return
            }
            if let responseLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
               responseLength != range.length {
                self.fail(id, DownloadEngineError.lengthMismatch(expected: range.length, actual: responseLength).localizedDescription)
                return
            }
            let strongETag = transfer.manifest.etag.flatMap { $0.lowercased().hasPrefix("w/") ? nil : $0 }
            if let strongETag, responseETag != strongETag {
                self.fail(id, DownloadEngineError.sourceChanged.localizedDescription)
                return
            }
            if strongETag == nil, let old = transfer.manifest.lastModified,
               http.value(forHTTPHeaderField: "Last-Modified") != old {
                self.fail(id, DownloadEngineError.sourceChanged.localizedDescription)
                return
            }
            let actual = ((try? FileManager.default.attributesOfItem(atPath: transient.path)[.size]) as? NSNumber)?.int64Value ?? -1
            guard actual == range.length else {
                self.fail(id, DownloadEngineError.lengthMismatch(expected: range.length, actual: actual).localizedDescription)
                return
            }
            do {
                let destination = Self.segmentURL(transfer.directory, index)
                try SegmentedDirectoryLocks.shared.withLock(directory: transfer.directory) {
                    let renameResult = transient.path.withCString { sourcePath in
                        destination.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
                    }
                    if renameResult != 0 {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: transient, to: destination)
                    }
                }
                transfer.running.removeValue(forKey: index)
                transfer.received.removeValue(forKey: index)
                transfer.completed.insert(index)
                self.reportProgress(transfer)
                self.schedule(id)
            } catch { self.fail(id, "无法保存 Range 分段：\(error.localizedDescription)") }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (id, generation, index) = Self.parse(task.taskDescription) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor [weak self] in
            guard let self, let transfer = self.transfers[id], transfer.generation == generation,
                  transfer.running[index] === task else { return }
            transfer.running.removeValue(forKey: index)
            transfer.received.removeValue(forKey: index)
            if transfer.cancelling || transfer.failing { return }
            if transfer.pausing {
                if transfer.running.isEmpty { self.finishPause(id) }
                return
            }
            if !cancelled { self.fail(id, error.localizedDescription) }
            else { self.schedule(id) }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       willPerformHTTPRedirection response: HTTPURLResponse,
                                       newRequest request: URLRequest,
                                       completionHandler: @escaping (URLRequest?) -> Void) {
        var safe = request
        guard let old = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let next = request.url, NetworkConfiguration.validate(next) else {
            completionHandler(nil)
            return
        }
        if old.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
            completionHandler(nil); return
        }
        if !NetworkConfiguration.hasSameOrigin(old, next) {
            for name in NetworkConfiguration.sensitiveHeaderNames { safe.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(safe)
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       didReceive challenge: URLAuthenticationChallenge,
                                       completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let policy = sessionPolicies.get(ObjectIdentifier(session))
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           policy?.allowInvalidTLS == true, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        if challenge.protectionSpace.isProxy(), let policy,
           !policy.proxyUsername.isEmpty, !policy.proxyPassword.isEmpty {
            completionHandler(.useCredential, URLCredential(user: policy.proxyUsername,
                password: policy.proxyPassword, persistence: .forSession)); return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private func scheduleProgressDrain(taskID: Int64, generation: UInt64) {
        if let current = progressDrainTasks[taskID], current.generation == generation { return }
        progressDrainTasks[taskID]?.task.cancel()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drainProgress(taskID: taskID, generation: generation)
        }
        progressDrainTasks[taskID] = (generation, task)
    }

    private func drainProgress(taskID: Int64, generation: UInt64) async {
        while let packet = progressMailbox.take(taskID: taskID, generation: generation) {
            guard let transfer = transfers[taskID], transfer.generation == generation,
                  !transfer.pausing, !transfer.cancelling, !transfer.failing else { break }
            for (index, received) in packet.latestByRange where transfer.running[index] != nil {
                transfer.received[index] = received
            }
            reportProgress(transfer)
            await enforceRateLimit(taskID: taskID, generation: generation, bytesWritten: packet.bytesWritten)
            if Task.isCancelled { break }
        }
        if progressDrainTasks[taskID]?.generation == generation { progressDrainTasks.removeValue(forKey: taskID) }
    }

    private func fail(_ id: Int64, _ message: String) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        transfer.failing = true
        transfer.running.values.forEach { $0.cancel() }
        if let session = transfer.session {
            sessionPolicies.remove(ObjectIdentifier(session))
            session.invalidateAndCancel()
        }
        rateSamples.removeValue(forKey: id)
        progressMailbox.end(taskID: id, generation: transfer.generation)
        progressDrainTasks.removeValue(forKey: id)?.task.cancel()
        let merge = mergeTasks.removeValue(forKey: id).flatMap { $0.generation == transfer.generation ? $0.task : nil }
        merge?.cancel()
        if let merge {
            registerCleanup(taskID: id) { await merge.value }
        }
        onFailed?(id, transfer.generation, message)
    }

    private func fallbackToSingle(_ id: Int64) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        transfer.failing = true
        transfer.running.values.forEach { $0.cancel() }
        if let session = transfer.session {
            sessionPolicies.remove(ObjectIdentifier(session))
            session.invalidateAndCancel()
        }
        rateSamples.removeValue(forKey: id)
        progressMailbox.end(taskID: id, generation: transfer.generation)
        progressDrainTasks.removeValue(forKey: id)?.task.cancel()
        let merge = mergeTasks.removeValue(forKey: id).flatMap { $0.generation == transfer.generation ? $0.task : nil }
        merge?.cancel()
        let directory = transfer.directory
        let generation = transfer.generation
        registerCleanup(taskID: id) {
            if let merge { await merge.value }
            Self.removeDirectory(directory, generation: generation)
        }
        onRangeUnsupported?(id, transfer.generation)
    }

    private func finishPause(_ id: Int64) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        if let session = transfer.session {
            sessionPolicies.remove(ObjectIdentifier(session))
            session.invalidateAndCancel()
        }
        rateSamples.removeValue(forKey: id)
        progressMailbox.end(taskID: id, generation: transfer.generation)
        progressDrainTasks.removeValue(forKey: id)?.task.cancel()
        let committed = min(transfer.manifest.total, completedBytes(transfer))
        onPaused?(id, transfer.generation, committed)
    }

    private func merge(_ id: Int64) {
        guard let transfer = transfers[id], transfer.completed.count == transfer.manifest.ranges.count,
              !transfer.merging, !transfer.pausing else { return }
        transfer.merging = true
        let generation = transfer.generation
        let manifest = transfer.manifest
        let directory = transfer.directory
        let sparse = transfer.settings.sparseFiles
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let outputURL = try Self.mergeSegments(directory: directory, generation: generation,
                                                       manifest: manifest, sparse: sparse)
                try Task.checkCancellation()
                await self?.mergeCompleted(taskID: id, generation: generation, outputURL: outputURL)
            } catch {
                await self?.mergeFailed(taskID: id, generation: generation, error: error)
            }
        }
        mergeTasks[id] = (generation, task)
    }

    private func registerCleanup(taskID: Int64, operation: @escaping @Sendable () async -> Void) {
        let previous = cleanupTasks[taskID]
        let token = UUID()
        let task = Task.detached(priority: .utility) { [weak self] in
            if let previous { await previous.task.value }
            await operation()
            await MainActor.run {
                if self?.cleanupTasks[taskID]?.token == token {
                    self?.cleanupTasks.removeValue(forKey: taskID)
                }
            }
        }
        cleanupTasks[taskID] = (token, task)
    }

    private func mergeCompleted(taskID: Int64, generation: UInt64, outputURL: URL) {
        if mergeTasks[taskID]?.generation == generation { mergeTasks.removeValue(forKey: taskID) }
        guard let transfer = transfers[taskID], transfer.generation == generation else { return }
        if transfer.pausing { finishPause(taskID); return }
        guard !transfer.cancelling, !transfer.failing else { return }
        transfers.removeValue(forKey: taskID)
        if let session = transfer.session {
            sessionPolicies.remove(ObjectIdentifier(session))
            session.finishTasksAndInvalidate()
        }
        rateSamples.removeValue(forKey: taskID)
        progressMailbox.end(taskID: taskID, generation: generation)
        if progressDrainTasks[taskID]?.generation == generation {
            progressDrainTasks.removeValue(forKey: taskID)?.task.cancel()
        }
        onFinished?(taskID, generation, outputURL)
    }

    private func mergeFailed(taskID: Int64, generation: UInt64, error: Error) {
        if mergeTasks[taskID]?.generation == generation { mergeTasks.removeValue(forKey: taskID) }
        guard let transfer = transfers[taskID], transfer.generation == generation else { return }
        if transfer.pausing || error is CancellationError {
            finishPause(taskID)
        } else {
            fail(taskID, "无法合并 Range 分段：\(error.localizedDescription)")
        }
    }

    private func completedBytes(_ transfer: Transfer) -> Int64 {
        transfer.manifest.ranges.filter { transfer.completed.contains($0.index) }.reduce(Int64(0)) { partial, range in
            let (sum, overflow) = partial.addingReportingOverflow(range.length)
            return overflow ? Int64.max : sum
        }
    }

    private func reportProgress(_ transfer: Transfer, force: Bool = false) {
        let done = completedBytes(transfer)
        let active = transfer.received.values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(max(0, value))
            return overflow ? Int64.max : sum
        }
        let (combined, overflow) = done.addingReportingOverflow(active)
        let received = min(transfer.manifest.total, overflow ? Int64.max : combined)
        let now = Date.now
        guard force || received >= transfer.manifest.total || now.timeIntervalSince(transfer.lastProgressEmission) >= 0.1 else { return }
        transfer.lastProgressEmission = now
        onProgress?(transfer.record.id, transfer.generation,
                    received, transfer.manifest.total)
    }

    private func enforceRateLimit(taskID: Int64, generation: UInt64, bytesWritten: Int64) async {
        guard let transfer = transfers[taskID], transfer.generation == generation else { return }
        let now = Date.now
        let previous = rateSamples[taskID] ?? (now, 0)
        let elapsed = now.timeIntervalSince(previous.0)
        let (sum, overflow) = previous.1.addingReportingOverflow(max(0, bytesWritten))
        let accumulated = overflow ? Int64.max : max(0, sum)
        var taskDelay: TimeInterval = 0
        if transfer.speedLimit > 0, elapsed > 0, Double(accumulated) > Double(transfer.speedLimit) * elapsed {
            taskDelay = max(0.05, Double(accumulated) / Double(transfer.speedLimit) - elapsed)
        } else if elapsed >= 1 { rateSamples[taskID] = (now, 0) }
        else { rateSamples[taskID] = (previous.0, accumulated) }
        let globalDelay: TimeInterval = if transfer.settings.globalSpeedLimitBytesPerSecond > 0 {
            await SharedGlobalRateLimiter.shared.reserve(bytes: bytesWritten,
                limit: transfer.settings.globalSpeedLimitBytesPerSecond)
        } else { 0 }
        let hostRule = URL(string: transfer.record.sourceURL).flatMap {
            NetworkConfiguration.matchingHostRule(for: $0, settings: transfer.settings)
        }
        let hostLimit = hostRule?.speedLimitBytesPerSecond ?? 0
        let hostDelay: TimeInterval = if hostLimit > 0, let hostRule {
            await SharedGlobalRateLimiter.shared.reserve(bytes: bytesWritten,
                limit: hostLimit, bucket: "host:\(hostRule.pattern.lowercased())")
        } else { 0 }
        let delay = min(2.0, max(taskDelay, max(globalDelay, hostDelay)))
        guard delay > 0 else { return }
        let suspendedTasks = Array(transfer.running.values)
        suspendedTasks.forEach { $0.suspend() }
        var remaining = delay
        while remaining > 0 {
            let slice = min(0.25, remaining)
            do { try await Task.sleep(for: .seconds(slice)) }
            catch { return }
            guard !Task.isCancelled, let current = transfers[taskID], current.generation == generation,
                  !current.pausing, !current.cancelling, !current.failing else { return }
            let activeHostLimit = URL(string: current.record.sourceURL).flatMap {
                NetworkConfiguration.matchingHostRule(for: $0, settings: current.settings)?.speedLimitBytesPerSecond
            } ?? 0
            if current.speedLimit <= 0 && current.settings.globalSpeedLimitBytesPerSecond <= 0 && activeHostLimit <= 0 {
                break
            }
            remaining -= slice
        }
        guard let current = transfers[taskID], current.generation == generation,
              !current.pausing, !current.cancelling, !current.failing else { return }
        rateSamples[taskID] = (.now, 0)
        for task in suspendedTasks where current.running.values.contains(where: { $0 === task }) { task.resume() }
    }

    nonisolated private static func makeRanges(total: Int64, minimum: Int64, connections: Int, dynamic: Bool) -> [ByteRange] {
        let maximum = 256
        let chunksForMinimum = max(1, Int(min(Int64(maximum), (total - 1) / minimum + 1)))
        let count = dynamic ? chunksForMinimum : min(max(1, connections), chunksForMinimum)
        let chunk = (total - 1) / Int64(count) + 1
        var start: Int64 = 0
        var result: [ByteRange] = []
        while start < total {
            let length = min(chunk, total - start)
            let end = start + length - 1
            result.append(ByteRange(index: result.count, lower: start, upper: end))
            start = end + 1
        }
        return result
    }

    nonisolated private static func parse(_ value: String?) -> (Int64, UInt64, Int)? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let id = Int64(parts[0]), let generation = UInt64(parts[1]),
              let index = Int(parts[2]) else { return nil }
        return (id, generation, index)
    }

    nonisolated private static func parseContentRange(_ value: String) -> (lower: Int64, upper: Int64, total: Int64)? {
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
        return (lower, upper, total)
    }

    nonisolated private func checkpointDirectory(_ id: Int64) -> URL {
        baseDirectory.appendingPathComponent("range-parts-\(id)", isDirectory: true)
    }

    nonisolated private static func segmentURL(_ directory: URL, _ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "segment-%04d.part", index))
    }

    nonisolated private static func mergeSegments(directory: URL, generation: UInt64,
                                                  manifest: Manifest, sparse: Bool) throws -> URL {
        try SegmentedDirectoryLocks.shared.withLock(directory: directory) {
            try Task.checkCancellation()
            let marker = directory.appendingPathComponent("active-generation")
            guard let stored = try? String(contentsOf: marker, encoding: .utf8),
                  stored == String(generation) else { throw CancellationError() }
            let outputURL = directory.appendingPathComponent("output.partial")
            let outputSize = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value
            if outputSize != manifest.total {
                try prepareMergeOutput(directory: directory, total: manifest.total, sparse: sparse)
            }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            for range in manifest.ranges.sorted(by: { $0.lower < $1.lower }) {
                try Task.checkCancellation()
                let inputURL = segmentURL(directory, range.index)
                let inputSize = ((try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size]) as? NSNumber)?.int64Value ?? -1
                guard inputSize == range.length else {
                    throw DownloadEngineError.lengthMismatch(expected: range.length, actual: inputSize)
                }
                let input = try FileHandle(forReadingFrom: inputURL)
                do {
                    var fileOffset = range.lower
                    var copied: Int64 = 0
                    while true {
                        try Task.checkCancellation()
                        let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        let chunkCount = Int64(chunk.count)
                        guard copied <= range.length - chunkCount else {
                            throw DownloadEngineError.lengthMismatch(expected: range.length, actual: copied + chunkCount)
                        }
                        try output.seek(toOffset: UInt64(fileOffset))
                        try output.write(contentsOf: chunk)
                        fileOffset += chunkCount
                        copied += chunkCount
                    }
                    try input.close()
                    guard copied == range.length else {
                        throw DownloadEngineError.lengthMismatch(expected: range.length, actual: copied)
                    }
                } catch {
                    try? input.close()
                    throw error
                }
            }
            try Task.checkCancellation()
            return outputURL
        }
    }

    nonisolated private static func prepareMergeOutput(directory: URL, total: Int64, sparse: Bool) throws {
        let url = directory.appendingPathComponent("output.partial")
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw DownloadEngineError.missingDestination
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        guard total > 0 else { return }
        if sparse {
            do { try output.truncate(atOffset: UInt64(total)); return }
            catch {
                try output.truncate(atOffset: 0)
                try fillAllocatedSpace(output, total: total)
                return
            }
        }
        var allocation = fstore_t()
        allocation.fst_flags = UInt32(F_ALLOCATEALL)
        allocation.fst_posmode = F_PEOFPOSMODE
        allocation.fst_offset = 0
        allocation.fst_length = off_t(total)
        if Darwin.fcntl(output.fileDescriptor, F_PREALLOCATE, &allocation) == -1 {
            let errorCode = errno
            guard errorCode == EINVAL || errorCode == ENOTSUP || errorCode == EOPNOTSUPP else {
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
            try output.truncate(atOffset: 0)
            try fillAllocatedSpace(output, total: total)
            return
        }
        guard Darwin.ftruncate(output.fileDescriptor, off_t(total)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated private static func fillAllocatedSpace(_ output: FileHandle, total: Int64) throws {
        let zeroes = Data(repeating: 0, count: 1024 * 1024)
        var remaining = total
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, Int64(zeroes.count)))
            try output.write(contentsOf: zeroes.prefix(count))
            remaining -= Int64(count)
        }
    }

    private static func makeConfiguration(_ settings: AppSettings, proxyPassword: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 256
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        NetworkConfiguration.applyProxy(settings: settings, proxyPassword: proxyPassword, to: config)
        return config
    }
}
