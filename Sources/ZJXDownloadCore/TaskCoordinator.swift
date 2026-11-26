import Foundation
import Observation
import CryptoKit
import IOKit.pwr_mgt
import Darwin

public struct TransferMetric: Sendable {
    public var bytesPerSecond: Double
    public var averageBytesPerSecond: Double
    public var updatedAt: Date
    public init(bytesPerSecond: Double = 0, averageBytesPerSecond: Double = 0, updatedAt: Date = .now) {
        self.bytesPerSecond = bytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
public final class TransferLiveState {
    public private(set) var receivedBytes: [Int64: Int64] = [:]
    public private(set) var totalBytes: [Int64: Int64] = [:]
    public private(set) var metrics: [Int64: TransferMetric] = [:]
    public private(set) var totalActiveSpeed: Double = 0

    public init() {}

    public func update(taskID: Int64, received: Int64, total: Int64?, metric: TransferMetric) {
        receivedBytes[taskID] = max(0, received)
        if let total, total >= 0 { totalBytes[taskID] = total }
        metrics[taskID] = metric
        recomputeTotalSpeed()
    }

    public func clear(taskID: Int64) {
        let hadReceived = receivedBytes.removeValue(forKey: taskID) != nil
        let hadTotal = totalBytes.removeValue(forKey: taskID) != nil
        let hadMetric = metrics.removeValue(forKey: taskID) != nil
        if hadReceived || hadTotal || hadMetric {
            recomputeTotalSpeed()
        }
    }

    public func clearAll() {
        guard !receivedBytes.isEmpty || !totalBytes.isEmpty || !metrics.isEmpty else { return }
        receivedBytes.removeAll(keepingCapacity: false)
        totalBytes.removeAll(keepingCapacity: false)
        metrics.removeAll(keepingCapacity: false)
        totalActiveSpeed = 0
    }

    public func prune(keeping validIDs: Set<Int64>) {
        var changed = false
        for key in Array(receivedBytes.keys) where !validIDs.contains(key) {
            receivedBytes.removeValue(forKey: key); changed = true
        }
        for key in Array(totalBytes.keys) where !validIDs.contains(key) {
            totalBytes.removeValue(forKey: key); changed = true
        }
        for key in Array(metrics.keys) where !validIDs.contains(key) {
            metrics.removeValue(forKey: key); changed = true
        }
        if changed { recomputeTotalSpeed() }
    }

    public func decayStaleSpeeds(now: Date = .now, threshold: TimeInterval = 3.0) {
        var changed = false
        for (id, metric) in metrics where metric.bytesPerSecond > 0 && now.timeIntervalSince(metric.updatedAt) >= threshold {
            metrics[id] = TransferMetric(bytesPerSecond: 0, averageBytesPerSecond: metric.averageBytesPerSecond, updatedAt: metric.updatedAt)
            changed = true
        }
        if changed { recomputeTotalSpeed() }
    }

    public func effectiveReceivedBytes(for task: DownloadRecord) -> Int64 {
        receivedBytes[task.id] ?? task.receivedBytes
    }

    public func effectiveTotalBytes(for task: DownloadRecord) -> Int64? {
        totalBytes[task.id] ?? task.totalBytes
    }

    public func effectiveProgress(for task: DownloadRecord) -> Double? {
        guard let total = effectiveTotalBytes(for: task), total > 0 else { return nil }
        return min(1, Double(effectiveReceivedBytes(for: task)) / Double(total))
    }

    private func recomputeTotalSpeed() {
        totalActiveSpeed = metrics.values.reduce(0) { partial, metric in
            let speed = metric.bytesPerSecond.isFinite && metric.bytesPerSecond > 0 ? metric.bytesPerSecond : 0
            return partial + speed
        }
    }
}

public struct ImportReviewItem: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    public let source: String
}

public struct PendingImportReview: Sendable, Identifiable {
    public let id: UUID
    public let items: [ImportReviewItem]
    public let totalCount: Int
}

public struct TaskStatusEvent: Sendable, Identifiable {
    public let sequence: UInt64
    public let taskID: Int64
    public let oldStatus: DownloadStatus?
    public let newStatus: DownloadStatus
    public let displayName: String
    public let showProgressWindow: Bool?
    public let showCompletionWindow: Bool?
    public let error: String?
    public var id: UInt64 { sequence }
}

public struct TaskStatusEventBatch: Sendable {
    public let events: [TaskStatusEvent]
    public let latestSequence: UInt64
    public let earliestSequence: UInt64?
    public let hasGap: Bool
}

private struct FileCommitTransaction: Sendable {
    let targetURL: URL
    let reservationPath: String
    let stagedURL: URL
    let backupURL: URL?
    let partialURL: URL
    let displayName: String
    let reservationID: UUID
    let installedIdentity: FileIdentity
}

private struct FileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }
}

private func canonicalFilePath(_ url: URL) -> String {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL.path
}

private struct FileAuditCandidate: Sendable {
    let taskID: Int64
    let outputURL: URL
}

private struct FileAuditResult: Sendable {
    let taskID: Int64
    let outputURL: URL
    let exists: Bool
}

private enum FileCommitError: Error, LocalizedError, Sendable {
    case targetReserved(URL)
    case recoveryRequired(backup: URL?, staged: URL?, reason: String)

    var requiresRecoveryArtifacts: Bool {
        if case .recoveryRequired = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .targetReserved(let url): return "目标路径正由另一项文件提交占用：\(url.path)"
        case .recoveryRequired(let backup, let staged, let reason):
            let recovery = [backup.map { "备份：\($0.path)" }, staged.map { "暂存：\($0.path)" }]
                .compactMap { $0 }.joined(separator: "；")
            return recovery.isEmpty ? "文件提交需要恢复：\(reason)" : "文件提交需要恢复：\(reason)（\(recovery)）"
        }
    }
}

/// Serializes final destination changes and performs all potentially large file
/// copies away from the main actor. A replace keeps the original until the
/// completed task state has been durably saved.
private actor FileCommitter {
    static let shared = FileCommitter()
    private var reservations: [String: UUID] = [:]

    func install(record: DownloadRecord, staged: URL, size: Int64, modificationDate: Date?,
                 occupiedPaths: Set<String>) async throws -> FileCommitTransaction {
        let requestedFolder = record.outputURL.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: requestedFolder, withIntermediateDirectories: true)
        let folder = requestedFolder.resolvingSymlinksInPath().standardizedFileURL
        var name = record.displayName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DownloadEngineError.invalidFileName
        }
        var target = folder.appendingPathComponent(name)
        let targetPath = canonicalFilePath(target)
        let targetIsReserved = reservations[targetPath] != nil
        if targetIsReserved || FileManager.default.fileExists(atPath: target.path) || occupiedPaths.contains(targetPath) {
            switch record.conflictPolicy {
            case .rename:
                name = uniqueName(name, in: folder, occupiedPaths: occupiedPaths.union(reservations.keys))
                target = folder.appendingPathComponent(name)
            case .replace:
                if targetIsReserved { throw FileCommitError.targetReserved(target) }
            case .cancel:
                if targetIsReserved { throw FileCommitError.targetReserved(target) }
                throw DownloadEngineError.conflict
            }
        }
        let resolvedTargetPath = canonicalFilePath(target)
        guard reservations[resolvedTargetPath] == nil else { throw FileCommitError.targetReserved(target) }
        let reservationID = UUID()
        reservations[resolvedTargetPath] = reservationID

        let partial = folder.appendingPathComponent(".zjx-download-\(UUID().uuidString).partial")
        let backup = folder.appendingPathComponent(".zjx-download-\(UUID().uuidString).backup")
        var hadTarget = false
        var installedTarget = false
        var installedIdentity: FileIdentity?
        do {
            try copyFile(staged, to: partial, expectedSize: size)
            if let modificationDate {
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: partial.path)
            }
            try Task.checkCancellation()
            hadTarget = FileManager.default.fileExists(atPath: target.path)
            if hadTarget {
                guard record.conflictPolicy == .replace else { throw DownloadEngineError.conflict }
                try FileManager.default.moveItem(at: target, to: backup)
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: target)
            installedTarget = true
            installedIdentity = FileIdentity.read(target)
            guard installedIdentity != nil else { throw CocoaError(.fileReadUnknown) }
            try Task.checkCancellation()
            guard let installedIdentity else { throw CocoaError(.fileReadUnknown) }
            return FileCommitTransaction(targetURL: target, reservationPath: resolvedTargetPath, stagedURL: staged,
                                         backupURL: hadTarget ? backup : nil,
                                         partialURL: partial, displayName: name,
                                         reservationID: reservationID, installedIdentity: installedIdentity)
        } catch let installError {
            do {
                try? FileManager.default.removeItem(at: partial)
                if installedTarget, FileManager.default.fileExists(atPath: target.path) {
                    guard let installedIdentity, FileIdentity.read(target) == installedIdentity else {
                        throw FileCommitError.recoveryRequired(backup: hadTarget ? backup : nil, staged: staged,
                                                               reason: "无法确认新目标文件身份，未删除目标")
                    }
                    try FileManager.default.removeItem(at: target)
                }
                if hadTarget, FileManager.default.fileExists(atPath: backup.path) {
                    guard !FileManager.default.fileExists(atPath: target.path) else {
                        throw FileCommitError.recoveryRequired(backup: backup, staged: staged,
                                                               reason: "目标路径已被外部改动占用")
                    }
                    try FileManager.default.moveItem(at: backup, to: target)
                }
                reservations.removeValue(forKey: resolvedTargetPath)
            } catch let recoveryError {
                reservations.removeValue(forKey: resolvedTargetPath)
                throw FileCommitError.recoveryRequired(backup: hadTarget ? backup : nil, staged: staged,
                    reason: "\(installError.localizedDescription)；\(recoveryError.localizedDescription)")
            }
            throw installError
        }
    }

    func rollback(_ transaction: FileCommitTransaction) throws {
        let path = transaction.reservationPath
        guard reservations[path] == transaction.reservationID else {
            throw FileCommitError.recoveryRequired(backup: transaction.backupURL, staged: transaction.stagedURL,
                                                   reason: "目标保留标识已失效，未删除任何目标文件")
        }
        do {
            if FileManager.default.fileExists(atPath: transaction.targetURL.path) {
                guard FileIdentity.read(transaction.targetURL) == transaction.installedIdentity else {
                    reservations.removeValue(forKey: path)
                    throw FileCommitError.recoveryRequired(backup: transaction.backupURL, staged: transaction.stagedURL,
                                                           reason: "目标文件已被外部替换，未删除该文件")
                }
                try FileManager.default.removeItem(at: transaction.targetURL)
            }
            if let backup = transaction.backupURL,
               FileManager.default.fileExists(atPath: backup.path) {
                guard !FileManager.default.fileExists(atPath: transaction.targetURL.path) else {
                    reservations.removeValue(forKey: path)
                    throw FileCommitError.recoveryRequired(backup: backup, staged: transaction.stagedURL,
                                                           reason: "目标路径已有外部文件，备份仍保留")
                }
                try FileManager.default.moveItem(at: backup, to: transaction.targetURL)
            }
            try? FileManager.default.removeItem(at: transaction.partialURL)
            try? FileManager.default.removeItem(at: transaction.stagedURL)
            reservations.removeValue(forKey: path)
        } catch {
            reservations.removeValue(forKey: path)
            if let recovery = error as? FileCommitError { throw recovery }
            throw FileCommitError.recoveryRequired(backup: transaction.backupURL, staged: transaction.stagedURL,
                                                   reason: error.localizedDescription)
        }
    }

    func finish(_ transaction: FileCommitTransaction) throws {
        let path = transaction.reservationPath
        guard reservations[path] == transaction.reservationID,
              FileIdentity.read(transaction.targetURL) == transaction.installedIdentity else {
            reservations.removeValue(forKey: path)
            throw FileCommitError.recoveryRequired(backup: transaction.backupURL, staged: transaction.stagedURL,
                                                   reason: "持久化后目标已被外部替换；保留提交备份")
        }
        if let backup = transaction.backupURL {
            do { try FileManager.default.removeItem(at: backup) }
            catch {
                reservations.removeValue(forKey: path)
                throw FileCommitError.recoveryRequired(backup: backup, staged: transaction.stagedURL,
                                                       reason: "新文件已提交，但旧文件备份清理失败：\(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: transaction.partialURL)
        do { try FileManager.default.removeItem(at: transaction.stagedURL) }
        catch {
            reservations.removeValue(forKey: path)
            throw FileCommitError.recoveryRequired(backup: nil, staged: transaction.stagedURL,
                                                   reason: "新文件已提交，但清理暂存文件失败：\(error.localizedDescription)")
        }
        reservations.removeValue(forKey: path)
    }

    private func copyFile(_ source: URL, to destination: URL, expectedSize: Int64) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        let actualSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(actualSize ?? -1) == expectedSize else {
            throw DownloadEngineError.lengthMismatch(expected: expectedSize, actual: Int64(actualSize ?? -1))
        }
    }

    private func uniqueName(_ name: String, in folder: URL, occupiedPaths: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
            let path = canonicalFilePath(folder.appendingPathComponent(candidate))
            if !occupiedPaths.contains(path) && !FileManager.default.fileExists(atPath: path) { return candidate }
            suffix += 1
        }
    }
}

@MainActor
@Observable
public final class TaskCoordinator {
    public private(set) var data: AppData
    public let liveState = TransferLiveState()
    public var liveMetrics: [Int64: TransferMetric] { liveState.metrics }
    public private(set) var startupError: String?
    public private(set) var lastActionMessage: String?
    public private(set) var lastCompletedTaskID: Int64?
    public private(set) var pendingImportReview: PendingImportReview?
    public var pendingImportCount: Int { importReviewQueue.count }
    public private(set) var taskStatusRevision: UInt64 = 0
    public var onGlobalSpeedLimitModeChanged: ((GlobalSpeedLimitMode) -> Void)?
    public var onIntegrationSettingsChanged: ((AppSettings) -> Void)?
    public var selectedTaskIDs = Set<Int64>()
    public var onQueueCompletionAction: ((CompletionAction) -> Void)?
    public var onTaskCompletionAction: ((CompletionAction) -> Void)?

