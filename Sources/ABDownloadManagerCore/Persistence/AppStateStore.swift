import Foundation
import CryptoKit

public enum AppStateIsolationError: Error, LocalizedError, Equatable {
    case taskOutsideIsolatedDownloads(taskID: Int64)
    case destinationOutsideIsolatedDownloads
    case missingIsolatedDefaultsSuite

    public var errorDescription: String? {
        switch self {
        case .taskOutsideIsolatedDownloads(let taskID):
            "Isolated verification profile contains task \(taskID) outside its download directory."
        case .destinationOutsideIsolatedDownloads:
            "The destination must remain inside the isolated verification download directory."
        case .missingIsolatedDefaultsSuite:
            "An isolated state or download directory requires ABDM_USER_DEFAULTS_SUITE."
        }
    }
}

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
    public var defaultCategoriesInitialized: Bool

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
        nextHistoryID: Int64 = 1,
        defaultCategoriesInitialized: Bool = false
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
        self.defaultCategoriesInitialized = defaultCategoriesInitialized
    }
}

public actor AppStateStore {
    public let fileURL: URL
    private var state: PersistedAppState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentials: KeychainCredentialStore
    private let credentialPrefix: String
    private let environment: [String: String]
    /// Sensitive request headers are fetched only for tasks the engine or an
    /// editor actually opens. Keeping them out of startup snapshots prevents
    /// one Keychain IPC per historical task and avoids copying secrets into
    /// list projections.
    private var taskCredentialCache: [Int64: [String: String]] = [:]

    /// Overrides the on-disk location for tests and sandboxed verification
    /// runs. Never read in production paths; default behaviour is untouched.
    public static func defaultDirectory(overridingWith env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["ABDM_STATE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABDownloadManager", isDirectory: true)
    }

    /// The shared `ABDownloadManager` bucket under App Support that both stores
    /// (state + folder bookmarks) read from in production.
    public static var sharedAppSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABDownloadManager", isDirectory: true)
    }

    public init(
        directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        _ = try VerificationLaunchConfiguration.validateIfRequired(
            marker: Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment
        )
        self.environment = environment
        let base = directory ?? Self.defaultDirectory(overridingWith: environment)
        let usesIsolatedDirectories = [environment["ABDM_STATE_DIRECTORY"], environment["ABDM_DOWNLOAD_DIRECTORY"]]
            .contains { value in value.map { !$0.isEmpty } ?? false }
        let defaultsForMigration: UserDefaults
        if let suiteName = environment["ABDM_USER_DEFAULTS_SUITE"], !suiteName.isEmpty {
            guard let suite = UserDefaults(suiteName: suiteName) else {
                throw AppStateIsolationError.missingIsolatedDefaultsSuite
            }
            defaultsForMigration = suite
        } else if usesIsolatedDirectories {
            throw AppStateIsolationError.missingIsolatedDefaultsSuite
        } else {
            defaultsForMigration = .standard
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("state.json")
        credentials = KeychainCredentialStore()
        let pathDigest = SHA256.hash(data: Data(base.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        credentialPrefix = String(pathDigest.prefix(24))
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateExists = FileManager.default.fileExists(atPath: fileURL.path)
        if stateExists {
            let data = try Data(contentsOf: fileURL)
            state = try decoder.decode(PersistedAppState.self, from: data)
        } else {
            let settings = Self.sanitizedSettings(SettingsMigration().importLegacyDefaults(defaultsForMigration), environment: environment)
            let defaults = DefaultCategories.make(downloadRoot: settings.defaultDownloadFolder)
            state = PersistedAppState(categories: defaults, settings: settings, nextCategoryID: Int64(defaults.count), defaultCategoriesInitialized: true)
        }
        let originalSettings = state.settings
        state.settings = Self.sanitizedSettings(state.settings, environment: environment)
        var categoriesOverridden = false
        if let isolatedRoot = environment["ABDM_DOWNLOAD_DIRECTORY"], !isolatedRoot.isEmpty {
            let rootURL = URL(fileURLWithPath: isolatedRoot, isDirectory: true).standardizedFileURL
            for index in state.categories.indices {
                let path = rootURL.appendingPathComponent(state.categories[index].name, isDirectory: true).path
                if state.categories[index].categoryPath != path {
                    state.categories[index].categoryPath = path
                    categoriesOverridden = true
                }
            }
            for task in state.tasks where !Self.isPath(task.folderPath, containedBy: rootURL) {
                throw AppStateIsolationError.taskOutsideIsolatedDownloads(taskID: task.id)
            }
        }
        let settingsOverridden = originalSettings != state.settings
        var migratedSecret = false
        if !state.defaultCategoriesInitialized {
            if state.categories.isEmpty { state.categories = DefaultCategories.make(downloadRoot: state.settings.defaultDownloadFolder) }
            state.defaultCategoriesInitialized = true
            let next = (state.categories.map(\.id).max() ?? -1) + 1
            state.nextCategoryID = max(state.nextCategoryID, next)
            migratedSecret = true
        }
        let legacyAPIKey = state.settings.integration.apiKey
        let savedAPIKey = try credentials.read(account: "\(credentialPrefix).integration.apiKey")
        if !legacyAPIKey.isEmpty { migratedSecret = true }
        if savedAPIKey == nil, !legacyAPIKey.isEmpty {
            try credentials.write(legacyAPIKey, account: "\(credentialPrefix).integration.apiKey")
        }
        state.settings.integration.apiKey = savedAPIKey ?? legacyAPIKey
        let legacyProxyPassword = state.settings.proxy.password
        let savedProxyPassword = try credentials.read(account: "\(credentialPrefix).proxy.password")
        if !legacyProxyPassword.isEmpty { migratedSecret = true }
        if savedProxyPassword == nil, !legacyProxyPassword.isEmpty {
            try credentials.write(legacyProxyPassword, account: "\(credentialPrefix).proxy.password")
        }
        state.settings.proxy.password = savedProxyPassword ?? legacyProxyPassword
        for index in state.hostOverrides.indices {
            let account = "\(credentialPrefix).host.\(state.hostOverrides[index].host).password"
            let legacyPassword = state.hostOverrides[index].authPassword
            let savedPassword = try credentials.read(account: account)
            if !legacyPassword.isEmpty { migratedSecret = true }
            if savedPassword == nil, !legacyPassword.isEmpty {
                try credentials.write(legacyPassword, account: account)
            }
            state.hostOverrides[index].authPassword = savedPassword ?? legacyPassword
        }
        for index in state.tasks.indices {
            let sensitive = Self.sensitiveHeaders(state.tasks[index].source.headers)
            // Current state files contain public headers only. Avoid looking
            // up a Keychain item for every task at launch; the credential is
            // read lazily by taskForExecution when this task is used.
            guard !sensitive.isEmpty else { continue }
            let taskID = state.tasks[index].id
            let account = "\(credentialPrefix).task.\(taskID).headers"
            if try credentials.read(account: account) == nil {
                try credentials.write(try Self.encodeHeaders(sensitive), account: account)
            }
            state.tasks[index].source.headers = Self.publicHeaders(state.tasks[index].source.headers)
            migratedSecret = true
        }
        Self.recoverInterruptedTasks(in: &state)
        if migratedSecret || settingsOverridden || categoriesOverridden {
            try Self.persist(state, to: fileURL, using: encoder)
        }
    }

    public func snapshot() -> PersistedAppState { state }

    /// Returns `settings` with any test/verification overrides applied.
    /// Verification instances redirect their REST server away from the default
    /// port so they can never collide with an instance launched by the user.
    public static func sanitizedSettings(
        _ settings: AppSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppSettings {
        var value = settings
        if let port = environment["ABDM_INTEGRATION_PORT"],
           let int = Int(port), int > 0 {
            value.integration.port = int
        }
        if let directory = environment["ABDM_DOWNLOAD_DIRECTORY"], !directory.isEmpty {
            let root = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let configured = URL(fileURLWithPath: value.defaultDownloadFolder, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            let rootPath = root.path
            let configuredPath = configured.path
            let contained = configuredPath == rootPath
                || configuredPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            value.defaultDownloadFolder = contained ? configured.path : root.path
        }
        if environment["ABDM_SUPPRESS_CLIPBOARD_MONITOR"] == "1" {
            value.clipboardMonitoring = false
        }
        if Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String == "YES" {
            value.autoStartOnBoot = false
            value.clipboardMonitoring = false
            value.notifications.soundEnabled = false
            value.notifications.showCompletionDialog = false
        }
        return value
    }

    private static func isPath(_ path: String, containedBy root: URL) -> Bool {
        let candidate = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == rootPath || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    public func upsertCategory(_ category: DownloadCategory) throws { if let index = state.categories.firstIndex(where: { $0.id == category.id }) { state.categories[index] = category } else { state.categories.append(category) }; state.defaultCategoriesInitialized = true; try persist() }
    public func addCategory(name: String, extensions: [String] = [], hosts: [String] = [], folder: String? = nil, icon: String = "folder") throws -> DownloadCategory { let category = DownloadCategory(id: state.nextCategoryID, name: name, order: state.categories.count, acceptedFileTypes: extensions, acceptedURLPatterns: hosts, categoryPath: folder, icon: icon); state.nextCategoryID += 1; state.categories.append(category); state.defaultCategoriesInitialized = true; try persist(); return category }
    public func deleteCategory(id: Int64) throws { state.categories.removeAll { $0.id == id }; for index in state.tasks.indices where state.tasks[index].categoryID == id { state.tasks[index].categoryID = nil }; try persist() }
    public func reorderCategories(ids: [Int64]) throws { let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }); for index in state.categories.indices { state.categories[index].order = ranks[state.categories[index].id] ?? state.categories[index].order }; state.categories.sort { $0.order < $1.order }; try persist() }
    public func resetCategoriesToDefaults() throws {
        let previous = state
        let defaults = DefaultCategories.make(downloadRoot: state.settings.defaultDownloadFolder)
        let validIDs = Set(defaults.map(\.id))
        state.categories = defaults
        state.nextCategoryID = Int64(defaults.count)
        state.defaultCategoriesInitialized = true
        for index in state.tasks.indices where state.tasks[index].categoryID.map({ !validIDs.contains($0) }) ?? false { state.tasks[index].categoryID = nil }
        do { try persist() } catch { state = previous; throw error }
    }

    @discardableResult
    public func categorizeExistingTasks() throws -> Int {
        guard !state.categories.isEmpty else { return 0 }
        let previous = state
        let ordered = state.categories.sorted { $0.order < $1.order }
        var changed = 0
        for index in state.tasks.indices {
            let task = state.tasks[index]
            let category = ordered.first { $0.matches(url: task.source.url, fileName: task.fileName) }
            let newID = category?.id
            if task.categoryID != newID { state.tasks[index].categoryID = newID; changed += 1 }
        }
        guard changed > 0 else { return 0 }
        do { try persist() } catch { state = previous; throw error }
        return changed
    }
    public func upsertHostOverride(_ override: HostOverride) throws {
        var value = override
        value.host = try HostOverride.normalizeHost(value.host)
        let previous = state
        let account = "\(credentialPrefix).host.\(value.host).password"
        let oldPassword = try credentials.read(account: account)
        try credentials.write(value.authPassword, account: account)
        if let index = state.hostOverrides.firstIndex(where: { $0.host == value.host }) { state.hostOverrides[index] = value }
        else { state.hostOverrides.append(value) }
        do { try persist() }
        catch {
            state = previous
            try? credentials.write(oldPassword ?? "", account: account)
            throw error
        }
    }
    public func removeHostOverride(host: String) throws {
        let normalized = host.lowercased()
        let previous = state
        let account = "\(credentialPrefix).host.\(normalized).password"
        let oldPassword = try credentials.read(account: account)
        try credentials.remove(account: account)
        state.hostOverrides.removeAll { $0.host == normalized }
        do { try persist() }
        catch {
            state = previous
            try? credentials.write(oldPassword ?? "", account: account)
            throw error
        }
    }
    public func matchingHostOverride(for url: URL) -> HostOverride? { state.hostOverrides.first { $0.applies(to: url) } }

    @discardableResult
    public func addTask(_ request: DownloadRequest) throws -> DownloadTask {
        guard let task = try addTasks([request]).first else { throw DownloadEngineError.missingTask }
        return task
    }

    /// Adds a group as one durable transaction so batch input cannot leave a
    /// partially persisted group when any destination or filename is invalid.
    @discardableResult
    public func addTasks(_ requests: [DownloadRequest]) throws -> [DownloadTask] {
        guard !requests.isEmpty else { return [] }
        let previousState = state
        var added: [DownloadTask] = []
        do {
            added.reserveCapacity(requests.count)
            for originalRequest in requests {
                var request = originalRequest
                let matchingHostOverride = state.hostOverrides.first(where: { $0.applies(to: request.source.url) })
                if let override = matchingHostOverride {
                    for (name, value) in override.headers where !Self.containsHeader(name, in: request.source.headers) { request.source.headers[name] = value }
                    if request.speedLimit == 0, let speed = override.speedLimit { request.speedLimit = speed }
                    if request.folderPath == nil { request.folderPath = override.defaultFolder }
                    if request.categoryID == nil { request.categoryID = override.categoryID }
                    if request.source.url.host != nil, !Self.containsHeader("User-Agent", in: request.source.headers), let agent = override.headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value { request.source.headers["User-Agent"] = agent }
                    if !override.userAgent.isEmpty, !Self.containsHeader("User-Agent", in: request.source.headers) { request.source.headers["User-Agent"] = override.userAgent }
                    if !Self.containsHeader("Authorization", in: request.source.headers), !override.authUsername.isEmpty {
                        request.source.headers["Authorization"] = "Basic " + Data("\(override.authUsername):\(override.authPassword)".utf8).base64EncodedString()
                    }
                }
                let connectionCountOverride = request.connectionCountOverride ?? matchingHostOverride?.threadCount
                let initialConnectionCount = min(max(connectionCountOverride ?? state.settings.threadCount, 1), 64)
                let fallback = request.source.suggestedName ?? request.source.url.lastPathComponent
                if request.categoryID == nil, let category = state.settings.useCategoryByDefault ? state.categories.first(where: { $0.matches(url: request.source.url, fileName: request.fileName ?? fallback) }) : nil {
                    request.categoryID = category.id
                    if request.folderPath == nil { request.folderPath = category.defaultFolder }
                }
                let name = try FileUtilities.sanitizedFileName(request.fileName ?? (fallback.isEmpty ? "download" : fallback))
                let folder = request.folderPath ?? state.settings.defaultDownloadFolder
                try validateIsolatedDestination(folder, taskID: state.nextTaskID)
                var task = DownloadTask(
                    id: state.nextTaskID,
                    source: request.source,
                    folderPath: folder,
                    fileName: name,
                    connectionCount: initialConnectionCount,
                    connectionCountOverride: connectionCountOverride,
                    appendExtensionToIncompleteDownloads: state.settings.appendExtensionToIncompleteDownloads,
                    speedLimit: request.speedLimit,
                    downloadPage: request.source.downloadPage,
                    kind: request.kind,
                    conflictPolicy: request.conflictPolicy,
                    isQueued: request.enqueue
                )
                task.queueID = request.queueID
                task.categoryID = request.categoryID
                task.expectedChecksum = request.expectedChecksum
                state.nextTaskID += 1
                try saveTaskCredentials(task)
                task.source.headers = Self.publicHeaders(task.source.headers)
                state.tasks.append(task)
                added.append(task)
            }
            try persist()
            return added
        } catch {
            state = previousState
            for task in added {
                try? credentials.remove(account: taskCredentialAccount(task.id))
                taskCredentialCache.removeValue(forKey: task.id)
            }
            throw error
        }
    }

    /// Returns the public task metadata without touching Keychain. Use this
    /// for lists, status checks, and persistence bookkeeping.
    public func task(id: Int64) -> DownloadTask? {
        guard var task = state.tasks.first(where: { $0.id == id }) else { return nil }
        if let sensitive = taskCredentialCache[id] {
            task.source.headers = Self.publicHeaders(task.source.headers).merging(sensitive) { _, secret in secret }
        }
        return task
    }

    /// Loads the task's sensitive request headers on demand. The result is
    /// cached for the life of this store so progress/status updates during a
    /// long download do not repeat Keychain IPCs.
    public func taskForExecution(id: Int64) throws -> DownloadTask? {
        guard var task = state.tasks.first(where: { $0.id == id }) else { return nil }
        let sensitive: [String: String]
        if let cached = taskCredentialCache[id] {
            sensitive = cached
        } else if let encoded = try credentials.read(account: taskCredentialAccount(id)) {
            sensitive = try Self.decodeHeaders(encoded)
            taskCredentialCache[id] = sensitive
        } else {
            sensitive = [:]
            taskCredentialCache[id] = sensitive
        }
        task.source.headers = Self.publicHeaders(task.source.headers).merging(sensitive) { _, secret in secret }
        return task
    }

    public func updateTask(_ task: DownloadTask) throws {
        guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { throw DownloadEngineError.missingTask }
        try validateIsolatedDestination(task.folderPath, taskID: task.id)
        let previous = state.tasks[index]
        let headersChanged = previous.source.headers != task.source.headers
        let previousCredentialValue = headersChanged ? try credentials.read(account: taskCredentialAccount(task.id)) : nil
        let previousCachedCredentials = taskCredentialCache[task.id]
        var storedTask = task
        do {
            if previous.source.headers != task.source.headers {
                try saveTaskCredentials(task)
                taskCredentialCache[task.id] = Self.sensitiveHeaders(task.source.headers)
            }
            storedTask.source.headers = Self.publicHeaders(storedTask.source.headers)
            state.tasks[index] = storedTask
            try persist()
        } catch {
            state.tasks[index] = previous
            if headersChanged {
                try? credentials.write(previousCredentialValue ?? "", account: taskCredentialAccount(task.id))
                if let previousCachedCredentials { taskCredentialCache[task.id] = previousCachedCredentials }
                else { taskCredentialCache.removeValue(forKey: task.id) }
            }
            throw error
        }
    }

    /// Applies a multi-task metadata edit as one durable transaction.
    public func updateTasks(_ tasks: [DownloadTask]) throws {
        guard !tasks.isEmpty else { return }
        let previousState = state
        var previousCredentialValues: [Int64: String] = [:]
        var credentialIDsToRestore = Set<Int64>()
        let previousCredentialCache = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            taskCredentialCache[task.id].map { (task.id, $0) }
        })
        for task in tasks {
            guard let previous = previousState.tasks.first(where: { $0.id == task.id }), previous.source.headers != task.source.headers else { continue }
            credentialIDsToRestore.insert(task.id)
            if let value = try credentials.read(account: taskCredentialAccount(task.id)) { previousCredentialValues[task.id] = value }
        }
        do {
            for task in tasks {
                guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { throw DownloadEngineError.missingTask }
                try validateIsolatedDestination(task.folderPath, taskID: task.id)
                var storedTask = task
                if state.tasks[index].source.headers != task.source.headers {
                    try saveTaskCredentials(task)
                    taskCredentialCache[task.id] = Self.sensitiveHeaders(task.source.headers)
                }
                storedTask.source.headers = Self.publicHeaders(storedTask.source.headers)
                state.tasks[index] = storedTask
            }
            try persist()
        } catch {
            state = previousState
            for id in credentialIDsToRestore {
                let previousValue = previousCredentialValues[id]
                try? credentials.write(previousValue ?? "", account: taskCredentialAccount(id))
                if let cached = previousCredentialCache[id] { taskCredentialCache[id] = cached }
                else { taskCredentialCache.removeValue(forKey: id) }
            }
            throw error
        }
    }

    public func removeTask(id: Int64) throws {
        let previous = state
        let account = taskCredentialAccount(id)
        let oldCredentials = try credentials.read(account: account)
        try credentials.remove(account: taskCredentialAccount(id))
        let oldCachedCredentials = taskCredentialCache.removeValue(forKey: id)
        state.tasks.removeAll { $0.id == id }
        do { try persist() }
        catch {
            state = previous
            taskCredentialCache[id] = oldCachedCredentials
            try? credentials.write(oldCredentials ?? "", account: account)
            throw error
        }
    }

    public func setSettings(_ settings: AppSettings) throws {
        var normalized = Self.sanitizedSettings(settings, environment: environment)
        normalized.normalize()
        let previous = state.settings
        do {
            try credentials.write(normalized.integration.apiKey, account: "\(credentialPrefix).integration.apiKey")
            try credentials.write(normalized.proxy.password, account: "\(credentialPrefix).proxy.password")
            state.settings = normalized
            try persist()
        }
        catch {
            state.settings = previous
            try? credentials.write(previous.integration.apiKey, account: "\(credentialPrefix).integration.apiKey")
            try? credentials.write(previous.proxy.password, account: "\(credentialPrefix).proxy.password")
            throw error
        }
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

    public func setAllQueuesRunning(_ isRunning: Bool) throws {
        let previous = state
        for index in state.queues.indices { state.queues[index].isRunning = isRunning }
        do { try persist() } catch { state = previous; throw error }
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
        try Self.persist(state, to: fileURL, using: encoder)
    }

    private static func persist(_ state: PersistedAppState, to fileURL: URL, using encoder: JSONEncoder) throws {
        var diskState = state
        diskState.settings.integration.apiKey = ""
        diskState.settings.proxy.password = ""
        for index in diskState.hostOverrides.indices { diskState.hostOverrides[index].authPassword = "" }
        for index in diskState.tasks.indices { diskState.tasks[index].source.headers = Self.publicHeaders(diskState.tasks[index].source.headers) }
        let data = try encoder.encode(diskState)
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

    private func taskCredentialAccount(_ id: Int64) -> String { "\(credentialPrefix).task.\(id).headers" }

    private func validateIsolatedDestination(_ path: String, taskID: Int64) throws {
        guard Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String == "YES",
              let downloadRoot = environment["ABDM_DOWNLOAD_DIRECTORY"] else { return }
        let root = URL(fileURLWithPath: downloadRoot, isDirectory: true).standardizedFileURL
        guard Self.isPath(path, containedBy: root) else {
            throw AppStateIsolationError.taskOutsideIsolatedDownloads(taskID: taskID)
        }
    }

    private func saveTaskCredentials(_ task: DownloadTask) throws {
        let sensitive = Self.sensitiveHeaders(task.source.headers)
        if sensitive.isEmpty { try credentials.remove(account: taskCredentialAccount(task.id)) }
        else { try credentials.write(try Self.encodeHeaders(sensitive), account: taskCredentialAccount(task.id)) }
        taskCredentialCache[task.id] = sensitive
    }

    private static func sensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        HTTPHeaderEditingPolicy.sensitiveHeaders(headers)
    }

    private static func containsHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func publicHeaders(_ headers: [String: String]) -> [String: String] {
        HTTPHeaderEditingPolicy.publicHeaders(headers)
    }

    private static func encodeHeaders(_ headers: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(headers)
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainCredentialError.invalidUTF8 }
        return value
    }

    private static func decodeHeaders(_ value: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    }
}

extension PersistedAppState {
    private enum CodingKeys: String, CodingKey { case version, tasks, queues, categories, history, hostOverrides, settings, nextTaskID, nextQueueID, nextCategoryID, nextHistoryID, defaultCategoriesInitialized }
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
        defaultCategoriesInitialized = try c.decodeIfPresent(Bool.self, forKey: .defaultCategoriesInitialized) ?? false
    }
}
