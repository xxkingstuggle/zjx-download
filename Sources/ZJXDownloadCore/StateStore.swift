import Foundation
import CryptoKit
import Darwin

private final class ExclusiveProcessLock {
    private let descriptor: Int32

    init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw StateStoreError.alreadyRunning
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum StateStoreError: Error, LocalizedError {
    case alreadyRunning
    case readOnlyRecovery
    case unsafeStateFile(URL)
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "另一个 zjx-download 实例正在管理这份数据。"
        case .readOnlyRecovery: "当前处于只读恢复模式，不能修改或覆盖原数据。"
        case .unsafeStateFile(let url): "状态路径不是普通文件，拒绝覆盖：\(url.path)"
        }
    }
}

public struct LegacyImportPreview: Sendable {
    public var sourceURL: URL
    public var taskCount: Int
    public var completedCount: Int
    public var unfinishedCount: Int
    public var categoryCount: Int
    public var queueCount: Int
    public var settingCount: Int
    public var lastModified: Date?
}

public struct LegacyImportResult: Sendable {
    public var tasksImported: Int
    public var categoriesImported: Int
    public var queuesImported: Int
    public var credentialItemsCopied: Int
    public var sourcePreservedAt: URL
    public var migrationNotes: [String]
}

@MainActor
public final class StateStore {
    public let directory: URL
    public let stateURL: URL
    public let resumeDirectory: URL
    private let processLock: ExclusiveProcessLock?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public let isReadOnlyRecovery: Bool
    private nonisolated let writeCoordinator = StateWriteCoordinator()
    private var backgroundSaveTask: Task<Void, Never>?

    public init(directory: URL? = nil) throws {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.name, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        processLock = try ExclusiveProcessLock(url: support.appendingPathComponent("instance.lock"))
        self.directory = support
        stateURL = support.appendingPathComponent("state-v2.json")
        resumeDirectory = support.appendingPathComponent("resume-data", isDirectory: true)
        try FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        isReadOnlyRecovery = false
    }

    private init(readOnlyRecoveryDirectory directory: URL) {
        self.directory = directory
        stateURL = directory.appendingPathComponent("state-v2.json")
        resumeDirectory = directory.appendingPathComponent("resume-data", isDirectory: true)
        processLock = nil
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        isReadOnlyRecovery = true
    }

    /// Opens the normal state location without creating files or acquiring a
    /// process lock. Callers can read a snapshot, but writes are rejected.
    public static func readOnlyRecovery(directory: URL? = nil) -> StateStore {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.name, isDirectory: true)
        return StateStore(readOnlyRecoveryDirectory: directory)
    }

    public func load() throws -> AppData {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AppData() }
        let data = try Data(contentsOf: stateURL)
        var value = try decoder.decode(AppData.self, from: data)
        guard value.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let legacyPrefix = AppSettings.legacySubdirectoryDefault + "/"
        for index in value.categories.indices {
            if let dir = value.categories[index].destinationDirectory,
               dir == AppSettings.legacySubdirectoryDefault || dir.hasPrefix(legacyPrefix) {
                value.categories[index].destinationDirectory = nil
            }
        }
        return value
    }

    public func save(_ data: AppData) throws {
        guard !isReadOnlyRecovery else { throw StateStoreError.readOnlyRecovery }
        var value = data
        value.schemaVersion = 2
        let bytes = try encoder.encode(value)
        let sequence = writeCoordinator.nextSequence()
        try writeCoordinator.writeSynchronously(bytes: bytes, sequence: sequence, directory: directory, stateURL: stateURL)
    }

    public func scheduleBackgroundSave(_ data: AppData, onFailure: (@MainActor @Sendable (String) -> Void)? = nil) {
        guard !isReadOnlyRecovery else { return }
        var snapshot = data
        snapshot.schemaVersion = 2
        let sequence = writeCoordinator.nextSequence()
        let directory = self.directory
        let stateURL = self.stateURL
        let coordinator = self.writeCoordinator
        backgroundSaveTask?.cancel()
        backgroundSaveTask = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let backgroundEncoder = JSONEncoder()
                backgroundEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                backgroundEncoder.dateEncodingStrategy = .iso8601
                let bytes = try backgroundEncoder.encode(snapshot)
                try Task.checkCancellation()
                try coordinator.writeIfCurrent(bytes: bytes, sequence: sequence, directory: directory, stateURL: stateURL)
            } catch is CancellationError {
                return
            } catch {
                if let onFailure {
                    await onFailure(error.localizedDescription)
                }
            }
        }
    }

    public func cancelPendingBackgroundSaves() {
        backgroundSaveTask?.cancel()
        backgroundSaveTask = nil
    }

    public func resumeDataURL(for name: String) -> URL { resumeDirectory.appendingPathComponent(name).standardizedFileURL }
    public func saveResumeData(_ bytes: Data, taskID: Int64) throws -> String {
        guard !isReadOnlyRecovery else { throw StateStoreError.readOnlyRecovery }
        let name = "task-\(taskID)-\(UUID().uuidString).resume"
        try bytes.write(to: resumeDataURL(for: name), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resumeDataURL(for: name).path)
        return name
    }
    public func readResumeData(named name: String?) -> Data? {
        guard let name, !name.contains("/"), !name.contains("..") else { return nil }
        return try? Data(contentsOf: resumeDataURL(for: name))
    }
    public func removeResumeData(named name: String?) {
        guard !isReadOnlyRecovery else { return }
        guard let name, !name.contains("/"), !name.contains("..") else { return }
        try? FileManager.default.removeItem(at: resumeDataURL(for: name))
    }

    public var legacyStateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABDownloadManager", isDirectory: true).appendingPathComponent("state.json")
    }

    public var hasLegacyState: Bool { FileManager.default.fileExists(atPath: legacyStateURL.path) }

    public func previewLegacyImport() throws -> LegacyImportPreview? {
        try LegacyStateImporter(sourceURL: legacyStateURL).preview()
    }

    public func importLegacy(into current: AppData) throws -> (AppData, LegacyImportResult) {
        try LegacyStateImporter(sourceURL: legacyStateURL).migrate(into: current, targetDirectory: directory)
    }
}

