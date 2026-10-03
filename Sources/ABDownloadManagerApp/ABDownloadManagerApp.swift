import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import AppIntents
import ABDownloadManagerCore
import Darwin

private var verificationBuildRequiresIsolation: Bool {
    Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String == "YES"
}


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
        WindowGroup {
            MainWindow(model: model)
                .defaultAppStorage(applicationDefaults())
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
                .preferredColorScheme(model.settings.theme.appearanceOverride.colorScheme)
        }
            .defaultSize(width: 1100, height: 720)
            .commands { AppCommands(model: model) }
        MenuBarExtra(LocalizedStringKey("app.title"), systemImage: "arrow.down.circle") {
            MenuBarView(model: model)
                .defaultAppStorage(applicationDefaults())
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
                .preferredColorScheme(model.settings.theme.appearanceOverride.colorScheme)
        }
        Settings {
            SettingsView(model: model)
                .defaultAppStorage(applicationDefaults())
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
                .dynamicTypeSize(dynamicTypeCategory(for: model.settings.uiScale ?? 1.0))
                .preferredColorScheme(model.settings.theme.appearanceOverride.colorScheme)
        }
    }
}

private func applicationDefaults() -> UserDefaults {
    let environment = ProcessInfo.processInfo.environment
    let verificationMarker = Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String
    if verificationMarker == "YES" {
        guard let suiteName = environment["ABDM_USER_DEFAULTS_SUITE"],
              let suite = UserDefaults(suiteName: suiteName) else {
            fatalError("Verification build could not create its isolated UserDefaults suite.")
        }
        return suite
    }
    if let suiteName = environment["ABDM_USER_DEFAULTS_SUITE"], !suiteName.isEmpty {
        guard let suite = UserDefaults(suiteName: suiteName) else {
            fatalError("ABDM_USER_DEFAULTS_SUITE could not be created.")
        }
        return suite
    }
    if [environment["ABDM_STATE_DIRECTORY"], environment["ABDM_DOWNLOAD_DIRECTORY"]]
        .contains(where: { value in value.map { !$0.isEmpty } ?? false }) {
        fatalError("Isolated app storage requires ABDM_USER_DEFAULTS_SUITE.")
    }
    return .standard
}

private func appLocale(_ language: String?) -> Locale {
    Locale(identifier: SupportedAppLanguage.foundationIdentifier(for: language ?? SupportedAppLanguage.defaultCode))
}

struct PendingRESTAddDraft: Identifiable {
    let id = UUID()
    let operation: RESTAddOperation
}

extension AppearanceOverride {
    /// SwiftUI-facing mapping. `nil` hands appearance control back to macOS so
    /// System mode tracks live system changes; otherwise the value is forced.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private func dynamicTypeCategory(for scale: Double) -> DynamicTypeSize {
    switch scale {
    case ..<0.9: .small
    case ..<1.05: .medium
    case ..<1.2: .large
    case ..<1.35: .xLarge
    case ..<1.5: .xxLarge
    default: .xxxLarge
    }
}

