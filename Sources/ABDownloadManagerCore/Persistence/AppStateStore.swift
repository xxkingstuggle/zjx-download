import Foundation

public struct PersistedAppState: Codable, Sendable, Equatable {
    public var version: Int
    public var tasks: [DownloadTask]
    public var queues: [DownloadQueue]
    public var categories: [DownloadCategory]
    public var history: [DownloadRecord]
    public var hostOverrides: [HostOverride]
    public var settings: AppSettings
    public var nextTaskID: Int64
    public var nextQueueID: Int64
    public var nextCategoryID: Int64
    public var nextHistoryID: Int64

    public init(
        version: Int = 1,
        tasks: [DownloadTask] = [],
        queues: [DownloadQueue] = [DownloadQueue(id: 1, name: "Default", order: 0)],
        categories: [DownloadCategory] = [],
        history: [DownloadRecord] = [],
        hostOverrides: [HostOverride] = [],
        settings: AppSettings = AppSettings(),
        nextTaskID: Int64 = 1,
        nextQueueID: Int64 = 2,
        nextCategoryID: Int64 = 1,
        nextHistoryID: Int64 = 1
    ) {
        self.version = version
        self.tasks = tasks
        self.queues = queues
        self.categories = categories
        self.history = history
        self.hostOverrides = hostOverrides
        self.settings = settings
        self.nextTaskID = nextTaskID
        self.nextQueueID = nextQueueID
        self.nextCategoryID = nextCategoryID
        self.nextHistoryID = nextHistoryID
    }
}