private struct LegacyStateImporter {
    let sourceURL: URL

    func preview() throws -> LegacyImportPreview? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let root = try readRoot()
        let tasks = root["tasks"] as? [[String: Any]] ?? []
        let categories = root["categories"] as? [[String: Any]] ?? []
        let queues = root["queues"] as? [[String: Any]] ?? []
        let settings = root["settings"] as? [String: Any] ?? [:]
        let completed = tasks.filter { ($0["status"] as? String)?.lowercased() == "completed" }.count
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        return LegacyImportPreview(sourceURL: sourceURL, taskCount: tasks.count, completedCount: completed,
                                   unfinishedCount: tasks.count - completed, categoryCount: categories.count,
                                   queueCount: queues.count, settingCount: settings.count,
                                   lastModified: attrs?[.modificationDate] as? Date)
    }

    func migrate(into current: AppData, targetDirectory: URL) throws -> (AppData, LegacyImportResult) {
        guard try preview() != nil else { throw CocoaError(.fileNoSuchFile) }
        let root = try readRoot()
        var result = current
        guard result.importedLegacyAt == nil else { throw CocoaError(.fileWriteFileExists) }
        result.nextTaskID = max(result.nextTaskID, (result.tasks.map(\.id).max() ?? 0) + 1)
        result.nextQueueID = max(result.nextQueueID, (result.queues.map(\.id).max() ?? 0) + 1)
        result.nextCategoryID = max(result.nextCategoryID, (result.categories.map(\.id).max() ?? 0) + 1)
        let tasks = root["tasks"] as? [[String: Any]] ?? []
        let categories = root["categories"] as? [[String: Any]] ?? []
        let queues = root["queues"] as? [[String: Any]] ?? []
        let legacySupport = sourceURL.deletingLastPathComponent()
        let legacyPrefix = Self.legacyCredentialPrefix(directory: legacySupport)
        let legacyCredentials = CredentialStore(service: "com.abdownloadmanager.mac.credentials")
        let newCredentials = CredentialStore()
        var credentialsCopied = 0

        let snapshotDir = targetDirectory.appendingPathComponent("legacy-import-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshot = snapshotDir.appendingPathComponent("state-before-import-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: sourceURL, to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)

        var categoryIDs: [Int64: Int64] = [:]
        if !categories.isEmpty {
            let converted = categories.compactMap { item -> CategoryRecord? in
                guard let oldID = number(item["id"]), let name = string(item["name"]) else { return nil }
                let newID = result.nextCategoryID
                result.nextCategoryID += 1
                categoryIDs[oldID] = newID
                return CategoryRecord(id: newID, name: name, symbol: string(item["icon"]) ?? "folder",
                                      extensions: item["acceptedFileTypes"] as? [String] ?? [],
                                      urlPatterns: item["acceptedURLPatterns"] as? [String] ?? [],
                                      destinationDirectory: string(item["categoryPath"]), order: integer(item["order"]) ?? result.categories.count)
            }
            result.categories.append(contentsOf: converted)
        }

        var queueIDs: [Int64: Int64] = [:]
        if !queues.isEmpty {
            let converted = queues.compactMap { item -> QueueRecord? in
                guard let oldID = number(item["id"]), let name = string(item["name"]) else { return nil }
                let newID = result.nextQueueID
                result.nextQueueID += 1
                queueIDs[oldID] = newID
                let oldSchedule = item["schedule"] as? [String: Any] ?? [:]
                let dayValues = (oldSchedule["weekdays"] as? [String] ?? []).compactMap { value -> Int? in
                    switch value.lowercased() {
                    case "monday": 1; case "tuesday": 2; case "wednesday": 3; case "thursday": 4
                    case "friday": 5; case "saturday": 6; case "sunday": 7; default: nil
                    }
                }
                let enabled = oldSchedule["isEnabled"] as? Bool ?? false
                let start = min(86_399, max(0, integer(oldSchedule["startSeconds"]) ?? 0))
                let end = min(86_399, max(0, integer(oldSchedule["endSeconds"]) ?? 86_399))
                let schedule = QueueSchedule(days: Set(dayValues.isEmpty ? Array(1...7) : dayValues),
                                             startEnabled: enabled, startHour: start / 3600, startMinute: (start % 3600) / 60,
                                             stopEnabled: enabled, stopHour: end / 3600, stopMinute: (end % 3600) / 60,
                                             stopWhenEmpty: false)
                let oldAction = string(item["completionAction"]) ?? "none"
                let completion: CompletionAction = switch oldAction {
                case "sleepComputer": .sleep
                case "shutDownComputer": .shutdown
                case "quitApplication": .quit
                default: .none
                }
                return QueueRecord(id: newID, name: name, concurrency: integer(item["concurrencyLimit"]) ?? 1,
                                   isRunning: false, schedule: schedule, completionAction: completion,
                                   order: integer(item["order"]) ?? result.queues.count)
            }
            result.queues.append(contentsOf: converted)
        }

        var taskIDs: [Int64: Int64] = [:]
        for object in tasks {
                guard let oldID = number(object["id"]), taskIDs[oldID] == nil, let source = object["source"] as? [String: Any],
                      let url = string(source["url"]), URL(string: url)?.scheme?.lowercased().isHTTPFamily == true,
                      let folder = string(object["folderPath"]), let name = string(object["fileName"]) else { continue }
                let id = result.nextTaskID
                result.nextTaskID += 1
                taskIDs[oldID] = id
                let oldStatus = (object["status"] as? String ?? "created").lowercased()
                let status: DownloadStatus = switch oldStatus {
                case "completed": .completed
                case "cancelled": .cancelled
                case "failed": .failed
                case "created": .queued
                case "downloading", "merging", "stopped", "paused": .paused
                default: .paused
                }
                let secretAccount = "\(legacyPrefix).task.\(oldID).headers"
                var headers = source["headers"] as? [String: String] ?? [:]
                if let secretData = try legacyCredentials.read(account: secretAccount), let bytes = secretData.data(using: .utf8),
                   let secretHeaders = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] {
                    headers.merge(secretHeaders) { _, new in new }
                }
                var newAccount: String?
                if !headers.isEmpty {
                    newAccount = "task-\(id)-headers"
                    let secretNames = ["authorization", "cookie", "proxy-authorization", "set-cookie"]
                    let sensitive = headers.filter { secretNames.contains($0.key.lowercased()) }
                    headers = headers.filter { !secretNames.contains($0.key.lowercased()) }
                    if !sensitive.isEmpty, let encoded = try? JSONSerialization.data(withJSONObject: sensitive, options: [.sortedKeys]) {
                        try newCredentials.writeData(encoded, account: newAccount!)
                        credentialsCopied += 1
                    }
                }
                let note = status == .paused && (number(object["downloadedSize"]) ?? 0) > 0
                    ? "旧项目的未完成文件与记录已保留；本次导入不会直接拼接旧分片。请在用户确认后重新下载或检查旧文件。"
                    : nil
                let task = DownloadRecord(id: id, kind: (object["kind"] as? String).flatMap(TransferKind.init(rawValue:)) ?? .http,
                                          sourceURL: url, pageURL: string(source["downloadPage"]), displayName: name,
                                          destinationDirectory: folder, status: status, totalBytes: number(object["totalSize"]),
                                          receivedBytes: number(object["downloadedSize"]) ?? 0,
                                          etag: (object["validator"] as? [String: Any]).flatMap { string($0["etag"]) },
                                          lastModified: (object["validator"] as? [String: Any]).flatMap { string($0["lastModified"]) },
                                          credentialAccount: newAccount, requestHeaders: headers,
                                          categoryID: number(object["categoryID"]).flatMap { categoryIDs[$0] },
                                          queueID: number(object["queueID"]).flatMap { queueIDs[$0] }, createdAt: date(object["createdAt"]) ?? .now,
                                          startedAt: date(object["startedAt"]), completedAt: date(object["completedAt"]),
                                          lastError: string(object["errorMessage"]), retryCount: integer(object["retryCount"]) ?? 0,
                                          expectedChecksum: string(object["expectedChecksum"]), actualChecksum: string(object["actualChecksum"]),
                                          speedLimitBytesPerSecond: number(object["speedLimit"]) ?? 0,
                                          sourceDescription: string(source["suggestedName"]), importedFromLegacy: true,
                                          legacyRecoveryNote: note,
                                          connectionCount: [integer(object["connectionCount"]), integer(object["threadCount"]), integer(object["connections"])]
                                            .compactMap { $0 }.first(where: { (1...256).contains($0) }))
                result.tasks.append(task)
        }

        for index in result.queues.indices {
            let oldQueueID = queueIDs.first(where: { $0.value == result.queues[index].id })?.key
            guard let oldQueueID else { continue }
            result.queues[index].taskIDs = result.tasks.compactMap { task in
                guard let oldTaskID = taskIDs.first(where: { $0.value == task.id })?.key,
                      let sourceObject = tasks.first(where: { number($0["id"]) == oldTaskID }),
                      number(sourceObject["queueID"]) == oldQueueID else { return nil }
                return task.id
            }
        }

        var migrationNotes: [String] = []
        if let settings = root["settings"] as? [String: Any] {
            try importSettings(settings, into: &result.settings, legacyCredentials: legacyCredentials,
                               newCredentials: newCredentials, legacyPrefix: legacyPrefix, credentialsCopied: &credentialsCopied)
            if settings["appendExtensionToIncompleteDownloads"] != nil {
                migrationNotes.append("旧版未完成文件后缀设置改由应用私有暂存区策略取代；新版本不在下载目录显示未完成文件。")
            }
        }
        let history = root["history"] as? [[String: Any]] ?? []
        result.history.append(contentsOf: history.compactMap { item in
            let source = item["source"] as? [String: Any]
            guard let url = string(item["url"]) ?? string(source?["url"]),
                  let name = string(item["fileName"]) ?? string(item["name"]),
                  let folder = string(item["folderPath"]),
                  let completed = date(item["finishedAt"]) ?? date(item["completedAt"]) else { return nil }
            return DownloadHistoryRecord(sourceURL: url, displayName: name, destinationDirectory: folder, completedAt: completed)
        })
        result.history = Array(result.history.suffix(5_000))

        try importHostRules(root["hostOverrides"] as? [[String: Any]] ?? [], into: &result.settings,
                            legacyCredentials: legacyCredentials, newCredentials: newCredentials,
                            legacyPrefix: legacyPrefix, credentialsCopied: &credentialsCopied)
        let legacyBookmarkURL = legacySupport.appendingPathComponent("folder-bookmarks.json")
        if FileManager.default.fileExists(atPath: legacyBookmarkURL.path) {
            let bookmarkCopy = snapshotDir.appendingPathComponent("folder-bookmarks-before-import.json")
            if !FileManager.default.fileExists(atPath: bookmarkCopy.path) { try FileManager.default.copyItem(at: legacyBookmarkURL, to: bookmarkCopy) }
        }
        result.importedLegacyAt = .now
        let imported = LegacyImportResult(tasksImported: taskIDs.count, categoriesImported: categoryIDs.count,
                                          queuesImported: queueIDs.count, credentialItemsCopied: credentialsCopied,
                                          sourcePreservedAt: sourceURL, migrationNotes: migrationNotes)
        return (result, imported)
    }

    private func importSettings(_ old: [String: Any], into settings: inout AppSettings,
                                legacyCredentials: CredentialStore, newCredentials: CredentialStore,
                                legacyPrefix: String, credentialsCopied: inout Int) throws {
        if let path = string(old["defaultDownloadFolder"]) { settings.defaultDownloadDirectory = path }
        settings.defaultConnectionCount = integer(old["threadCount"]) ?? settings.defaultConnectionCount
        settings.maxManualDownloads = integer(old["maxConcurrentDownloads"]) ?? settings.maxManualDownloads
        settings.maximumRetries = integer(old["maxRetryCount"]) ?? settings.maximumRetries
        settings.minimumSegmentSizeBytes = number(old["minSegmentSize"]) ?? settings.minimumSegmentSizeBytes
        settings.dynamicSegmentation = old["dynamicSegmentCreationEnabled"] as? Bool ?? settings.dynamicSegmentation
        settings.sparseFiles = old["sparseFileAllocationEnabled"] as? Bool ?? settings.sparseFiles
        settings.useServerTimestamp = old["useLastModified"] as? Bool ?? settings.useServerTimestamp
        settings.deletePartialOnCancel = old["deletePartialFileOnDownloadCancellation"] as? Bool ?? settings.deletePartialOnCancel
        settings.trackDeletedFiles = old["trackDeletedFilesOnDisk"] as? Bool ?? settings.trackDeletedFiles
        settings.preventSleepDuringTransfers = old["preventSystemSleep"] as? Bool ?? settings.preventSleepDuringTransfers
        settings.userAgent = string(old["userAgent"]) ?? settings.userAgent
        if let appearance = string(old["theme"])?.lowercased() {
            settings.appearance = appearance == "dark" ? .dark : appearance == "light" ? .light : .system
        }
        if let language = string(old["language"]), !language.isEmpty { settings.language = language }
        if let scale = (old["uiScale"] as? NSNumber)?.doubleValue { settings.scalePercent = max(50, min(200, Int((scale * 100).rounded()))) }
        if let unit = string(old["sizeUnit"]) { settings.sizeUnit = unit.lowercased().contains("decimal") ? "decimal" : "binary" }
        if let unit = string(old["speedUnit"]) { settings.speedUnit = unit.lowercased().contains("decimal") ? "decimal" : "bytes" }
        settings.globalSpeedLimitBytesPerSecond = number(old["speedLimit"]) ?? settings.globalSpeedLimitBytesPerSecond
        if let notifications = old["notifications"] as? [String: Any] {
            settings.soundEnabled = notifications["soundEnabled"] as? Bool ?? settings.soundEnabled
            settings.showProgressWindow = notifications["showDownloadProgressDialog"] as? Bool ?? settings.showProgressWindow
            settings.showCompletionWindow = notifications["showCompletionDialog"] as? Bool ?? settings.showCompletionWindow
        }
        settings.loginItemEnabled = old["autoStartOnBoot"] as? Bool ?? settings.loginItemEnabled
        if let integration = old["integration"] as? [String: Any] {
            settings.apiEnabled = integration["enabled"] as? Bool ?? settings.apiEnabled
            settings.apiPort = integer(integration["port"]) ?? settings.apiPort
            settings.apiRequiresKey = integration["authEnabled"] as? Bool ?? settings.apiRequiresKey
            let oldKey = try string(integration["apiKey"]) ?? legacyCredentials.read(account: "\(legacyPrefix).integration.apiKey") ?? ""
            if !oldKey.isEmpty { try newCredentials.write(oldKey, account: settings.apiKeyAccount); credentialsCopied += 1 }
        }
        if let proxy = old["proxy"] as? [String: Any] {
            settings.proxyHost = string(proxy["host"]) ?? settings.proxyHost
            settings.proxyPort = integer(proxy["port"]) ?? settings.proxyPort
            let oldMode = string(proxy["mode"])?.lowercased() ?? "system"
            settings.proxyMode = oldMode == "none" ? .direct : ProxyMode(rawValue: oldMode) ?? .system
            settings.proxyScheme = string(proxy["scheme"]).flatMap(ProxyScheme.init(rawValue:)) ?? settings.proxyScheme
            settings.proxyUsername = string(proxy["username"]) ?? settings.proxyUsername
            settings.proxyBypass = (string(proxy["bypassList"]) ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
            settings.pacURL = string(proxy["pacURL"]) ?? settings.pacURL
            let oldPassword = try string(proxy["password"]) ?? legacyCredentials.read(account: "\(legacyPrefix).proxy.password") ?? ""
            if !oldPassword.isEmpty { try newCredentials.write(oldPassword, account: settings.proxyPasswordAccount); credentialsCopied += 1 }
        }
        if let tls = old["tls"] as? [String: Any] {
            settings.allowInvalidTLSCertificates = tls["allowInsecureCertificates"] as? Bool ?? settings.allowInvalidTLSCertificates
        }
        if let dns = old["dns"] as? [String: Any], string(dns["mode"]) == "https" {
            settings.dohURL = string(dns["httpsURL"]) ?? settings.dohURL
            settings.dnsMode = .doh
        }
        if let manifest = string(old["updateManifestURL"]) { settings.updateManifestURL = manifest }
        if let channel = string(old["updateChannel"]) { settings.updatesEnabled = channel.lowercased() != "disabled" }
        if let checked = date(old["lastUpdateCheck"]) { settings.lastUpdateCheck = checked }
    }

    private func importHostRules(_ legacy: [[String: Any]], into settings: inout AppSettings,
                                 legacyCredentials: CredentialStore, newCredentials: CredentialStore,
                                 legacyPrefix: String, credentialsCopied: inout Int) throws {
        for item in legacy {
            guard let host = string(item["host"]), !host.isEmpty else { continue }
            let account = "host-\(host.lowercased())-credentials"
            let password = try legacyCredentials.read(account: "\(legacyPrefix).host.\(host.lowercased()).password") ?? ""
            var headers = item["headers"] as? [String: String] ?? [:]
            var sensitive = headers.filter { NetworkConfiguration.sensitiveHeaderNames.contains($0.key.lowercased()) }
            headers = headers.filter { !NetworkConfiguration.sensitiveHeaderNames.contains($0.key.lowercased()) }
            let username = string(item["authUsername"]) ?? ""
            if !username.isEmpty { sensitive["Authorization"] = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString() }
            let credentialAccount: String?
            if !sensitive.isEmpty {
                credentialAccount = account
                try newCredentials.writeData(JSONSerialization.data(withJSONObject: sensitive, options: [.sortedKeys]), account: account)
                credentialsCopied += 1
            } else { credentialAccount = nil }
            let storedConnections = integer(item["threads"]) ?? integer(item["threadCount"])
            let connectionCount = storedConnections.flatMap { (1...256).contains($0) ? $0 : nil }
            settings.hostRules.append(HostRule(pattern: host, userAgent: string(item["userAgent"]) ?? "", headers: headers,
                                               credentialAccount: credentialAccount,
                                               speedLimitBytesPerSecond: number(item["speedLimit"]) ?? 0,
                                               connectionCount: connectionCount))
        }
    }

    private func readRoot() throws -> [String: Any] {
        let bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }

    private func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
    private func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
    private static func legacyCredentialPrefix(directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        return String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

private extension String {
    var isHTTPFamily: Bool { self == "http" || self == "https" }
}

private final class StateWriteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSequence: UInt64 = 0

    func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestSequence &+= 1
        return latestSequence
    }

    func writeSynchronously(bytes: Data, sequence: UInt64, directory: URL, stateURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sequence == latestSequence else { return }
        try Self.writeAtomically(bytes: bytes, directory: directory, stateURL: stateURL)
    }

    func writeIfCurrent(bytes: Data, sequence: UInt64, directory: URL, stateURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sequence == latestSequence else { return }
        try Self.writeAtomically(bytes: bytes, directory: directory, stateURL: stateURL)
    }

    private static func writeAtomically(bytes: Data, directory: URL, stateURL: URL) throws {
        let temporaryURL = directory.appendingPathComponent(".state-v2-\(UUID().uuidString).tmp")
        do {
            try bytes.write(to: temporaryURL, options: [.completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            var existing = stat()
            if lstat(stateURL.path, &existing) == 0 {
                guard (existing.st_mode & S_IFMT) == S_IFREG else { throw StateStoreError.unsafeStateFile(stateURL) }
            } else if errno != ENOENT {
                throw CocoaError(.fileWriteNoPermission)
            }

            let result = temporaryURL.path.withCString { source in
                stateURL.path.withCString { destination in Darwin.rename(source, destination) }
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