private struct SystemQueueCompletionActionExecutor: QueueCompletionActionExecutor {
    func execute(_ action: QueueCompletionAction) async throws {
        switch action {
        case .none:
            return
        case .quitApplication, .sleepComputer, .shutDownComputer:
            guard !verificationBuildRequiresIsolation else {
                throw NSError(domain: "QueueCompletionAction", code: 78, userInfo: [NSLocalizedDescriptionKey: "System completion actions are disabled in verification builds."])
            }
        }
        switch action {
        case .none:
            return
        case .quitApplication:
            await MainActor.run { NSApp.terminate(nil) }
        case .sleepComputer:
            try await Self.run(executable: "/usr/bin/pmset", arguments: ["sleepnow"])
        case .shutDownComputer:
            try await Self.run(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"System Events\" to shut down"])
        }
    }

    private static func run(executable: String, arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "QueueCompletionAction", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"])
            }
        }.value
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if verificationBuildRequiresIsolation
            || ProcessInfo.processInfo.environment["ABDM_SUPPRESS_PERMISSION_PROMPT"] == "1" { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var visibleTasks: [DownloadTask] = []
    @Published private(set) var filteredTasks: [DownloadTask] = []
    @Published private(set) var projectionRevision: UInt64 = 0
    @Published private(set) var queues: [DownloadQueue] = []
    @Published private(set) var history: [DownloadRecord] = []
    @Published private(set) var categories: [DownloadCategory] = []
    @Published private(set) var hostOverrides: [HostOverride] = []
    @Published private var settingsDraft = SettingsDraft()
    var settings: AppSettings {
        get { settingsDraft.value }
        set { settingsDraft.updateDraft(newValue) }
    }
    /// Multi-selection over the currently visible task ids. The list view
    /// binds its native selection directly to this value; ids are pruned in
    /// `refresh()` so selection can never outlive its tasks.
    @Published var selectedIDs: Set<Int64> = Set<Int64>()
    /// The anchor task for the inspector / double-click target. Remains one of
    /// the selected ids when possible and is kept in sync by `setSelection`.
    @Published var primaryTaskID: Int64?
    @Published var section: SidebarSection = .downloads
    @Published var downloadSearch = "" { didSet { rebuildTaskProjection(); pruneSelection() } }
    @Published var statusFilter = "all" { didSet { rebuildTaskProjection(); pruneSelection() } }
    @Published var categoryFilter: Int64? { didSet { rebuildTaskProjection(); pruneSelection() } }
    @Published var queueFilter: Int64? { didSet { rebuildTaskProjection(); pruneSelection() } }
    @Published var settingsScrollTarget: String?
    @Published private(set) var taskSortField = "createdAt"
    @Published private(set) var taskSortAscending = false
    @Published var isShowingNewDownload = false
    @Published private(set) var newDownloadSessionID = UUID()
    @Published private(set) var newDownloadPrefill = ""
    @Published private(set) var newDownloadStartsInBatchMode = false
    @Published private(set) var pendingRESTAddDraft: PendingRESTAddDraft?
    @Published var isShowingProgressDialog = false
    @Published var isShowingSettings = false
    @Published var isShowingChecksum = false
    @Published private(set) var checksumFileURLs: [URL] = []
    @Published var editingTask: DownloadTask?
    @Published var lastError: String?
    @Published var updateStatus: String?
    @Published var isCheckingUpdates = false
    @Published var isDownloadingUpdate = false
    @Published private(set) var availableUpdate: UpdateManifest?
    @Published private(set) var downloadedUpdateURL: URL?
    @Published var progress: [Int64: DownloadProgress] = [:]
    @Published private(set) var progressRevision: UInt64 = 0
    @Published private(set) var progressDialogTaskIDs: [Int64] = []
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
    private var currentNotificationSound: NSSound?
    private let queueCompletionRunner = QueueCompletionActionRunner(executor: SystemQueueCompletionActionExecutor())
    private var restAddConfirmationQueue = RESTAddConfirmationQueue()

    init() {
        let environment = ProcessInfo.processInfo.environment
        let verificationMarker = Bundle.main.object(forInfoDictionaryKey: "ABDMRequiresIsolation") as? String
        if verificationMarker == "YES" {
            do {
                _ = try VerificationLaunchConfiguration.validateIfRequired(
                    marker: verificationMarker,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    environment: environment
                )
            } catch {
                fputs("[verification-fail-closed] \(error.localizedDescription)\n", stderr)
                Darwin.exit(78)
            }
        }
        if let stateStore = try? AppStateStore() {
            store = stateStore
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
                await MainActor.run {
                    self.progress[event.taskID] = event
                    self.progressRevision &+= 1
                }
            }
        }
        clipboardMonitor = ClipboardMonitor { [weak self] links in
            guard let self else { return }
            Task { await self.addLinks(links.joined(separator: "\n"), folder: self.settings.defaultDownloadFolder, start: false) }
        }
        if settings.clipboardMonitoring && !clipboardMonitoringSuppressed { clipboardMonitor?.start() }
        Task { [weak self] in await self?.bootstrap() }
    }

    deinit { refreshTask?.cancel(); progressTask?.cancel() }

    private var clipboardMonitoringSuppressed: Bool {
        verificationBuildRequiresIsolation
            || ProcessInfo.processInfo.environment["ABDM_SUPPRESS_CLIPBOARD_MONITOR"] == "1"
    }

    func bootstrap() async {
        guard let store else { return }
        var snapshot = await store.snapshot()
        if snapshot.settings.language == nil {
            snapshot.settings.language = "zh-Hans"
            try? await store.setSettings(snapshot.settings)
        }
        settingsDraft = SettingsDraft(persisted: sanitized(snapshot.settings)); tasks = snapshot.tasks; rebuildTaskProjection(); queues = snapshot.queues; history = snapshot.history; categories = snapshot.categories; hostOverrides = snapshot.hostOverrides
        try? settings.dns.applyToDefaultPrivacyContext()
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

    func beginNewDownload(prefillFromClipboard: Bool = false, batchMode: Bool = false) {
        newDownloadPrefill = prefillFromClipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : ""
        newDownloadStartsInBatchMode = batchMode
        newDownloadSessionID = UUID()
        isShowingNewDownload = true
    }

    func openSettings(target: String? = nil) {
        settingsScrollTarget = target
        section = .settings
    }

    func refresh() async {
        guard let store else { return }
        let snapshot = await store.snapshot()
        // SettingsView owns an explicit draft. Store refreshes may update the
        // draft's persisted/cancel target, but never replace active edits.
        let persistedSettings = sanitized(snapshot.settings)
        if settingsDraft.persisted != persistedSettings {
            settingsDraft.receivePersisted(persistedSettings)
        }
        let tasksChanged = tasks != snapshot.tasks
        let queuesChanged = queues != snapshot.queues
        if tasksChanged { tasks = snapshot.tasks; rebuildTaskProjection() }
        if queuesChanged { queues = snapshot.queues }
        if history != snapshot.history { history = snapshot.history }
        if categories != snapshot.categories { categories = snapshot.categories }
        if hostOverrides != snapshot.hostOverrides { hostOverrides = snapshot.hostOverrides }
        guard tasksChanged || queuesChanged else { return }
        if tasksChanged {
            pruneSelection()
            notifyForFinishedTasks(snapshot.tasks)
        }
        do { try await queueCompletionRunner.observe(queues: snapshot.queues, tasks: snapshot.tasks) }
        catch { lastError = error.localizedDescription }
    }

    /// Applies verification-only environment overrides to the persisted settings.
    /// Production launches (no env) are untouched.
    private func sanitized(_ settings: AppSettings) -> AppSettings {
        AppStateStore.sanitizedSettings(settings)
    }

    /// Updates the virtualized table input only when task data or a filter
    /// changes. Unrelated progress/settings publications reuse these arrays.
    private func rebuildTaskProjection() {
        let projection = DownloadTaskListProjection(
            tasks: tasks,
            search: downloadSearch,
            status: statusFilter,
            categoryID: categoryFilter,
            queueID: queueFilter,
            sortField: taskSortField,
            sortAscending: taskSortAscending
        )
        visibleTasks = projection.visible
        filteredTasks = projection.filtered
        projectionRevision &+= 1
    }

    func setTaskSort(field: String, ascending: Bool) {
        guard taskSortField != field || taskSortAscending != ascending else { return }
        taskSortField = field
        taskSortAscending = ascending
        rebuildTaskProjection()
    }

    var selectedTasks: [DownloadTask] {
        filteredTasks.filter { selectedIDs.contains($0.id) }
    }

    var isSelectionEmpty: Bool { selectedIDs.isEmpty }
    var selectionCount: Int { selectedIDs.count }

    /// True when every visible id is selected. Uses subset semantics (all
    /// visible ids ⊆ selected) instead of an equality count so a poisoned
    /// selection that still holds hidden ids cannot misreport "all selected".
    /// Matches upstream's `isALlSelected` (`list.map { it.id }.all { it in
    /// selectionList }`), which also returns false for an empty list.
    var isAllVisibleSelected: Bool {
        !filteredTasks.isEmpty && filteredTasks.allSatisfy { selectedIDs.contains($0.id) }
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
        let visible = Set(filteredTasks.map(\.id))
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
            let selection = TaskSelection(ids: selectedIDs, primary: primaryTaskID).selecting(visible: filteredTasks.map(\.id))
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
        let visible = filteredTasks.map(\.id)
        let selection = TaskSelection(ids: selectedIDs, primary: primaryTaskID).pruned(available: visible)
        selectedIDs = selection.ids
        if let primary = primaryTaskID, !selectedIDs.contains(primary) {
            primaryTaskID = selection.primary ?? selectedTasks.first?.id
        }
    }


    private func notifyForFinishedTasks(_ current: [DownloadTask]) {
        guard !verificationBuildRequiresIsolation, settings.notifications.showCompletionDialog else { return }
        for task in current {
            guard task.status == .completed || task.status == .failed, notifiedStatuses[task.id] != task.status else { continue }
            notifiedStatuses[task.id] = task.status
            let content = UNMutableNotificationContent()
            content.title = task.status == .completed ? AppLocalization.string("notification.complete") : AppLocalization.string("notification.failed")
            content.body = task.fileName
            if settings.notifications.soundEnabled {
                let customSound = task.status == .completed ? settings.notifications.successSound : settings.notifications.errorSound
                if customSound.isEmpty { content.sound = .default }
                else { playSound(customSound) }
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-\(task.id)-\(task.status.rawValue)", content: content, trigger: nil))
        }
    }

    private func playSound(_ path: String) {
        guard !verificationBuildRequiresIsolation else { return }
        guard settings.notifications.soundEnabled else { return }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        currentNotificationSound?.stop()
        currentNotificationSound = NSSound(contentsOfFile: path, byReference: false)
        currentNotificationSound?.play()
    }

    private func focusNewTasks(_ created: [DownloadTask], presentProgress: Bool = true) {
        guard let first = created.first else { return }
        section = .downloads
        downloadSearch = ""
        statusFilter = "all"
        categoryFilter = nil
        queueFilter = nil
        replaceSelection(Set(created.map(\.id)), preferredPrimary: first.id)
        if presentProgress && settings.notifications.showDownloadProgressDialog {
            progressDialogTaskIDs = created.map(\.id)
            isShowingProgressDialog = true
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }
    }

    func addCategory(name: String, extensions: [String], hosts: [String], folder: String?, icon: String = "folder") async { guard let store else { return }; do { _ = try await store.addCategory(name: name, extensions: extensions, hosts: hosts, folder: folder, icon: icon); await refresh() } catch { lastError = error.localizedDescription } }
    func deleteCategory(_ category: DownloadCategory) async { guard let store else { return }; do { try await store.deleteCategory(id: category.id); await refresh() } catch { lastError = error.localizedDescription } }
    func saveCategory(_ category: DownloadCategory) async { guard let store else { return }; do { try await store.upsertCategory(category); await refresh() } catch { lastError = error.localizedDescription } }
    func resetCategoriesToDefaults() async { guard let store else { return }; do { try await store.resetCategoriesToDefaults(); await refresh() } catch { lastError = error.localizedDescription } }
    func categorizeExistingTasks() async { guard let store else { return }; do { try await store.categorizeExistingTasks(); await refresh() } catch { lastError = error.localizedDescription } }
    func deleteHostOverride(_ value: HostOverride) async { guard let store else { return }; do { try await store.removeHostOverride(host: value.host); await refresh() } catch { lastError = error.localizedDescription } }
    func saveHostOverride(host: String, userAgent: String, authUsername: String, authPassword: String, headers: [String: String], threadCount: Int?, speedLimit: Int64?, defaultFolder: String?, categoryID: Int64?) async { guard let store else { return }; do { let value = try HostOverride(validatingHost: host, headers: headers, userAgent: userAgent, authUsername: authUsername, authPassword: authPassword, threadCount: threadCount, speedLimit: speedLimit, defaultFolder: defaultFolder, categoryID: categoryID); try await store.upsertHostOverride(value); await refresh() } catch { lastError = error.localizedDescription } }
    @discardableResult
    func addBatch(
        pattern: String,
        start: Int,
        end: Int,
        padding: Int,
        folder: String?,
        queueID: Int64?,
        categoryID: Int64? = nil,
        headers: [String: String] = [:],
        checksum: String? = nil,
        speedLimit: Int64 = 0,
        connectionCount: Int? = nil,
        conflict: FileConflictPolicy = .rename,
        startImmediately: Bool
    ) async -> Bool {
        guard let store, let engine else { lastError = DownloadEngineError.missingTask.localizedDescription; return false }
        do {
            let batch = try BatchURLPattern(pattern: pattern, start: start, end: end, wildcardLength: padding)
            let requests = try batch.downloadRequests(
                folderPath: folder,
                headers: headers,
                expectedChecksum: checksum,
                speedLimit: speedLimit,
                connectionCountOverride: connectionCount,
                queueID: queueID,
                categoryID: categoryID,
                conflictPolicy: conflict,
                startImmediately: startImmediately
            )
            let created = try await store.addTasks(requests)
            await refresh()
            focusNewTasks(created)
            playSound(settings.notifications.generalSound)
            if startImmediately {
                var failures: [String] = []
                for task in created {
                    do { try await engine.start(taskID: task.id) }
                    catch { failures.append("\(task.fileName): \(error.localizedDescription)") }
                }
                if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
            }
            isShowingNewDownload = false
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func addQueue(name: String, concurrency: Int) async { guard let store else { return }; do { _ = try await store.addQueue(name: name.isEmpty ? "Queue \(queues.count + 1)" : name, concurrencyLimit: concurrency); await refresh() } catch { lastError = error.localizedDescription } }
    func updateQueue(_ queue: DownloadQueue) async { guard let store else { return }; do { try await store.updateQueue(queue); await refresh() } catch { lastError = error.localizedDescription } }
    func toggleQueue(_ queue: DownloadQueue) async { guard let store else { return }; var value = queue; value.isRunning.toggle(); do { try await store.updateQueue(value); await refresh() } catch { lastError = error.localizedDescription } }
    func setAllQueuesRunning(_ running: Bool) async { guard let store else { return }; do { try await store.setAllQueuesRunning(running); await refresh(); if running { await scheduler?.scheduleNow() } } catch { lastError = error.localizedDescription } }
    func setQueueRunning(id: Int64, running: Bool) async {
        guard let store, var queue = queues.first(where: { $0.id == id }) else { return }
        queue.isRunning = running
        do {
            try await store.updateQueue(queue)
            await refresh()
            if running { await scheduler?.scheduleNow() }
        } catch { lastError = error.localizedDescription }
    }
    func stopAllDownloads() async {
        await engine?.stopAll()
        await setAllQueuesRunning(false)
        await refresh()
    }
    func deleteQueue(_ queue: DownloadQueue) async { guard let store else { return }; do { try await store.deleteQueue(id: queue.id); await refresh() } catch { lastError = error.localizedDescription } }
    func add(request: DownloadRequest) async throws {
        try await add(request: request, shouldStart: request.startImmediately)
    }

    func add(request: DownloadRequest, shouldStart: Bool) async throws {
        try await add(request: request, shouldStart: shouldStart, showProgress: true)
    }

    func acceptIncomingRESTAdd(_ draft: PendingRESTAddDraft, request: DownloadRequest) async -> Bool {
        guard pendingRESTAddDraft?.id == draft.id, let store, let engine else { return false }
        do {
            let task = try await store.addTask(request)
            await refresh()
            focusNewTasks([task])
            playSound(settings.notifications.generalSound)
            if request.startImmediately {
                do { try await engine.start(taskID: task.id) }
                catch { lastError = error.localizedDescription }
            }
            if draft.operation.startQueue, let queueID = request.queueID,
               var queue = (await store.snapshot()).queues.first(where: { $0.id == queueID }) {
                queue.isRunning = true
                try await store.updateQueue(queue)
                await scheduler?.scheduleNow()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func incomingRESTAddSheetDismissed() {
        if pendingRESTAddDraft != nil {
            _ = restAddConfirmationQueue.resolveCurrent()
            pendingRESTAddDraft = nil
        }
        presentNextIncomingRESTAddIfNeeded()
    }

    private func presentNextIncomingRESTAddIfNeeded() {
        guard !isShowingNewDownload, pendingRESTAddDraft == nil,
              let operation = restAddConfirmationQueue.current else { return }
        pendingRESTAddDraft = PendingRESTAddDraft(operation: operation)
        isShowingNewDownload = true
    }

    private func add(request: DownloadRequest, shouldStart: Bool, showProgress: Bool) async throws {
        guard let store, let engine else { throw DownloadEngineError.missingTask }
        var request = request
        request.startImmediately = shouldStart
        let task = try await store.addTask(request)
        await refresh()
        focusNewTasks([task], presentProgress: showProgress)
        if showProgress { playSound(settings.notifications.generalSound) }
        if shouldStart { try await engine.start(taskID: task.id) }
    }

    func handle(operation: RESTAddOperation) async throws {
        guard !operation.requiresUserConfirmation else {
            restAddConfirmationQueue.enqueue(operation)
            presentNextIncomingRESTAddIfNeeded()
            return
        }
        try await add(
            request: operation.request,
            shouldStart: operation.shouldStartImmediately,
            showProgress: false
        )
        if operation.startQueue, let queueID = operation.request.queueID, let store {
            if var queue = (await store.snapshot()).queues.first(where: { $0.id == queueID }) {
                queue.isRunning = true
                try await store.updateQueue(queue)
                await scheduler?.scheduleNow()
            }
        }
    }

    @discardableResult
    func addLinks(_ text: String, folder: String?, start: Bool, headers: [String: String] = [:], checksum: String? = nil, queueID: Int64? = nil, categoryID: Int64? = nil, conflict: FileConflictPolicy = .rename, speedLimit: Int64 = 0, connectionCount: Int? = nil) async -> Bool {
        guard let store, let engine else { lastError = DownloadEngineError.missingTask.localizedDescription; return false }
        do {
            let urls = try DownloadInputParser.links(text)
            let requests = urls.map { url in
                DownloadRequest(
                    source: DownloadSource(url: url, headers: headers),
                    folderPath: folder,
                    queueID: queueID,
                    categoryID: categoryID,
                    kind: url.pathExtension.lowercased() == "m3u8" ? .hls : .http,
                    startImmediately: start,
                    conflictPolicy: conflict,
                    expectedChecksum: checksum,
                    speedLimit: speedLimit,
                    connectionCountOverride: connectionCount
                )
            }
            let created = try await store.addTasks(requests)
            await refresh()
            focusNewTasks(created)
            playSound(settings.notifications.generalSound)
            if start {
                var failures: [String] = []
                for task in created {
                    do { try await engine.start(taskID: task.id) }
                    catch { failures.append("\(task.fileName): \(error.localizedDescription)") }
                }
                if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
            }
            isShowingNewDownload = false
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func start(_ task: DownloadTask) async { do { try await engine?.start(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func pause(_ task: DownloadTask) async { do { try await engine?.pause(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func cancel(_ task: DownloadTask) async { do { try await engine?.cancel(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func retry(_ task: DownloadTask) async { do { try await engine?.retry(taskID: task.id); await refresh() } catch { lastError = error.localizedDescription } }
    func redownload(ids: Set<Int64>) async {
        guard let store, let engine else { return }
        var created: [DownloadTask] = []
        var failures: [String] = []
        for id in ids {
            guard let task = tasks.first(where: { $0.id == id }), task.status == .completed else { continue }
            do {
                let original = try await store.taskForExecution(id: id) ?? task
                let request = DownloadRequest(
                    source: original.source,
                    folderPath: original.folderPath,
                    fileName: original.fileName,
                    queueID: original.queueID,
                    categoryID: original.categoryID,
                    kind: original.kind,
                    startImmediately: false,
                    conflictPolicy: .rename,
                    expectedChecksum: original.expectedChecksum,
                    speedLimit: original.speedLimit,
                    enqueue: false,
                    connectionCountOverride: original.connectionCountOverride
                )
                let copy = try await store.addTask(request)
                created.append(copy)
                try await engine.start(taskID: copy.id)
            } catch { failures.append("\(task.fileName): \(error.localizedDescription)") }
        }
        await refresh()
        if !created.isEmpty { focusNewTasks(created) }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }
    /// Double-click semantics: a completed file opens, otherwise the row is
    /// focused in the inspector. Never opens a random item from a multi-selection.
    func openTask(_ task: DownloadTask) async {
        if task.status == .completed {
            if FileManager.default.fileExists(atPath: task.filePath) { NSWorkspace.shared.open(URL(fileURLWithPath: task.filePath)) } else { lastError = AppLocalization.string("error.fileMissing") }
        }
        setPrimary(task)
    }
    func taskForEditing(_ task: DownloadTask) async -> DownloadTask {
        guard let store else { return task }
        do { return try await store.taskForExecution(id: task.id) ?? task }
        catch { lastError = error.localizedDescription; return task }
    }
    func requestEdit(ids: Set<Int64>) {
        guard ids.count == 1, let task = filteredTasks.first(where: { ids.contains($0.id) }), task.canEdit else { return }
        Task {
            let hydrated = await taskForEditing(task)
            guard hydrated.canEdit else { return }
            editingTask = hydrated
        }
    }
    func editTask(_ task: DownloadTask, fileName: String, folder: String, urlText: String, queueID: Int64?, categoryID: Int64?, headers: [String: String], sensitiveHeaders: [String: String], checksum: String?, speedLimit: Int64) async -> Bool {
        guard let store, task.canEdit else { lastError = AppLocalization.string("error.taskNotEditable"); return false }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { lastError = AppLocalization.string("error.invalidTaskURL"); return false }
        do {
            let original = try await store.taskForExecution(id: task.id) ?? task
            try validateTaskDestination(folder)
            let safeName = try FileUtilities.sanitizedFileName(fileName)
            var updated = original; updated.fileName = safeName; updated.folderPath = folder; updated.queueID = queueID; updated.categoryID = categoryID
            if task.canEditRemoteSettings {
                updated.source.url = url
                updated.source.headers = HTTPHeaderEditingPolicy.merge(
                    public: headers,
                    sensitive: sensitiveHeaders,
                    original: original.source.headers,
                    from: original.source.url,
                    to: url
                )
                updated.expectedChecksum = checksum
                updated.speedLimit = max(0, speedLimit)
            }
            if task.status == .completed {
                let oldURL = URL(fileURLWithPath: task.filePath); let newBase = try FileUtilities.containedURL(folder: URL(fileURLWithPath: folder), fileName: safeName); let destination = try FileUtilities.resolveConflict(at: newBase, policy: .rename)
                if oldURL != destination, FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.moveItem(at: oldURL, to: destination); updated.fileName = destination.lastPathComponent }
            }
            try await store.updateTask(updated); await refresh(); return true
        } catch { lastError = error.localizedDescription; return false }
    }

    private func validateTaskDestination(_ folder: String) throws {
        guard verificationBuildRequiresIsolation else { return }
        guard let rootPath = ProcessInfo.processInfo.environment["ABDM_DOWNLOAD_DIRECTORY"], !rootPath.isEmpty else {
            throw VerificationLaunchConfiguration.ValidationError.missingSetting("ABDM_DOWNLOAD_DIRECTORY")
        }
        let candidate = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw AppStateIsolationError.destinationOutsideIsolatedDownloads
        }
    }

    func saveSettings(folderBookmarkURL: URL? = nil) async -> Bool {
        guard let store else { return false }
        if settings.integration.enabled && settings.integration.authEnabled && settings.integration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = RESTService.ConfigurationError.missingAPIKey.localizedDescription
            return false
        }
        let priorBookmarkExists: Bool
        if let folderBookmarkURL, let bookmarkStore {
            priorBookmarkExists = await bookmarkStore.contains(path: folderBookmarkURL.standardizedFileURL.path)
        } else {
            priorBookmarkExists = false
        }
        do {
            if let folderBookmarkURL {
                guard let bookmarkStore else { throw CocoaError(.fileWriteNoPermission) }
                try await bookmarkStore.store(url: folderBookmarkURL)
            }
            var value = settings
            value.integration.apiKey = value.integration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if clipboardMonitoringSuppressed {
                value.clipboardMonitoring = false
                value.autoStartOnBoot = false
            }
            value = AppStateStore.sanitizedSettings(value)
            _ = try value.dns.resolverConfiguration()
            try value.dns.applyToDefaultPrivacyContext()
            value.normalize(); try await store.setSettings(value)
            settingsDraft.saveSucceeded(value)
            AppLocalization.defaultLanguageCode = value.language ?? "zh-Hans"
            if !verificationBuildRequiresIsolation,
               ProcessInfo.processInfo.environment["ABDM_SUPPRESS_LOGIN_ITEM"] != "1", #available(macOS 13.0, *) {
                do {
                    if value.autoStartOnBoot { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                } catch { lastError = "Login item: \(error.localizedDescription)" }
            }
            await restartREST(using: value.integration)
            if value.clipboardMonitoring { clipboardMonitor?.start() } else { clipboardMonitor?.stop() }
            return true
        } catch {
            if let folderBookmarkURL, !priorBookmarkExists {
                try? await bookmarkStore?.remove(path: folderBookmarkURL.standardizedFileURL.path)
            }
            lastError = error.localizedDescription
            return false
        }
    }

    func checkForUpdates() async {
        guard settings.updateChannel != .disabled else { return }
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        do {
            guard let url = URL(string: settings.updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SecureUpdatePolicy.UpdateError.invalidManifest
            }
            let policy = SecureUpdatePolicy(channel: settings.updateChannel)
            let manifest = try await policy.fetchManifest(from: url)
            availableUpdate = manifest
            downloadedUpdateURL = nil
            updateStatus = AppLocalization.format("settings.latestRelease", language: settings.language ?? "zh-Hans", manifest.version)
            settings.lastUpdateCheck = Date()
            try await store?.setSettings(settings)
            settingsDraft.saveSucceeded(settings)
        } catch {
            availableUpdate = nil
            updateStatus = localizedUpdateError(error)
        }
    }

    private func localizedUpdateError(_ error: Error) -> String {
        guard let error = error as? SecureUpdatePolicy.UpdateError else { return error.localizedDescription }
        let language = settings.language ?? SupportedAppLanguage.defaultCode
        switch error {
        case .updatesDisabled: return AppLocalization.string("update.error.disabled", language: language)
        case .invalidManifest: return AppLocalization.string("update.error.invalidManifest", language: language)
        case .insecureURL: return AppLocalization.string("update.error.insecureURL", language: language)
        case .badResponse: return AppLocalization.string("update.error.badResponse", language: language)
        case .artifactTooLarge: return AppLocalization.string("update.error.artifactTooLarge", language: language)
        case .checksumMismatch: return AppLocalization.string("update.error.checksumMismatch", language: language)
        case .invalidFile: return AppLocalization.string("update.error.invalidFile", language: language)
        }
    }

    func cancelSettings() {
        settingsDraft.cancel()
    }

    func downloadVerifiedUpdate() async {
        guard let manifest = availableUpdate, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        defer { isDownloadingUpdate = false }
        do {
            let downloads: URL
            if verificationBuildRequiresIsolation {
                let config = try VerificationLaunchConfiguration.validateIfRequired(
                    marker: "YES",
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    environment: ProcessInfo.processInfo.environment
                )
                guard let config else { throw VerificationLaunchConfiguration.ValidationError.missingSetting("ABDM_DOWNLOAD_DIRECTORY") }
                downloads = config.downloadDirectory
            } else {
                downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            }
            let destination = downloads.appendingPathComponent("zjx-download Updates", isDirectory: true)
            let policy = SecureUpdatePolicy(channel: settings.updateChannel)
            let artifact = try await policy.downloadAndVerify(manifest, to: destination) { url in
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse else { throw SecureUpdatePolicy.UpdateError.badResponse }
                return (file, http)
            }
            downloadedUpdateURL = artifact
            updateStatus = AppLocalization.format("settings.updateVerified", language: settings.language ?? "zh-Hans", artifact.lastPathComponent)
        } catch {
            downloadedUpdateURL = nil
            updateStatus = localizedUpdateError(error)
        }
    }

    func revealDownloadedUpdate() {
        guard let downloadedUpdateURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedUpdateURL])
    }

    // MARK: Batch selection actions -------------------------------------------

    /// Runs `action` over the currently selected (or passed) id snapshot.
    /// Tasks the action does not apply to are skipped — a state mismatch is
    /// not treated as a failure (upstream guards these the same way) — and
    /// only genuine engine/store errors are aggregated into `lastError`.
    /// A single failing item never aborts the rest of the legal items.
    private func batch(_ label: String, ids: Set<Int64>, using action: BatchAction) async {
        guard !ids.isEmpty else { return }
        if let failures = await runBatch(action, ids: ids, visible: filteredTasks) {
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

    func moveSelectedToQueue(_ queueID: Int64) async { await move(ids: selectedIDs, queueID: queueID, categoryID: nil, movingQueue: true) }
    func moveSelectedToCategory(_ categoryID: Int64) async { await move(ids: selectedIDs, queueID: nil, categoryID: categoryID, movingQueue: false) }
    func move(ids: Set<Int64>, queueID: Int64?, categoryID: Int64?, movingQueue: Bool) async {
        guard let store else { return }
        do {
            var changed = filteredTasks.filter { ids.contains($0.id) }
            for index in changed.indices {
                if movingQueue { changed[index].queueID = queueID } else { changed[index].categoryID = categoryID }
            }
            try await store.updateTasks(changed)
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func copyURLs(ids: Set<Int64>) {
        let values = filteredTasks.filter { ids.contains($0.id) }.map { $0.source.url.absoluteString }
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    func copyCurl(ids: Set<Int64>) async {
        guard let store else { return }
        var commands: [String] = []
        for visible in filteredTasks where ids.contains(visible.id) {
            let task: DownloadTask
            do { task = try await store.taskForExecution(id: visible.id) ?? visible }
            catch { lastError = error.localizedDescription; continue }
            commands.append(
            (["curl", "--location"] + task.source.headers.sorted { $0.key < $1.key }.flatMap { ["-H", "\($0.key): \($0.value)"] } + [task.source.url.absoluteString]).map(Self.shellQuote).joined(separator: " ")
            )
        }
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
    }

    func copyTaskJSON(ids: Set<Int64>) {
        guard let data = try? JSONEncoder().encode(filteredTasks.filter { ids.contains($0.id) }), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealTasks(ids: Set<Int64>) {
        for task in filteredTasks where ids.contains(task.id) {
            NSWorkspace.shared.selectFile(task.filePath, inFileViewerRootedAtPath: task.folderPath)
        }
    }

    func openSingleSelected(ids: Set<Int64>) {
        guard ids.count == 1, let task = filteredTasks.first(where: { ids.contains($0.id) }) else { return }
        Task { await openTask(task) }
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
        let confirmation = DeleteSelectionSummary.classify(Array(tasks.filter { source.contains($0.id) }))
        deleteConfirmation = confirmation
        return confirmation
    }

    @discardableResult
    func requestDeleteVisibleConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(filteredTasks.map(\.id)))
    }

    @discardableResult
    func requestDeleteAllConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(tasks.map(\.id)))
    }

    @discardableResult
    func requestDeleteCompletedConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(tasks.lazy.filter { $0.status == .completed }.map(\.id)))
    }

    @discardableResult
    func requestDeleteFailedConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(tasks.lazy.filter { $0.status == .failed }.map(\.id)))
    }

    @discardableResult
    func requestDeleteIncompleteConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(tasks.lazy.filter { $0.status != .completed && $0.status != .failed }.map(\.id)))
    }

    @discardableResult
    func requestDeleteMissingFilesConfirmation() -> DeleteSelectionSummary? {
        requestDeleteConfirmation(ids: Set(tasks.lazy.filter {
            $0.status == .completed && !FileManager.default.fileExists(atPath: $0.filePath)
        }.map(\.id)))
    }

    func showChecksumForSelection(ids: Set<Int64>) {
        guard hasChecksumFiles(ids: ids) else {
            if !ids.isEmpty { lastError = AppLocalization.string("error.fileMissing", language: settings.language) }
            return
        }
        let files = tasks.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.filePath) }
        checksumFileURLs = files
        isShowingChecksum = true
    }

    func hasChecksumFiles(ids: Set<Int64>) -> Bool {
        guard !ids.isEmpty else { return false }
        let matching = tasks.filter { ids.contains($0.id) }
        return matching.count == ids.count && matching.allSatisfy {
            $0.status == .completed && FileManager.default.fileExists(atPath: $0.filePath)
        }
    }

    func showChecksumPicker() {
        checksumFileURLs = []
        isShowingChecksum = true
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
            // `path(forResource:ofType:)` compares the table directory name
            // case-sensitively, but the on-disk casing is not guaranteed to
            // match the identifier the app asks for — a SwiftPM build
            // lowercases it (`zh-hans.lproj` for `zh-Hans`), which would make
            // every lookup fall back to the raw key. Match case-insensitively.
            if let resourceURL = candidate.resourceURL,
               let entries = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil),
               let match = entries.first(where: {
                   $0.pathExtension == "lproj"
                       && $0.deletingPathExtension().lastPathComponent.compare(identifier, options: .caseInsensitive) == .orderedSame
               }),
               let localized = Bundle(url: match) {
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
    switch value { case .none: "proxy.none"; case .system: "proxy.system"; case .manual: "proxy.manual"; case .pac: "proxy_pac" }
}

private func proxySchemeKey(_ value: ProxySettings.Scheme) -> LocalizedStringKey {
    switch value { case .http: "settings.proxyScheme.http"; case .https: "settings.proxyScheme.https"; case .socks5: "settings.proxyScheme.socks5" }
}

private func sizeUnitKey(_ value: SizeUnit) -> LocalizedStringKey {
    switch value { case .binaryBytes: "settings.unit.binary"; case .decimalBytes: "settings.unit.decimal" }
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

    /// Sidebar visibility is owned by the split view so macOS can auto-collapse
    /// the column at narrow widths instead of clipping its icons and titles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The user's intent for the inspector. The inspector is only laid out as a
    /// third column when the detail area is genuinely wide enough; otherwise it
    /// is offered as a sheet, so three panes are never crammed into a window
    /// that cannot hold them.
    @State private var wantsInspector = false
    @State private var showingInspectorSheet = false
    @State private var detailWidth: CGFloat = 0

    /// Honest working minimum, measured rather than guessed: the sidebar's
    /// ideal 220pt plus the list's 300pt minimum plus the split view's insets.
    /// Below that the split view overflows and clips the sidebar, so this is
    /// the smallest window the layout genuinely supports. The inspector is not
    /// part of the floor — it becomes a sheet before the window gets this
    /// narrow.
    static let minimumContentSize = CGSize(width: 544, height: 420)
    /// Below this detail width the list and inspector can no longer sit side by
    /// side without clipping, so the inspector switches to its sheet form.
    static let inspectorColumnMinimumWidth: CGFloat = 620

    private var inspectorAvailable: Bool { model.section == .downloads && model.primaryTaskID != nil }

    private var inspectorColumnVisible: Bool {
        wantsInspector && inspectorAvailable && detailWidth >= Self.inspectorColumnMinimumWidth
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
            .lineLimit(1)
            .navigationTitle(Text(AppLocalization.string("app.title", language: model.settings.language)))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            .safeAreaInset(edge: .bottom) { SidebarStatus(model: model) }
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: Self.minimumContentSize.width, minHeight: Self.minimumContentSize.height)
        .background(WindowMinimumSize(minimum: Self.minimumContentSize))
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.isShowingNewDownload, onDismiss: { model.incomingRESTAddSheetDismissed() }) {
            NewDownloadSheet(
                model: model,
                incomingDraft: model.pendingRESTAddDraft,
                initialLinks: model.newDownloadPrefill,
                startsInBatchMode: model.newDownloadStartsInBatchMode
            )
            .id(model.pendingRESTAddDraft?.id ?? model.newDownloadSessionID)
            // A sheet captures the environment where the presentation modifier
            // is declared. MainWindow applies the selected locale after this
            // modifier, so pass it explicitly to keep modal strings in sync.
            .environment(\.locale, appLocale(model.settings.language))
            .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
        }
        .sheet(isPresented: $model.isShowingProgressDialog) {
            DownloadProgressSheet(model: model)
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
        }
        .sheet(isPresented: $showingInspectorSheet) {
            inspectorSheet
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
        }
        .alert(LocalizedStringKey("app.title"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) { Button(LocalizedStringKey("common.ok")) {} } message: { Text(model.lastError ?? "") }
                .environment(\.locale, appLocale(model.settings.language))
                .environment(\.appLanguage, model.settings.language ?? SupportedAppLanguage.defaultCode)
        .dynamicTypeSize(dynamicTypeCategory(for: model.settings.uiScale ?? 1.0))
    }

    @ViewBuilder private var detailColumn: some View {
        Group {
            switch model.section {
            case .downloads:
                DownloadsDetail(
                    model: model,
                    inspectorVisible: inspectorColumnVisible
                )
            case .queues: QueueList(model: model)
            case .categories: CategoriesView(model: model)
            case .history: HistoryList(model: model)
            case .settings: SettingsView(model: model)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if model.section == .downloads {
            ToolbarItem(placement: .primaryAction) {
                Button { model.beginNewDownload() } label: {
                    if model.settings.showIconLabels { Label(LocalizedStringKey("toolbar.newDownload"), systemImage: "plus") }
                    else { Image(systemName: "plus") }
                }
                    .help(LocalizedStringKey("toolbar.newDownload"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { toggleInspector() } label: {
                    if model.settings.showIconLabels { Label(LocalizedStringKey("toolbar.inspector"), systemImage: "sidebar.right") }
                    else { Image(systemName: "sidebar.right") }
                }
                    .help(LocalizedStringKey("toolbar.inspector"))
                    .accessibilityLabel(LocalizedStringKey("toolbar.inspector"))
                    .disabled(!inspectorAvailable)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { Task { await model.refresh() } } label: {
                if model.settings.showIconLabels { Label(LocalizedStringKey("toolbar.refresh"), systemImage: "arrow.clockwise") }
                else { Image(systemName: "arrow.clockwise") }
            }
                .help(LocalizedStringKey("toolbar.refresh"))
                .accessibilityLabel(LocalizedStringKey("toolbar.refresh"))
        }
    }

    /// Wide enough: the inspector is a normal column and the button toggles it.
    /// Narrow: the column would clip, so the inspector opens as a sheet instead
    /// of forcing the window wider than it can lay out.
    private func toggleInspector() {
        guard inspectorAvailable else { return }
        if detailWidth >= Self.inspectorColumnMinimumWidth {
            wantsInspector.toggle()
        } else {
            showingInspectorSheet = true
        }
    }

    @ViewBuilder private var inspectorSheet: some View {
        if let id = model.primaryTaskID, let task = model.tasks.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack {
                    Text(LocalizedStringKey("task.details")).font(.headline)
                    Spacer()
                    Button(LocalizedStringKey("common.ok")) { showingInspectorSheet = false }
                }.padding()
                Divider()
                TaskInspector(model: model, task: task, progress: model.progress[id])
            }
            .frame(minWidth: 380, minHeight: 420)
        }
    }
}

/// The downloads page detail pane. The inspector column only exists when the
/// detail area is genuinely wide enough; below that threshold the same
/// inspector is offered as a sheet (`MainWindow.inspectorSheet`), so three
/// panes are never crammed into a window that cannot hold them. Keeping the
/// inspector's presence as a boolean parameter instead of an `if/else` of two
/// separate root views also keeps the result builder shallow (the SwiftUI
/// type-checker crashes on the old branching form with this toolchain).
///
/// Uses a plain `HStack` rather than `HSplitView`. `HSplitView` wraps
/// `NSSplitView`, which enforces a large hard minimum on its arranged subviews
/// regardless of their `frame(minWidth:)` — measured at ~528pt for this
/// content. A window narrower than sidebar + that floor cannot shrink the
/// detail column at all, so the split view overflows and the sidebar's icons
/// and titles are pushed off the leading edge. The divider here is not
/// user-draggable, which is the intended behaviour: the inspector's width is
/// governed by `inspectorColumnVisible`, not by a drag position that can be
/// left in an unsatisfiable state.
private struct DownloadsDetail: View {
    @ObservedObject var model: AppModel
    var inspectorVisible: Bool

    var body: some View {
        HStack(spacing: 0) {
            DownloadList(model: model)
                .frame(minWidth: 300, maxWidth: .infinity)
            if inspectorVisible, let id = model.primaryTaskID, let task = model.tasks.first(where: { $0.id == id }) {
                Divider()
                TaskInspector(model: model, task: task, progress: model.progress[id])
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
            }
        }
    }
}

/// Declares the real minimum content size on the hosting `NSWindow`.
///
/// `WindowGroup.defaultSize` is only a hint, and a large `.frame(minWidth:)` on
/// the split view inflates the *content* minimum into a floor the collapsing
/// columns cannot actually satisfy. Setting `contentMinSize` is the documented
/// AppKit way to state a size the layout genuinely supports.
private struct WindowMinimumSize: NSViewRepresentable {
    let minimum: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window, window.contentMinSize != minimum else { return }
            window.contentMinSize = minimum
        }
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
    @AppStorage("downloads.sort.field") private var sortField = "createdAt"
    @AppStorage("downloads.sort.ascending") private var sortAscending = false
    @AppStorage("downloads.table.visibleColumns") private var visibleColumnsStorage = "selection,fileName,downloadedSize,status,speed,timeRemaining,createdAt"
    @AppStorage("downloads.columnWidth.fileName") private var fileNameColumnWidth = 215.0
    @AppStorage("downloads.columnWidth.status") private var statusColumnWidth = 110.0
    @AppStorage("downloads.columnWidth.downloadedSize") private var sizeColumnWidth = 115.0
    @AppStorage("downloads.columnWidth.connectionCount") private var connectionsColumnWidth = 110.0
    @AppStorage("downloads.columnWidth.createdAt") private var dateColumnWidth = 115.0
    @AppStorage("downloads.columnWidth.speed") private var speedColumnWidth = 95.0
    @AppStorage("downloads.columnWidth.timeRemaining") private var remainingColumnWidth = 95.0
    @AppStorage("downloads.columnWidth.startedAt") private var startedColumnWidth = 170.0
    @AppStorage("downloads.columnWidth.completedAt") private var completedColumnWidth = 170.0
    @AppStorage("downloads.columnWidth.selection") private var selectionColumnWidth = 42.0

    private var visibleColumnIDs: Set<String> {
        Set(visibleColumnsStorage.split(separator: ",").map(String.init))
    }

    private var columnWidths: [String: CGFloat] {
        [
            "fileName": CGFloat(fileNameColumnWidth), "status": CGFloat(statusColumnWidth),
            "downloadedSize": CGFloat(sizeColumnWidth), "connectionCount": CGFloat(connectionsColumnWidth),
            "createdAt": CGFloat(dateColumnWidth), "speed": CGFloat(speedColumnWidth),
            "timeRemaining": CGFloat(remainingColumnWidth), "startedAt": CGFloat(startedColumnWidth),
            "completedAt": CGFloat(completedColumnWidth), "selection": CGFloat(selectionColumnWidth),
        ]
    }

    private func setColumnVisible(_ id: String, _ visible: Bool) {
        var columns = visibleColumnIDs
        if visible { columns.insert(id) } else { columns.remove(id) }
        let canonicalOrder = ["selection", "fileName", "downloadedSize", "status", "speed", "timeRemaining", "createdAt", "startedAt", "completedAt", "connectionCount"]
        visibleColumnsStorage = canonicalOrder.filter(columns.contains).joined(separator: ",")
    }

    private func persistColumnWidth(_ id: String, _ width: CGFloat) {
        switch id {
        case "fileName": fileNameColumnWidth = Double(width)
        case "status": statusColumnWidth = Double(width)
        case "downloadedSize": sizeColumnWidth = Double(width)
        case "connectionCount": connectionsColumnWidth = Double(width)
        case "createdAt": dateColumnWidth = Double(width)
        case "speed": speedColumnWidth = Double(width)
        case "timeRemaining": remainingColumnWidth = Double(width)
        case "startedAt": startedColumnWidth = Double(width)
        case "completedAt": completedColumnWidth = Double(width)
        case "selection": selectionColumnWidth = Double(width)
        default: break
        }
    }

    var body: some View {
        Group {
            if model.visibleTasks.isEmpty {
                ContentUnavailableView(LocalizedStringKey("downloads.empty.title"), systemImage: "arrow.down.circle", description: Text(LocalizedStringKey("downloads.empty.description")))
            } else if model.filteredTasks.isEmpty {
                ContentUnavailableView.search(text: model.downloadSearch)
            } else {
                NativeDownloadTaskTable(
                    model: model,
                    tasks: model.filteredTasks,
                    projectionRevision: model.projectionRevision,
                    progressRevision: model.progressRevision,
                    sortField: sortField,
                    sortAscending: sortAscending,
                    visibleColumnIDs: visibleColumnIDs,
                    columnWidths: columnWidths,
                    onSort: { field, ascending in
                        sortField = field
                        sortAscending = ascending
                        model.setTaskSort(field: field, ascending: ascending)
                    },
                    onColumnResize: persistColumnWidth
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.setTaskSort(field: sortField, ascending: sortAscending) }
        .navigationTitle(Text(AppLocalization.string("downloads.title", language: model.settings.language)))
        .searchable(text: $model.downloadSearch, placement: .toolbar, prompt: Text(LocalizedStringKey("downloads.search")))
        .toolbar {
            if !model.isSelectionEmpty && !model.visibleTasks.isEmpty {
                ToolbarItem(placement: .status) { selectionStatus }
            }
            ToolbarItem(placement: .automatic) { filterMenu }
            ToolbarItem(placement: .automatic) { columnVisibilityMenu }
            ToolbarItem(placement: .automatic) { Button { model.selectAllVisible(!model.isAllVisibleSelected) } label: { Image(systemName: model.isAllVisibleSelected ? "checkmark.circle.fill" : "checkmark.circle") }.help(LocalizedStringKey(model.isAllVisibleSelected ? "selection.clearAll" : "selection.selectAll")).accessibilityLabel(LocalizedStringKey(model.isAllVisibleSelected ? "selection.clearAll" : "selection.selectAll")) }
            if !model.isSelectionEmpty && !model.visibleTasks.isEmpty {
                ToolbarItem(placement: .confirmationAction) { Menu(LocalizedStringKey("selection.actions")) { selectionMenu } }
            }
            ToolbarItem(placement: .automatic) { Button { model.showChecksumPicker() } label: { Image(systemName: "number") }.help(LocalizedStringKey("toolbar.checksum")).accessibilityLabel(LocalizedStringKey("toolbar.checksum")) }
        }
        .sheet(isPresented: $model.isShowingChecksum) { ChecksumToolView(initialFileURLs: model.checksumFileURLs) }
        .sheet(isPresented: Binding(get: { model.deleteConfirmation != nil }, set: { presented in if !presented { model.dismissDeleteConfirmation() } })) { DeleteSelectionSheet(model: model) }
        .sheet(item: $model.editingTask) { EditTaskSheet(model: model, task: $0) }
    }

    @ViewBuilder private var filterMenu: some View {
        Menu {
            Picker(LocalizedStringKey("task.status"), selection: $model.statusFilter) {
                Text(LocalizedStringKey("filter.all")).tag("all")
                ForEach(DownloadStatus.allCases, id: \.rawValue) { status in Text(statusKey(status)).tag(status.rawValue) }
            }
            Picker(LocalizedStringKey("newDownload.category"), selection: $model.categoryFilter) {
                Text(LocalizedStringKey("filter.all")).tag(Int64?.none)
                ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker(LocalizedStringKey("newDownload.queue"), selection: $model.queueFilter) {
                Text(LocalizedStringKey("filter.all")).tag(Int64?.none)
                ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) }
            }
            Button(LocalizedStringKey("filter.reset")) { model.statusFilter = "all"; model.categoryFilter = nil; model.queueFilter = nil; model.downloadSearch = "" }
        } label: { Label(LocalizedStringKey("filter.title"), systemImage: "line.3.horizontal.decrease.circle") }
        .help(LocalizedStringKey("filter.title"))
    }

    @ViewBuilder private var columnVisibilityMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("fileName") }, set: { setColumnVisible("fileName", $0) })) { Text(LocalizedStringKey("task.file")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("selection") }, set: { setColumnVisible("selection", $0) })) { Text(LocalizedStringKey("task.select")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("timeRemaining") }, set: { setColumnVisible("timeRemaining", $0) })) { Text(LocalizedStringKey("task.remaining")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("status") }, set: { setColumnVisible("status", $0) })) { Text(LocalizedStringKey("task.status")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("downloadedSize") }, set: { setColumnVisible("downloadedSize", $0) })) { Text(LocalizedStringKey("task.size")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("connectionCount") }, set: { setColumnVisible("connectionCount", $0) })) { Text(LocalizedStringKey("task.connections")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("createdAt") }, set: { setColumnVisible("createdAt", $0) })) { Text(LocalizedStringKey("task.date")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("startedAt") }, set: { setColumnVisible("startedAt", $0) })) { Text(LocalizedStringKey("task.startedDate")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("completedAt") }, set: { setColumnVisible("completedAt", $0) })) { Text(LocalizedStringKey("task.finishedDate")) }
            Toggle(isOn: Binding(get: { visibleColumnIDs.contains("speed") }, set: { setColumnVisible("speed", $0) })) { Text(LocalizedStringKey("task.speed")) }
        } label: { Label(LocalizedStringKey("customize_columns"), systemImage: "tablecells") }
        .help(LocalizedStringKey("customize_columns"))
    }

    @ViewBuilder var selectionStatus: some View {
        Text(selectionCountLabel).foregroundStyle(.secondary).font(.caption).padding(.horizontal, 8).accessibilityLabel(selectionCountLabel)
    }

    @ViewBuilder var selectionMenu: some View {
        TaskSelectionMenu(model: model, selection: model.selectedIDs)
    }

    private var selectionCountLabel: String {
        AppLocalization.format("selection.count", language: language, model.selectionCount)
    }

    private func dateLabel(_ date: Date) -> String {
        model.settings.useRelativeDateTime ? date.formatted(.relative(presentation: .named)) : date.formatted(date: .abbreviated, time: .shortened)
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
        if selection.count == 1, let id = selection.first, let task = model.tasks.first(where: { $0.id == id }), task.status == .completed {
            Button(LocalizedStringKey("task.open")) { apply(); Task { await model.openTask(task) } }
            Button(LocalizedStringKey("task.reveal")) { apply(); model.revealTasks(ids: selection) }
            Divider()
        }
        if selection.count == 1, let id = selection.first, model.tasks.first(where: { $0.id == id })?.canEdit == true {
            Button(LocalizedStringKey("task.edit")) { apply(); model.requestEdit(ids: selection) }
            Divider()
        }
        let completedSelection = model.tasks.filter { selection.contains($0.id) }
        if !completedSelection.isEmpty && completedSelection.allSatisfy({ $0.status == .completed }) {
            Button(LocalizedStringKey("commands.redownload")) { apply(); Task { await model.redownload(ids: selection) } }
        }
        if !selection.isEmpty {
            Button(LocalizedStringKey("commands.checksumSelected")) { apply(); model.showChecksumForSelection(ids: selection) }
                .disabled(!model.hasChecksumFiles(ids: selection))
        }
        Button(LocalizedStringKey("selection.start")) { apply(); Task { await model.resume(ids: selection) } }
        Button(LocalizedStringKey("selection.pause")) { apply(); Task { await model.pause(ids: selection) } }
        Button(LocalizedStringKey("selection.retry")) { apply(); Task { await model.retry(ids: selection) } }
        Divider()
        Button(LocalizedStringKey("commands.copyURLs")) { apply(); model.copyURLs(ids: selection) }
        Button(LocalizedStringKey("commands.copyCurl")) { apply(); Task { await model.copyCurl(ids: selection) } }
        Button(LocalizedStringKey("commands.copyJSON")) { apply(); model.copyTaskJSON(ids: selection) }
        Menu(LocalizedStringKey("commands.moveToQueue")) {
            ForEach(model.queues) { queue in Button(queue.name) { apply(); Task { await model.moveSelectedToQueue(queue.id) } } }
        }.disabled(model.queues.isEmpty)
        Menu(LocalizedStringKey("commands.moveToCategory")) {
            ForEach(model.categories) { category in Button(category.name) { apply(); Task { await model.moveSelectedToCategory(category.id) } } }
        }.disabled(model.categories.isEmpty)
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
    var body: some View {
        Form {
            LabeledContent(LocalizedStringKey("task.file"), value: task.fileName); LabeledContent { Text(statusKey(task.status)) } label: { Text(LocalizedStringKey("task.status")) }; LabeledContent(LocalizedStringKey("task.destination"), value: task.folderPath)
            if let total = task.totalSize { LabeledContent(LocalizedStringKey("task.size"), value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            LabeledContent(LocalizedStringKey("task.connections"), value: "\(task.connectionCount)")
            if let speed = progress?.bytesPerSecond { LabeledContent(LocalizedStringKey("task.speed"), value: ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
            if let eta = progress?.eta { LabeledContent(LocalizedStringKey("task.remaining"), value: Duration.seconds(eta).formatted(.time(pattern: .hourMinuteSecond))) }
            if let error = task.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button(LocalizedStringKey("task.edit")) {
                    model.requestEdit(ids: [task.id])
                }.disabled(!task.canEdit)
                if task.status == .completed { Button(LocalizedStringKey("task.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: task.filePath)) }; Button(LocalizedStringKey("task.reveal")) { NSWorkspace.shared.selectFile(task.filePath, inFileViewerRootedAtPath: task.folderPath) } }
            }
        }.formStyle(.grouped).padding().navigationTitle(LocalizedStringKey("task.details")).accessibilityElement(children: .contain)
    }
}

struct EditTaskSheet: View {
    @ObservedObject var model: AppModel
    let task: DownloadTask
    @State private var name: String; @State private var folder: String; @State private var url: String
    @State private var queueID: Int64?; @State private var categoryID: Int64?; @State private var headers = ""; @State private var sensitiveHeaders: [String: String]; @State private var checksum: String; @State private var speed: String
    @State private var headerError = ""
    @State private var showingHeaderError = false
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, task: DownloadTask) {
        self.model = model
        self.task = task
        _name = State(initialValue: task.fileName)
        _folder = State(initialValue: task.folderPath)
        _url = State(initialValue: task.source.url.absoluteString)
        _queueID = State(initialValue: task.queueID)
        _categoryID = State(initialValue: task.categoryID)
        _headers = State(initialValue: HTTPHeaderEditingPolicy.publicHeaders(task.source.headers).map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        let existingSensitiveHeaders = HTTPHeaderEditingPolicy.sensitiveHeaders(task.source.headers)
        var secureFields: [String: String] = [:]
        for name in HTTPHeaderEditingPolicy.sensitiveNames {
            secureFields[name] = existingSensitiveHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        _sensitiveHeaders = State(initialValue: secureFields)
        _checksum = State(initialValue: task.expectedChecksum ?? "")
        _speed = State(initialValue: String(task.speedLimit))
    }
    var body: some View {
        Form {
            TextField(LocalizedStringKey("task.fileName"), text: $name); TextField(LocalizedStringKey("task.folder"), text: $folder); TextField(LocalizedStringKey("task.url"), text: $url).disabled(task.status == .completed)
            HStack { Picker(LocalizedStringKey("newDownload.queue"), selection: $queueID) { Text(LocalizedStringKey("newDownload.noQueue")).tag(Int64?.none); ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) } }; Picker(LocalizedStringKey("newDownload.category"), selection: $categoryID) { Text(LocalizedStringKey("newDownload.automatic")).tag(Int64?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } } }
            TextEditor(text: $headers).font(.body.monospaced()).frame(minHeight: 90).disabled(task.status == .completed).accessibilityLabel(LocalizedStringKey("host.headers"))
            ForEach(HTTPHeaderEditingPolicy.sensitiveNames, id: \.self) { name in
                SecureField(name, text: Binding(get: { sensitiveHeaders[name] ?? "" }, set: { sensitiveHeaders[name] = $0 })).disabled(task.status == .completed)
            }
            TextField(LocalizedStringKey("toolbar.checksum"), text: $checksum).disabled(task.status == .completed); TextField(LocalizedStringKey("host.speed"), text: $speed).disabled(task.status == .completed)
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) {
                do {
                    let parsed = try DownloadInputParser.headers(headers)
                    Task {
                        let saved = await model.editTask(task, fileName: name, folder: folder, urlText: url, queueID: queueID, categoryID: categoryID, headers: HTTPHeaderEditingPolicy.publicHeaders(parsed), sensitiveHeaders: sensitiveHeaders, checksum: checksum.isEmpty ? nil : checksum, speedLimit: Int64(speed) ?? 0)
                        if saved { dismiss() }
                    }
                } catch {
                    headerError = error.localizedDescription
                    showingHeaderError = true
                }
            }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 650)
            .alert(LocalizedStringKey("task.edit"), isPresented: $showingHeaderError) {
                Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}
            } message: { Text(headerError) }
    }
}

private struct DownloadProgressSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var tasks: [DownloadTask] {
        model.progressDialogTaskIDs.compactMap { id in model.tasks.first(where: { $0.id == id }) }
    }

    var body: some View {
        NavigationStack {
            List(tasks) { task in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: task.status == .completed ? "checkmark.circle.fill" : task.status == .failed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(task.status == .failed ? .red : task.status == .completed ? .green : .accentColor)
                            .accessibilityHidden(true)
                        Text(task.fileName).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(statusKey(task.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = model.progress[task.id], let total = progress.total, total > 0 {
                        ProgressView(value: Double(progress.downloaded), total: Double(total))
                            .accessibilityLabel(Text(LocalizedStringKey("progress.fileProgress")))
                            .accessibilityValue("\(Int(Double(progress.downloaded) * 100 / Double(total)))%")
                        Text("\(ByteDisplayFormatter.string(progress.downloaded, unit: model.settings.sizeUnit)) / \(ByteDisplayFormatter.string(total, unit: model.settings.sizeUnit))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle(LocalizedStringKey("progress.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("progress.close")) {
                        model.isShowingProgressDialog = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("progress.showDownloads")) {
                        model.section = .downloads
                        model.isShowingProgressDialog = false
                        dismiss()
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 220)
        }
    }
}

struct NewDownloadSheet: View {
    @ObservedObject var model: AppModel
    let incomingDraft: PendingRESTAddDraft?
    @Environment(\.appLanguage) private var language
    @State private var links = ""
    @State private var batchPattern = ""
    @State private var batchStart = "0"
    @State private var batchEnd = "0"
    @State private var batchPadding = "0"
    @State private var batchExpanded = false
    @State private var folder: String
    @State private var headers = ""
    @State private var checksum = ""
    @State private var speed = "0"
    @State private var connections = ""
    @State private var queueID: Int64?
    @State private var categoryID: Int64?
    @State private var conflict: FileConflictPolicy = .rename
    @State private var start = true
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, incomingDraft: PendingRESTAddDraft? = nil, initialLinks: String = "", startsInBatchMode: Bool = false) {
        self.model = model
        self.incomingDraft = incomingDraft
        let request = incomingDraft?.operation.request
        _links = State(initialValue: request?.source.url.absoluteString ?? initialLinks)
        _batchExpanded = State(initialValue: startsInBatchMode)
        _folder = State(initialValue: request?.folderPath ?? model.settings.defaultDownloadFolder)
        _headers = State(initialValue: (request?.source.headers ?? [:]).sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        _checksum = State(initialValue: request?.expectedChecksum ?? "")
        _speed = State(initialValue: String(request?.speedLimit ?? 0))
        _connections = State(initialValue: request?.connectionCountOverride.map { String($0) } ?? "")
        _queueID = State(initialValue: request?.queueID)
        _categoryID = State(initialValue: request?.categoryID)
        _conflict = State(initialValue: request?.conflictPolicy ?? .rename)
        _start = State(initialValue: incomingDraft.map { $0.operation.options.silentStart || $0.operation.request.startImmediately } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("newDownload.title")).font(.title2.bold())
            Text(LocalizedStringKey("newDownload.linksHelp")).foregroundStyle(.secondary)
            TextEditor(text: $links).frame(minHeight: 105).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            DisclosureGroup(isExpanded: $batchExpanded) {
                TextField("https://example.test/file-*.bin", text: $batchPattern)
                HStack { TextField(LocalizedStringKey("newDownload.from"), text: $batchStart); TextField(LocalizedStringKey("newDownload.to"), text: $batchEnd); TextField(LocalizedStringKey("newDownload.padding"), text: $batchPadding) }
                if let count = batchCount { Text(AppLocalization.format("newDownload.preview", language: language, count)).font(.caption).foregroundStyle(.secondary) }
            } label: { Text(LocalizedStringKey("newDownload.batch")) }
            HStack { TextField(LocalizedStringKey("newDownload.destination"), text: $folder); Button(LocalizedStringKey("newDownload.choose")) { chooseFolder() } }
            TextEditor(text: $headers).frame(minHeight: 56, maxHeight: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).accessibilityLabel(LocalizedStringKey("newDownload.headers"))
            HStack {
                TextField(LocalizedStringKey("newDownload.checksum"), text: $checksum)
                TextField(LocalizedStringKey("newDownload.taskLimit"), text: $speed)
                TextField(LocalizedStringKey("newDownload.connections"), text: $connections)
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
                Task {
                    let parsedHeaders: [String: String]
                    do { parsedHeaders = try DownloadInputParser.headers(headers) }
                    catch { model.lastError = error.localizedDescription; return }
                    let speedValue = Int64(speed) ?? -1
                    let connectionValue: Int?
                    if connections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { connectionValue = nil }
                    else if let parsed = Int(connections), (1...64).contains(parsed) { connectionValue = parsed }
                    else { model.lastError = "Connections must be between 1 and 64."; return }
                    guard speedValue >= 0 else { model.lastError = "Speed limit must be zero or greater."; return }
                    if let incomingDraft {
                        do {
                            let parsedLinks = try DownloadInputParser.links(links)
                            guard parsedLinks.count == 1 else {
                                model.lastError = "Add one browser-captured link at a time in this dialog."
                                return
                            }
                            var request = incomingDraft.operation.request
                            request.source.url = parsedLinks[0]
                            request.source.headers = parsedHeaders
                            request.folderPath = folder
                            request.queueID = queueID
                            request.categoryID = categoryID
                            request.expectedChecksum = checksum.isEmpty ? nil : checksum
                            request.speedLimit = speedValue
                            request.connectionCountOverride = connectionValue
                            request.conflictPolicy = conflict
                            request.startImmediately = start
                            if await model.acceptIncomingRESTAdd(incomingDraft, request: request) { dismiss() }
                        } catch { model.lastError = error.localizedDescription }
                        return
                    }
                    let didAdd: Bool
                    if !batchPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        didAdd = await model.addBatch(pattern: batchPattern, start: Int(batchStart) ?? -1, end: Int(batchEnd) ?? -1, padding: Int(batchPadding) ?? 0, folder: folder, queueID: queueID, categoryID: categoryID, headers: parsedHeaders, checksum: checksum.isEmpty ? nil : checksum, speedLimit: speedValue, connectionCount: connectionValue, conflict: conflict, startImmediately: start)
                    } else {
                        didAdd = await model.addLinks(links, folder: folder, start: start, headers: parsedHeaders, checksum: checksum.isEmpty ? nil : checksum, queueID: queueID, categoryID: categoryID, conflict: conflict, speedLimit: speedValue, connectionCount: connectionValue)
                    }
                    if didAdd { dismiss() }
                }
            }.keyboardShortcut(.defaultAction).disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && batchPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
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
    @State private var deletingQueue: DownloadQueue?
    var body: some View {
        List {
            ForEach(sortedQueues) { queue in
                QueueRow(model: model, queue: queue, editing: { editingQueue = queue }, deleting: { deletingQueue = queue })
            }
            .onMove(perform: move)
        }
        .toolbar {
            Menu {
                Button(LocalizedStringKey("queue.new")) { showingNewQueue = true }
                Divider()
                Button(LocalizedStringKey("queue.startAll")) { Task { await model.setAllQueuesRunning(true) } }
                Button(LocalizedStringKey("queue.stopAll")) { Task { await model.setAllQueuesRunning(false) } }
            } label: { Label(LocalizedStringKey("queue.actions"), systemImage: "ellipsis.circle") }
        }
        .navigationTitle(Text(AppLocalization.string("queues.title", language: model.settings.language)))
        .sheet(isPresented: $showingNewQueue) { NewQueueSheet(model: model) }
        .sheet(item: $editingQueue) { QueueEditSheet(model: model, queue: $0) }
        .alert(LocalizedStringKey("queue.deleteTitle"), isPresented: Binding(get: { deletingQueue != nil }, set: { if !$0 { deletingQueue = nil } })) {
            Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}
            Button(LocalizedStringKey("common.delete"), role: .destructive) { if let deletingQueue { Task { await model.deleteQueue(deletingQueue) } } }
        } message: { Text(LocalizedStringKey("queue.deleteMessage")) }
    }

    private var sortedQueues: [DownloadQueue] {
        model.queues.sorted { $0.order < $1.order }
    }

    private func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var reordered = sortedQueues.map(\.id)
        reordered.move(fromOffsets: offsets, toOffset: destination)
        Task { try? await model.store?.reorderQueues(ids: reordered); await model.refresh() }
    }
}

/// One queue row, factored into its own view so the `QueueList` builder stays
/// shallow (see `QueueEditSheet` note about the type-checker).
private struct QueueRow: View {
    @ObservedObject var model: AppModel
    let queue: DownloadQueue
    @Environment(\.appLanguage) private var language
    let editing: () -> Void
    let deleting: () -> Void

    var body: some View {
        HStack {
            Button { Task { await model.toggleQueue(queue) } } label: { Image(systemName: queue.isRunning ? "play.circle.fill" : "pause.circle") }.buttonStyle(.borderless).accessibilityLabel(queue.isRunning ? "Stop \(queue.name)" : "Start \(queue.name)")
            Text(queue.name)
            Button(action: editing) { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("queue.edit"))
            Spacer()
            Text(AppLocalization.format("task.maxConnections", language: language, queue.concurrencyLimit)).font(.caption).foregroundStyle(.secondary)
            if model.queues.count > 1 { Button(action: deleting) { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("common.delete")) }
        }
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
            Section {
                TextField(LocalizedStringKey("queue.name"), text: $queue.name)
                Stepper(AppLocalization.format("queue.concurrentCount", language: language, queue.concurrencyLimit), value: $queue.concurrencyLimit, in: 1...64)
                Toggle(LocalizedStringKey("queue.schedule"), isOn: $scheduleEnabled)
            }
            Section {
                if scheduleEnabled {
                    HStack { TextField(LocalizedStringKey("queue.start"), text: $startText); TextField(LocalizedStringKey("queue.end"), text: $endText) }
                    ScheduleWeekdayGrid(weekdays: $weekdays)
                    Text(LocalizedStringKey("queue.overnight")).font(.caption).foregroundStyle(.secondary)
                }
            }
            completionSection
        }
        .padding().frame(width: 520)
        .alert(LocalizedStringKey("queue.confirmTitle"), isPresented: $showPowerConfirmation) {
            Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}
            Button(LocalizedStringKey("queue.enable")) { save() }
        } message: { Text(LocalizedStringKey("queue.confirmMessage")) }
    }

    @ViewBuilder private var completionSection: some View {
        Section {
            Picker(LocalizedStringKey("queue.completion"), selection: $queue.completionAction) {
                ForEach(QueueCompletionAction.allCases) { Text(completionActionKey($0)).tag($0) }
            }
            Text(LocalizedStringKey("queue.completionWarning")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }
                Button(LocalizedStringKey("task.save")) { if queue.completionAction.isPowerAction { showPowerConfirmation = true } else { save() } }.keyboardShortcut(.defaultAction)
            }
        }
    }
    private func save() { var value = queue; if scheduleEnabled, let start = QueueEditSheet.seconds(startText), let end = QueueEditSheet.seconds(endText) { value.schedule = QueueSchedule(weekdays: weekdays, startSeconds: start, endSeconds: end) } else { value.schedule = nil }; Task { await model.updateQueue(value); dismiss() } }
    static func seconds(_ text: String) -> Int? { let pair = text.split(separator: ":").compactMap { Int($0) }; guard pair.count == 2, pair[0] >= 0, pair[0] < 24, pair[1] >= 0, pair[1] < 60 else { return nil }; return pair[0] * 3600 + pair[1] * 60 }
    static func time(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60) }
}