    public let store: StateStore
    public let credentials: CredentialStore
    public let engine: DownloadEngine
    public let segmentedEngine: SegmentedDownloadService
    public let queueScheduler: QueueScheduler
    @ObservationIgnored private var hlsWork: [Int64: (generation: UInt64, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var hlsPolicies: [Int64: (generation: UInt64, policy: HLSRuntimePolicy)] = [:]
    @ObservationIgnored private var preparationWork: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var fileCommitWork: [Int64: (generation: UInt64, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var transferGenerations: [Int64: UInt64] = [:]
    @ObservationIgnored private var pauseInProgress: [Int64: UInt64] = [:]
    @ObservationIgnored private var retainedTaskStatusEvents: [TaskStatusEvent] = []
    @ObservationIgnored private var progressSnapshots: [Int64: (Date, Int64)] = [:]
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var fileAuditWork: Task<Void, Never>?
    @ObservationIgnored private var completionActionsTriggered = Set<Int64>()
    @ObservationIgnored private var backgroundInteractionActive = false
    @ObservationIgnored private var importReviewQueue: [(review: PendingImportReview, continuation: CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var inFlightImportTasks: [String: (digest: String, waiters: Int, task: Task<ImportRequestResult, Error>)] = [:]
    @ObservationIgnored private var activeImportRequestCount = 0
    @ObservationIgnored private var activeSessionStartedAt: [Int64: Date] = [:]
    @ObservationIgnored private var accumulatedActiveDuration: [Int64: TimeInterval] = [:]
    @ObservationIgnored private var pendingHLSReset = Set<Int64>()
    @ObservationIgnored private var schedulerWakeContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var sleepAssertionID: IOPMAssertionID?
    @ObservationIgnored private var lastDiskAudit = Date.distantPast

    public init(directory: URL? = nil, credentialService: String = ProductIdentity.bundleID + ".credentials") {
        let loadedStore: StateStore
        let loadedData: AppData
        var loadError: String? = nil
        do {
            let candidate = try StateStore(directory: directory)
            let value = try candidate.load()
            loadedStore = candidate
            loadedData = value
        } catch {
            let originalError = error
            let recovery = StateStore.readOnlyRecovery(directory: directory)
            loadedStore = recovery
            do {
                loadedData = try recovery.load()
                loadError = "无法安全打开下载数据写入锁：\(originalError.localizedDescription)。已只读显示最后保存的数据。"
            } catch {
                loadedData = AppData()
                loadError = "无法读取下载数据：\(error.localizedDescription)。原文件未更改；当前为只读恢复界面。"
            }
        }
        store = loadedStore
        data = loadedData
        startupError = loadError
        _ = ProcessDNSResolver.apply(mode: loadedData.settings.dnsMode, dohURL: loadedData.settings.dohURL)
        credentials = CredentialStore(service: credentialService)
        engine = DownloadEngine(baseDirectory: loadedStore.directory)
        segmentedEngine = SegmentedDownloadService(baseDirectory: loadedStore.directory)
        queueScheduler = QueueScheduler()
        wireComponents()
        recoverInterruptedTasks()
        startScheduler()
    }

    public var legacyStateAvailable: Bool { store.hasLegacyState && data.importedLegacyAt == nil }
    public var hasOutstandingTransfers: Bool {
        data.tasks.contains(where: \.status.isActive) || !preparationWork.isEmpty || !hlsWork.isEmpty ||
            !fileCommitWork.isEmpty ||
            engine.activeTransferCount > 0 || segmentedEngine.activeTransferCount > 0
    }

    public func updateSystemActivity(appIsActive: Bool, idleInterval: TimeInterval) {
        let isInteractingInBackground = !appIsActive && idleInterval >= 0 && idleInterval < 60
        guard backgroundInteractionActive != isInteractingInBackground else { return }
        let previousLimit = effectiveGlobalSpeedLimit
        backgroundInteractionActive = isInteractingInBackground
        guard previousLimit != effectiveGlobalSpeedLimit else { return }
        Task { await SharedGlobalRateLimiter.shared.resetGlobalReservation() }
        reconfigureActiveNetworkTransfers()
    }

    public func previewLegacyImport() throws -> LegacyImportPreview? { try store.previewLegacyImport() }

    public func taskStatusEvents(after sequence: UInt64) -> TaskStatusEventBatch {
        let events = retainedTaskStatusEvents.filter { $0.sequence > sequence }
        let earliest = retainedTaskStatusEvents.first?.sequence
        let hasGap = earliest.map { sequence < $0 && $0 - sequence > 1 } ?? false
        return TaskStatusEventBatch(events: events, latestSequence: taskStatusRevision,
                                    earliestSequence: earliest, hasGap: hasGap)
    }

    public func importLegacyData() throws -> LegacyImportResult {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        let previous = data
        let (migrated, result) = try store.importLegacy(into: data)
        data = migrated
        do { try store.save(data) }
        catch { data = previous; throw error }
        lastActionMessage = "已导入 \(result.tasksImported) 项任务。原 state.json、下载文件与旧钥匙串条目仍保留。"
        return result
    }

    @discardableResult
    public func add(_ request: CreateDownloadRequest) async throws -> Int64 {
        try await addPersisting(request, beforePersist: nil)
    }

    private func addPersisting(_ request: CreateDownloadRequest,
                               beforePersist: ((Int64) throws -> Void)?) async throws -> Int64 {
        guard startupError == nil else { throw ValidationError("应用数据无法读取；为保护原数据，当前不能新增或修改任务。") }
        try Task.checkCancellation()
        var sourceHeaders = request.headers
        let sourceURL = try urlWithoutInlineCredentials(request.sourceURL, moveCredentialsTo: &sourceHeaders)
        guard NetworkConfiguration.validate(sourceURL) else { throw DownloadEngineError.invalidURL }
        let effective = try prepareEffectiveRequest(url: sourceURL, headers: sourceHeaders,
                                                    settings: data.settings, taskLimit: request.speedLimitBytesPerSecond,
                                                    taskConnectionCount: request.connectionCount)
        var probeSettings = data.settings
        if effective.connectionCount > 0 { probeSettings.defaultConnectionCount = effective.connectionCount }
        let proxyPassword = try credentials.read(account: data.settings.proxyPasswordAccount) ?? ""
        let remote: RemoteResourceInfo
        do {
            remote = try await engine.probe(sourceURL, headers: effective.headers.merging(effective.credentialHeaders) { _, new in new },
                                            userAgent: effective.userAgent, settings: probeSettings, proxyPassword: proxyPassword)
        } catch {
            throw ValidationError(redactSensitiveURL(in: error.localizedDescription, sourceURL: request.sourceURL))
        }
        try Task.checkCancellation()
        let proposedName = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? remote.suggestedName ?? sourceURL.lastPathComponent.nonEmpty ?? sourceURL.host ?? "download"
        let safeName = try Self.sanitizeFileName(proposedName)
        let matchingCategory = request.categoryID == nil && data.settings.autoCategorizeNewDownloads
            ? bestMatchingCategory(url: sourceURL, fileName: safeName) : nil
        let categoryID = request.categoryID ?? matchingCategory?.id
        let categoryPath = data.categories.first(where: { $0.id == categoryID })?.destinationDirectory
        let destination = request.destinationDirectory?.standardizedFileURL.path ?? categoryPath ?? data.settings.defaultDownloadDirectory
        let folder = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw DownloadEngineError.missingDestination }
        let conflict = request.conflictPolicy
        let currentName = conflict == .rename ? Self.uniqueName(safeName, in: folder, tasks: data.tasks) : safeName
        let output = folder.appendingPathComponent(currentName)
        if conflict == .cancel && (FileManager.default.fileExists(atPath: output.path) || data.tasks.contains(where: { $0.outputURL.standardizedFileURL == output.standardizedFileURL })) {
            throw DownloadEngineError.conflict
        }
        let priorData = data
        let id = data.nextTaskID
        let account = "task-\(id)-headers"
        let sensitive = effective.credentialHeaders
        let encodedSecrets = try JSONSerialization.data(withJSONObject: sensitive, options: [.sortedKeys])
        do { try credentials.writeData(sensitive.isEmpty ? nil : encodedSecrets, account: account) }
        catch { data = priorData; throw error }
        data.nextTaskID += 1
        var headers = effective.headers
        if !effective.userAgent.isEmpty { headers["User-Agent"] = effective.userAgent }
        let safePageURL = request.pageURL.map(urlRemovingInlineCredentials)
        if let page = safePageURL { headers["Referer"] = page.absoluteString }
        let record = DownloadRecord(id: id, kind: request.kind, sourceURL: sourceURL.absoluteString,
                                     pageURL: safePageURL?.absoluteString, displayName: currentName,
                                     destinationDirectory: folder.path, status: .queued,
                                     totalBytes: request.kind == .http ? remote.contentLength : nil,
                                     etag: request.kind == .http ? remote.etag : nil,
                                     lastModified: request.kind == .http ? remote.lastModified : nil,
                                     supportsRanges: remote.supportsRanges, credentialAccount: sensitive.isEmpty ? nil : account,
                                     requestHeaders: headers, categoryID: categoryID, queueID: request.queueID,
                                     createdAt: .now, expectedChecksum: request.expectedChecksum,
                                     speedLimitBytesPerSecond: request.speedLimitBytesPerSecond, conflictPolicy: conflict,
                                     removePartialOnCancel: data.settings.deletePartialOnCancel,
                                     sourceDescription: request.sourceDescription,
                                     connectionCount: effective.connectionCount > 0 ? effective.connectionCount : nil)
        data.tasks.append(record)
        if let queueID = request.queueID, let index = data.queues.firstIndex(where: { $0.id == queueID }) {
            if !data.queues[index].taskIDs.contains(id) { data.queues[index].taskIDs.append(id) }
        }
        data.settings.lastUsedQueueID = request.queueID
        do { try Task.checkCancellation(); try beforePersist?(id); try persist() }
        catch {
            data = priorData
            try? credentials.writeData(nil, account: account)
            throw error
        }
        publishStatusTransition(from: nil, to: record)
        if request.startImmediately { startTask(id, manual: true) }
        else { pumpQueues() }
        wakeScheduler()
        return id
    }

    @discardableResult
    public func addMany(_ requests: [CreateDownloadRequest]) async -> (added: [Int64], errors: [String]) {
        var added: [Int64] = []
        var errors: [String] = []
        for (index, request) in requests.enumerated() {
            if Task.isCancelled {
                errors.append("添加已取消；剩余 \(requests.count - index) 项未处理。")
                break
            }
            do { added.append(try await add(request)) }
            catch {
                errors.append("\(redactedURLForDisplay(request.sourceURL)): \(redactSensitiveURL(in: error.localizedDescription, sourceURL: request.sourceURL))")
            }
        }
        lastActionMessage = "已添加 \(added.count) 项；失败 \(errors.count) 项。"
        return (added, errors)
    }

    public func start(_ ids: [Int64]) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        for id in ids {
            guard let index = taskIndex(id), data.tasks[index].status.canResume else { continue }
            startTask(id, manual: true)
        }
    }

    public func pause(_ ids: [Int64]) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let uniqueIDs = Set(ids)
        let queuedIDs = uniqueIDs.filter { taskIndex($0).map { data.tasks[$0].status == .queued } ?? false }
        if !queuedIDs.isEmpty {
            let previousData = data
            var transitions: [(DownloadRecord, DownloadRecord)] = []
            var affectedQueues = Set<Int64>()
            for id in queuedIDs {
                guard let index = taskIndex(id), data.tasks[index].status == .queued else { continue }
                let previous = data.tasks[index]
                data.tasks[index].status = .paused
                transitions.append((previous, data.tasks[index]))
                if let queueID = data.tasks[index].queueID { affectedQueues.insert(queueID) }
            }
            do {
                try persist()
                for (previous, current) in transitions { publishStatusTransition(from: previous, to: current) }
                affectedQueues.forEach(handleQueueDrained)
            } catch {
                data = previousData
                lastActionMessage = "无法暂停等待中的任务：状态保存失败（\(error.localizedDescription)）。"
            }
        }
        for id in ids {
            guard let index = taskIndex(id), data.tasks[index].status.isActive else { continue }
            let generation = transferGenerations[id] ?? 0
            pauseInProgress[id] = generation
            _ = nextTransferGeneration(for: id)
            let preparing = preparationWork.removeValue(forKey: id)
            preparing?.cancel()
            if let work = hlsWork.removeValue(forKey: id) { work.task.cancel() }
            if segmentedEngine.isActive(taskID: id) {
                segmentedEngine.pause(taskID: id, generation: generation)
            } else if engine.isActive(taskID: id) {
                engine.pause(taskID: id, generation: generation)
            } else if preparing != nil {
                segmentedEngine.cancel(taskID: id, generation: generation, deletePartial: false)
                engine.cancel(taskID: id, generation: generation)
                finishPause(id, generation: generation, resumeData: nil)
            } else {
                finishPause(id, generation: generation, resumeData: nil)
            }
        }
    }

    public func cancel(_ ids: [Int64], deletePartial: Bool? = nil) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let validIDs = Set(ids.filter { id in
            guard let record = task(id) else { return false }
            return record.status != .completed && record.status != .cancelled
        })
        guard !validIDs.isEmpty else { return }
        let previousData = data
        let previousRecords = Dictionary(uniqueKeysWithValues: validIDs.compactMap { id in task(id).map { (id, $0) } })
        let affectedQueues = Set(validIDs.compactMap { task($0)?.queueID })
        let removePartial = deletePartial ?? data.settings.deletePartialOnCancel
        for id in validIDs {
            guard let index = taskIndex(id) else { continue }
            data.tasks[index].status = .cancelled
            data.tasks[index].lastError = nil
            if removePartial {
                data.tasks[index].resumeDataName = nil
                data.tasks[index].receivedBytes = 0
            } else if let liveReceived = liveState.receivedBytes[id] {
                data.tasks[index].receivedBytes = max(data.tasks[index].receivedBytes, liveReceived)
                if let liveTotal = liveState.totalBytes[id] { data.tasks[index].totalBytes = liveTotal }
            }
        }
        do { try persist() }
        catch {
            data = previousData
            lastActionMessage = "无法取消任务：状态保存失败（\(error.localizedDescription)）。"
            return
        }
        for id in validIDs {
            guard let previous = previousRecords[id] else { continue }
            let generation = transferGenerations[id] ?? 0
            invalidateTransferGeneration(for: id)
            pauseInProgress.removeValue(forKey: id)
            preparationWork.removeValue(forKey: id)?.cancel()
            if let work = hlsWork.removeValue(forKey: id) { work.task.cancel() }
            segmentedEngine.cancel(taskID: id, generation: generation, deletePartial: removePartial)
            engine.cancel(taskID: id, generation: generation)
            clearLiveTransferState(for: id, resetDuration: removePartial)
            if removePartial {
                schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: true)
            }
            if let current = task(id) { publishStatusTransition(from: previous, to: current) }
        }
        affectedQueues.forEach(handleQueueDrained)
        updateSleepAssertion()
        pumpQueues()
        wakeScheduler()
    }

    public func resume(_ ids: [Int64]) { start(ids) }

    public func redownload(_ ids: [Int64]) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let validIDs = Set(ids.filter { taskIndex($0) != nil })
        guard !validIDs.isEmpty else { return }
        let previousData = data
        let previousRecords = Dictionary(uniqueKeysWithValues: validIDs.compactMap { id in task(id).map { (id, $0) } })
        for id in validIDs {
            guard let index = taskIndex(id) else { continue }
            data.tasks[index].resumeDataName = nil
            data.tasks[index].receivedBytes = 0
            data.tasks[index].totalBytes = nil
            data.tasks[index].etag = nil
            data.tasks[index].lastModified = nil
            data.tasks[index].actualChecksum = nil
            data.tasks[index].completedAt = nil
            data.tasks[index].status = .queued
            data.tasks[index].lastError = nil
        }
        do { try persist() }
        catch {
            data = previousData
            lastActionMessage = "无法重新下载：状态保存失败（\(error.localizedDescription)）。"
            return
        }
        for id in validIDs {
            guard let previous = previousRecords[id] else { continue }
            let generation = transferGenerations[id] ?? 0
            invalidateTransferGeneration(for: id)
            pauseInProgress.removeValue(forKey: id)
            preparationWork.removeValue(forKey: id)?.cancel()
            if let work = hlsWork.removeValue(forKey: id) { work.task.cancel() }
            segmentedEngine.cancel(taskID: id, generation: generation, deletePartial: true)
            engine.cancel(taskID: id, generation: generation)
            clearLiveTransferState(for: id, resetDuration: true)
            if previous.kind == .hls {
                pendingHLSReset.insert(id)
                schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: false)
            } else {
                schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: true)
            }
            if let current = task(id) { publishStatusTransition(from: previous, to: current) }
        }
        start(Array(validIDs))
    }

    public func remove(_ ids: [Int64], removeCompletedFiles: Bool) -> [String] {
        guard startupError == nil else { return ["数据无法读取，当前为只读恢复模式。"] }
        var errors: [String] = []
        let validIDs = Set(ids.filter { taskIndex($0) != nil })
        guard !validIDs.isEmpty else { return errors }
        let previousData = data
        let previousRecords = Dictionary(uniqueKeysWithValues: validIDs.compactMap { id in task(id).map { (id, $0) } })
        for queueIndex in data.queues.indices {
            data.queues[queueIndex].taskIDs.removeAll { validIDs.contains($0) }
        }
        data.tasks.removeAll { validIDs.contains($0.id) }
        do { try persist() }
        catch {
            data = previousData
            return ["无法删除任务记录：状态保存失败（\(error.localizedDescription)）。"]
        }
        for id in validIDs {
            guard let task = previousRecords[id] else { continue }
            let generation = transferGenerations[id] ?? 0
            invalidateTransferGeneration(for: id)
            pauseInProgress.removeValue(forKey: id)
            preparationWork.removeValue(forKey: id)?.cancel()
            if let work = hlsWork.removeValue(forKey: id) { work.task.cancel() }
            segmentedEngine.cancel(taskID: id, generation: generation, deletePartial: true)
            engine.cancel(taskID: id, generation: generation)
            schedulePartialCleanup(id: id, resumeDataName: task.resumeDataName, removeHLS: true)
            Task { await HLSService.clearStoredState(taskID: id) }
            if let account = task.credentialAccount { try? credentials.writeData(nil, account: account) }
            if task.status == .completed && removeCompletedFiles {
                do {
                    do {
                        try FileManager.default.trashItem(at: task.outputURL, resultingItemURL: nil)
                    } catch {
                        try FileManager.default.removeItem(at: task.outputURL)
                    }
                }
                catch { errors.append("\(task.displayName): \(error.localizedDescription)") }
            }
            clearLiveTransferState(for: id, resetDuration: true)
            pendingHLSReset.remove(id)
        }
        liveState.prune(keeping: Set(data.tasks.map(\.id)))
        selectedTaskIDs.subtract(validIDs)
        updateSleepAssertion()
        pumpQueues()
        wakeScheduler()
        return errors
    }

    public func clearCompletedTasks() -> [String] {
        let completedIDs = data.tasks.filter { $0.status == .completed }.map(\.id)
        return remove(completedIDs, removeCompletedFiles: false)
    }

    public func editTask(_ id: Int64, name: String, sourceURL: URL, pageURL: URL?, headers: [String: String],
                         destination: URL, speedLimitBytesPerSecond: Int64, connectionCount: Int?,
                         clearStoredCredentials: Bool = false) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let index = taskIndex(id) else { throw ValidationError("找不到任务。") }
        guard !data.tasks[index].status.isActive else { throw ValidationError("请先暂停任务后编辑。") }
        guard data.tasks[index].status != .completed else { throw ValidationError("已完成任务不能改写来源或目标。") }
        var editableHeaders = headers.filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
        let safeSourceURL = try urlWithoutInlineCredentials(sourceURL, moveCredentialsTo: &editableHeaders)
        guard NetworkConfiguration.validate(safeSourceURL) else { throw DownloadEngineError.invalidURL }
        let safeName = try Self.sanitizeFileName(name)
        guard FileManager.default.fileExists(atPath: destination.path), FileManager.default.isWritableFile(atPath: destination.path) else { throw DownloadEngineError.missingDestination }
        let previous = data.tasks[index]
        let account = previous.credentialAccount ?? "task-\(id)-headers"
        let oldStoredSecret = try credentials.readData(account: account)
        let previousSecrets = clearStoredCredentials ? [:] : try readTaskSecrets(previous)
        let mergedHeaders = previousSecrets.merging(editableHeaders) { _, explicit in explicit }
        let effective = try prepareEffectiveRequest(url: safeSourceURL, headers: mergedHeaders, settings: data.settings,
                                                    taskLimit: speedLimitBytesPerSecond,
                                                    taskConnectionCount: connectionCount)
        let secretJSON = try JSONSerialization.data(withJSONObject: effective.credentialHeaders, options: [.sortedKeys])
        try credentials.writeData(effective.credentialHeaders.isEmpty ? nil : secretJSON, account: account)
        var updated = previous
        updated.sourceURL = safeSourceURL.absoluteString
        updated.pageURL = pageURL.map(urlRemovingInlineCredentials)?.absoluteString
        updated.displayName = safeName
        updated.destinationDirectory = destination.standardizedFileURL.path
        updated.speedLimitBytesPerSecond = max(0, speedLimitBytesPerSecond)
        updated.connectionCount = connectionCount ?? (effective.connectionCount > 0 ? effective.connectionCount : nil)
        updated.requestHeaders = effective.headers
        updated.credentialAccount = effective.credentialHeaders.isEmpty ? nil : account
        updated.totalBytes = nil
        updated.receivedBytes = 0
        updated.etag = nil
        updated.lastModified = nil
        updated.supportsRanges = nil
        updated.resumeDataName = nil
        updated.retryCount = 0
        updated.completedAt = nil
        updated.actualChecksum = nil
        updated.status = .queued
        updated.lastError = nil
        data.tasks[index] = updated
        do { try persist() }
        catch {
            data.tasks[index] = previous
            try? credentials.writeData(oldStoredSecret, account: account)
            throw error
        }
        publishStatusTransition(from: previous, to: updated)
        let generation = transferGenerations[id] ?? 0
        invalidateTransferGeneration(for: id)
        pauseInProgress.removeValue(forKey: id)
        preparationWork.removeValue(forKey: id)?.cancel()
        if let work = hlsWork.removeValue(forKey: id) { work.task.cancel() }
        segmentedEngine.cancel(taskID: id, generation: generation, deletePartial: true)
        engine.cancel(taskID: id, generation: generation)
        clearLiveTransferState(for: id, resetDuration: true)
        pendingHLSReset.remove(id)
        schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: true)
        pumpQueues()
    }

    public func updateTaskTransferSettings(_ id: Int64, speedLimitBytesPerSecond: Int64, connectionCount: Int?) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard speedLimitBytesPerSecond >= 0, connectionCount.map({ (0...256).contains($0) }) ?? true else {
            throw ValidationError("限速必须为非负值，连接数必须为 0 到 256。")
        }
        guard let index = taskIndex(id), data.tasks[index].status != .completed else {
            throw ValidationError("找不到可编辑的未完成任务。")
        }
        let previous = data.tasks[index]
        data.tasks[index].speedLimitBytesPerSecond = speedLimitBytesPerSecond
        data.tasks[index].connectionCount = connectionCount.flatMap { $0 > 0 ? $0 : nil }
        do { try persist() }
        catch { data.tasks[index] = previous; throw error }
        reconfigureActiveNetworkTransfers()
    }

    public func updateTaskPresentation(_ id: Int64, showProgressWindow: Bool?, showCompletionWindow: Bool?,
                                       completionAction: CompletionAction) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let index = taskIndex(id) else { throw ValidationError("找不到任务。") }
        let previous = data.tasks[index]
        data.tasks[index].showProgressWindow = showProgressWindow
        data.tasks[index].showCompletionWindow = showCompletionWindow
        data.tasks[index].completionAction = completionAction
        do { try persist() }
        catch { data.tasks[index] = previous; throw error }
    }

    public func updateSettings(_ transform: (inout AppSettings) -> Void) {
        guard startupError == nil else { lastActionMessage = "数据文件无法读取，设置暂未保存。"; return }
        let previousSettings = data.settings
        let previousCategories = data.categories
        var nextSettings = previousSettings
        var nextCategories = previousCategories
        transform(&nextSettings)
        nextSettings.defaultDownloadDirectory = URL(fileURLWithPath: nextSettings.defaultDownloadDirectory,
            isDirectory: true).standardizedFileURL.path
        nextSettings.proxyHost = nextSettings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        nextSettings.dohURL = nextSettings.dohURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDefaultDirectory = URL(fileURLWithPath: previousSettings.defaultDownloadDirectory, isDirectory: true).standardizedFileURL
        let newDefaultDirectory = URL(fileURLWithPath: nextSettings.defaultDownloadDirectory, isDirectory: true).standardizedFileURL
        if oldDefaultDirectory != newDefaultDirectory {
            for index in nextCategories.indices {
                let category = nextCategories[index]
                let followsDefault = URL(fileURLWithPath: oldDefaultDirectory.path, isDirectory: true)
                    .appendingPathComponent(category.name, isDirectory: true).standardizedFileURL.path
                if category.destinationDirectory == followsDefault {
                    nextCategories[index].destinationDirectory = newDefaultDirectory
                        .appendingPathComponent(category.name, isDirectory: true).standardizedFileURL.path
                }
            }
        }
        if nextSettings.apiPort < 1024 || nextSettings.apiPort > 65535 { nextSettings.apiPort = ProductIdentity.defaultPort }
        if nextSettings.extensionSettings.apiPort < 1024 || nextSettings.extensionSettings.apiPort > 65535 {
            nextSettings.extensionSettings.apiPort = ProductIdentity.defaultPort
        }
        if nextSettings.maximumRetries < 0 { nextSettings.maximumRetries = 0 }
        nextSettings.maxManualDownloads = min(32, max(1, nextSettings.maxManualDownloads))
        nextSettings.maximumRetries = min(10, nextSettings.maximumRetries)
        nextSettings.retryDelaySeconds = min(120, max(1, nextSettings.retryDelaySeconds))
        nextSettings.defaultConnectionCount = max(1, min(nextSettings.defaultConnectionCount, 256))
        nextSettings.proxyPort = min(65_535, max(nextSettings.proxyMode == .manual ? 1 : 0, nextSettings.proxyPort))
        let supportedScales = [80, 90, 100, 110, 125, 150, 175, 200]
        if !supportedScales.contains(nextSettings.scalePercent) {
            nextSettings.scalePercent = supportedScales.min(by: { abs($0 - nextSettings.scalePercent) < abs($1 - nextSettings.scalePercent) }) ?? 100
        }
        nextSettings.minimumSegmentSizeBytes = max(1_024, min(nextSettings.minimumSegmentSizeBytes, 2 * 1_024 * 1_024 * 1_024))
        nextSettings.globalSpeedLimitBytesPerSecond = max(0, nextSettings.globalSpeedLimitBytesPerSecond)
        guard nextSettings != previousSettings || nextCategories != previousCategories else { return }

        let dnsChanged = nextSettings.dnsMode != previousSettings.dnsMode || nextSettings.dohURL != previousSettings.dohURL
        let oldGlobalLimit = globalSpeedLimit(for: previousSettings, backgroundInteraction: backgroundInteractionActive)
        let newGlobalLimit = globalSpeedLimit(for: nextSettings, backgroundInteraction: backgroundInteractionActive)
        let activeNetworkPolicyChanged = dnsChanged ||
            nextSettings.proxyMode != previousSettings.proxyMode || nextSettings.proxyScheme != previousSettings.proxyScheme ||
            nextSettings.proxyHost != previousSettings.proxyHost || nextSettings.proxyPort != previousSettings.proxyPort ||
            nextSettings.proxyUsername != previousSettings.proxyUsername || nextSettings.proxyPasswordAccount != previousSettings.proxyPasswordAccount ||
            nextSettings.proxyBypass != previousSettings.proxyBypass || nextSettings.pacURL != previousSettings.pacURL ||
            nextSettings.allowInvalidTLSCertificates != previousSettings.allowInvalidTLSCertificates ||
            nextSettings.userAgent != previousSettings.userAgent || nextSettings.hostRules != previousSettings.hostRules ||
            nextSettings.defaultConnectionCount != previousSettings.defaultConnectionCount ||
            nextSettings.minimumSegmentSizeBytes != previousSettings.minimumSegmentSizeBytes ||
            nextSettings.dynamicSegmentation != previousSettings.dynamicSegmentation
        let globalLimitChanged = oldGlobalLimit != newGlobalLimit
        let sleepPolicyChanged = nextSettings.preventSleepDuringTransfers != previousSettings.preventSleepDuringTransfers
        let globalModeChanged = nextSettings.globalSpeedLimitMode != previousSettings.globalSpeedLimitMode
        let integrationSettingsChanged = nextSettings.apiEnabled != previousSettings.apiEnabled ||
            nextSettings.apiPort != previousSettings.apiPort || nextSettings.apiRequiresKey != previousSettings.apiRequiresKey ||
            nextSettings.apiKeyAccount != previousSettings.apiKeyAccount

        data.settings = nextSettings
        data.categories = nextCategories
        do { try persist() }
        catch {
            data.settings = previousSettings
            data.categories = previousCategories
            lastActionMessage = "设置未保存：\(error.localizedDescription)"
            return
        }
        if dnsChanged, let dnsError = ProcessDNSResolver.apply(mode: nextSettings.dnsMode, dohURL: nextSettings.dohURL) {
            lastActionMessage = dnsError
        }
        if globalLimitChanged { Task { await SharedGlobalRateLimiter.shared.resetGlobalReservation() } }
        if activeNetworkPolicyChanged || globalLimitChanged { reconfigureActiveNetworkTransfers() }
        if sleepPolicyChanged { updateSleepAssertion() }
        if globalModeChanged { onGlobalSpeedLimitModeChanged?(nextSettings.globalSpeedLimitMode) }
        if integrationSettingsChanged { onIntegrationSettingsChanged?(nextSettings) }
        if nextSettings.maxManualDownloads > previousSettings.maxManualDownloads { pumpQueues() }
        if nextSettings.trackDeletedFiles != previousSettings.trackDeletedFiles { wakeScheduler() }
    }

    private var effectiveGlobalSpeedLimit: Int64 {
        globalSpeedLimit(for: data.settings, backgroundInteraction: backgroundInteractionActive)
    }

    private func globalSpeedLimit(for settings: AppSettings, backgroundInteraction: Bool) -> Int64 {
        switch settings.globalSpeedLimitMode {
        case .off: 0
        case .always: settings.globalSpeedLimitBytesPerSecond
        case .backgroundInteraction: backgroundInteraction ? settings.globalSpeedLimitBytesPerSecond : 0
        }
    }

    private var effectiveNetworkSettings: AppSettings {
        var settings = data.settings
        settings.globalSpeedLimitBytesPerSecond = effectiveGlobalSpeedLimit
        return settings
    }

    private func reconfigureActiveNetworkTransfers() {
        let networkSettings = effectiveNetworkSettings
        for record in data.tasks where record.status == .downloading {
            engine.updateGlobalRateLimit(taskID: record.id, limit: effectiveGlobalSpeedLimit)
            let rule = URL(string: record.sourceURL).flatMap {
                NetworkConfiguration.matchingHostRule(for: $0, settings: networkSettings)
            }
            engine.updateRateLimits(taskID: record.id, taskLimit: record.speedLimitBytesPerSecond,
                                    globalLimit: effectiveGlobalSpeedLimit, hostRule: rule)
            guard segmentedEngine.isActive(taskID: record.id) || hlsPolicies[record.id] != nil else { continue }
            let effectiveLimit = record.connectionCount ?? rule?.connectionCount ?? networkSettings.defaultConnectionCount
            let speedLimits = [record.speedLimitBytesPerSecond, networkSettings.globalSpeedLimitBytesPerSecond,
                               rule?.speedLimitBytesPerSecond ?? 0].filter { $0 > 0 }
            if segmentedEngine.isActive(taskID: record.id) {
                segmentedEngine.updateSettings(taskID: record.id, settings: networkSettings,
                                               speedLimit: speedLimits.min() ?? 0, connectionLimit: effectiveLimit)
            }
            if let policy = hlsPolicies[record.id]?.policy {
                Task { await policy.update(settings: networkSettings, maximumConnections: effectiveLimit,
                                           speedLimitBytesPerSecond: speedLimits.min() ?? 0,
                                           taskConnectionOverride: record.connectionCount != nil) }
            }
        }
    }

    public func createQueue(name: String) throws -> Int64 {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ValidationError("队列名称不能为空。") }
        guard !data.queues.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else { throw ValidationError("队列名称已存在。") }
        let previous = data
        let id = data.nextQueueID
        data.nextQueueID += 1
        data.queues.append(QueueRecord(id: id, name: normalized, concurrency: 2, order: data.queues.count))
        do { try persist() } catch { data = previous; throw error }
        return id
    }

    public func deleteQueue(_ id: Int64) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard id != 0 else { throw ValidationError("Main 队列不能删除。") }
        guard let index = data.queues.firstIndex(where: { $0.id == id }) else { return }
        let previous = data
        let tasks = data.queues[index].taskIDs
        for taskID in tasks where taskIndex(taskID) != nil {
            data.tasks[taskIndex(taskID)!].queueID = nil
        }
        data.queues.remove(at: index)
        do { try persist() } catch { data = previous; throw error }
        let active = tasks.filter { task($0)?.status.isActive == true }
        if !active.isEmpty { pause(active) }
    }

    public func updateQueue(_ id: Int64, transform: (inout QueueRecord) -> Void) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let index = data.queues.firstIndex(where: { $0.id == id }) else { throw ValidationError("找不到队列。") }
        var updated = data.queues[index]
        transform(&updated)
        let normalized = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ValidationError("队列名称不能为空。") }
        guard !data.queues.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw ValidationError("队列名称已存在。")
        }
        updated.name = normalized
        updated.concurrency = min(32, max(1, updated.concurrency))
        if updated.schedule.days.isEmpty { updated.schedule.days = Set(1...7) }
        let previous = data.queues[index]
        data.queues[index] = updated
        do { try persist() } catch { data.queues[index] = previous; throw error }
        pumpQueues()
        wakeScheduler()
    }

    public func reorderQueues(_ orderedIDs: [Int64]) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard orderedIDs.count == data.queues.count, Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(data.queues.map(\.id)) else { throw ValidationError("队列排序数据无效。") }
        let previous = data.queues
        for (order, id) in orderedIDs.enumerated() {
            guard let index = data.queues.firstIndex(where: { $0.id == id }) else { continue }
            data.queues[index].order = order
        }
        do { try persist() } catch { data.queues = previous; throw error }
    }

    public func clearQueue(_ id: Int64) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let index = data.queues.firstIndex(where: { $0.id == id }) else { return }
        let previousQueues = data.queues
        let previousTasks = data.tasks
        let members = data.queues[index].taskIDs
        data.queues[index].taskIDs.removeAll()
        for taskID in members {
            if let taskIndex = taskIndex(taskID) { data.tasks[taskIndex].queueID = nil }
        }
        do { try persist() }
        catch { data.queues = previousQueues; data.tasks = previousTasks; throw error }
    }

    public func moveTaskWithinQueue(_ taskID: Int64, queueID: Int64, offset: Int) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let queueIndex = data.queues.firstIndex(where: { $0.id == queueID }),
              let sourceIndex = data.queues[queueIndex].taskIDs.firstIndex(of: taskID) else { return }
        let destinationIndex = min(data.queues[queueIndex].taskIDs.count - 1, max(0, sourceIndex + offset))
        guard destinationIndex != sourceIndex else { return }
        let previous = data.queues[queueIndex].taskIDs
        let moved = data.queues[queueIndex].taskIDs.remove(at: sourceIndex)
        data.queues[queueIndex].taskIDs.insert(moved, at: destinationIndex)
        do { try persist() } catch { data.queues[queueIndex].taskIDs = previous; throw error }
        pumpQueues()
    }

    public func updateCategory(_ id: Int64, transform: (inout CategoryRecord) -> Void) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard let index = data.categories.firstIndex(where: { $0.id == id }) else { throw ValidationError("找不到分类。") }
        var updated = data.categories[index]
        transform(&updated)
        let normalized = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ValidationError("分类名称不能为空。")
        }
        guard !data.categories.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw ValidationError("分类名称已存在。")
        }
        updated.name = normalized
        let previous = data.categories[index]
        data.categories[index] = updated
        do { try persist() } catch { data.categories[index] = previous; throw error }
    }

    public func reorderCategories(_ orderedIDs: [Int64]) throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        guard orderedIDs.count == data.categories.count, Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(data.categories.map(\.id)) else { throw ValidationError("分类排序数据无效。") }
        let previous = data.categories
        for (order, id) in orderedIDs.enumerated() {
            guard let index = data.categories.firstIndex(where: { $0.id == id }) else { continue }
            data.categories[index].order = order
        }
        do { try persist() } catch { data.categories = previous; throw error }
    }

    public func autoCategorizeUnassigned() {
        guard startupError == nil else { return }
        let previous = data.tasks
        var changed = false
        for index in data.tasks.indices where data.tasks[index].categoryID == nil &&
            (data.tasks[index].status.isActive || data.tasks[index].status == .completed) {
            guard let url = URL(string: data.tasks[index].sourceURL) else { continue }
            let categoryID = bestMatchingCategory(url: url, fileName: data.tasks[index].displayName)?.id
            if categoryID != nil {
                data.tasks[index].categoryID = categoryID
                changed = true
            }
        }
        guard changed else { return }
        do { try persist() } catch { data.tasks = previous; lastActionMessage = "自动分类未保存：\(error.localizedDescription)" }
    }

    public func restoreDefaultCategories() throws {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        let previous = data
        let base = data.nextCategoryID
        let defaults = AppData.defaultCategories(root: data.settings.defaultDownloadDirectory).enumerated().map { offset, item in
            CategoryRecord(id: base + Int64(offset), name: item.name, symbol: item.symbol,
                           extensions: item.extensions, destinationDirectory: item.destinationDirectory, order: offset)
        }
        data.categories = defaults
        data.nextCategoryID = base + Int64(defaults.count)
        for index in data.tasks.indices {
            guard let url = URL(string: data.tasks[index].sourceURL) else { data.tasks[index].categoryID = nil; continue }
            data.tasks[index].categoryID = Self.bestMatchingCategory(url: url, fileName: data.tasks[index].displayName, in: defaults)?.id
        }
        do { try persist() } catch { data = previous; throw error }
    }

    private func bestMatchingCategory(url: URL, fileName: String) -> CategoryRecord? {
        Self.bestMatchingCategory(url: url, fileName: fileName, in: data.categories)
    }

    private static func bestMatchingCategory(url: URL, fileName: String, in categories: [CategoryRecord]) -> CategoryRecord? {
        categories.filter { $0.matches(url: url, fileName: fileName) }.sorted { lhs, rhs in
            let lhsHasURL = !lhs.urlPatterns.isEmpty, rhsHasURL = !rhs.urlPatterns.isEmpty
            if lhsHasURL != rhsHasURL { return lhsHasURL }
            if lhs.urlPatterns.count != rhs.urlPatterns.count { return lhs.urlPatterns.count < rhs.urlPatterns.count }
            let lhsHasExtensions = !lhs.extensions.isEmpty, rhsHasExtensions = !rhs.extensions.isEmpty
            if lhsHasExtensions != rhsHasExtensions { return lhsHasExtensions }
            if lhs.extensions.count != rhs.extensions.count { return lhs.extensions.count < rhs.extensions.count }
            return lhs.order < rhs.order
        }.first
    }

    public func startQueue(_ id: Int64) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        guard let index = data.queues.firstIndex(where: { $0.id == id }) else { return }
        let previous = data.queues[index].isRunning
        completionActionsTriggered.remove(id)
        data.queues[index].isRunning = true
        do { try persist() }
        catch {
            data.queues[index].isRunning = previous
            lastActionMessage = "队列未能启动：\(error.localizedDescription)"
            return
        }
        pumpQueues()
        wakeScheduler()
    }

    public func stopQueue(_ id: Int64) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        guard let index = data.queues.firstIndex(where: { $0.id == id }) else { return }
        let previous = data.queues[index].isRunning
        data.queues[index].isRunning = false
        let ids = data.queues[index].taskIDs.filter { taskIndex($0).map { data.tasks[$0].status.isActive } ?? false }
        do { try persist() }
        catch {
            data.queues[index].isRunning = previous
            lastActionMessage = "队列未能停止：\(error.localizedDescription)"
            return
        }
        for taskID in ids { pause([taskID]) }
    }

    public func move(_ ids: [Int64], toQueue queueID: Int64?) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let previous = data
        for id in ids {
            for index in data.queues.indices { data.queues[index].taskIDs.removeAll { $0 == id } }
            if let index = taskIndex(id) { data.tasks[index].queueID = queueID }
            if let queueID, let index = data.queues.firstIndex(where: { $0.id == queueID }), !data.queues[index].taskIDs.contains(id) {
                data.queues[index].taskIDs.append(id)
            }
        }
        do { try persist() } catch { data = previous; lastActionMessage = "队列调整未保存：\(error.localizedDescription)" }
    }

    public func move(_ ids: [Int64], toCategory categoryID: Int64?) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let previous = data.tasks
        for id in ids { if let index = taskIndex(id) { data.tasks[index].categoryID = categoryID } }
        do { try persist() } catch { data.tasks = previous; lastActionMessage = "分类调整未保存：\(error.localizedDescription)" }
    }

    public func deleteCategory(_ id: Int64) {
        guard startupError == nil else { lastActionMessage = "数据无法读取，任务保持只读。"; return }
        let previousCategories = data.categories
        let previousTasks = data.tasks
        data.categories.removeAll { $0.id == id }
        for index in data.tasks.indices where data.tasks[index].categoryID == id { data.tasks[index].categoryID = nil }
        do { try persist() }
        catch {
            data.categories = previousCategories
            data.tasks = previousTasks
            lastActionMessage = "分类未能删除：\(error.localizedDescription)"
        }
    }

    public func createCategory(name: String, symbol: String, extensions: [String], patterns: [String], destination: String?) throws -> Int64 {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !data.categories.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
            throw ValidationError("分类名称不能为空且不能重复。")
        }
        let previous = data
        let id = data.nextCategoryID
        data.nextCategoryID += 1
        data.categories.append(CategoryRecord(id: id, name: clean, symbol: symbol, extensions: extensions,
                                              urlPatterns: patterns, destinationDirectory: destination, order: data.categories.count))
        do { try persist() } catch { data = previous; throw error }
        return id
    }

    public func importRequest(_ payload: [String: Any], requestID: String?, digest: String) async throws -> [Int64] {
        try await importRequestDetailed(payload, requestID: requestID, digest: digest).acceptedTaskIDs
    }

    public func importRequestDetailed(_ payload: [String: Any], requestID: String?, digest: String, deadline: Date? = nil) async throws -> ImportRequestResult {
        guard startupError == nil else { throw StateStoreError.readOnlyRecovery }
        try checkImportDeadline(deadline)
        let requestItemCount = (payload["items"] as? [[String: Any]])?.count ?? 0
        if let requestID, let existing = inFlightImportTasks[requestID] {
            guard existing.digest == digest else { throw IntegrationError.requestConflict }
            var updated = existing
            updated.waiters += 1
            inFlightImportTasks[requestID] = updated
            defer { releaseImportWaiter(requestID: requestID) }
            return try await awaitImportResult(existing.task, requestID: requestID)
        }
        if data.idempotency.contains(where: { Date.now.timeIntervalSince($0.acceptedAt) >= 600 && inFlightImportTasks[$0.requestID] == nil }) {
            let previousData = data
            data.idempotency.removeAll { Date.now.timeIntervalSince($0.acceptedAt) >= 600 && inFlightImportTasks[$0.requestID] == nil }
            do { try persist() }
            catch { data = previousData; throw error }
        }
        if let requestID, let previous = data.idempotency.first(where: { $0.requestID == requestID }) {
            guard previous.bodyDigest == digest else { throw IntegrationError.requestConflict }
            return replayResult(previous, expectedItemCount: requestItemCount)
        }
        guard activeImportRequestCount < 32 else { throw IntegrationError.unavailable }
        activeImportRequestCount += 1
        let work = Task { @MainActor in
            try await self.performImportRequestDetailed(payload, requestID: requestID, digest: digest, deadline: deadline)
        }
        if let requestID { inFlightImportTasks[requestID] = (digest, 1, work) }
        defer {
            activeImportRequestCount -= 1
            if let requestID { inFlightImportTasks.removeValue(forKey: requestID) }
        }
        return try await awaitImportResult(work, requestID: requestID)
    }

    private func checkImportDeadline(_ deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date.now >= deadline { throw CancellationError() }
    }

    public func cancelImportRequest(requestID: String) {
        inFlightImportTasks[requestID]?.task.cancel()
    }

    private func releaseImportWaiter(requestID: String) {
        guard var entry = inFlightImportTasks[requestID] else { return }
        entry.waiters = max(0, entry.waiters - 1)
        inFlightImportTasks[requestID] = entry
    }

    private func awaitImportResult(_ work: Task<ImportRequestResult, Error>, requestID: String?) async throws -> ImportRequestResult {
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { work.cancel(); return }
                if let requestID, let entry = self.inFlightImportTasks[requestID], entry.waiters > 1 {
                    return
                }
                work.cancel()
            }
        }
    }

    private func replayResult(_ record: IdempotencyRecord, expectedItemCount: Int) -> ImportRequestResult {
        let count = record.itemCount ?? expectedItemCount
        if record.itemResults == nil, record.taskIDs.count != count {
            // Legacy receipts retained IDs but no original item positions. A partial
            // receipt cannot safely authorize cancelling an indexed browser download.
            return ImportRequestResult(items: (0..<max(0, count)).map {
                ImportRequestItemResult(index: $0, error: "旧请求未保存逐项接收位置；请在 App 核对已存在任务，不会据此取消浏览器下载。")
            })
        }
        var known = record.itemResults ?? record.taskIDs.enumerated().map { index, id in
            ImportRequestItemResult(index: index, taskID: id)
        }
        known.sort { $0.index < $1.index }
        let byIndex = Dictionary(known.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let items = (0..<max(0, count)).map { index in
            byIndex[index] ?? ImportRequestItemResult(index: index,
                error: "原请求未能记录此项结果；该项未确认接收，请使用新的 requestID 重试。")
        }
        return ImportRequestResult(items: items)
    }

    private func performImportRequestDetailed(_ payload: [String: Any], requestID: String?, digest: String, deadline: Date?) async throws -> ImportRequestResult {
        let items = payload["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { throw IntegrationError.invalidRequest("items 不能为空。") }
        let options = payload["options"] as? [String: Any] ?? [:]
        let silentAdd = options["silentAdd"] as? Bool ?? false
        let silentStart = silentAdd && (options["silentStart"] as? Bool ?? false)
        let shouldStartQueue = options["startQueue"] as? Bool ?? false
        let requestedQueue = (options["queueId"] as? NSNumber)?.int64Value
        let queueID = requestedQueue ?? data.settings.lastUsedQueueID ?? 0
        guard data.queues.contains(where: { $0.id == queueID }) else { throw IntegrationError.invalidRequest("队列不存在：\(queueID)") }
        try checkImportDeadline(deadline)
        if !silentAdd {
            guard await requestImportApproval(items) else {
                try checkImportDeadline(deadline)
                throw IntegrationError.userDeclined
            }
        }
        try checkImportDeadline(deadline)

        if let requestID {
            let previousData = data
            data.idempotency.removeAll { Date.now.timeIntervalSince($0.acceptedAt) >= 600 && inFlightImportTasks[$0.requestID] == nil }
            data.idempotency.append(IdempotencyRecord(requestID: requestID, bodyDigest: digest, taskIDs: [],
                acceptedAt: .now, itemCount: items.count, itemResults: []))
            do { try persist() }
            catch { data = previousData; throw error }
        }

        var results: [ImportRequestItemResult] = []
        for (itemIndex, item) in items.enumerated() {
            if Task.isCancelled || deadline.map({ Date.now >= $0 }) == true {
                let cancelledResults = results + (itemIndex..<items.count).map {
                    ImportRequestItemResult(index: $0, error: "请求已取消或超时；此项未接收。")
                }
                if let requestID {
                    let previous = data
                    storeImportResults(cancelledResults, requestID: requestID)
                    do { try persist() }
                    catch { data = previous; throw error }
                }
                return ImportRequestResult(items: cancelledResults)
            }
            guard let link = item["link"] as? String, let url = URL(string: link), NetworkConfiguration.validate(url) else {
                try appendImportResult(ImportRequestItemResult(index: itemIndex, error: "某一项缺少有效链接。"),
                                       requestID: requestID, results: &results)
                continue
            }
            if let rawKind = item["type"] as? String, TransferKind(rawValue: rawKind) == nil {
                try appendImportResult(ImportRequestItemResult(index: itemIndex, error: "不支持的下载类型：\(rawKind)"),
                                       requestID: requestID, results: &results)
                continue
            }
            let kind = TransferKind(rawValue: item["type"] as? String ?? "http") ?? .http
            let headers = item["headers"] as? [String: String] ?? [:]
            let page = (item["downloadPage"] as? String).flatMap(URL.init(string:))
            let folder = (item["folder"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            let itemQueue = (item["queueId"] as? NSNumber)?.int64Value ?? queueID
            let itemCategory = (item["categoryId"] as? NSNumber)?.int64Value
            guard data.queues.contains(where: { $0.id == itemQueue }) else {
                try appendImportResult(ImportRequestItemResult(index: itemIndex, error: "队列不存在：\(itemQueue)"),
                                       requestID: requestID, results: &results)
                continue
            }
            if let itemCategory, !data.categories.contains(where: { $0.id == itemCategory }) {
                try appendImportResult(ImportRequestItemResult(index: itemIndex, error: "分类不存在：\(itemCategory)"),
                                       requestID: requestID, results: &results)
                continue
            }
            let start = (item["startDownload"] as? Bool) ?? silentStart
            let request = CreateDownloadRequest(kind: kind, sourceURL: url, pageURL: page,
                                                displayName: item["suggestedName"] as? String,
                                                destinationDirectory: folder, headers: headers, queueID: itemQueue,
                                                categoryID: itemCategory, startImmediately: start,
                                                sourceDescription: item["description"] as? String)
            do {
                let id = try await addPersisting(request) { [weak self] id in
                    guard let self else { throw CancellationError() }
                    try self.checkImportDeadline(deadline)
                    guard let requestID else { return }
                    let itemResult = ImportRequestItemResult(index: itemIndex, taskID: id)
                    self.storeImportResults(results + [itemResult], requestID: requestID)
                }
                results.append(ImportRequestItemResult(index: itemIndex, taskID: id))
            } catch {
                try appendImportResult(ImportRequestItemResult(index: itemIndex,
                    error: "第 \(itemIndex + 1) 项：\(redactSensitiveURL(in: error.localizedDescription, sourceURL: url))"),
                                       requestID: requestID, results: &results)
            }
        }
        if !Task.isCancelled, shouldStartQueue, results.contains(where: \.isAccepted) { startQueue(queueID) }
        let errors = results.compactMap(\.error)
        if !errors.isEmpty {
            lastActionMessage = "已接受 \(results.filter(\.isAccepted).count) 项，\(errors.count) 项需修正。\n" + errors.joined(separator: "\n")
        }
        return ImportRequestResult(items: results.sorted { $0.index < $1.index })
    }

    private func storeImportResults(_ results: [ImportRequestItemResult], requestID: String) {
        guard let index = data.idempotency.firstIndex(where: { $0.requestID == requestID }) else { return }
        data.idempotency[index].itemResults = results
        data.idempotency[index].taskIDs = results.compactMap(\.taskID)
        data.idempotency[index].acceptedAt = .now
    }

    private func appendImportResult(_ result: ImportRequestItemResult, requestID: String?,
                                    results: inout [ImportRequestItemResult]) throws {
        let next = results + [result]
        guard let requestID else { results = next; return }
        let previousData = data
        storeImportResults(next, requestID: requestID)
        do { try persist(); results = next }
        catch { data = previousData; throw error }
    }

    private func requestImportApproval(_ items: [[String: Any]]) async -> Bool {
        let reviewID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let visibleItems = items.prefix(10).enumerated().compactMap { index, item -> ImportReviewItem? in
                    guard let raw = item["link"] as? String, let url = URL(string: raw) else { return nil }
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.user = nil; components?.password = nil; components?.query = nil; components?.fragment = nil
                    let source = components?.string ?? "HTTP(S) 地址"
                    let title = (item["suggestedName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? url.host ?? "下载项 \(index + 1)"
                    return ImportReviewItem(index: index, title: title, source: source)
                }
                let review = PendingImportReview(id: reviewID, items: visibleItems, totalCount: items.count)
                importReviewQueue.append((review, continuation))
                if pendingImportReview == nil { pendingImportReview = review }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelImportReview(reviewID) }
        }
    }

    private func cancelImportReview(_ id: UUID) {
        guard let index = importReviewQueue.firstIndex(where: { $0.review.id == id }) else { return }
        let removed = importReviewQueue.remove(at: index)
        pendingImportReview = importReviewQueue.first?.review
        removed.continuation.resume(returning: false)
    }

    public func resolveImportReview(_ id: UUID, accepted: Bool) {
        guard let first = importReviewQueue.first, first.review.id == id else { return }
        importReviewQueue.removeFirst()
        pendingImportReview = importReviewQueue.first?.review
        first.continuation.resume(returning: accepted)
    }

    private func rejectPendingImportReviews() {
        let waiting = importReviewQueue
        importReviewQueue.removeAll()
        pendingImportReview = nil
        for item in waiting { item.continuation.resume(returning: false) }
    }

    public func task(_ id: Int64) -> DownloadRecord? {
        guard var record = data.tasks.first(where: { $0.id == id }) else { return nil }
        if let liveReceived = liveState.receivedBytes[id] { record.receivedBytes = liveReceived }
        if let liveTotal = liveState.totalBytes[id] { record.totalBytes = liveTotal }
        return record
    }

    public func queueList() -> [[String: Any]] { data.queues.sorted { $0.order < $1.order }.map { ["id": $0.id, "name": $0.name] } }

    public func stopAll() {
        for queueID in data.queues.filter(\.isRunning).map(\.id) { stopQueue(queueID) }
        let pauseTargets = data.tasks.filter {
            $0.status.isActive || ($0.status == .queued && $0.queueID == nil)
        }.map(\.id)
        pause(pauseTargets)
    }

    public func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        guard startupError == nil else { completion(true); return }
        schedulerTask?.cancel()
        schedulerTask = nil
        schedulerWakeContinuation?.resume()
        schedulerWakeContinuation = nil
        rejectPendingImportReviews()
        stopAll()
        Task { @MainActor [weak self] in
            guard let self else { completion(false); return }
            let deadline = Date.now.addingTimeInterval(30)
            while self.hasOutstandingTransfers {
                guard Date.now < deadline else { completion(false); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.store.cancelPendingBackgroundSaves()
            self.syncLiveBytesIntoData()
            do { try self.persist(); completion(true) }
            catch { self.lastActionMessage = "退出前保存失败：\(error.localizedDescription)"; completion(false) }
        }
    }

    public func taskCount(for status: DownloadStatus) -> Int { data.tasks.filter { $0.status == status }.count }

    private func wireComponents() {
        engine.onProgress = { [weak self] id, generation, received, total in
            self?.updateProgress(id, generation: generation, received: received, total: total)
        }
        engine.onFinished = { [weak self] id, generation, staged, response in
            self?.completeTransfer(id, generation: generation, staged: staged, response: response)
        }
        engine.onFailed = { [weak self] id, generation, message in
            self?.transferFailed(id, generation: generation, message: message)
        }
        engine.onPaused = { [weak self] id, generation, resume in
            self?.transferPaused(id, generation: generation, resumeData: resume)
        }
        segmentedEngine.onProgress = { [weak self] id, generation, received, total in
            self?.updateProgress(id, generation: generation, received: received, total: total)
        }
        segmentedEngine.onFinished = { [weak self] id, generation, staged in
            self?.completeTransfer(id, generation: generation, staged: staged, response: nil)
        }
        segmentedEngine.onFailed = { [weak self] id, generation, message in
            self?.transferFailed(id, generation: generation, message: message)
        }
        segmentedEngine.onPaused = { [weak self] id, generation, committedBytes in
            self?.transferPaused(id, generation: generation, resumeData: nil, committedBytes: committedBytes)
        }
        segmentedEngine.onRangeUnsupported = { [weak self] id, generation in
            self?.fallbackToSingleConnection(id, generation: generation)
        }
        queueScheduler.onStartQueue = { [weak self] id in self?.startQueue(id) }
        queueScheduler.onStopQueue = { [weak self] id in self?.stopQueue(id) }
    }

    private func recoverInterruptedTasks() {
        guard !store.isReadOnlyRecovery else { return }
        let previousData = data
        var changed = false
        for index in data.tasks.indices where data.tasks[index].status.isActive ||
            (data.tasks[index].status == .queued && data.tasks[index].queueID == nil) {
            let previousStatus = data.tasks[index].status
            let wasActive = previousStatus.isActive
            data.tasks[index].status = .paused
            if wasActive {
                data.tasks[index].lastError = "应用上次退出时任务仍在传输。请恢复任务；来源校验后才会继续。"
                if data.tasks[index].kind == .http {
                    if let committed = segmentedEngine.committedBytes(for: data.tasks[index]) {
                        data.tasks[index].receivedBytes = committed
                    } else {
                        let validResumeOnDisk: Bool = {
                            guard previousStatus == .preparing,
                                  let name = data.tasks[index].resumeDataName,
                                  !name.contains("/"), !name.contains("..") else { return false }
                            return FileManager.default.fileExists(atPath: store.resumeDataURL(for: name).path)
                        }()
                        if !validResumeOnDisk {
                            if let staleResume = data.tasks[index].resumeDataName {
                                schedulePartialCleanup(id: data.tasks[index].id, resumeDataName: staleResume, removeHLS: false)
                            }
                            data.tasks[index].resumeDataName = nil
                            data.tasks[index].receivedBytes = 0
                        }
                    }
                }
            }
            changed = true
        }
        for index in data.queues.indices where data.queues[index].isRunning {
            data.queues[index].isRunning = false
            changed = true
        }
        guard changed else { return }
        do { try persist() }
        catch {
            data = previousData
            startupError = "上次运行任务的恢复状态未能保存：\(error.localizedDescription)。为避免覆盖原数据，当前保持只读。"
            return
        }
        for task in previousData.tasks {
            guard let current = data.tasks.first(where: { $0.id == task.id }) else { continue }
            publishStatusTransition(from: task, to: current)
        }
    }

    private func startScheduler() {
        guard startupError == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.nextSchedulerInterval()
                if let delay {
                    await self.waitForSchedulerOrWake(seconds: delay)
                } else {
                    await self.waitUntilSchedulerWoken()
                }
                guard !Task.isCancelled else { return }
                if self.hasActiveTransfersForMetrics {
                    self.liveState.decayStaleSpeeds(now: .now, threshold: 3.0)
                }
                if self.hasScheduledQueues {
                    self.queueScheduler.tick(queues: self.data.queues)
                }
                if self.hasPendingQueuedWork {
                    self.pumpQueues()
                }
                if self.data.settings.trackDeletedFiles &&
                    self.data.tasks.contains(where: { $0.status == .completed }) &&
                    Date.now.timeIntervalSince(self.lastDiskAudit) >= 30 {
                    self.auditCompletedFiles()
                }
            }
        }
    }

    private var hasScheduledQueues: Bool {
        data.queues.contains { $0.schedule.startEnabled || $0.schedule.stopEnabled }
    }

    private var hasActiveTransfersForMetrics: Bool {
        data.tasks.contains(where: \.status.isActive) || !liveState.metrics.isEmpty
    }

    private var hasPendingQueuedWork: Bool {
        let hasManualQueued = data.tasks.contains { $0.queueID == nil && $0.status == .queued }
        let hasRunningQueue = data.queues.contains(where: \.isRunning)
        return hasManualQueued || hasRunningQueue
    }

    private func nextSchedulerInterval() -> TimeInterval? {
        var interval: TimeInterval?
        if hasActiveTransfersForMetrics {
            interval = min(interval ?? .infinity, 2.0)
        }
        if hasScheduledQueues {
            let second = Calendar.current.component(.second, from: .now)
            let toNextMinute = max(1.0, Double(60 - second))
            interval = min(interval ?? .infinity, min(15.0, toNextMinute))
        }
        if data.settings.trackDeletedFiles && data.tasks.contains(where: { $0.status == .completed }) {
            let remaining = max(1.0, 30.0 - Date.now.timeIntervalSince(lastDiskAudit))
            interval = min(interval ?? .infinity, remaining)
        }
        return interval
    }

    private func waitUntilSchedulerWoken() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else { continuation.resume(); return }
                schedulerWakeContinuation?.resume()
                schedulerWakeContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.schedulerWakeContinuation?.resume()
                self?.schedulerWakeContinuation = nil
            }
        }
    }

    private func waitForSchedulerOrWake(seconds: TimeInterval) async {
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(max(0.25, seconds)))
                await MainActor.run { [weak self] in
                    self?.wakeScheduler()
                }
            } catch {}
        }
        await waitUntilSchedulerWoken()
        timer.cancel()
    }

    private func wakeScheduler() {
        schedulerWakeContinuation?.resume()
        schedulerWakeContinuation = nil
    }

    private func auditCompletedFiles() {
        guard startupError == nil, data.settings.trackDeletedFiles, fileAuditWork == nil else { return }
        lastDiskAudit = .now
        let candidates = data.tasks.filter { $0.status == .completed }.map {
            FileAuditCandidate(taskID: $0.id, outputURL: $0.outputURL)
        }
        fileAuditWork = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                candidates.map { candidate in
                    FileAuditResult(taskID: candidate.taskID, outputURL: candidate.outputURL,
                                    exists: FileManager.default.fileExists(atPath: candidate.outputURL.path))
                }
            }.value
            guard let self else { return }
            self.fileAuditWork = nil
            guard self.startupError == nil, self.data.settings.trackDeletedFiles else { return }
            let previousTasks = self.data.tasks
            var changed = false
            for result in results {
                guard let index = self.taskIndex(result.taskID), self.data.tasks[index].status == .completed,
                      self.data.tasks[index].outputURL.standardizedFileURL == result.outputURL.standardizedFileURL else { continue }
                if !result.exists && self.data.tasks[index].lastError == nil {
                    self.data.tasks[index].lastError = "跟踪发现完成文件已移动或删除。记录仍保留；文件不会自动恢复。"
                    changed = true
                } else if result.exists && self.data.tasks[index].lastError?.hasPrefix("跟踪发现完成文件") == true {
                    self.data.tasks[index].lastError = nil
                    changed = true
                }
            }
            guard changed else { return }
            do { try self.persist() }
            catch {
                self.data.tasks = previousTasks
                self.lastActionMessage = "完成文件状态未能保存：\(error.localizedDescription)"
            }
        }
    }

    private func pumpQueues() {
        let activeManualCount = data.tasks.filter { $0.queueID == nil && $0.status.isActive }.count
        let availableManual = max(0, max(1, data.settings.maxManualDownloads) - activeManualCount)
        if availableManual > 0 {
            let manualCandidates = data.tasks.filter { $0.queueID == nil && $0.status == .queued }.map(\.id)
            for id in manualCandidates.prefix(availableManual) { startTask(id, manual: false) }
        }
        for queueIndex in data.queues.indices where data.queues[queueIndex].isRunning {
            let queue = data.queues[queueIndex]
            let activeCount = queue.taskIDs.filter { id in task(id)?.status.isActive == true }.count
            let available = max(0, queue.concurrency - activeCount)
            guard available > 0 else { continue }
            let candidates = queue.taskIDs.compactMap { id -> Int64? in
                guard let task = task(id), task.status == .queued else { return nil }
                return id
            }
            for id in candidates.prefix(available) { startTask(id, manual: false) }
        }
    }

    private func startTask(_ id: Int64, manual: Bool) {
        guard startupError == nil, let index = taskIndex(id) else { return }
        guard data.tasks[index].status.canResume else { return }
        let previousData = data
        let previous = data.tasks[index]
        var record = data.tasks[index]
        if manual {
            if record.queueID != nil {
                record.queueID = nil
                for queueIndex in data.queues.indices { data.queues[queueIndex].taskIDs.removeAll { $0 == id } }
            }
            let activeManualCount = data.tasks.filter { $0.id != id && $0.queueID == nil && $0.status.isActive }.count
            if activeManualCount >= max(1, data.settings.maxManualDownloads) {
                record.status = .queued
                record.lastError = nil
                if data.tasks[index] != record || data.queues != previousData.queues {
                    data.tasks[index] = record
                    do { try persist() }
                    catch {
                        data = previousData
                        lastActionMessage = "无法排队任务：状态保存失败（\(error.localizedDescription)）。"
                        return
                    }
                    publishStatusTransition(from: previous, to: record)
                }
                return
            }
        }
        let previousGeneration = transferGenerations[id]
        let generation = nextTransferGeneration(for: id)
        pauseInProgress.removeValue(forKey: id)
        clearLiveTransferState(for: id, resetDuration: false)
        activeSessionStartedAt[id] = .now
        record.status = .preparing
        record.lastError = nil
        record.startedAt = record.startedAt ?? .now
        var discardLegacyResume = false
        if record.importedFromLegacy && record.receivedBytes > 0 {
            record.receivedBytes = 0
            discardLegacyResume = record.resumeDataName != nil
            record.resumeDataName = nil
            record.legacyRecoveryNote = "旧项目部分文件保留在原路径；为避免混合不同实现的分片，本任务将从头取得内容。"
        }
        data.tasks[index] = record
        do { try persist() }
        catch {
            data = previousData
            lastActionMessage = "无法启动任务：状态保存失败（\(error.localizedDescription)）。"
            return
        }
        publishStatusTransition(from: previous, to: record)
        updateSleepAssertion()
        wakeScheduler()
        if let previousGeneration {
            preparationWork.removeValue(forKey: id)?.cancel()
            if let oldHLS = hlsWork.removeValue(forKey: id), oldHLS.generation == previousGeneration { oldHLS.task.cancel() }
            segmentedEngine.cancel(taskID: id, generation: previousGeneration, deletePartial: discardLegacyResume)
            engine.cancel(taskID: id, generation: previousGeneration)
        }
        if discardLegacyResume {
            if previousGeneration == nil {
                segmentedEngine.cancel(taskID: id, generation: 0, deletePartial: true)
            }
            schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: record.kind == .hls)
        }
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentGeneration(generation, for: id) { self.preparationWork.removeValue(forKey: id) }
            }
            do {
                let secrets = try self.readTaskSecrets(record)
                guard let sourceURL = URL(string: record.sourceURL), NetworkConfiguration.validate(sourceURL) else {
                    throw DownloadEngineError.invalidURL
                }
                var engineSettings = self.effectiveNetworkSettings
                let effective = try self.prepareEffectiveRequest(url: sourceURL,
                    headers: record.requestHeaders.merging(secrets) { _, new in new }, settings: engineSettings,
                    taskLimit: record.speedLimitBytesPerSecond, taskConnectionCount: record.connectionCount)
                if effective.connectionCount > 0 { engineSettings.defaultConnectionCount = effective.connectionCount }
                let resumeURL: URL?
                if let name = record.resumeDataName, !name.contains("/"), !name.contains("..") {
                    resumeURL = self.store.resumeDataURL(for: name)
                } else {
                    resumeURL = nil
                }
                var resume: Data?
                if let resumeURL {
                    resume = await Task.detached(priority: .utility) { try? Data(contentsOf: resumeURL) }.value
                    guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id),
                          let currentIndex = self.taskIndex(id) else { return }
                    record = self.data.tasks[currentIndex]
                }
                if record.kind == .http, record.receivedBytes > 0 {
                    let info = try await self.engine.probe(sourceURL,
                        headers: effective.headers.merging(effective.credentialHeaders) { _, new in new },
                        userAgent: effective.userAgent, settings: engineSettings,
                        proxyPassword: try self.credentials.read(account: engineSettings.proxyPasswordAccount) ?? "")
                    guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id),
                          let currentIndex = self.taskIndex(id) else { return }
                    record = self.data.tasks[currentIndex]
                    let lengthChanged = record.totalBytes != nil && info.contentLength != nil && record.totalBytes != info.contentLength
                    guard !lengthChanged else {
                        self.updateStatus(id, .failed, error: DownloadEngineError.sourceChanged.localizedDescription,
                                          generation: generation)
                        return
                    }
                    let strongETag = record.etag.flatMap { $0.lowercased().hasPrefix("w/") ? nil : $0 }
                    if let strongETag, let remoteETag = info.etag, remoteETag != strongETag {
                        self.updateStatus(id, .failed, error: DownloadEngineError.sourceChanged.localizedDescription,
                                          generation: generation)
                        return
                    }
                    if let modified = record.lastModified, let remoteModified = info.lastModified,
                       remoteModified != modified {
                        self.updateStatus(id, .failed, error: DownloadEngineError.sourceChanged.localizedDescription,
                                          generation: generation)
                        return
                    }
                    // A missing HEAD validator means the persisted bytes cannot
                    // be tied to this representation. Drop them and issue a
                    // normal GET; only explicit validator/length changes fail.
                    let validatorConfirmed = strongETag.map { info.etag == $0 }
                        ?? record.lastModified.map { info.lastModified == $0 }
                        ?? false
                    if !validatorConfirmed {
                        // Equal length alone cannot prove that persisted bytes belong to this version.
                        let prior = self.data.tasks[currentIndex]
                        record.resumeDataName = nil
                        record.receivedBytes = 0
                        record.totalBytes = info.contentLength
                        record.etag = info.etag
                        record.lastModified = info.lastModified
                        record.supportsRanges = info.supportsRanges
                        record.legacyRecoveryNote = "来源未提供可比对的 ETag 或 Last-Modified；为防止拼接不同内容，已清除续传进度并从头下载。"
                        resume = nil
                        self.data.tasks[currentIndex] = record
                        do { try self.persist() }
                        catch {
                            if let rollbackIndex = self.taskIndex(id) { self.data.tasks[rollbackIndex] = prior }
                            throw error
                        }
                        self.schedulePartialCleanup(id: id, resumeDataName: prior.resumeDataName, removeHLS: false)
                        self.segmentedEngine.cancel(taskID: id, generation: previousGeneration ?? 0, deletePartial: true)
                    }
                } else if record.kind == .http, record.supportsRanges == nil {
                    let info = try await self.engine.probe(sourceURL,
                        headers: effective.headers.merging(effective.credentialHeaders) { _, new in new },
                        userAgent: effective.userAgent, settings: engineSettings,
                        proxyPassword: try self.credentials.read(account: engineSettings.proxyPasswordAccount) ?? "")
                    guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id),
                          let currentIndex = self.taskIndex(id) else { return }
                    let prior = self.data.tasks[currentIndex]
                    record = prior
                    record.totalBytes = info.contentLength
                    record.etag = info.etag
                    record.lastModified = info.lastModified
                    record.supportsRanges = info.supportsRanges
                    self.data.tasks[currentIndex] = record
                    do { try self.persist() }
                    catch {
                        if let rollbackIndex = self.taskIndex(id) { self.data.tasks[rollbackIndex] = prior }
                        throw error
                    }
                }
                try Task.checkCancellation()
                guard self.isCurrentGeneration(generation, for: id) else { return }
                if record.kind == .hls {
                    let connections = effective.connectionCount > 0 ? effective.connectionCount : engineSettings.defaultConnectionCount
                    let proxyPassword = try self.credentials.read(account: engineSettings.proxyPasswordAccount) ?? ""
                    var hostCredentials: [String: [String: String]] = [:]
                    for rule in engineSettings.hostRules {
                        guard let account = rule.credentialAccount,
                              let bytes = try self.credentials.readData(account: account) else { continue }
                        guard let values = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else {
                            throw CredentialStoreError.invalidData
                        }
                        hostCredentials[account] = values
                    }
                    self.startHLS(record: record,
                                  generation: generation,
                                  headers: effective.headers.merging(effective.credentialHeaders) { _, new in new },
                                  settings: engineSettings, proxyPassword: proxyPassword,
                                  hostCredentials: hostCredentials, maximumConnections: connections,
                                  speedLimitBytesPerSecond: effective.speedLimit)
                } else if record.supportsRanges == true,
                          (record.etag.map { !$0.lowercased().hasPrefix("w/") } == true || record.lastModified != nil),
                          let total = record.totalBytes,
                          total >= max(1_024, engineSettings.minimumSegmentSizeBytes) * 2,
                          engineSettings.defaultConnectionCount > 1 {
                    let proxyPassword = try self.credentials.read(account: engineSettings.proxyPasswordAccount) ?? ""
                    try await self.segmentedEngine.start(task: record, generation: generation,
                        headers: effective.headers.merging(effective.credentialHeaders) { _, new in new },
                        settings: engineSettings, speedLimit: effective.speedLimit, proxyPassword: proxyPassword)
                    guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id) else { return }
                    self.updateStatus(id, .downloading, error: nil, generation: generation)
                } else {
                    let proxyPassword = try self.credentials.read(account: engineSettings.proxyPasswordAccount) ?? ""
                    try self.engine.start(task: record, generation: generation,
                                          headers: effective.headers.merging(effective.credentialHeaders) { _, new in new }, settings: engineSettings,
                                          resumeData: record.resumeDataName == nil ? nil : resume,
                                          speedLimitBytesPerSecond: effective.speedLimit, proxyPassword: proxyPassword)
                    guard self.isCurrentGeneration(generation, for: id) else { return }
                    self.updateStatus(id, .downloading, error: nil, generation: generation)
                }
            } catch {
                if Task.isCancelled || !self.isCurrentGeneration(generation, for: id) { return }
                self.transferFailed(id, generation: generation, message: error.localizedDescription)
            }
        }
        preparationWork[id] = work
    }

    private func startHLS(record: DownloadRecord, generation: UInt64, headers: [String: String], settings: AppSettings,
                          proxyPassword: String, hostCredentials: [String: [String: String]], maximumConnections: Int,
                          speedLimitBytesPerSecond: Int64) {
        let id = record.id
        let baseDirectory = store.directory
        let shouldResetHLS = pendingHLSReset.remove(id) != nil
        let runtimePolicy = HLSRuntimePolicy(settings: settings, maximumConnections: maximumConnections,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond, taskConnectionOverride: record.connectionCount != nil)
        hlsPolicies[id] = (generation, runtimePolicy)
        let work = Task { [weak self] in
            defer {
                if self?.hlsWork[id]?.generation == generation { self?.hlsWork.removeValue(forKey: id) }
                if self?.hlsPolicies[id]?.generation == generation { self?.hlsPolicies.removeValue(forKey: id) }
                if Task.isCancelled, self?.taskIndex(id) == nil { self?.schedulePartialCleanup(id: id, resumeDataName: nil, removeHLS: true) }
            }
            do {
                let staged = try await HLSService.download(task: record, headers: headers, settings: settings,
                    proxyPassword: proxyPassword, hostCredentials: hostCredentials,
                    maximumConnections: maximumConnections,
                    speedLimitBytesPerSecond: speedLimitBytesPerSecond, runtimePolicy: runtimePolicy,
                    generation: generation, baseDirectory: baseDirectory, resetResume: shouldResetHLS) { [weak self] received, total in
                    Task { @MainActor in self?.updateProgress(id, generation: generation, received: received, total: total) }
                }
                guard let self, !Task.isCancelled, self.isCurrentGeneration(generation, for: id) else {
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged) }
                    return
                }
                self.completeTransfer(id, generation: generation, staged: staged, response: nil)
            } catch {
                guard let self else { return }
                if Task.isCancelled { self.finishPause(id, generation: generation, resumeData: nil) }
                else { self.transferFailed(id, generation: generation, message: error.localizedDescription) }
            }
        }
        hlsWork[id] = (generation, work)
        updateStatus(id, .downloading, error: nil, generation: generation)
    }

    private func updateProgress(_ id: Int64, generation: UInt64, received: Int64, total: Int64?) {
        guard isCurrentGeneration(generation, for: id) else { return }
        guard let index = taskIndex(id) else { return }
        let now = Date.now
        let existingSnapshot = progressSnapshots[id]
        if let prior = existingSnapshot {
            guard now.timeIntervalSince(prior.0) >= 0.2 || received >= (total ?? Int64.max) else { return }
        }
        let baselineReceived = liveState.receivedBytes[id] ?? data.tasks[index].receivedBytes
        let clampedReceived = existingSnapshot == nil
            ? max(0, received)
            : max(baselineReceived, max(0, received))
        let speed: Double
        if let prior = existingSnapshot {
            let elapsed = max(0.05, now.timeIntervalSince(prior.0))
            speed = Double(max(0, clampedReceived - prior.1)) / elapsed
        } else {
            speed = 0
        }
        progressSnapshots[id] = (now, clampedReceived)
        let currentSessionStart = activeSessionStartedAt[id] ?? now
        let activeDuration = (accumulatedActiveDuration[id] ?? 0) + max(0, now.timeIntervalSince(currentSessionStart))
        let averageElapsed = max(0.05, activeDuration)
        let averageSpeed = Double(max(0, clampedReceived)) / averageElapsed
        let metric = TransferMetric(bytesPerSecond: speed, averageBytesPerSecond: averageSpeed, updatedAt: now)
        liveState.update(taskID: id, received: clampedReceived, total: total, metric: metric)
        if now.timeIntervalSince(lastPersistTime) >= 3 {
            lastPersistTime = now
            let snapshot = snapshotWithLiveProgress()
            store.scheduleBackgroundSave(snapshot) { [weak self] message in
                self?.lastActionMessage = "下载进度暂未保存：\(message)"
            }
        }
    }

    @ObservationIgnored private var lastPersistTime: Date = .distantPast

    private func completeTransfer(_ id: Int64, generation: UInt64, staged: URL, response: HTTPURLResponse?) {
        guard isCurrentGeneration(generation, for: id), let index = taskIndex(id) else {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged) }
            return
        }
        if fileCommitWork[id]?.generation == generation { return }
        let record = data.tasks[index]
        let serverModified = response?.value(forHTTPHeaderField: "Last-Modified") ?? record.lastModified
        let modificationDate = data.settings.useServerTimestamp ? serverModified.flatMap(HTTPDate.parse) : nil
        let occupiedPaths = Set(data.tasks.filter { $0.id != id }.map {
            canonicalFilePath($0.outputURL)
        })
        let work = Task { [weak self] in
            guard let self else {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged) }
                return
            }
            defer { self.clearFileCommitWork(id, generation: generation) }
            do {
                let verification = Task.detached(priority: .utility) { () throws -> (Int64, String?) in
                    let values = try staged.resourceValues(forKeys: [.fileSizeKey])
                    let size = Int64(values.fileSize ?? 0)
                    if let expected = record.totalBytes, expected >= 0, size != expected {
                        throw DownloadEngineError.lengthMismatch(expected: expected, actual: size)
                    }
                    var checksum: String?
                    if let wanted = record.expectedChecksum {
                        let parts = wanted.split(separator: ":", maxSplits: 1).map(String.init)
                        let algorithm = parts.count == 2 ? parts[0] : "SHA-256"
                        let expected = parts.count == 2 ? parts[1] : parts[0]
                        checksum = try ChecksumService.calculate(file: staged, algorithm: algorithm)
                        guard checksum?.caseInsensitiveCompare(expected) == .orderedSame else {
                            throw DownloadEngineError.checksumMismatch(expected: wanted, actual: checksum ?? "")
                        }
                    }
                    return (size, checksum)
                }
                let (size, checksum) = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: {
                    verification.cancel()
                }
                guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id) else {
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged) }
                    return
                }
                let transaction: FileCommitTransaction
                do {
                    transaction = try await FileCommitter.shared.install(record: record, staged: staged,
                        size: size, modificationDate: modificationDate, occupiedPaths: occupiedPaths)
                } catch {
                    let needsRecovery = (error as? FileCommitError)?.requiresRecoveryArtifacts == true
                    let preserveStaged = needsRecovery || (!Task.isCancelled && self.isCurrentGeneration(generation, for: id))
                    self.finishFileCommitFailure(id, generation: generation, staged: staged, error: error,
                                                 preserveStaged: preserveStaged)
                    return
                }
                guard !Task.isCancelled, self.isCurrentGeneration(generation, for: id) else {
                    do { try await FileCommitter.shared.rollback(transaction) }
                    catch { self.lastActionMessage = "提交已取消；恢复原目标文件失败，备份仍保留：\(error.localizedDescription)" }
                    self.clearFileCommitWork(id, generation: generation)
                    return
                }
                await self.finishFileCommit(id, generation: generation, record: record, size: size,
                                            checksum: checksum, transaction: transaction)
            } catch {
                self.finishFileCommitFailure(id, generation: generation, staged: staged, error: error)
            }
        }
        fileCommitWork[id] = (generation, work)
    }

    private func finishFileCommit(_ id: Int64, generation: UInt64, record: DownloadRecord, size: Int64,
                                  checksum: String?, transaction: FileCommitTransaction) async {
        guard isCurrentGeneration(generation, for: id), let index = taskIndex(id) else {
            do { try await FileCommitter.shared.rollback(transaction) }
            catch { lastActionMessage = "提交已取消；恢复原目标文件失败：\(error.localizedDescription)" }
            clearFileCommitWork(id, generation: generation)
            return
        }
        let previousData = data
        let queueID = record.queueID
        var completed = data.tasks[index]
        completed.displayName = transaction.displayName
        completed.status = .completed
        completed.receivedBytes = size
        completed.totalBytes = size
        completed.completedAt = .now
        completed.actualChecksum = checksum
        completed.lastError = nil
        completed.resumeDataName = nil
        data.tasks[index] = completed
        data.history.insert(DownloadHistoryRecord(sourceURL: completed.sourceURL, displayName: completed.displayName,
                                                  destinationDirectory: completed.destinationDirectory, completedAt: .now), at: 0)
        data.history = Array(data.history.prefix(1000))
        for queueIndex in data.queues.indices { data.queues[queueIndex].taskIDs.removeAll { $0 == id } }
        do { try persist() }
        catch {
            data = previousData
            var rollbackError: String?
            do { try await FileCommitter.shared.rollback(transaction) }
            catch { rollbackError = error.localizedDescription }
            guard isCurrentGeneration(generation, for: id), let failedIndex = taskIndex(id) else {
                clearFileCommitWork(id, generation: generation)
                return
            }
            if let rollbackError {
                lastActionMessage = "完成状态未保存；恢复原目标文件失败，备份仍保留：\(rollbackError)"
            }
            do {
                let old = data.tasks[failedIndex]
                data.tasks[failedIndex].status = .failed
                data.tasks[failedIndex].lastError = rollbackError.map {
                    "下载文件已校验，但完成状态保存失败；原文件恢复失败，备份仍保留：\($0)"
                } ?? "下载文件已校验，但完成状态保存失败；已尝试恢复原目标文件。"
                try persist()
                publishStatusTransition(from: old, to: data.tasks[failedIndex])
            } catch {
                lastActionMessage = "下载失败状态也未能保存：\(error.localizedDescription)"
            }
            clearFileCommitWork(id, generation: generation)
            updateSleepAssertion()
            if lastActionMessage == nil || lastActionMessage?.hasPrefix("下载失败状态") != true {
                lastActionMessage = "下载文件完成状态未能保存：\(error.localizedDescription)"
            }
            return
        }
        publishStatusTransition(from: previousData.tasks.first(where: { $0.id == id }), to: completed)
        clearLiveTransferState(for: id, resetDuration: true)
        lastCompletedTaskID = id
        lastActionMessage = "下载完成：\(completed.displayName)"
        updateSleepAssertion()
        schedulePartialCleanup(id: id, resumeDataName: record.resumeDataName, removeHLS: true)
        do { try await FileCommitter.shared.finish(transaction) }
        catch { lastActionMessage = "下载已完成；旧备份或暂存文件仍保留以便恢复：\(error.localizedDescription)" }
        if record.kind == .http {
            segmentedEngine.cleanupCompletedArtifacts(taskID: id, generation: generation)
        }
        guard isCurrentGeneration(generation, for: id), task(id)?.status == .completed else { return }
        pumpQueues()
        wakeScheduler()
        if let queueID { handleQueueDrained(queueID) }
        if let action = completed.completionAction, action != .none {
            if data.tasks.contains(where: { $0.id != id && $0.status.isActive }) {
                lastActionMessage = "此任务已完成，但其他任务仍在传输；为避免中断它们，没有执行系统动作。"
            } else {
                onTaskCompletionAction?(action)
            }
        }
    }

    private func finishFileCommitFailure(_ id: Int64, generation: UInt64, staged: URL, error: Error,
                                         preserveStaged: Bool = false) {
        clearFileCommitWork(id, generation: generation)
        if !preserveStaged {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged) }
        }
        guard isCurrentGeneration(generation, for: id), !Task.isCancelled else { return }
        let message = preserveStaged
            ? "\(error.localizedDescription) 已校验的暂存文件保留在：\(staged.path)"
            : error.localizedDescription
        updateStatus(id, .failed, error: message, generation: generation)
    }

    private func clearFileCommitWork(_ id: Int64, generation: UInt64) {
        if fileCommitWork[id]?.generation == generation { fileCommitWork.removeValue(forKey: id) }
    }

    private func transferFailed(_ id: Int64, generation: UInt64, message: String) {
        guard isCurrentGeneration(generation, for: id), let index = taskIndex(id) else { return }
        accumulateActiveDuration(for: id)
        if let liveReceived = liveState.receivedBytes[id] {
            data.tasks[index].receivedBytes = max(data.tasks[index].receivedBytes, liveReceived)
        }
        if let liveTotal = liveState.totalBytes[id] {
            data.tasks[index].totalBytes = liveTotal
        }
        clearLiveTransferState(for: id, resetDuration: false)
        let message = URL(string: data.tasks[index].sourceURL).map { redactSensitiveURL(in: message, sourceURL: $0) } ?? "传输失败；任务源地址无效。"
        if message.localizedCaseInsensitiveContains("HTTP 401") || message.localizedCaseInsensitiveContains("HTTP 403") ||
            message.localizedCaseInsensitiveContains("远端文件与暂停前不同") || message.localizedCaseInsensitiveContains("不受支持") {
            updateStatus(id, .failed, error: message, generation: generation)
            pumpQueues()
            if let queueID = data.tasks[index].queueID { handleQueueDrained(queueID) }
            return
        }
        if data.tasks[index].retryCount < data.settings.maximumRetries {
            let previous = data.tasks[index]
            data.tasks[index].retryCount += 1
            data.tasks[index].status = .failed
            data.tasks[index].lastError = "连接失败，将在 \(data.settings.retryDelaySeconds) 秒后重试（\(data.tasks[index].retryCount)/\(data.settings.maximumRetries)）。"
            do { try persist() }
            catch {
                data.tasks[index] = previous
                lastActionMessage = "失败状态未能保存：\(error.localizedDescription)"
                return
            }
            publishStatusTransition(from: previous, to: data.tasks[index])
            updateSleepAssertion()
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(max(1, self.data.settings.retryDelaySeconds)))
                guard self.isCurrentGeneration(generation, for: id), let index = self.taskIndex(id),
                      self.data.tasks[index].status == .failed else { return }
                let belongsToQueue = self.data.tasks[index].queueID != nil
                self.startTask(id, manual: !belongsToQueue)
            }
        } else {
            updateStatus(id, .failed, error: message, generation: generation)
            pumpQueues()
            if let queueID = data.tasks[index].queueID { handleQueueDrained(queueID) }
        }
    }

    private func fallbackToSingleConnection(_ id: Int64, generation: UInt64) {
        guard isCurrentGeneration(generation, for: id), let index = taskIndex(id) else { return }
        let previous = data.tasks[index]
        data.tasks[index].supportsRanges = false
        data.tasks[index].receivedBytes = 0
        data.tasks[index].lastError = "服务器忽略了 Range 请求；已清除本次分段并改用单连接下载。"
        data.tasks[index].status = .queued
        do { try persist() }
        catch {
            data.tasks[index] = previous
            updateStatus(id, .failed, error: "服务器忽略 Range 请求，且回退状态无法保存：\(error.localizedDescription)", generation: generation)
            return
        }
        publishStatusTransition(from: previous, to: data.tasks[index])
        invalidateTransferGeneration(for: id)
        pauseInProgress.removeValue(forKey: id)
        let belongsToQueue = data.tasks[index].queueID != nil
        startTask(id, manual: !belongsToQueue)
    }

    private func handleQueueDrained(_ queueID: Int64) {
        guard let index = data.queues.firstIndex(where: { $0.id == queueID }), data.queues[index].isRunning else { return }
        let members = data.queues[index].taskIDs.compactMap(task)
        guard members.allSatisfy({ !$0.status.isActive && $0.status != .queued }) else { return }
        let previousQueue = data.queues[index]
        if previousQueue.schedule.stopWhenEmpty {
            data.queues[index].isRunning = false
            do { try persist() }
            catch {
                data.queues[index] = previousQueue
                lastActionMessage = "队列完成状态未能保存：\(error.localizedDescription)"
                return
            }
        }
        let action = data.queues[index].completionAction
        if action != .none, completionActionsTriggered.insert(queueID).inserted {
            if data.tasks.contains(where: \.status.isActive) {
                lastActionMessage = "队列已完成，但其他任务仍在传输；为避免中断它们，没有执行系统动作。"
            } else {
                onQueueCompletionAction?(action)
            }
        }
    }

    private func transferPaused(_ id: Int64, generation: UInt64, resumeData: Data?, committedBytes: Int64? = nil) {
        guard pauseInProgress[id] == generation else { return }
        finishPause(id, generation: generation, resumeData: resumeData, committedBytes: committedBytes)
    }

    private func finishPause(_ id: Int64, generation: UInt64, resumeData: Data?, committedBytes: Int64? = nil) {
        guard pauseInProgress[id] == generation, let index = taskIndex(id) else { return }
        let previous = data.tasks[index]
        var next = previous
        accumulateActiveDuration(for: id)
        if let committedBytes {
            next.receivedBytes = max(0, committedBytes)
        } else if let liveReceived = liveState.receivedBytes[id] {
            next.receivedBytes = max(next.receivedBytes, liveReceived)
        }
        if let liveTotal = liveState.totalBytes[id] {
            next.totalBytes = liveTotal
        }
        var newResumeName: String?
        if let resumeData, !resumeData.isEmpty {
            do {
                newResumeName = try store.saveResumeData(resumeData, taskID: id)
                next.resumeDataName = newResumeName
            } catch {
                next.lastError = "已暂停，但无法保存续传信息：\(error.localizedDescription)"
            }
        }
        next.status = .paused
        if newResumeName != nil { next.lastError = nil }
        data.tasks[index] = next
        do {
            try persist()
            if previous.resumeDataName != next.resumeDataName {
                schedulePartialCleanup(id: id, resumeDataName: previous.resumeDataName, removeHLS: false)
            }
        } catch {
            // Keep the transfer paused in memory. If a later save succeeds, the
            // returned resume data remains available through this record.
            data.tasks[index].lastError = "已暂停，但状态未能保存：\(error.localizedDescription)"
            lastActionMessage = data.tasks[index].lastError
        }
        if previous.status != data.tasks[index].status { publishStatusTransition(from: previous, to: data.tasks[index]) }
        pauseInProgress.removeValue(forKey: id)
        clearLiveTransferState(for: id, resetDuration: false)
        updateSleepAssertion()
        pumpQueues()
        wakeScheduler()
        if let queueID = data.tasks[index].queueID { handleQueueDrained(queueID) }
    }

    private func updateStatus(_ id: Int64, _ status: DownloadStatus, error: String?, generation: UInt64? = nil) {
        if let generation, !isCurrentGeneration(generation, for: id) { return }
        guard let index = taskIndex(id) else { return }
        let previous = data.tasks[index]
        guard previous.status != status || previous.lastError != error else { return }
        data.tasks[index].status = status
        data.tasks[index].lastError = error
        if status == .completed { data.tasks[index].completedAt = .now }
        do { try persist() }
        catch {
            data.tasks[index] = previous
            lastActionMessage = "任务状态未能保存：\(error.localizedDescription)"
            return
        }
        publishStatusTransition(from: previous, to: data.tasks[index])
        if !status.isActive {
            accumulateActiveDuration(for: id)
            clearLiveTransferState(for: id, resetDuration: status == .completed || status == .cancelled)
        }
        updateSleepAssertion()
    }

    private func publishStatusTransition(from previous: DownloadRecord?, to current: DownloadRecord) {
        guard previous?.status != current.status else { return }
        taskStatusRevision &+= 1
        retainedTaskStatusEvents.append(TaskStatusEvent(sequence: taskStatusRevision, taskID: current.id,
            oldStatus: previous?.status, newStatus: current.status, displayName: current.displayName,
            showProgressWindow: current.showProgressWindow, showCompletionWindow: current.showCompletionWindow,
            error: current.lastError))
        if retainedTaskStatusEvents.count > 256 {
            retainedTaskStatusEvents.removeFirst(retainedTaskStatusEvents.count - 256)
        }
    }

    private func nextTransferGeneration(for id: Int64) -> UInt64 {
        let next = (transferGenerations[id] ?? 0) &+ 1
        if let pending = fileCommitWork[id], pending.generation != next { pending.task.cancel() }
        transferGenerations[id] = next
        return next
    }

    private func invalidateTransferGeneration(for id: Int64) {
        _ = nextTransferGeneration(for: id)
    }

    private func isCurrentGeneration(_ generation: UInt64, for id: Int64) -> Bool {
        transferGenerations[id] == generation
    }

    private func updateSleepAssertion() {
        let shouldPreventSleep = data.settings.preventSleepDuringTransfers && data.tasks.contains { $0.status.isActive }
        if shouldPreventSleep, sleepAssertionID == nil {
            var assertion: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "zjx-download active transfer" as CFString, &assertion)
            if result == kIOReturnSuccess { sleepAssertionID = assertion }
        } else if !shouldPreventSleep, let assertion = sleepAssertionID {
            IOPMAssertionRelease(assertion)
            sleepAssertionID = nil
        }
    }

    private func readTaskSecrets(_ task: DownloadRecord) throws -> [String: String] {
        guard let account = task.credentialAccount, let bytes = try credentials.readData(account: account) else { return [:] }
        guard let headers = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else { throw CredentialStoreError.invalidData }
        return headers
    }

    private func urlWithoutInlineCredentials(_ url: URL, moveCredentialsTo headers: inout [String: String]) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DownloadEngineError.invalidURL
        }
        if components.user != nil || components.password != nil {
            let username = components.user ?? ""
            let password = components.password ?? ""
            if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                guard let bytes = "\(username):\(password)".data(using: .utf8) else { throw DownloadEngineError.invalidURL }
                headers["Authorization"] = "Basic \(bytes.base64EncodedString())"
            }
            components.user = nil
            components.password = nil
            guard let sanitized = components.url else { throw DownloadEngineError.invalidURL }
            return sanitized
        }
        return url
    }

    private func urlRemovingInlineCredentials(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user != nil || components.password != nil else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    private func redactedURLForDisplay(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "HTTP(S) 地址" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "HTTP(S) 地址"
    }

    private func redactSensitiveURL(in message: String, sourceURL: URL) -> String {
        let safeURL = redactedURLForDisplay(sourceURL)
        var candidates = [sourceURL.absoluteString]
        if var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            if let value = components.url?.absoluteString { candidates.append(value) }
        }
        let decodedCandidates = candidates.compactMap { $0.removingPercentEncoding }
        candidates.append(contentsOf: decodedCandidates)
        return candidates.reduce(message) { result, candidate in
            guard !candidate.isEmpty, candidate != safeURL else { return result }
            return result.replacingOccurrences(of: candidate, with: safeURL)
        }
    }

    private func prepareEffectiveRequest(url: URL, headers: [String: String], settings: AppSettings,
                                         taskLimit: Int64 = 0, taskConnectionCount: Int? = nil) throws -> EffectiveRequest {
        var effective = NetworkConfiguration.prepare(url: url, explicitHeaders: headers, settings: settings,
            taskLimit: taskLimit, taskConnectionCount: taskConnectionCount)
        guard let account = NetworkConfiguration.matchingHostRule(for: url, settings: settings)?.credentialAccount else { return effective }
        guard let data = try credentials.readData(account: account) else {
            throw ValidationError("匹配的主机规则凭据已从钥匙串移除，请重新保存该规则。")
        }
        guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw CredentialStoreError.invalidData }
        effective.credentialHeaders = stored.merging(effective.credentialHeaders) { _, explicit in explicit }
        return effective
    }

    private func schedulePartialCleanup(id: Int64, resumeDataName: String?, removeHLS: Bool) {
        let resumeURL: URL?
        if let name = resumeDataName, !name.contains("/"), !name.contains("..") {
            resumeURL = store.resumeDataURL(for: name)
        } else {
            resumeURL = nil
        }
        let hlsURL = removeHLS
            ? store.directory.appendingPathComponent("hls-\(id)", isDirectory: true)
            : nil
        Task.detached(priority: .utility) {
            if let resumeURL { try? FileManager.default.removeItem(at: resumeURL) }
            if let hlsURL { try? FileManager.default.removeItem(at: hlsURL) }
        }
    }

    private func removeHLSParts(_ id: Int64) {
        schedulePartialCleanup(id: id, resumeDataName: nil, removeHLS: true)
    }

    private func taskIndex(_ id: Int64) -> Int? { data.tasks.firstIndex { $0.id == id } }

    private func accumulateActiveDuration(for id: Int64) {
        if let started = activeSessionStartedAt.removeValue(forKey: id) {
            accumulatedActiveDuration[id, default: 0] += max(0, Date.now.timeIntervalSince(started))
        }
    }

    private func clearLiveTransferState(for id: Int64, resetDuration: Bool) {
        liveState.clear(taskID: id)
        progressSnapshots.removeValue(forKey: id)
        activeSessionStartedAt.removeValue(forKey: id)
        if resetDuration { accumulatedActiveDuration.removeValue(forKey: id) }
    }

    private func syncLiveBytesIntoData() {
        for index in data.tasks.indices {
            let id = data.tasks[index].id
            if let received = liveState.receivedBytes[id] {
                data.tasks[index].receivedBytes = max(data.tasks[index].receivedBytes, received)
            }
            if let total = liveState.totalBytes[id] {
                data.tasks[index].totalBytes = total
            }
        }
    }

    private func snapshotWithLiveProgress() -> AppData {
        var snapshot = data
        for index in snapshot.tasks.indices {
            let id = snapshot.tasks[index].id
            if let received = liveState.receivedBytes[id] {
                snapshot.tasks[index].receivedBytes = max(snapshot.tasks[index].receivedBytes, received)
            }
            if let total = liveState.totalBytes[id] {
                snapshot.tasks[index].totalBytes = total
            }
        }
        return snapshot
    }

    private func persist() throws {
        try store.save(data)
        lastPersistTime = .now
    }

    private static func sanitizeFileName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DownloadEngineError.invalidFileName
        }
        return name
    }

    internal static func uniqueName(_ name: String, in folder: URL, tasks: [DownloadRecord]) -> String {
        let occupied = Set(tasks.map { $0.outputURL.standardizedFileURL.path })
        let initialPath = folder.appendingPathComponent(name).standardizedFileURL.path
        if !occupied.contains(initialPath) && !FileManager.default.fileExists(atPath: initialPath) {
            return name
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
            let path = folder.appendingPathComponent(candidate).standardizedFileURL.path
            if !occupied.contains(path) && !FileManager.default.fileExists(atPath: path) { return candidate }
            suffix += 1
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension URLSessionDownloadTask {
    // Identity comparison helper used after delayed speed-limit suspension.
}

private enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}
