import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import AppIntents
import ABDownloadManagerCore


struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "app.openDownloads"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
@main
struct ABDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { MainWindow(model: model).environment(\.locale, Locale(identifier: model.settings.language ?? "zh-Hans"))
            .environment(\.appLanguage, model.settings.language ?? "zh-Hans") }
            .defaultSize(width: 1100, height: 720)
            .commands { AppCommands(model: model) }
        MenuBarExtra(LocalizedStringKey("app.title"), systemImage: "arrow.down.circle") {
            MenuBarView(model: model)
                .environment(\.locale, Locale(identifier: model.settings.language ?? "zh-Hans"))
                .environment(\.appLanguage, model.settings.language ?? "zh-Hans")
        }
        Settings { SettingsView(model: model).environment(\.locale, Locale(identifier: model.settings.language ?? "zh-Hans"))
            .environment(\.appLanguage, model.settings.language ?? "zh-Hans") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var queues: [DownloadQueue] = []
    @Published private(set) var history: [DownloadRecord] = []
    @Published private(set) var categories: [DownloadCategory] = []
    @Published private(set) var hostOverrides: [HostOverride] = []
    @Published var settings: AppSettings = AppSettings()
    /// Multi-selection over the currently visible task ids. The list view
    /// binds its native selection directly to this value; ids are pruned in
    /// `refresh()` so selection can never outlive its tasks.
    @Published var selectedIDs: Set<Int64> = Set<Int64>()
    /// The anchor task for the inspector / double-click target. Remains one of
    /// the selected ids when possible and is kept in sync by `setSelection`.
    @Published var primaryTaskID: Int64?
    @Published var section: SidebarSection = .downloads
    @Published var isShowingNewDownload = false
    @Published var isShowingSettings = false
    @Published var lastError: String?
    @Published var progress: [Int64: DownloadProgress] = [:]
    @Published var deleteConfirmation: DeleteSelectionSummary?
    private var notifiedStatuses: [Int64: DownloadStatus] = [:]

    let store: AppStateStore?
    let engine: DownloadEngine?
    let scheduler: QueueScheduler?
    let bookmarkStore: FolderBookmarkStore?
    private var rest: RESTService?
    private var refreshTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var clipboardMonitor: ClipboardMonitor?

    init() {
        if let stateStore = try? AppStateStore() {
            store = stateStore
            settings = AppSettings()
            let bookmarks = try? FolderBookmarkStore()
            bookmarkStore = bookmarks
            engine = DownloadEngine(store: stateStore, bookmarkStore: bookmarks, settingsProvider: { await stateStore.snapshot().settings })
            scheduler = QueueScheduler(store: stateStore, engine: engine!)
        } else {
            store = nil; engine = nil; scheduler = nil; bookmarkStore = nil
        }
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
        progressTask = Task { [weak self] in
            guard let self, let engine else { return }
            for await event in await engine.progressStream() {
                await MainActor.run { self.progress[event.taskID] = event }
            }
        }
        clipboardMonitor = ClipboardMonitor { [weak self] links in
            guard let self else { return }
            Task { await self.addLinks(links.joined(separator: "\n"), folder: self.settings.defaultDownloadFolder, start: false) }
        }
        if settings.clipboardMonitoring { clipboardMonitor?.start() }
        Task { [weak self] in await self?.bootstrap() }
    }

    deinit { refreshTask?.cancel(); progressTask?.cancel() }

    func bootstrap() async {
        guard let store else { return }
        var snapshot = await store.snapshot()
        if snapshot.settings.language == nil {
            snapshot.settings.language = "zh-Hans"
            try? await store.setSettings(snapshot.settings)
        }
        settings = snapshot.settings; tasks = snapshot.tasks; queues = snapshot.queues; history = snapshot.history; categories = snapshot.categories; hostOverrides = snapshot.hostOverrides
        AppLocalization.defaultLanguageCode = snapshot.settings.language ?? "zh-Hans"
        if settings.clipboardMonitoring { clipboardMonitor?.start() } else { clipboardMonitor?.stop() }
        if settings.integration.enabled {
            do {
                let service = try RESTService(settings: settings.integration, addHandler: { [weak self] operation in
                    guard let self else { return }
                    try await self.handle(operation: operation)
                }, queueProvider: { [weak store] in (await store?.snapshot().queues) ?? [] })
                rest = service
                try await service.start()
            } catch { lastError = error.localizedDescription }
        }
        await scheduler?.start()
    }

    func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func refresh() async {
        guard let store else { return }
        let snapshot = await store.snapshot()
        tasks = snapshot.tasks; queues = snapshot.queues; history = snapshot.history; categories = snapshot.categories; hostOverrides = snapshot.hostOverrides; settings = snapshot.settings
        pruneSelection()
        notifyForFinishedTasks(snapshot.tasks)
    }

    /// The downloads page's visible tasks, newest-first. Cancelled items are
    /// considered dismissed (they surface again in History) while completed
    /// files stay in the list so they can be opened, revealed or deleted.
    /// Selection and "select all" always resolve against this exact list so
    /// hidden results can never be silently selected.
    var visibleTasks: [DownloadTask] {
        tasks.filter { $0.status != .cancelled }.sorted { $0.createdAt > $1.createdAt }
    }

    var selectedTasks: [DownloadTask] {
        visibleTasks.filter { selectedIDs.contains($0.id) }
    }

    var isSelectionEmpty: Bool { selectedIDs.isEmpty }
    var selectionCount: Int { selectedIDs.count }

    /// True when every visible id is selected. Uses subset semantics (all
    /// visible ids ⊆ selected) instead of an equality count so a poisoned
    /// selection that still holds hidden ids cannot misreport "all selected".
    /// Matches upstream's `isALlSelected` (`list.map { it.id }.all { it in
    /// selectionList }`), which also returns false for an empty list.
    var isAllVisibleSelected: Bool {
        !visibleTasks.isEmpty && visibleTasks.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// Replaces the visible selection with exactly `ids`, anchored on
    /// `preferredPrimary` when present, and keeps the inspector primary stable.
    ///
    /// This mirrors upstream's `BaseHomeComponent.newSelection`: a non-empty
    /// selection keeps the previous primary when it is still visible; otherwise
    /// the primary becomes the first selected id in visible (newest-first)
    /// order so the inspector never flickers to a random set member.
    func replaceSelection(_ ids: Set<Int64>, preferredPrimary: Int64? = nil) {
        // Never adopt an id that is not currently visible; a snapshot coming
        // from a stale binding or a just-deleted row is dropped here so it
        // cannot leak into the selection that a later Command+A reasons about.
        let visible = Set(visibleTasks.map(\.id))
        selectedIDs = ids.intersection(visible)
        if let primary = preferredPrimary, selectedIDs.contains(primary) {
            primaryTaskID = primary
        } else if let current = primaryTaskID, selectedIDs.contains(current) {
            primaryTaskID = current
        } else if let stable = selectedTasks.first?.id {
            primaryTaskID = stable
        } else {
            primaryTaskID = nil
        }
    }

    /// Replaces the visible selection with exactly the currently visible tasks
    /// (or clears it), keeping the primary anchor when still visible.
    func selectAllVisible(_ select: Bool) {
        if select {
            let selection = TaskSelection(ids: selectedIDs, primary: primaryTaskID).selecting(visible: visibleTasks.map(\.id))
            replaceSelection(selection.ids, preferredPrimary: selection.primary)
        } else {
            clearSelection()
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
        primaryTaskID = nil
    }

    /// Sets the primary task; if it is not yet selected it becomes the sole
    /// selection, matching single-click behaviour in the list.
    func setPrimary(_ task: DownloadTask) {
        if !selectedIDs.contains(task.id) {
            selectedIDs = Set([task.id])
        }
        primaryTaskID = task.id
    }

    /// Removes ids that no longer correspond to a *visible* task. Pruning
    /// against `visibleTasks` (which drops cancelled items) means a hidden or
    /// mid-delete id can never keep batch operations or a subsequent
    /// Command+A pointing at tasks the user can no longer see.
    func pruneSelection() {
        if selectedIDs.isEmpty { return }
        let visible = visibleTasks.map(\.id)
        let selection = TaskSelection(ids: selectedIDs, primary: primaryTaskID).pruned(available: visible)
        selectedIDs = selection.ids
        if let primary = primaryTaskID, !selectedIDs.contains(primary) {
            primaryTaskID = selection.primary ?? selectedTasks.first?.id
        }
    }


    private func notifyForFinishedTasks(_ current: [DownloadTask]) {
        guard settings.notifications.showCompletionDialog else { return }
        for task in current {
            guard task.status == .completed || task.status == .failed, notifiedStatuses[task.id] != task.status else { continue }
            notifiedStatuses[task.id] = task.status
            let content = UNMutableNotificationContent()
            content.title = task.status == .completed ? AppLocalization.string("notification.complete") : AppLocalization.string("notification.failed")
            content.body = task.fileName
            if settings.notifications.soundEnabled { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-\(task.id)-\(task.status.rawValue)", content: content, trigger: nil))
        }
    }

    func addCategory(name: String, extensions: [String], hosts: [String], folder: String?) async { guard let store else { return }; do { _ = try await store.addCategory(name: name, extensions: extensions, hosts: hosts, folder: folder); await refresh() } catch { lastError = error.localizedDescription } }
    func deleteCategory(_ category: DownloadCategory) async { guard let store else { return }; do { try await store.deleteCategory(id: category.id); await refresh() } catch { lastError = error.localizedDescription } }
    func saveCategory(_ category: DownloadCategory) async { guard let store else { return }; do { try await store.upsertCategory(category); await refresh() } catch { lastError = error.localizedDescription } }
    func deleteHostOverride(_ value: HostOverride) async { guard let store else { return }; do { try await store.removeHostOverride(host: value.host); await refresh() } catch { lastError = error.localizedDescription } }
    func saveHostOverride(host: String, headers: [String: String], threadCount: Int?, speedLimit: Int64?, defaultFolder: String?, categoryID: Int64?) async { guard let store else { return }; do { let value = try HostOverride(validatingHost: host, headers: headers, threadCount: threadCount, speedLimit: speedLimit, defaultFolder: defaultFolder, categoryID: categoryID); try await store.upsertHostOverride(value); await refresh() } catch { lastError = error.localizedDescription } }
    func addBatch(pattern: String, start: Int, end: Int, padding: Int, folder: String?, queueID: Int64?, startImmediately: Bool) async { do { let batch = try BatchURLPattern(pattern: pattern, start: start, end: end, wildcardLength: padding); for url in try batch.allLinks() { try await add(request: DownloadRequest(source: DownloadSource(url: url), folderPath: folder, queueID: queueID, startImmediately: startImmediately)) }; isShowingNewDownload = false } catch { lastError = error.localizedDescription } }

    func addQueue(name: String, concurrency: Int) async { guard let store else { return }; do { _ = try await store.addQueue(name: name.isEmpty ? "Queue \(queues.count + 1)" : name, concurrencyLimit: concurrency); await refresh() } catch { lastError = error.localizedDescription } }
    func updateQueue(_ queue: DownloadQueue) async { guard let store else { return }; do { try await store.updateQueue(queue); await refresh() } catch { lastError = error.localizedDescription } }
    func toggleQueue(_ queue: DownloadQueue) async { guard let store else { return }; var value = queue; value.isRunning.toggle(); do { try await store.updateQueue(value); await refresh() } catch { lastError = error.localizedDescription } }
    func deleteQueue(_ queue: DownloadQueue) async { guard let store else { return }; do { try await store.deleteQueue(id: queue.id); await refresh() } catch { lastError = error.localizedDescription } }
    func add(request: DownloadRequest) async throws {
        try await add(request: request, shouldStart: request.startImmediately)
    }

    func add(request: DownloadRequest, shouldStart: Bool) async throws {
        guard let store, let engine else { throw DownloadEngineError.missingTask }
        var request = request
        request.startImmediately = shouldStart
        let task = try await store.addTask(request)
        await refresh()
        if shouldStart { try await engine.start(taskID: task.id) }
    }

    func handle(operation: RESTAddOperation) async throws {
        try await add(request: operation.request, shouldStart: operation.options.silentStart || operation.request.startImmediately)
        if operation.startQueue, let queueID = operation.request.queueID, let store {
            if var queue = (await store.snapshot()).queues.first(where: { $0.id == queueID }) {
                queue.isRunning = true
                try await store.updateQueue(queue)
                await scheduler?.scheduleNow()
            }
        }
    }

    func addLinks(_ text: String, folder: String?, start: Bool, headers: [String: String] = [:], checksum: String? = nil, queueID: Int64? = nil, categoryID: Int64? = nil, conflict: FileConflictPolicy = .rename, speedLimit: Int64 = 0) async {
        let links = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init).filter { !$0.isEmpty }
        do {
            for link in links {
                guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                let source = DownloadSource(url: url, headers: headers)
                let request = DownloadRequest(source: source, folderPath: folder, queueID: queueID, categoryID: categoryID, kind: url.pathExtension.lowercased() == "m3u8" ? .hls : .http, startImmediately: start, conflictPolicy: conflict, expectedChecksum: checksum, speedLimit: speedLimit)
                try await add(request: request)
            }
            isShowingNewDownload = false
        } catch { lastError = error.localizedDescription }
    }

    func start(_ task: DownloadTask) async { do { try await engine?.start(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func pause(_ task: DownloadTask) async { do { try await engine?.pause(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func cancel(_ task: DownloadTask) async { do { try await engine?.cancel(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func retry(_ task: DownloadTask) async { do { try await engine?.retry(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    /// Double-click semantics: a completed file opens, otherwise the row is
    /// focused in the inspector. Never opens a random item from a multi-selection.
    func openTask(_ task: DownloadTask) async {
        if task.status == .completed {
            if FileManager.default.fileExists(atPath: task.filePath) { NSWorkspace.shared.open(URL(fileURLWithPath: task.filePath)) } else { lastError = AppLocalization.string("error.fileMissing") }
        }
        setPrimary(task)
    }
    func editTask(_ task: DownloadTask, fileName: String, folder: String, urlText: String, queueID: Int64?, categoryID: Int64?, headers: [String: String], checksum: String?, speedLimit: Int64) async {
        guard let store, task.canEdit else { lastError = AppLocalization.string("error.taskNotEditable"); return }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { lastError = AppLocalization.string("error.invalidTaskURL"); return }
        do {
            let safeName = try FileUtilities.sanitizedFileName(fileName)
            var updated = task; updated.fileName = safeName; updated.folderPath = folder; updated.queueID = queueID; updated.categoryID = categoryID
            if task.canEditRemoteSettings { updated.source.url = url; updated.source.headers = headers; updated.expectedChecksum = checksum; updated.speedLimit = max(0, speedLimit) }
            if task.status == .completed {
                let oldURL = URL(fileURLWithPath: task.filePath); let newBase = try FileUtilities.containedURL(folder: URL(fileURLWithPath: folder), fileName: safeName); let destination = try FileUtilities.resolveConflict(at: newBase, policy: .rename)
                if oldURL != destination, FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.moveItem(at: oldURL, to: destination); updated.fileName = destination.lastPathComponent }
            }
            try await store.updateTask(updated); await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func saveSettings() async {
        guard let store else { return }
        do {
            var value = settings; value.normalize(); try await store.setSettings(value)
            AppLocalization.defaultLanguageCode = value.language ?? "zh-Hans"
            if #available(macOS 13.0, *) {
                do {
                    if value.autoStartOnBoot { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                } catch { lastError = "Login item: \(error.localizedDescription)" }
            }
            await restartREST(using: value.integration)
            if value.clipboardMonitoring { clipboardMonitor?.start() } else { clipboardMonitor?.stop() }
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Batch selection actions -------------------------------------------

    /// Runs `action` over the currently selected (or passed) id snapshot.
    /// Tasks the action does not apply to are skipped — a state mismatch is
    /// not treated as a failure (upstream guards these the same way) — and
    /// only genuine engine/store errors are aggregated into `lastError`.
    /// A single failing item never aborts the rest of the legal items.
    private func batch(_ label: String, ids: Set<Int64>, using action: BatchAction) async {
        guard !ids.isEmpty else { return }
        if let failures = await runBatch(action, ids: ids, visible: visibleTasks) {
            lastError = "\(label)\n" + failures
        }
        await refresh()
    }

    private static func resumableAction(_ perform: @escaping @Sendable (DownloadTask) async throws -> Void) -> BatchAction {
        BatchAction(appliesTo: { $0.status.isResumable }, perform: perform)
    }
    private static func activeAction(_ perform: @escaping @Sendable (DownloadTask) async throws -> Void) -> BatchAction {
        BatchAction(appliesTo: { $0.status.isActive }, perform: perform)
    }
    private static func retryAction(_ perform: @escaping @Sendable (DownloadTask) async throws -> Void) -> BatchAction {
        BatchAction(appliesTo: { $0.status == .failed || $0.status == .stopped }, perform: perform)
    }
    private static func cancelAction(_ perform: @escaping @Sendable (DownloadTask) async throws -> Void) -> BatchAction {
        BatchAction(appliesTo: { !$0.status.isTerminal }, perform: perform)
    }

    func startSelected() async { await batch(AppLocalization.string("error.batchFailure"), ids: selectedIDs, using: Self.resumableAction { [engine] task in try await engine?.start(taskID: task.id) }) }
    func resumeSelected() async { await batch(AppLocalization.string("error.batchFailure"), ids: selectedIDs, using: Self.resumableAction { [engine] task in try await engine?.start(taskID: task.id) }) }
    func pauseSelected() async { await batch(AppLocalization.string("error.batchFailure"), ids: selectedIDs, using: Self.activeAction { [engine] task in try await engine?.pause(taskID: task.id) }) }
    func retrySelected() async { await batch(AppLocalization.string("error.batchFailure"), ids: selectedIDs, using: Self.retryAction { [engine] task in try await engine?.retry(taskID: task.id) }) }
    func cancelSelected() async { await batch(AppLocalization.string("error.batchFailure"), ids: selectedIDs, using: Self.cancelAction { [engine] task in try await engine?.cancel(taskID: task.id) }) }

    /// Batch variants that act on an explicit id snapshot (used by the context
    /// menu, which carries its own selection).
    func start(ids: Set<Int64>) async { await batch(AppLocalization.string("error.batchFailure"), ids: ids, using: Self.resumableAction { [engine] task in try await engine?.start(taskID: task.id) }) }
    func resume(ids: Set<Int64>) async { await batch(AppLocalization.string("error.batchFailure"), ids: ids, using: Self.resumableAction { [engine] task in try await engine?.start(taskID: task.id) }) }
    func pause(ids: Set<Int64>) async { await batch(AppLocalization.string("error.batchFailure"), ids: ids, using: Self.activeAction { [engine] task in try await engine?.pause(taskID: task.id) }) }
    func retry(ids: Set<Int64>) async { await batch(AppLocalization.string("error.batchFailure"), ids: ids, using: Self.retryAction { [engine] task in try await engine?.retry(taskID: task.id) }) }
    func cancel(ids: Set<Int64>) async { await batch(AppLocalization.string("error.batchFailure"), ids: ids, using: Self.cancelAction { [engine] task in try await engine?.cancel(taskID: task.id) }) }

    /// Deletes the tasks captured by `confirmation`; when `alsoDeleteFiles` is
    /// set the completed destination file is removed first (split from the task
    /// deletion so a failure to remove a file does not lose the task). Partial
    /// files of unfinished tasks are cleaned by the engine's `abort` path
    /// without writing a cancellation History record. The selection is pruned
    /// afterwards by `refresh()`.
    func confirmDelete(_ confirmation: DeleteSelectionSummary, alsoDeleteFiles: Bool) async {
        guard !confirmation.ids.isEmpty else { deleteConfirmation = nil; return }
        guard let store else { return }
        if alsoDeleteFiles {
            for id in confirmation.ids {
                guard let task = await store.task(id: id), task.status == .completed else { continue }
                do {
                    let url = try FileUtilities.containedURL(folder: URL(fileURLWithPath: task.folderPath), fileName: task.fileName)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { lastError = error.localizedDescription }
            }
        }
        for id in confirmation.ids {
            await engine?.abort(taskID: id)
            do { try await store.removeTask(id: id) } catch { lastError = error.localizedDescription }
        }
        deleteConfirmation = nil
        await refresh()
    }

    /// Computes the delete confirmation summary for `ids` (defaults to the
    /// current selection) and stores it so a sheet can render the
    /// finished/unfinished mix and the "also delete files" option. Returns
    /// `nil` when there is nothing to delete.
    func requestDeleteConfirmation(ids: Set<Int64>? = nil) -> DeleteSelectionSummary? {
        let source = ids ?? selectedIDs
        guard !source.isEmpty else { return nil }
        let confirmation = DeleteSelectionSummary.classify(Array(visibleTasks.filter { source.contains($0.id) }))
        deleteConfirmation = confirmation
        return confirmation
    }

    func dismissDeleteConfirmation() {
        deleteConfirmation = nil
    }

    private func restartREST(using integration: IntegrationSettings) async {
        await rest?.stop(); rest = nil
        guard integration.enabled else { return }
        do {
            let service = try RESTService(settings: integration, addHandler: { [weak self] operation in try await self?.handle(operation: operation) }, queueProvider: { [weak store] in (await store?.snapshot().queues) ?? [] })
            try await service.start(); rest = service
        } catch { lastError = error.localizedDescription }
    }
}


/// Environment value carrying the language selected in Settings so views can
/// resolve localized strings for the *chosen* language instead of the system
/// language. `NSLocalizedString` always consults the system preference, which
/// would desynchronise counters and alerts from the SwiftUI `.locale`.
private struct AppLanguageKey: EnvironmentKey { static let defaultValue = "zh-Hans" }

extension EnvironmentValues {
    var appLanguage: String { get { self[AppLanguageKey.self] } set { self[AppLanguageKey.self] = newValue } }
}

/// Resolves `.strings` entries for an explicit language, looking inside the app
/// bundle and inside SwiftPM resource bundles so both `xcodebuild` and
/// `swift run` layouts work.
@MainActor
enum AppLocalization {
    static var defaultLanguageCode = "zh-Hans"

    static func bundle(for identifier: String) -> Bundle {
        var candidates: [Bundle] = [.main]
        if let resourceURL = Bundle.main.resourceURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: entries.filter { $0.pathExtension == "bundle" }.compactMap { Bundle(url: $0) })
        }
        for candidate in candidates {
            if let path = candidate.path(forResource: identifier, ofType: "lproj"), let localized = Bundle(path: path) {
                return localized
            }
        }
        return .main
    }

    static func string(_ key: String, language: String? = nil) -> String {
        bundle(for: language ?? defaultLanguageCode).localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, language: String? = nil, _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), arguments: arguments)
    }
}

/// Immutable snapshot taken when a multi-delete is confirmed. The ids are
/// captured once at request time so the sheet and the delete action agree even
/// if the list refreshes in between. The classification logic lives in core
/// (`DeleteSelectionSummary`) so it can be unit tested.
typealias DeleteConfirmation = DeleteSelectionSummary

private func statusKey(_ status: DownloadStatus) -> LocalizedStringKey {
    switch status {
    case .created: "status.created"
    case .downloading: "status.downloading"
    case .paused: "status.paused"
    case .completed: "status.completed"
    case .failed: "status.failed"
    case .stopped: "status.stopped"
    case .cancelled: "status.cancelled"
    case .merging: "status.merging"
    }
}

private func conflictKey(_ value: FileConflictPolicy) -> LocalizedStringKey {
    switch value { case .rename: "conflict.rename"; case .overwrite: "conflict.overwrite"; case .skip: "conflict.skip" }
}

private func themeKey(_ value: ThemeMode) -> LocalizedStringKey {
    switch value { case .system: "theme.system"; case .light: "theme.light"; case .dark: "theme.dark" }
}

private func proxyKey(_ value: ProxySettings.Mode) -> LocalizedStringKey {
    switch value { case .none: "proxy.none"; case .system: "proxy.system"; case .manual: "proxy.manual" }
}

private func updateKey(_ value: UpdateChannel) -> LocalizedStringKey {
    switch value { case .disabled: "update.disabled"; case .stable: "update.stable" }
}

private func completionActionKey(_ value: QueueCompletionAction) -> LocalizedStringKey {
    switch value { case .none: "queue.action.none"; case .quitApplication: "queue.action.quitApplication"; case .sleepComputer: "queue.action.sleepComputer"; case .shutDownComputer: "queue.action.shutDownComputer" }
}

private func weekdayKey(_ value: QueueSchedule.Weekday) -> LocalizedStringKey {
    switch value { case .sunday: "queue.weekday.sunday"; case .monday: "queue.weekday.monday"; case .tuesday: "queue.weekday.tuesday"; case .wednesday: "queue.weekday.wednesday"; case .thursday: "queue.weekday.thursday"; case .friday: "queue.weekday.friday"; case .saturday: "queue.weekday.saturday" }
}

enum SidebarSection: String, CaseIterable, Identifiable { case downloads, queues, categories, history, settings; var id: String { rawValue }; var title: String { rawValue.capitalized }; var icon: String { switch self { case .downloads: "arrow.down.circle"; case .queues: "list.number"; case .categories: "square.grid.2x2"; case .history: "clock"; case .settings: "gear" } } }

struct MainWindow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section(LocalizedStringKey("sidebar.library")) {
                    Label(LocalizedStringKey("downloads.title"), systemImage: SidebarSection.downloads.icon).tag(SidebarSection.downloads)
                    Label(LocalizedStringKey("queues.title"), systemImage: SidebarSection.queues.icon).tag(SidebarSection.queues)
                    Label(LocalizedStringKey("categories.title"), systemImage: SidebarSection.categories.icon).tag(SidebarSection.categories)
                    Label(LocalizedStringKey("history.title"), systemImage: SidebarSection.history.icon).tag(SidebarSection.history)
                }
                Section(LocalizedStringKey("sidebar.application")) {
                    Label(LocalizedStringKey("settings.title"), systemImage: SidebarSection.settings.icon).tag(SidebarSection.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(LocalizedStringKey("app.title"))
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .safeAreaInset(edge: .bottom) { SidebarStatus(model: model) }
        } detail: {
            switch model.section {
            case .downloads:
                if let id = model.primaryTaskID, let task = model.tasks.first(where: { $0.id == id }) {
                    HSplitView {
                        DownloadList(model: model).frame(minWidth: 340, idealWidth: 560)
                        TaskInspector(model: model, task: task, progress: model.progress[id]).frame(minWidth: 360, idealWidth: 420)
                    }
                } else {
                    DownloadList(model: model)
                }
            case .queues: QueueList(model: model)
            case .categories: CategoriesView(model: model)
            case .history: HistoryList(model: model)
            case .settings: SettingsView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            if model.section == .downloads {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.isShowingNewDownload = true } label: { Label(LocalizedStringKey("toolbar.newDownload"), systemImage: "plus") }
                        .help(LocalizedStringKey("toolbar.newDownload"))
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(LocalizedStringKey("toolbar.refresh"))
                    .accessibilityLabel(LocalizedStringKey("toolbar.refresh"))
            }
        }
        .sheet(isPresented: $model.isShowingNewDownload) { NewDownloadSheet(model: model) }
        .alert(LocalizedStringKey("app.title"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) { Button(LocalizedStringKey("common.ok")) {} } message: { Text(model.lastError ?? "") }
        .preferredColorScheme(model.settings.theme == .dark ? .dark : model.settings.theme == .light ? .light : nil)
        .environment(\.locale, Locale(identifier: model.settings.language ?? "zh-Hans"))
            .environment(\.appLanguage, model.settings.language ?? "zh-Hans")
    }
}

struct SidebarStatus: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    var body: some View {
        let active = model.tasks.filter { $0.status.isActive }.count
        let summary = AppLocalization.format("status.activeTotal", language: language, active, model.tasks.count)
        return Text(summary).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12).accessibilityLabel(summary)
    }
}
struct DownloadList: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var showingChecksum = false
    var body: some View {
        Group {
            if model.visibleTasks.isEmpty {
                ContentUnavailableView(LocalizedStringKey("downloads.empty.title"), systemImage: "arrow.down.circle", description: Text(LocalizedStringKey("downloads.empty.description")))
            } else {
                List(selection: Binding(get: { model.selectedIDs }, set: { value in
                    model.replaceSelection(value)
                })) {
                    ForEach(model.visibleTasks) { task in DownloadRow(task: task, progress: model.progress[task.id], onStart: { Task { await model.start(task) } }, onPause: { Task { await model.pause(task) } }, onCancel: { Task { await model.cancel(task) } }, onRetry: { Task { await model.retry(task) } }, onDoubleClick: { Task { await model.openTask(task) } }).tag(task.id) }
                }
                .contextMenu(forSelectionType: Int64.self) { selection in TaskSelectionMenu(model: model, selection: selection) }
                .accessibilityLabel(LocalizedStringKey("downloads.active"))
            }
        }
        .navigationTitle(LocalizedStringKey("downloads.title"))
        .toolbar {
            if !model.isSelectionEmpty && !model.visibleTasks.isEmpty {
                ToolbarItem(placement: .status) { selectionStatus }
            }
            ToolbarItem(placement: .automatic) { Button { model.selectAllVisible(!model.isAllVisibleSelected) } label: { Image(systemName: model.isAllVisibleSelected ? "checkmark.circle.fill" : "checkmark.circle") }.help(LocalizedStringKey(model.isAllVisibleSelected ? "selection.clearAll" : "selection.selectAll")).accessibilityLabel(LocalizedStringKey(model.isAllVisibleSelected ? "selection.clearAll" : "selection.selectAll")) }
            if !model.isSelectionEmpty && !model.visibleTasks.isEmpty {
                ToolbarItem(placement: .confirmationAction) { Menu(LocalizedStringKey("selection.actions")) { selectionMenu } }
            }
            ToolbarItem(placement: .automatic) { Button { showingChecksum = true } label: { Image(systemName: "number") }.help(LocalizedStringKey("toolbar.checksum")).accessibilityLabel(LocalizedStringKey("toolbar.checksum")) }
        }
        .sheet(isPresented: $showingChecksum) { ChecksumToolView() }
        .sheet(isPresented: Binding(get: { model.deleteConfirmation != nil }, set: { presented in if !presented { model.dismissDeleteConfirmation() } })) { DeleteSelectionSheet(model: model) }
    }

    @ViewBuilder var selectionStatus: some View {
        Text(selectionCountLabel).foregroundStyle(.secondary).font(.caption).padding(.horizontal, 8).accessibilityLabel(selectionCountLabel)
    }

    @ViewBuilder var selectionMenu: some View {
        Button(LocalizedStringKey("selection.start")) { Task { await model.resumeSelected() } }
        Button(LocalizedStringKey("selection.pause")) { Task { await model.pauseSelected() } }
        Button(LocalizedStringKey("selection.retry")) { Task { await model.retrySelected() } }
        Divider()
        Button(LocalizedStringKey("selection.cancel")) { Task { await model.cancelSelected() } }
        Button(LocalizedStringKey("common.delete"), role: .destructive) { _ = model.requestDeleteConfirmation() }
    }

    private var selectionCountLabel: String {
        AppLocalization.format("selection.count", language: language, model.selectionCount)
    }
}

/// Context menu shown when right-clicking a row. `selection` is the snapshot
/// SwiftUI passes in for the rows under the cursor, which may differ from
/// `model.selectedIDs` until the binding syncs — so every action resolves
/// against this snapshot, never the model.
///
/// Semantics (matching upstream `onRequestOpenDownloadItemOption`):
/// - Right-click an unselected row: the menu acts on just that row. It is
///   added to the model selection (via `apply()`) so the list and inspector
///   agree with what was clicked, but the batch action itself uses the passed
///   id snapshot so a stale binding cannot leak unrelated tasks in.
/// - Right-click an already-selected multi-selection: the menu acts on the
///   whole selection as shown.
/// - Right-click after a single select: acts on that one row.
struct TaskSelectionMenu: View {
    @ObservedObject var model: AppModel
    let selection: Set<Int64>

    var body: some View {
        Button(LocalizedStringKey("selection.start")) { apply(); Task { await model.resume(ids: selection) } }
        Button(LocalizedStringKey("selection.pause")) { apply(); Task { await model.pause(ids: selection) } }
        Button(LocalizedStringKey("selection.retry")) { apply(); Task { await model.retry(ids: selection) } }
        Divider()
        Button(LocalizedStringKey("selection.cancel")) { apply(); Task { await model.cancel(ids: selection) } }
        Button(LocalizedStringKey("common.delete"), role: .destructive) { apply(); _ = model.requestDeleteConfirmation(ids: selection) }
    }

    /// Mirrors upstream's right-click contract: a right-clicked row that is
    /// not selected replaces the selection. Batch actions still use the
    /// snapshot passed in, so this only affects the inspector/list sync.
    private func apply() {
        if !model.selectedIDs.isSuperset(of: selection) {
            model.replaceSelection(selection)
        }
    }
}

struct DeleteSelectionSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var alsoDeleteFiles = false

    var body: some View {
        Group {
            if let confirmation = model.deleteConfirmation {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey("selection.deleteTitle")).font(.title2.bold())
                    Text(deleteMessage).foregroundStyle(.secondary)
                    if confirmation.hasFinished {
                        Toggle(LocalizedStringKey("selection.deleteFiles"), isOn: $alsoDeleteFiles)
                    }
                    HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("common.delete"), role: .destructive) { dismiss(); Task { await model.confirmDelete(confirmation, alsoDeleteFiles: alsoDeleteFiles) } } }
                }.padding(24).frame(width: 480)
            }
        }
        .onAppear { alsoDeleteFiles = false }
        .onChange(of: model.deleteConfirmation?.ids) { alsoDeleteFiles = false }
    }
    private var deleteMessage: String {
        guard let confirmation = model.deleteConfirmation else { return "" }
        if confirmation.hasFinished && confirmation.hasUnfinished { return AppLocalization.format("selection.deleteMixed", language: language, confirmation.ids.count) }
        if confirmation.hasFinished { return AppLocalization.format("selection.deleteFinished", language: language, confirmation.ids.count) }
        return AppLocalization.format("selection.deleteUnfinished", language: language, confirmation.ids.count)
    }
}

struct DownloadRow: View {
    let task: DownloadTask; let progress: DownloadProgress?; let onStart: () -> Void; let onPause: () -> Void; let onCancel: () -> Void; let onRetry: () -> Void; let onDoubleClick: () -> Void
    @Environment(\.appLanguage) private var language
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { Text(task.fileName).lineLimit(1); HStack { ProgressView(value: task.progress); statusLabel.font(.caption).foregroundStyle(.secondary) } }
            Spacer(); if task.status == .downloading { Button(action: onPause) { Image(systemName: "pause.fill") }.buttonStyle(.borderless).accessibilityLabel(Text(pauseLabel)) } else if task.status.isResumable { Button(action: onStart) { Image(systemName: "play.fill") }.buttonStyle(.borderless).accessibilityLabel(Text(startLabel)) }; if task.status.isActive { Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(Text(cancelLabel)) }
        }.padding(.vertical, 5).onTapGesture(count: 2, perform: { onDoubleClick() })
    }
    var icon: String { switch task.status { case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .paused: "pause.circle"; case .downloading: "arrow.down.circle.fill"; default: "circle" } }
    var color: Color { task.status == .failed ? .red : task.status == .completed ? .green : .accentColor }
    @ViewBuilder var statusLabel: some View { if let progress { Text("\(Int((progress.total.map { Double(progress.downloaded) / Double(max(1, $0)) } ?? task.progress) * 100))% · \(formatBytes(progress.bytesPerSecond))/s") } else { Text(statusKey(task.status)) } }
    private var pauseLabel: String { AppLocalization.format("task.pauseFormat", language: language, task.fileName) }
    private var startLabel: String { AppLocalization.format("task.startFormat", language: language, task.fileName) }
    private var cancelLabel: String { AppLocalization.format("task.cancelFormat", language: language, task.fileName) }
    func formatBytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}

struct TaskInspector: View {
    @ObservedObject var model: AppModel
    let task: DownloadTask
    let progress: DownloadProgress?
    @State private var editing = false
    var body: some View {
        Form {
            LabeledContent(LocalizedStringKey("task.file"), value: task.fileName); LabeledContent { Text(statusKey(task.status)) } label: { Text(LocalizedStringKey("task.status")) }; LabeledContent(LocalizedStringKey("task.destination"), value: task.folderPath)
            if let total = task.totalSize { LabeledContent(LocalizedStringKey("task.size"), value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            LabeledContent(LocalizedStringKey("task.connections"), value: "\(task.connectionCount)")
            if let speed = progress?.bytesPerSecond { LabeledContent(LocalizedStringKey("task.speed"), value: ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
            if let eta = progress?.eta { LabeledContent(LocalizedStringKey("task.remaining"), value: Duration.seconds(eta).formatted(.time(pattern: .hourMinuteSecond))) }
            if let error = task.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button(LocalizedStringKey("task.edit")) { editing = true }.disabled(!task.canEdit)
                if task.status == .completed { Button(LocalizedStringKey("task.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: task.filePath)) }; Button(LocalizedStringKey("task.reveal")) { NSWorkspace.shared.selectFile(task.filePath, inFileViewerRootedAtPath: task.folderPath) } }
            }
        }.formStyle(.grouped).padding().navigationTitle(LocalizedStringKey("task.details")).accessibilityElement(children: .contain).sheet(isPresented: $editing) { EditTaskSheet(model: model, task: task) }
    }
}

struct EditTaskSheet: View {
    @ObservedObject var model: AppModel
    let task: DownloadTask
    @State private var name: String; @State private var folder: String; @State private var url: String
    @State private var queueID: Int64?; @State private var categoryID: Int64?; @State private var headers = ""; @State private var checksum: String; @State private var speed: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, task: DownloadTask) { self.model = model; self.task = task; _name = State(initialValue: task.fileName); _folder = State(initialValue: task.folderPath); _url = State(initialValue: task.source.url.absoluteString); _queueID = State(initialValue: task.queueID); _categoryID = State(initialValue: task.categoryID); _checksum = State(initialValue: task.expectedChecksum ?? ""); _speed = State(initialValue: String(task.speedLimit)) }
    var body: some View {
        Form {
            TextField(LocalizedStringKey("task.fileName"), text: $name); TextField(LocalizedStringKey("task.folder"), text: $folder); TextField(LocalizedStringKey("task.url"), text: $url).disabled(task.status == .completed)
            HStack { Picker(LocalizedStringKey("newDownload.queue"), selection: $queueID) { Text(LocalizedStringKey("newDownload.noQueue")).tag(Int64?.none); ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) } }; Picker(LocalizedStringKey("newDownload.category"), selection: $categoryID) { Text(LocalizedStringKey("newDownload.automatic")).tag(Int64?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } } }
            TextField(LocalizedStringKey("host.headers"), text: $headers).disabled(task.status == .completed); TextField(LocalizedStringKey("toolbar.checksum"), text: $checksum).disabled(task.status == .completed); TextField(LocalizedStringKey("host.speed"), text: $speed).disabled(task.status == .completed)
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) { let parsed = Dictionary(uniqueKeysWithValues: headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> (String, String)? in let pair = line.split(separator: ":", maxSplits: 1).map(String.init); guard pair.count == 2 else { return nil }; return (pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces)) }); Task { await model.editTask(task, fileName: name, folder: folder, urlText: url, queueID: queueID, categoryID: categoryID, headers: parsed, checksum: checksum.isEmpty ? nil : checksum, speedLimit: Int64(speed) ?? 0); dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 650)
    }
}

struct NewDownloadSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var links = ""
    @State private var batchPattern = ""
    @State private var batchStart = "0"
    @State private var batchEnd = "0"
    @State private var batchPadding = "0"
    @State private var folder = AppSettings.defaultDownloadFolderPath
    @State private var headers = ""
    @State private var checksum = ""
    @State private var speed = "0"
    @State private var queueID: Int64?
    @State private var categoryID: Int64?
    @State private var conflict: FileConflictPolicy = .rename
    @State private var start = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("newDownload.title")).font(.title2.bold())
            Text(LocalizedStringKey("newDownload.linksHelp")).foregroundStyle(.secondary)
            TextEditor(text: $links).frame(minHeight: 105).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            DisclosureGroup(LocalizedStringKey("newDownload.batch")) {
                TextField("https://example.test/file-*.bin", text: $batchPattern)
                HStack { TextField(LocalizedStringKey("newDownload.from"), text: $batchStart); TextField(LocalizedStringKey("newDownload.to"), text: $batchEnd); TextField(LocalizedStringKey("newDownload.padding"), text: $batchPadding) }
                if let count = batchCount { Text(AppLocalization.format("newDownload.preview", language: language, count)).font(.caption).foregroundStyle(.secondary) }
            }
            HStack { TextField(LocalizedStringKey("newDownload.destination"), text: $folder); Button(LocalizedStringKey("newDownload.choose")) { chooseFolder() } }
            TextField(LocalizedStringKey("newDownload.headers"), text: $headers)
            HStack {
                TextField(LocalizedStringKey("newDownload.checksum"), text: $checksum)
                TextField(LocalizedStringKey("newDownload.taskLimit"), text: $speed)
            }
            HStack {
                Picker(LocalizedStringKey("newDownload.queue"), selection: $queueID) {
                    Text(LocalizedStringKey("newDownload.noQueue")).tag(Int64?.none)
                    ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(LocalizedStringKey("newDownload.category"), selection: $categoryID) {
                    Text(LocalizedStringKey("newDownload.automatic")).tag(Int64?.none)
                    ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(LocalizedStringKey("newDownload.conflict"), selection: $conflict) { ForEach(FileConflictPolicy.allCases) { Text(conflictKey($0)).tag($0) } }
            }
            Toggle(LocalizedStringKey("newDownload.startImmediately"), isOn: $start)
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("newDownload.add")) {
                let parsedHeaders = Dictionary(uniqueKeysWithValues: headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> (String, String)? in let pair = line.split(separator: ":", maxSplits: 1).map(String.init); guard pair.count == 2 else { return nil }; return (pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces)) })
                Task {
                    if !batchPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await model.addBatch(pattern: batchPattern, start: Int(batchStart) ?? -1, end: Int(batchEnd) ?? -1, padding: Int(batchPadding) ?? 0, folder: folder, queueID: queueID, startImmediately: start)
                    } else {
                        await model.addLinks(links, folder: folder, start: start, headers: parsedHeaders, checksum: checksum.isEmpty ? nil : checksum, queueID: queueID, categoryID: categoryID, conflict: conflict, speedLimit: Int64(speed) ?? 0)
                    }
                    dismiss()
                }
            }.keyboardShortcut(.defaultAction).disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 650)
    }
    private var batchCount: Int? { guard let start = Int(batchStart), let end = Int(batchEnd), end >= start else { return nil }; return end - start + 1 }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { folder = url.path; Task { try? await model.bookmarkStore?.store(url: url) } } }
}