/// The weekday multi-select grid, kept as its own small view so the queue
/// editor's `Form` stays shallow and the SwiftUI type-checker cannot blow up on
/// one giant builder expression.
private struct ScheduleWeekdayGrid: View {
    @Binding var weekdays: Set<QueueSchedule.Weekday>
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
            ForEach(QueueSchedule.Weekday.allCases, id: \.self) { day in
                Toggle(weekdayKey(day), isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
            }
        }
    }
}

struct HistoryList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        List(model.history) { record in
            let exists = FileManager.default.fileExists(atPath: record.folderPath + "/" + record.fileName)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(record.name).lineLimit(1); Spacer(); Text(statusKey(record.finalStatus)).font(.caption).foregroundStyle(.secondary) }
                Text(record.finishedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                if model.settings.trackDeletedFilesOnDisk && !exists {
                    Label(LocalizedStringKey("history.fileMissing"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if let message = record.errorMessage, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Button(LocalizedStringKey("history.reveal")) { NSWorkspace.shared.selectFile(record.folderPath + "/" + record.fileName, inFileViewerRootedAtPath: record.folderPath) }
                    .buttonStyle(.link).disabled(!exists)
            }.accessibilityElement(children: .contain)
        }
        .toolbar {
            Button(LocalizedStringKey("commands.refresh")) { Task { await model.refresh() } }
            Button(LocalizedStringKey("history.clear")) { Task { guard let store = model.store else { return }; try? await store.clearHistory(); await model.refresh() } }
        }
        .navigationTitle(Text(AppLocalization.string("history.title", language: model.settings.language)))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @State private var folderBookmarkToCommit: URL?
    private var scale: Binding<Double> {
        Binding(get: { model.settings.uiScale ?? 1.0 }, set: { model.settings.uiScale = $0 })
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section(LocalizedStringKey("settings.appearance")) {
                Picker(LocalizedStringKey("settings.theme"), selection: $model.settings.theme) { ForEach(ThemeMode.allCases) { Text(themeKey($0)).tag($0) } }
                Picker(LocalizedStringKey("settings.language"), selection: Binding(get: { model.settings.language ?? SupportedAppLanguage.defaultCode }, set: { model.settings.language = $0 })) {
                    ForEach(SupportedAppLanguage.all) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }
                Toggle(LocalizedStringKey("settings.iconLabels"), isOn: $model.settings.showIconLabels)
                Toggle(LocalizedStringKey("settings.relativeDates"), isOn: $model.settings.useRelativeDateTime)
                VStack(alignment: .leading) {
                    Slider(value: scale, in: 0.8...1.6, step: 0.1)
                    Text(AppLocalization.format("settings.textScale", language: language, String(format: "%.1f×", scale.wrappedValue))).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(LocalizedStringKey("settings.clipboard"), isOn: $model.settings.clipboardMonitoring)
                    .disabled(verificationBuildRequiresIsolation)
            }.id("settings.appearance")
            Section(LocalizedStringKey("downloads.title")) {
                Stepper(AppLocalization.format("settings.connectionCount", language: language, model.settings.threadCount), value: $model.settings.threadCount, in: 1...64)
                Stepper(AppLocalization.format("settings.concurrentCount", language: language, model.settings.maxConcurrentDownloads), value: $model.settings.maxConcurrentDownloads, in: 1...64)
                Stepper(AppLocalization.format("settings.retryCount", language: language, model.settings.maxDownloadRetryCount), value: $model.settings.maxDownloadRetryCount, in: 0...100)
                HStack { TextField(LocalizedStringKey("settings.folder"), text: $model.settings.defaultDownloadFolder); Button(LocalizedStringKey("settings.chooseFolder"), action: chooseFolder) }
                TextField(LocalizedStringKey("settings.userAgent"), text: $model.settings.userAgent)
                TextField(LocalizedStringKey("settings.globalSpeed"), value: $model.settings.speedLimit, format: .number)
                Toggle(LocalizedStringKey("settings.dynamicParts"), isOn: $model.settings.dynamicPartCreation)
                Toggle(LocalizedStringKey("settings.lastModified"), isOn: $model.settings.useServerLastModifiedTime)
                Toggle(LocalizedStringKey("settings.incompleteExtension"), isOn: $model.settings.appendExtensionToIncompleteDownloads)
                Toggle(LocalizedStringKey("settings.averageSpeed"), isOn: $model.settings.useAverageSpeed)
                Toggle(LocalizedStringKey("settings.autoCategory"), isOn: $model.settings.useCategoryByDefault)
                Toggle(LocalizedStringKey("settings.deletePartial"), isOn: $model.settings.deletePartialFileOnDownloadCancellation)
                Toggle(LocalizedStringKey("settings.trackMissing"), isOn: $model.settings.trackDeletedFilesOnDisk)
                Picker(LocalizedStringKey("settings.sizeUnit"), selection: $model.settings.sizeUnit) { ForEach(SizeUnit.allCases, id: \.self) { Text(sizeUnitKey($0)).tag($0) } }
                Picker(LocalizedStringKey("settings.speedUnit"), selection: $model.settings.speedUnit) { ForEach(SizeUnit.allCases, id: \.self) { Text(sizeUnitKey($0)).tag($0) } }
            }.id("settings.downloads")
            Section(LocalizedStringKey("settings.proxyTLS")) {
                Picker(LocalizedStringKey("settings.proxy"), selection: $model.settings.proxy.mode) { ForEach(ProxySettings.Mode.allCases) { Text(proxyKey($0)).tag($0) } }
                if model.settings.proxy.mode == .pac {
                    TextField(LocalizedStringKey("proxy_pac_url"), text: $model.settings.proxy.pacURL)
                    TextField(LocalizedStringKey("settings.proxyBypass"), text: $model.settings.proxy.bypassList)
                } else if model.settings.proxy.mode == .manual {
                    Picker(LocalizedStringKey("settings.proxyScheme"), selection: $model.settings.proxy.scheme) { ForEach(ProxySettings.Scheme.allCases) { Text(proxySchemeKey($0)).tag($0) } }
                    TextField(LocalizedStringKey("settings.proxyHost"), text: $model.settings.proxy.host)
                    TextField(LocalizedStringKey("settings.proxyPort"), value: $model.settings.proxy.port, format: .number)
                    TextField(LocalizedStringKey("settings.proxyUser"), text: $model.settings.proxy.username)
                    SecureField(LocalizedStringKey("settings.proxyPassword"), text: $model.settings.proxy.password)
                    TextField(LocalizedStringKey("settings.proxyBypass"), text: $model.settings.proxy.bypassList)
                }
                Toggle(LocalizedStringKey("settings.insecureTLS"), isOn: $model.settings.tls.allowInsecureCertificates)
            }.id("settings.proxy")
            Section(LocalizedStringKey("settings.dns")) {
                Picker(LocalizedStringKey("settings.dnsMode"), selection: $model.settings.dns.mode) {
                    Text(LocalizedStringKey("settings.dns.system")).tag(DNSSettings.Mode.system)
                    Text(LocalizedStringKey("settings.dns.https")).tag(DNSSettings.Mode.https)
                    Text(LocalizedStringKey("settings.dns.tls")).tag(DNSSettings.Mode.tls)
                }
                if model.settings.dns.mode == .https {
                    TextField(LocalizedStringKey("settings.dnsHTTPSURL"), text: $model.settings.dns.httpsURL)
                } else if model.settings.dns.mode == .tls {
                    TextField(LocalizedStringKey("settings.dnsTLSHost"), text: $model.settings.dns.tlsHost)
                }
                if model.settings.dns.mode != .system {
                    TextField(LocalizedStringKey("settings.dnsBootstrap"), text: $model.settings.dns.bootstrapAddresses)
                    Text(LocalizedStringKey("settings.dnsScopeNote")).font(.caption).foregroundStyle(.secondary)
                }
            }.id("settings.dns")
            Section(LocalizedStringKey("settings.integration")) {
                Toggle(LocalizedStringKey("settings.rest"), isOn: $model.settings.integration.enabled)
                TextField(LocalizedStringKey("settings.apiPort"), value: $model.settings.integration.port, format: .number)
                Toggle(LocalizedStringKey("settings.useAPIKey"), isOn: $model.settings.integration.authEnabled)
                SecureField(LocalizedStringKey("settings.apiKey"), text: $model.settings.integration.apiKey)
                Text(AppLocalization.format("settings.boundLoopback", language: language, model.settings.integration.port)).font(.caption).foregroundStyle(.secondary)
            }.id("settings.integration")
            HostOverridesView(model: model).id("settings.hosts")
            Section(LocalizedStringKey("settings.notifications")) {
                Toggle(LocalizedStringKey("settings.sound"), isOn: $model.settings.notifications.soundEnabled)
                    .disabled(verificationBuildRequiresIsolation)
                Toggle(LocalizedStringKey("settings.completionNotifications"), isOn: $model.settings.notifications.showCompletionDialog)
                    .disabled(verificationBuildRequiresIsolation)
                Toggle(LocalizedStringKey("settings.progressFocus"), isOn: $model.settings.notifications.showDownloadProgressDialog)
                soundRow("settings.generalSound", path: $model.settings.notifications.generalSound)
                soundRow("settings.successSound", path: $model.settings.notifications.successSound)
                soundRow("settings.errorSound", path: $model.settings.notifications.errorSound)
                Toggle(LocalizedStringKey("settings.login"), isOn: $model.settings.autoStartOnBoot)
                    .disabled(verificationBuildRequiresIsolation)
                Picker(LocalizedStringKey("settings.updateChannel"), selection: $model.settings.updateChannel) { ForEach(UpdateChannel.allCases) { Text(updateKey($0)).tag($0) } }
                TextField(LocalizedStringKey("settings.updateManifestURL"), text: $model.settings.updateManifestURL)
                Text(LocalizedStringKey("settings.updateNote")).font(.caption).foregroundStyle(.secondary)
                Button(LocalizedStringKey("settings.checkUpdates")) { Task { await model.checkForUpdates() } }
                    .disabled(model.settings.updateChannel == .disabled || model.isCheckingUpdates || model.settings.updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let updateStatus = model.updateStatus { Text(updateStatus).font(.caption).textSelection(.enabled) }
                if model.availableUpdate != nil {
                    Button {
                        Task { await model.downloadVerifiedUpdate() }
                    } label: {
                        if model.isDownloadingUpdate {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
                            Text(LocalizedStringKey("settings.downloadingUpdate"))
                        } else {
                            Text(LocalizedStringKey("settings.downloadVerifyUpdate"))
                        }
                    }
                    .disabled(model.isDownloadingUpdate)
                }
                if model.downloadedUpdateURL != nil {
                    Button(LocalizedStringKey("settings.revealUpdate")) { model.revealDownloadedUpdate() }
                }
            }.id("settings.notifications")
            HStack {
                Spacer()
                Button(LocalizedStringKey("newDownload.cancel")) {
                    folderBookmarkToCommit = nil
                    model.cancelSettings()
                    dismiss()
                }
                Button(LocalizedStringKey("settings.save")) {
                    Task {
                        if await model.saveSettings(folderBookmarkURL: matchingFolderBookmarkToCommit) {
                            folderBookmarkToCommit = nil
                        }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(Text(AppLocalization.string("settings.title", language: model.settings.language)))
        .onAppear { scrollToRequestedSettingsTarget(using: proxy) }
        .onChange(of: model.settingsScrollTarget) { _, target in
            guard target != nil else { return }
            scrollToRequestedSettingsTarget(using: proxy)
        }
        }
    }

    private func scrollToRequestedSettingsTarget(using proxy: ScrollViewProxy) {
        guard let target = model.settingsScrollTarget else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(target, anchor: .top)
        }
        model.settingsScrollTarget = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.defaultDownloadFolder = url.path
        folderBookmarkToCommit = url
    }

    private var matchingFolderBookmarkToCommit: URL? {
        guard let folderBookmarkToCommit else { return nil }
        let chosenPath = folderBookmarkToCommit.standardizedFileURL.path
        let configuredPath = URL(fileURLWithPath: model.settings.defaultDownloadFolder, isDirectory: true).standardizedFileURL.path
        return chosenPath == configuredPath ? folderBookmarkToCommit : nil
    }

    private func soundRow(_ title: String, path: Binding<String>) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer(minLength: 12)
            Text(path.wrappedValue.isEmpty ? AppLocalization.string("settings.systemDefaultSound", language: language) : URL(fileURLWithPath: path.wrappedValue).lastPathComponent)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button(LocalizedStringKey("settings.chooseSound")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
            Button(LocalizedStringKey("settings.previewSound")) {
                guard !path.wrappedValue.isEmpty else { return }
                modelPreviewSound(path.wrappedValue)
            }.disabled(path.wrappedValue.isEmpty)
        }
    }

    private func modelPreviewSound(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { model.lastError = AppLocalization.string("error.fileMissing", language: language); return }
        NSSound(contentsOfFile: path, byReference: false)?.play()
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language

    var body: some View {
        Text(AppLocalization.format("menubar.active", language: language, model.tasks.filter { $0.status.isActive }.count))
        Divider()
        Button(LocalizedStringKey("toolbar.newDownload")) { model.beginNewDownload() }
        Button(LocalizedStringKey("queue.startAll")) { Task { await model.setAllQueuesRunning(true) } }
            .disabled(model.queues.isEmpty)
        Button(LocalizedStringKey("queue.stopAll")) { Task { await model.setAllQueuesRunning(false) } }
            .disabled(model.queues.isEmpty)
        Button(LocalizedStringKey("commands.stopAllDownloads")) { Task { await model.stopAllDownloads() } }
        Button(LocalizedStringKey("menubar.open")) { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(LocalizedStringKey("menubar.quit")) { NSApp.terminate(nil) }
    }
}
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    private var inDownloads: Bool { model.section == .downloads }
    private func localized(_ key: String) -> String {
        AppLocalization.string(key, language: model.settings.language)
    }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(localized("toolbar.newDownload")) { model.beginNewDownload() }.keyboardShortcut("n", modifiers: .command)
            Button(localized("commands.newFromClipboard")) { model.beginNewDownload(prefillFromClipboard: true) }
            Button(localized("commands.newBatch")) { model.beginNewDownload(batchMode: true) }
            Button(localized("commands.refresh")) { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu(localized("menu.tasks")) {
            Button(localized("commands.selectAll")) {
                guard inDownloads else { return }
                model.selectAllVisible(!model.isAllVisibleSelected)
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!inDownloads)
            Button(localized("task.edit")) { model.requestEdit(ids: model.selectedIDs) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!inDownloads || model.selectedIDs.count != 1 || model.filteredTasks.first(where: { model.selectedIDs.contains($0.id) })?.canEdit != true)
            Button(localized("commands.deleteSelected")) {
                guard inDownloads else { return }
                _ = model.requestDeleteConfirmation()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.deleteVisible"), role: .destructive) {
                guard inDownloads else { return }
                _ = model.requestDeleteVisibleConfirmation()
            }
            .disabled(!inDownloads || model.filteredTasks.isEmpty)
            Button(localized("commands.deleteAll"), role: .destructive) {
                guard inDownloads else { return }
                _ = model.requestDeleteAllConfirmation()
            }
            .disabled(!inDownloads || model.tasks.isEmpty)
            Divider()
            Button(localized("commands.startSelected")) {
                guard inDownloads else { return }
                Task { await model.startSelected() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.pauseSelected")) {
                guard inDownloads else { return }
                Task { await model.pauseSelected() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.resumeSelected")) {
                guard inDownloads else { return }
                Task { await model.resumeSelected() }
            }
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.retrySelected")) {
                guard inDownloads else { return }
                Task { await model.retrySelected() }
            }
            .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.stopAllDownloads")) {
                guard inDownloads else { return }
                Task { await model.stopAllDownloads() }
            }
            .disabled(!inDownloads)
            Divider()
            Menu(localized("commands.startQueue")) {
                ForEach(model.queues.sorted { $0.order < $1.order }) { queue in
                    Button(queue.name) { Task { await model.setQueueRunning(id: queue.id, running: true) } }
                }
            }.disabled(!inDownloads || model.queues.isEmpty)
            Menu(localized("commands.stopQueue")) {
                ForEach(model.queues.sorted { $0.order < $1.order }) { queue in
                    Button(queue.name) { Task { await model.setQueueRunning(id: queue.id, running: false) } }
                }
            }.disabled(!inDownloads || model.queues.isEmpty)
            Button(localized("queue.startAll")) { Task { await model.setAllQueuesRunning(true) } }
                .disabled(!inDownloads || model.queues.isEmpty)
            Button(localized("queue.stopAll")) { Task { await model.setAllQueuesRunning(false) } }
                .disabled(!inDownloads || model.queues.isEmpty)
            Divider()
            Button(localized("commands.deleteCompleted"), role: .destructive) { _ = model.requestDeleteCompletedConfirmation() }
                .disabled(!inDownloads || model.tasks.isEmpty)
            Button(localized("commands.deleteFailed"), role: .destructive) { _ = model.requestDeleteFailedConfirmation() }
                .disabled(!inDownloads || model.tasks.isEmpty)
            Button(localized("commands.deleteIncomplete"), role: .destructive) { _ = model.requestDeleteIncompleteConfirmation() }
                .disabled(!inDownloads || model.tasks.isEmpty)
            Button(localized("commands.deleteMissingFiles"), role: .destructive) { _ = model.requestDeleteMissingFilesConfirmation() }
                .disabled(!inDownloads || model.tasks.isEmpty)
            Divider()
            Menu(localized("commands.moveToQueue")) {
                ForEach(model.queues) { queue in
                    Button(queue.name) { Task { await model.moveSelectedToQueue(queue.id) } }
                }
            }.disabled(!inDownloads || model.isSelectionEmpty || model.queues.isEmpty)
            Menu(localized("commands.moveToCategory")) {
                ForEach(model.categories) { category in
                    Button(category.name) { Task { await model.moveSelectedToCategory(category.id) } }
                }
            }.disabled(!inDownloads || model.isSelectionEmpty || model.categories.isEmpty)
            Divider()
            Button(localized("commands.copyURLs")) { model.copyURLs(ids: model.selectedIDs) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.copyCurl")) { let ids = model.selectedIDs; Task { await model.copyCurl(ids: ids) } }
                .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.copyJSON")) { model.copyTaskJSON(ids: model.selectedIDs) }
                .disabled(!inDownloads || model.isSelectionEmpty)
            Button(localized("commands.revealSelected")) { model.revealTasks(ids: model.selectedIDs) }
                .disabled(!inDownloads || model.isSelectionEmpty)
        }
        CommandMenu(localized("menu.tools")) {
            Button(localized("menu.browserIntegration")) { model.openSettings(target: "settings.integration") }
            Button(localized("menu.hostSettings")) { model.openSettings(target: "settings.hosts") }
            Button(localized("settings.title")) { model.openSettings() }
            Divider()
            Button(localized("commands.checksumSelected")) { model.showChecksumForSelection(ids: model.selectedIDs) }
                .disabled(!model.hasChecksumFiles(ids: model.selectedIDs))
            Button(localized("toolbar.checksum")) { model.showChecksumPicker() }
        }
        CommandGroup(after: .help) {
            Button(localized("menu.supportCommunity")) { openProjectURL("issues") }
            Button(localized("menu.projectHome")) { openProjectURL("") }
            Button(localized("menu.openSourceLibraries")) { showAcknowledgements() }
            Button(localized("menu.translations")) { openProjectURL("issues/new?title=Translation%20feedback") }
            Divider()
            Button(localized("settings.checkUpdates")) { Task { await model.checkForUpdates() } }
                .disabled(model.settings.updateChannel == .disabled || model.isCheckingUpdates || model.settings.updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(localized("menu.about")) { NSApp.orderFrontStandardAboutPanel(nil) }
        }
    }

    private func openProjectURL(_ path: String) {
        let base = "https://github.com/xxkingstuggle/zjx-download"
        guard let url = URL(string: path.isEmpty ? base : "\(base)/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showAcknowledgements() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localized("menu.openSourceLibraries")
        alert.informativeText = AppLocalization.string("menu.acknowledgements", language: model.settings.language)
        alert.addButton(withTitle: localized("menu.openNotices"))
        alert.addButton(withTitle: localized("common.ok"))
        if alert.runModal() == .alertFirstButtonReturn {
            guard let noticesURL = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = localized("menu.openSourceLibraries")
                failure.informativeText = AppLocalization.string("menu.noticesMissing", language: model.settings.language)
                failure.runModal()
                return
            }
            NSWorkspace.shared.open(noticesURL)
        }
    }
}

struct CategoriesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appLanguage) private var language
    @State private var editing: DownloadCategory?
    @State private var deleting: DownloadCategory?
    @State private var showingReset = false
    var body: some View {
        List {
            ForEach(model.categories.sorted { $0.order < $1.order }) { category in
                HStack {
                    Image(systemName: category.icon).foregroundStyle(.tint)
                    VStack(alignment: .leading) { Text(category.name); Text(category.acceptedFileTypes.isEmpty ? AppLocalization.string("category.allFileTypes", language: language) : category.acceptedFileTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); if let path = category.defaultFolder { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Button { editing = category } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("category.edit"))
                    Button { deleting = category } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(LocalizedStringKey("common.delete"))
                }
            }
            .onMove { offsets, destination in var ids = model.categories.sorted { $0.order < $1.order }.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination); Task { try? await model.store?.reorderCategories(ids: ids); await model.refresh() } }
        }
        .toolbar {
            Menu {
                Button(LocalizedStringKey("category.new")) { editing = DownloadCategory(id: -1, name: "", order: model.categories.count) }
                Button(LocalizedStringKey("category.categorizeExisting")) { Task { await model.categorizeExistingTasks() } }
                Divider()
                Button(LocalizedStringKey("category.restoreDefaults"), role: .destructive) { showingReset = true }
            } label: { Label(LocalizedStringKey("category.actions"), systemImage: "ellipsis.circle") }
        }
        .navigationTitle(Text(AppLocalization.string("categories.title", language: model.settings.language)))
        .sheet(item: $editing) { CategoryEditorSheet(model: model, category: $0) }
        .alert(LocalizedStringKey("category.deleteTitle"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}; Button(LocalizedStringKey("common.delete"), role: .destructive) { if let deleting { Task { await model.deleteCategory(deleting) } } } } message: { Text(LocalizedStringKey("category.deleteMessage")) }
        .alert(LocalizedStringKey("category.restoreDefaultsTitle"), isPresented: $showingReset) { Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}; Button(LocalizedStringKey("category.restoreDefaults"), role: .destructive) { Task { await model.resetCategoriesToDefaults() } } } message: { Text(LocalizedStringKey("category.restoreDefaultsMessage")) }
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
            TextField(LocalizedStringKey("category.icon"), text: $category.icon)
            TextField(LocalizedStringKey("category.extensions"), text: $extensions)
            TextField(LocalizedStringKey("category.patterns"), text: $hosts)
            HStack { Text(category.defaultFolder ?? AppLocalization.string("category.noFolder", language: language)).lineLimit(1); Button(LocalizedStringKey("newDownload.choose")) { chooseFolder() }; if category.defaultFolder != nil { Button(LocalizedStringKey("category.clear")) { category.defaultFolder = nil } } }
            HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button(LocalizedStringKey("task.save")) { category.acceptedFileTypes = split(extensions); category.acceptedURLPatterns = split(hosts); Task { if category.id < 0 { await model.addCategory(name: category.name, extensions: category.acceptedFileTypes, hosts: category.acceptedURLPatterns, folder: category.defaultFolder, icon: category.icon) } else { await model.saveCategory(category) }; dismiss() } }.keyboardShortcut(.defaultAction).disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty || category.icon.trimmingCharacters(in: .whitespaces).isEmpty) }
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
            TextField(LocalizedStringKey("host.userAgent"), text: $value.userAgent)
            TextField(LocalizedStringKey("host.authUsername"), text: $value.authUsername)
            SecureField(LocalizedStringKey("host.authPassword"), text: $value.authPassword)
            TextField(LocalizedStringKey("task.connections"), text: $threads); TextField(LocalizedStringKey("host.speed"), text: $speed); TextField(LocalizedStringKey("host.headers"), text: $headers)
            HStack {
                Spacer()
                Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }
                Button(LocalizedStringKey("task.save")) {
                    guard (threads.isEmpty || Int(threads) != nil), (speed.isEmpty || Int64(speed) != nil) else { model.lastError = AppLocalization.string("error.invalidHostSettings", language: language); return }
                    do {
                        let parsedHeaders = try DownloadInputParser.headers(headers)
                        Task {
                            await model.saveHostOverride(host: value.host, userAgent: value.userAgent, authUsername: value.authUsername, authPassword: value.authPassword, headers: parsedHeaders, threadCount: Int(threads), speedLimit: Int64(speed), defaultFolder: value.defaultFolder, categoryID: value.categoryID)
                            dismiss()
                        }
                    } catch { model.lastError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 620)
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { value.defaultFolder = panel.url?.path } }
}