public actor AppStateStore {
    public let fileURL: URL
    private var state: PersistedAppState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABDownloadManager", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("state.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try decoder.decode(PersistedAppState.self, from: data)
        } else {
            state = PersistedAppState(settings: SettingsMigration().importLegacyDefaults())
        }
        Self.recoverInterruptedTasks(in: &state)
    }

    public func snapshot() -> PersistedAppState { state }

    public func upsertCategory(_ category: DownloadCategory) throws { if let index = state.categories.firstIndex(where: { $0.id == category.id }) { state.categories[index] = category } else { state.categories.append(category) }; try persist() }
    public func addCategory(name: String, extensions: [String] = [], hosts: [String] = [], folder: String? = nil) throws -> DownloadCategory { let category = DownloadCategory(id: state.nextCategoryID, name: name, order: state.categories.count, acceptedFileTypes: extensions, acceptedURLPatterns: hosts, categoryPath: folder); state.nextCategoryID += 1; state.categories.append(category); try persist(); return category }
    public func deleteCategory(id: Int64) throws { state.categories.removeAll { $0.id == id }; for index in state.tasks.indices where state.tasks[index].categoryID == id { state.tasks[index].categoryID = nil }; try persist() }
    public func reorderCategories(ids: [Int64]) throws { let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }); for index in state.categories.indices { state.categories[index].order = ranks[state.categories[index].id] ?? state.categories[index].order }; state.categories.sort { $0.order < $1.order }; try persist() }
    public func upsertHostOverride(_ override: HostOverride) throws { var value = override; value.host = try HostOverride.normalizeHost(value.host); if let index = state.hostOverrides.firstIndex(where: { $0.host == value.host }) { state.hostOverrides[index] = value } else { state.hostOverrides.append(value) }; try persist() }
    public func removeHostOverride(host: String) throws { state.hostOverrides.removeAll { $0.host == host.lowercased() }; try persist() }
    public func matchingHostOverride(for url: URL) -> HostOverride? { state.hostOverrides.first { $0.applies(to: url) } }

    @discardableResult
    public func addTask(_ request: DownloadRequest) throws -> DownloadTask {
        var request = request
        if let override = state.hostOverrides.first(where: { $0.applies(to: request.source.url) }) {
            request.source.headers = request.source.headers.merging(override.headers) { current, _ in current }
            if request.speedLimit == 0, let speed = override.speedLimit { request.speedLimit = speed }
            if request.folderPath == nil { request.folderPath = override.defaultFolder }
            if request.categoryID == nil { request.categoryID = override.categoryID }
            if request.source.url.host != nil, request.source.headers["User-Agent"] == nil, let agent = override.headers["User-Agent"] { request.source.headers["User-Agent"] = agent }
        }
        let fallback = request.source.suggestedName ?? request.source.url.lastPathComponent
        if request.categoryID == nil, let category = state.categories.first(where: { $0.matches(url: request.source.url, fileName: request.fileName ?? fallback) }) {
            request.categoryID = category.id
            if request.folderPath == nil { request.folderPath = category.defaultFolder }
        }
        let name = try FileUtilities.sanitizedFileName(request.fileName ?? (fallback.isEmpty ? "download" : fallback))
        let folder = request.folderPath ?? state.settings.defaultDownloadFolder
        var task = DownloadTask(
            id: state.nextTaskID,
            source: request.source,
            folderPath: folder,
            fileName: name,
            speedLimit: request.speedLimit,
            downloadPage: request.source.downloadPage,
            kind: request.kind,
            conflictPolicy: request.conflictPolicy,
            isQueued: request.enqueue
        )
        if let override = state.hostOverrides.first(where: { $0.applies(to: request.source.url) }), let threads = override.threadCount { task.connectionCount = min(max(threads, 1), 64) }
        task.queueID = request.queueID
        task.categoryID = request.categoryID
        task.expectedChecksum = request.expectedChecksum
        state.nextTaskID += 1
        state.tasks.append(task)
        try persist()
        return task
    }

    public func task(id: Int64) -> DownloadTask? { state.tasks.first { $0.id == id } }

    public func updateTask(_ task: DownloadTask) throws {
        guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { throw DownloadEngineError.missingTask }
        state.tasks[index] = task
        try persist()
    }

    public func removeTask(id: Int64) throws {
        state.tasks.removeAll { $0.id == id }
        try persist()
    }

    public func setSettings(_ settings: AppSettings) throws {
        var normalized = settings
        normalized.normalize()
        state.settings = normalized
        try persist()
    }

    @discardableResult
    public func addQueue(name: String, concurrencyLimit: Int = 1, schedule: QueueSchedule? = nil) throws -> DownloadQueue {
        let queue = DownloadQueue(id: state.nextQueueID, name: name, order: state.queues.count, concurrencyLimit: max(1, concurrencyLimit), schedule: schedule)
        state.nextQueueID += 1
        state.queues.append(queue)
        try persist()
        return queue
    }

    public func updateQueue(_ queue: DownloadQueue) throws {
        guard let index = state.queues.firstIndex(where: { $0.id == queue.id }) else { return }
        var value = queue
        value.concurrencyLimit = max(1, value.concurrencyLimit)
        state.queues[index] = value
        try persist()
    }

    public func deleteQueue(id: Int64) throws {
        guard state.queues.count > 1 else { return }
        state.queues.removeAll { $0.id == id }
        for index in state.tasks.indices where state.tasks[index].queueID == id { state.tasks[index].queueID = nil }
        try persist()
    }

    public func reorderQueues(ids: [Int64]) throws {
        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for index in state.queues.indices { state.queues[index].order = ranks[state.queues[index].id] ?? state.queues[index].order }
        state.queues.sort { $0.order < $1.order }
        try persist()
    }

    public func appendHistory(for task: DownloadTask) throws {
        guard !state.history.contains(where: { $0.taskID == task.id && $0.finalStatus == task.status }) else { return }
        let record = DownloadRecord(
            id: state.nextHistoryID, taskID: task.id, name: task.fileName,
            url: task.source.url.absoluteString, folderPath: task.folderPath, fileName: task.fileName,
            finalStatus: task.status, totalSize: task.totalSize, downloadedSize: task.downloadedSize,
            startedAt: task.startedAt, finishedAt: task.completedAt ?? Date(),
            errorMessage: task.errorMessage, checksum: task.actualChecksum
        )
        state.nextHistoryID += 1
        state.history.append(record)
        try persist()
    }

    public func clearHistory() throws {
        state.history.removeAll()
        try persist()
    }

    public func persist() throws {
        let data = try encoder.encode(state)
        let temporary = fileURL.appendingPathExtension("tmp")
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

    private static func recoverInterruptedTasks(in state: inout PersistedAppState) {
        for index in state.tasks.indices where state.tasks[index].status.isActive {
            state.tasks[index].status = .paused
            state.tasks[index].errorMessage = nil
        }
    }
}

extension PersistedAppState {
    private enum CodingKeys: String, CodingKey { case version, tasks, queues, categories, history, hostOverrides, settings, nextTaskID, nextQueueID, nextCategoryID, nextHistoryID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedAppState()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        tasks = try c.decodeIfPresent([DownloadTask].self, forKey: .tasks) ?? []
        queues = try c.decodeIfPresent([DownloadQueue].self, forKey: .queues) ?? defaults.queues
        categories = try c.decodeIfPresent([DownloadCategory].self, forKey: .categories) ?? []
        history = try c.decodeIfPresent([DownloadRecord].self, forKey: .history) ?? []
        hostOverrides = try c.decodeIfPresent([HostOverride].self, forKey: .hostOverrides) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? defaults.settings
        nextTaskID = try c.decodeIfPresent(Int64.self, forKey: .nextTaskID) ?? ((tasks.map(\.id).max() ?? 0) + 1)
        nextQueueID = try c.decodeIfPresent(Int64.self, forKey: .nextQueueID) ?? ((queues.map(\.id).max() ?? 0) + 1)
        nextCategoryID = try c.decodeIfPresent(Int64.self, forKey: .nextCategoryID) ?? ((categories.map(\.id).max() ?? 0) + 1)
        nextHistoryID = try c.decodeIfPresent(Int64.self, forKey: .nextHistoryID) ?? ((history.map(\.id).max() ?? 0) + 1)
    }
}