struct QueueList: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var showingNewQueue = false
    @State private var editingQueue: DownloadQueue?
    var body: some View {
        List {
            ForEach(model.queues.sorted { $0.order < $1.order }) { queue in
                HStack {
                    Button { Task { await model.toggleQueue(queue) } } label: { Image(systemName: queue.isRunning ? "play.circle.fill" : "pause.circle") }.buttonStyle(.borderless).accessibilityLabel(queue.isRunning ? "Stop \(queue.name)" : "Start \(queue.name)")
                    Text(queue.name)
                    Button { editingQueue = queue } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("queue.edit"))
                    Spacer()
                    Text(AppLocalization.format("task.maxConnections", language: language, queue.concurrencyLimit)).font(.caption).foregroundStyle(.secondary)
                    if model.queues.count > 1 { Button { Task { await model.deleteQueue(queue) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("common.delete")) }
                }
            }
            .onMove { offsets, destination in
                let ids = model.queues.sorted { $0.order < $1.order }.map(\.id)
                var reordered = ids; reordered.move(fromOffsets: offsets, toOffset: destination)
                Task { try? await model.store?.reorderQueues(ids: reordered); await model.refresh() }
            }
        }
        .toolbar { Button { showingNewQueue = true } label: { Label(LocalizedStringKey("queue.new"), systemImage: "plus") } }
        .navigationTitle(LocalizedStringKey("queues.title"))
        .sheet(isPresented: $showingNewQueue) { NewQueueSheet(model: model) }
        .sheet(item: $editingQueue) { QueueEditSheet(model: model, queue: $0) }
    }
}

struct NewQueueSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var name = ""
    @State private var concurrency = 1
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form { TextField(LocalizedStringKey("queue.name"), text: $name); Stepper(AppLocalization.format("queue.concurrentCount", language: language, concurrency), value: $concurrency, in: 1...64); HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("common.create")) { Task { await model.addQueue(name: name, concurrency: concurrency); dismiss() } }.keyboardShortcut(.defaultAction) } }.padding().frame(width: 420)
    }
}

struct QueueEditSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State var queue: DownloadQueue
    @State private var scheduleEnabled: Bool
    @State private var startText: String
    @State private var endText: String
    @State private var weekdays: Set<QueueSchedule.Weekday>
    @State private var showPowerConfirmation = false
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, queue: DownloadQueue) { self.model = model; _queue = State(initialValue: queue); let schedule = queue.schedule ?? QueueSchedule(); _scheduleEnabled = State(initialValue: queue.schedule != nil); _startText = State(initialValue: QueueEditSheet.time(schedule.startSeconds)); _endText = State(initialValue: QueueEditSheet.time(schedule.endSeconds)); _weekdays = State(initialValue: schedule.weekdays) }
    var body: some View {
        Form {
            TextField(LocalizedStringKey("queue.name"), text: $queue.name)
            Stepper(AppLocalization.format("queue.concurrentCount", language: language, queue.concurrencyLimit), value: $queue.concurrencyLimit, in: 1...64)
            Toggle(LocalizedStringKey("queue.schedule"), isOn: $scheduleEnabled)
            if scheduleEnabled {
                HStack { TextField(LocalizedStringKey("queue.start"), text: $startText); TextField(LocalizedStringKey("queue.end"), text: $endText) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) { ForEach(QueueSchedule.Weekday.allCases, id: \.self) { day in Toggle(weekdayKey(day), isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } })) } }
                Text(LocalizedStringKey("queue.overnight")).font(.caption).foregroundStyle(.secondary)
            }
            Picker(LocalizedStringKey("queue.completion"), selection: $queue.completionAction) { ForEach(QueueCompletionAction.allCases) { Text(completionActionKey($0)).tag($0) } }
            Text(LocalizedStringKey("queue.completionWarning")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) { if queue.completionAction.isPowerAction { showPowerConfirmation = true } else { save() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 520).alert(LocalizedStringKey("queue.confirmTitle"), isPresented: $showPowerConfirmation) { Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}; Button(LocalizedStringKey("queue.enable")) { save() } } message: { Text(LocalizedStringKey("queue.confirmMessage")) }
    }
    private func save() { var value = queue; if scheduleEnabled, let start = QueueEditSheet.seconds(startText), let end = QueueEditSheet.seconds(endText) { value.schedule = QueueSchedule(weekdays: weekdays, startSeconds: start, endSeconds: end) } else { value.schedule = nil }; Task { await model.updateQueue(value); dismiss() } }
    static func seconds(_ text: String) -> Int? { let pair = text.split(separator: ":").compactMap { Int($0) }; guard pair.count == 2, pair[0] >= 0, pair[0] < 24, pair[1] >= 0, pair[1] < 60 else { return nil }; return pair[0] * 3600 + pair[1] * 60 }
    static func time(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60) }
}

struct HistoryList: View { @ObservedObject var model: AppModel; var body: some View { List(model.history) { record in VStack(alignment: .leading) { Text(record.name); Text(record.finishedAt.formatted()).font(.caption).foregroundStyle(.secondary); Button(LocalizedStringKey("history.reveal")) { NSWorkspace.shared.selectFile(record.folderPath + "/" + record.fileName, inFileViewerRootedAtPath: record.folderPath) }.buttonStyle(.link) } }.toolbar { Button(LocalizedStringKey("history.clear")) { Task { guard let store = model.store else { return }; try? await store.clearHistory(); await model.refresh() } } }.navigationTitle(LocalizedStringKey("history.title")) } }

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    var body: some View {
        Form {
            Section(LocalizedStringKey("settings.appearance")) {
                Picker(LocalizedStringKey("settings.theme"), selection: $model.settings.theme) { ForEach(ThemeMode.allCases) { Text(themeKey($0)).tag($0) } }
                Picker(LocalizedStringKey("settings.language"), selection: Binding(get: { model.settings.language ?? "zh-Hans" }, set: { model.settings.language = $0 })) { Text(LocalizedStringKey("language.zhHans")).tag("zh-Hans"); Text(LocalizedStringKey("language.english")).tag("en") }
                Toggle(LocalizedStringKey("settings.clipboard"), isOn: $model.settings.clipboardMonitoring)
            }
            Section(LocalizedStringKey("downloads.title")) {
                Stepper(AppLocalization.format("settings.connectionCount", language: language, model.settings.threadCount), value: $model.settings.threadCount, in: 1...64)
                Stepper(AppLocalization.format("settings.concurrentCount", language: language, model.settings.maxConcurrentDownloads), value: $model.settings.maxConcurrentDownloads, in: 1...64)
                TextField(LocalizedStringKey("settings.folder"), text: $model.settings.defaultDownloadFolder)
                TextField(LocalizedStringKey("settings.userAgent"), text: $model.settings.userAgent)
                TextField(LocalizedStringKey("settings.globalSpeed"), value: $model.settings.speedLimit, format: .number)
                Toggle(LocalizedStringKey("settings.deletePartial"), isOn: $model.settings.deletePartialFileOnDownloadCancellation)
            }
            Section(LocalizedStringKey("settings.proxyTLS")) {
                Picker(LocalizedStringKey("settings.proxy"), selection: $model.settings.proxy.mode) { ForEach(ProxySettings.Mode.allCases) { Text(proxyKey($0)).tag($0) } }
                TextField(LocalizedStringKey("settings.proxyHost"), text: $model.settings.proxy.host)
                TextField(LocalizedStringKey("settings.proxyPort"), value: $model.settings.proxy.port, format: .number)
                TextField(LocalizedStringKey("settings.proxyUser"), text: $model.settings.proxy.username)
                SecureField(LocalizedStringKey("settings.proxyPassword"), text: $model.settings.proxy.password)
                Toggle(LocalizedStringKey("settings.insecureTLS"), isOn: $model.settings.tls.allowInsecureCertificates)
            }
            Section(LocalizedStringKey("settings.integration")) {
                Toggle(LocalizedStringKey("settings.rest"), isOn: $model.settings.integration.enabled)
                TextField(LocalizedStringKey("settings.apiPort"), value: $model.settings.integration.port, format: .number)
                Toggle(LocalizedStringKey("settings.useAPIKey"), isOn: $model.settings.integration.authEnabled)
                SecureField(LocalizedStringKey("settings.apiKey"), text: $model.settings.integration.apiKey)
                Text(AppLocalization.format("settings.boundLoopback", language: language, model.settings.integration.port)).font(.caption).foregroundStyle(.secondary)
            }
            HostOverridesView(model: model)
            Section(LocalizedStringKey("settings.notifications")) {
                Toggle(LocalizedStringKey("settings.sound"), isOn: $model.settings.notifications.soundEnabled)
                Toggle(LocalizedStringKey("settings.completionNotifications"), isOn: $model.settings.notifications.showCompletionDialog)
                Toggle(LocalizedStringKey("settings.login"), isOn: $model.settings.autoStartOnBoot)
                Picker(LocalizedStringKey("settings.updateChannel"), selection: $model.settings.updateChannel) { ForEach(UpdateChannel.allCases) { Text(updateKey($0)).tag($0) } }
                Text(LocalizedStringKey("settings.updateNote")).font(.caption).foregroundStyle(.secondary)
            }
            Button(LocalizedStringKey("settings.save")) { Task { await model.saveSettings() } }.keyboardShortcut(.defaultAction)
        }.formStyle(.grouped).padding().navigationTitle(LocalizedStringKey("settings.title"))
    }
}

struct MenuBarView: View { @ObservedObject var model: AppModel; @Environment(\.appLanguage) private var language; var body: some View { Text(AppLocalization.format("menubar.active", language: language, model.tasks.filter { $0.status.isActive }.count)); Divider(); Button(LocalizedStringKey("toolbar.newDownload")) { model.isShowingNewDownload = true }; Button(LocalizedStringKey("menubar.open")) { NSApp.activate(ignoringOtherApps: true) }; Divider(); Button(LocalizedStringKey("menubar.quit")) { NSApp.terminate(nil) } } }
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    private var inDownloads: Bool { model.section == .downloads }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(LocalizedStringKey("toolbar.newDownload")) { model.isShowingNewDownload = true }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu(LocalizedStringKey("downloads.title")) {
            Button(LocalizedStringKey("commands.selectAll")) {
                guard inDownloads else { return }
                model.selectAllVisible(!model.isAllVisibleSelected)
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!inDownloads)
            Button(LocalizedStringKey("commands.deleteSelected")) {
                guard inDownloads else { return }
                _ = model.requestDeleteConfirmation()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Divider()
            Button(LocalizedStringKey("commands.startSelected")) {
                guard inDownloads else { return }
                Task { await model.startSelected() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(LocalizedStringKey("commands.pauseSelected")) {
                guard inDownloads else { return }
                Task { await model.pauseSelected() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(LocalizedStringKey("commands.resumeSelected")) {
                guard inDownloads else { return }
                Task { await model.resumeSelected() }
            }
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(LocalizedStringKey("commands.retrySelected")) {
                guard inDownloads else { return }
                Task { await model.retrySelected() }
            }
            .disabled(!inDownloads || model.isSelectionEmpty)
        }
    }
}

struct CategoriesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var editing: DownloadCategory?
    @State private var deleting: DownloadCategory?
    var body: some View {
        List {
            ForEach(model.categories.sorted { $0.order < $1.order }) { category in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.tint)
                    VStack(alignment: .leading) { Text(category.name); Text(category.acceptedFileTypes.isEmpty ? AppLocalization.string("category.allFileTypes", language: language) : category.acceptedFileTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); if let path = category.defaultFolder { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Button { editing = category } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("category.edit"))
                    Button { deleting = category } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("common.delete"))
                }
            }
            .onMove { offsets, destination in var ids = model.categories.sorted { $0.order < $1.order }.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination); Task { try? await model.store?.reorderCategories(ids: ids); await model.refresh() } }
        }
        .toolbar { Button { editing = DownloadCategory(id: 0, name: "", order: model.categories.count) } label: { Label(LocalizedStringKey("category.new"), systemImage: "plus") } }
        .navigationTitle(LocalizedStringKey("categories.title"))
        .sheet(item: $editing) { CategoryEditorSheet(model: model, category: $0) }
        .alert(LocalizedStringKey("category.deleteTitle"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}; Button(LocalizedStringKey("common.delete"), role: .destructive) { if let deleting { Task { await model.deleteCategory(deleting) } } } } message: { Text(LocalizedStringKey("category.deleteMessage")) }
    }
}

struct CategoryEditorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State var category: DownloadCategory
    @State private var extensions: String
    @State private var hosts: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, category: DownloadCategory) { self.model = model; _category = State(initialValue: category); _extensions = State(initialValue: category.acceptedFileTypes.joined(separator: ", ")); _hosts = State(initialValue: category.acceptedURLPatterns.joined(separator: ", ")) }
    var body: some View {
        Form {
            TextField(LocalizedStringKey("category.name"), text: $category.name)
            TextField(LocalizedStringKey("category.extensions"), text: $extensions)
            TextField(LocalizedStringKey("category.patterns"), text: $hosts)
            HStack { Text(category.defaultFolder ?? AppLocalization.string("category.noFolder", language: language)).lineLimit(1); Button(LocalizedStringKey("newDownload.choose")) { chooseFolder() }; if category.defaultFolder != nil { Button(LocalizedStringKey("category.clear")) { category.defaultFolder = nil } } }
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) { category.acceptedFileTypes = split(extensions); category.acceptedURLPatterns = split(hosts); Task { if category.id == 0 { await model.addCategory(name: category.name, extensions: category.acceptedFileTypes, hosts: category.acceptedURLPatterns, folder: category.defaultFolder) } else { await model.saveCategory(category) }; dismiss() } }.keyboardShortcut(.defaultAction).disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding().frame(width: 560)
    }
    private func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { category.defaultFolder = panel.url?.path } }
}

struct HostOverridesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: HostOverride?
    var body: some View {
        Section(LocalizedStringKey("host.title")) {
            ForEach(model.hostOverrides) { value in
                HStack { Text(value.host); Spacer(); Text(value.threadCount.map(String.init) ?? "global").font(.caption); Button { editing = value } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("host.edit")); Button { Task { await model.deleteHostOverride(value) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("host.delete")) }
            }
            Button(LocalizedStringKey("host.add")) { editing = HostOverride(host: "") }
        }.sheet(item: $editing) { HostOverrideEditorSheet(model: model, value: $0) }
    }
}

struct HostOverrideEditorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State var value: HostOverride
    @State private var threads: String; @State private var speed: String; @State private var headers: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, value: HostOverride) { self.model = model; _value = State(initialValue: value); _threads = State(initialValue: value.threadCount.map(String.init) ?? ""); _speed = State(initialValue: value.speedLimit.map(String.init) ?? ""); _headers = State(initialValue: value.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")) }
    var body: some View {
        Form {
            TextField(LocalizedStringKey("host.name"), text: $value.host)
            HStack { Text(value.defaultFolder ?? AppLocalization.string("category.noFolder", language: language)).lineLimit(1); Button(LocalizedStringKey("newDownload.choose")) { chooseFolder() }; if value.defaultFolder != nil { Button(LocalizedStringKey("category.clear")) { value.defaultFolder = nil } } }
            Picker(LocalizedStringKey("host.defaultCategory"), selection: $value.categoryID) { Text(LocalizedStringKey("common.none")).tag(Int64?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } }
            TextField(LocalizedStringKey("task.connections"), text: $threads); TextField(LocalizedStringKey("host.speed"), text: $speed); TextField(LocalizedStringKey("host.headers"), text: $headers)
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) { let pairs = headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> (String, String)? in let parts = line.split(separator: ":", maxSplits: 1).map(String.init); guard parts.count == 2 else { return nil }; return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)) }; Task { await model.saveHostOverride(host: value.host, headers: Dictionary(uniqueKeysWithValues: pairs), threadCount: Int(threads), speedLimit: Int64(speed), defaultFolder: value.defaultFolder, categoryID: value.categoryID); dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 620)
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { value.defaultFolder = panel.url?.path } }
}
