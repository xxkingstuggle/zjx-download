import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import AppIntents
import ABDownloadManagerCore


struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Downloads"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
@main
struct ABDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("AB Download Manager") { MainWindow(model: model) }
            .defaultSize(width: 1180, height: 760)
            .commands { AppCommands(model: model) }
        MenuBarExtra("AB Download Manager", systemImage: "arrow.down.circle") {
            MenuBarView(model: model)
        }
        Settings { SettingsView(model: model) }
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
    @Published var selectedTaskID: Int64?
    @Published var section: SidebarSection = .downloads
    @Published var isShowingNewDownload = false
    @Published var isShowingSettings = false
    @Published var lastError: String?
    @Published var progress: [Int64: DownloadProgress] = [:]
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
        let snapshot = await store.snapshot()
        settings = snapshot.settings; tasks = snapshot.tasks; queues = snapshot.queues; history = snapshot.history; categories = snapshot.categories; hostOverrides = snapshot.hostOverrides
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
        notifyForFinishedTasks(snapshot.tasks)
    }


    private func notifyForFinishedTasks(_ current: [DownloadTask]) {
        guard settings.notifications.showCompletionDialog else { return }
        for task in current {
            guard task.status == .completed || task.status == .failed, notifiedStatuses[task.id] != task.status else { continue }
            notifiedStatuses[task.id] = task.status
            let content = UNMutableNotificationContent()
            content.title = task.status == .completed ? "Download complete" : "Download failed"
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
    func editTask(_ task: DownloadTask, fileName: String, folder: String, urlText: String, queueID: Int64?, categoryID: Int64?, headers: [String: String], checksum: String?, speedLimit: Int64) async {
        guard let store, task.canEdit else { lastError = "This task cannot be edited while running."; return }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { lastError = "A stopped task requires a valid HTTP(S) URL."; return }
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
            if #available(macOS 13.0, *) {
                do {
                    if value.autoStartOnBoot { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                } catch { lastError = "Login item: \(error.localizedDescription)" }
            }
            await restartREST(using: value.integration)
            if value.clipboardMonitoring { clipboardMonitor?.start() } else { clipboardMonitor?.stop() }
        } catch { lastError = error.localizedDescription }
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

enum SidebarSection: String, CaseIterable, Identifiable { case downloads, queues, categories, history, settings; var id: String { rawValue }; var title: String { rawValue.capitalized }; var icon: String { switch self { case .downloads: "arrow.down.circle"; case .queues: "list.number"; case .categories: "square.grid.2x2"; case .history: "clock"; case .settings: "gear" } } }

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingChecksum = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Library") {
                    ForEach([SidebarSection.downloads, .queues, .categories, .history]) { section in Label(LocalizedStringKey("\(section.rawValue).title"), systemImage: section.icon).tag(section) }
                }
                Section("Application") { Label(LocalizedStringKey("settings.title"), systemImage: SidebarSection.settings.icon).tag(SidebarSection.settings) }
            }
            .navigationTitle("AB Download Manager")
            .safeAreaInset(edge: .bottom) { SidebarStatus(model: model) }
        } content: {
            switch model.section {
            case .downloads: DownloadList(model: model)
            case .queues: QueueList(model: model)
            case .categories: CategoriesView(model: model)
            case .history: HistoryList(model: model)
            case .settings: SettingsView(model: model)
            }
        } detail: {
            if let id = model.selectedTaskID, let task = model.tasks.first(where: { $0.id == id }) { TaskInspector(model: model, task: task, progress: model.progress[id]) }
            else { ContentUnavailableView("Select a Download", systemImage: "arrow.down.circle", description: Text("Choose an item to inspect its status and destination.")) }
        }
        .toolbar { ToolbarItemGroup { Button { model.isShowingNewDownload = true } label: { Label("New Download", systemImage: "plus") }; Button { showingChecksum = true } label: { Label("Checksum", systemImage: "number") }; Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } } }
        .sheet(isPresented: $model.isShowingNewDownload) { NewDownloadSheet(model: model) }
        .sheet(isPresented: $showingChecksum) { ChecksumToolView() }
        .alert("AB Download Manager", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) { Button("OK") {} } message: { Text(model.lastError ?? "") }
        .preferredColorScheme(model.settings.theme == .dark ? .dark : model.settings.theme == .light ? .light : nil)
        .modifier(GlassModifier(enabled: !reduceTransparency && !reduceMotion))
    }
}

struct GlassModifier: ViewModifier { let enabled: Bool; func body(content: Content) -> some View { if #available(macOS 26.0, *), enabled { content.glassEffect(.regular, in: .rect(cornerRadius: 12)) } else { content.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12)) } } }

struct SidebarStatus: View { @ObservedObject var model: AppModel; var body: some View { let active = model.tasks.filter { $0.status.isActive }.count; return Text("\(active) active · \(model.tasks.count) total").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12).accessibilityLabel("\(active) active downloads, \(model.tasks.count) total") } }

struct DownloadList: View {
    @ObservedObject var model: AppModel
    var visible: [DownloadTask] { model.tasks.filter { !$0.status.isTerminal }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        Group { if visible.isEmpty { ContentUnavailableView(LocalizedStringKey("downloads.empty.title"), systemImage: "arrow.down.circle", description: Text(LocalizedStringKey("downloads.empty.description"))) } else { List(selection: $model.selectedTaskID) { ForEach(visible) { task in DownloadRow(task: task, progress: model.progress[task.id], onStart: { Task { await model.start(task) } }, onPause: { Task { await model.pause(task) } }, onCancel: { Task { await model.cancel(task) } }, onRetry: { Task { await model.retry(task) } }).tag(task.id) } }.accessibilityLabel("Active downloads") } }
        .navigationTitle(LocalizedStringKey("downloads.title"))
    }
}

struct DownloadRow: View {
    let task: DownloadTask; let progress: DownloadProgress?; let onStart: () -> Void; let onPause: () -> Void; let onCancel: () -> Void; let onRetry: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { Text(task.fileName).lineLimit(1); HStack { ProgressView(value: task.progress); Text(statusText).font(.caption).foregroundStyle(.secondary) } }
            Spacer(); if task.status == .downloading { Button(action: onPause) { Image(systemName: "pause.fill") }.buttonStyle(.borderless).accessibilityLabel("Pause \(task.fileName)") } else if task.status.isResumable { Button(action: onStart) { Image(systemName: "play.fill") }.buttonStyle(.borderless).accessibilityLabel("Start \(task.fileName)") }; if task.status.isActive { Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Cancel \(task.fileName)") }
        }.padding(.vertical, 5).contextMenu { Button("Start", action: onStart); Button("Pause", action: onPause); Button("Cancel", action: onCancel); if task.status == .failed { Button("Retry", action: onRetry) } }
    }
    var icon: String { switch task.status { case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .paused: "pause.circle"; case .downloading: "arrow.down.circle.fill"; default: "circle" } }
    var color: Color { task.status == .failed ? .red : task.status == .completed ? .green : .accentColor }
    var statusText: String { if let progress { return "\(Int((progress.total.map { Double(progress.downloaded) / Double(max(1, $0)) } ?? task.progress) * 100))% · \(formatBytes(progress.bytesPerSecond))/s" }; return task.status.rawValue.capitalized }
    func formatBytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}

struct TaskInspector: View {
    @ObservedObject var model: AppModel
    let task: DownloadTask
    let progress: DownloadProgress?
    @State private var editing = false
    var body: some View {
        Form {
            LabeledContent("File", value: task.fileName); LabeledContent("Status", value: task.status.rawValue.capitalized); LabeledContent("Destination", value: task.folderPath)
            if let total = task.totalSize { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            LabeledContent("Connections", value: "\(task.connectionCount)")
            if let speed = progress?.bytesPerSecond { LabeledContent("Speed", value: ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
            if let eta = progress?.eta { LabeledContent("Time remaining", value: Duration.seconds(eta).formatted(.time(pattern: .hourMinuteSecond))) }
            if let error = task.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Edit Task") { editing = true }.disabled(!task.canEdit)
                if task.status == .completed { Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: task.filePath)) }; Button("Reveal") { NSWorkspace.shared.selectFile(task.filePath, inFileViewerRootedAtPath: task.folderPath) } }
            }
        }.formStyle(.grouped).padding().navigationTitle("Details").accessibilityElement(children: .contain).sheet(isPresented: $editing) { EditTaskSheet(model: model, task: task) }
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
            TextField("File name", text: $name); TextField("Folder", text: $folder); TextField("URL", text: $url).disabled(task.status == .completed)
            HStack { Picker("Queue", selection: $queueID) { Text("No queue").tag(Int64?.none); ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) } }; Picker("Category", selection: $categoryID) { Text("Automatic").tag(Int64?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } } }
            TextField("Headers Name: Value per line", text: $headers).disabled(task.status == .completed); TextField("Checksum", text: $checksum).disabled(task.status == .completed); TextField("Speed bytes/s", text: $speed).disabled(task.status == .completed)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { let parsed = Dictionary(uniqueKeysWithValues: headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> (String, String)? in let pair = line.split(separator: ":", maxSplits: 1).map(String.init); guard pair.count == 2 else { return nil }; return (pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces)) }); Task { await model.editTask(task, fileName: name, folder: folder, urlText: url, queueID: queueID, categoryID: categoryID, headers: parsed, checksum: checksum.isEmpty ? nil : checksum, speedLimit: Int64(speed) ?? 0); dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 650)
    }
}

struct NewDownloadSheet: View {
    @ObservedObject var model: AppModel
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
            Text("Paste one or more HTTP(S) links, one per line.").foregroundStyle(.secondary)
            TextEditor(text: $links).frame(minHeight: 105).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            DisclosureGroup("Batch URL pattern (optional)") {
                TextField("https://example.test/file-*.bin", text: $batchPattern)
                HStack { TextField("From", text: $batchStart); TextField("To", text: $batchEnd); TextField("Padding (0 = auto)", text: $batchPadding) }
                if let count = batchCount { Text("Preview: \(count) URLs").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { TextField("Destination folder", text: $folder); Button("Choose…") { chooseFolder() } }
            TextField("Request headers (one Name: Value per line)", text: $headers)
            HStack {
                TextField("Checksum (SHA-256:hex)", text: $checksum)
                TextField("Task limit bytes/s (0 = global)", text: $speed)
            }
            HStack {
                Picker("Queue", selection: $queueID) {
                    Text("No queue").tag(Int64?.none)
                    ForEach(model.queues) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Category", selection: $categoryID) {
                    Text("Automatic").tag(Int64?.none)
                    ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Conflict", selection: $conflict) { ForEach(FileConflictPolicy.allCases) { Text($0.rawValue.capitalized).tag($0) } }
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
    @State private var showingNewQueue = false
    @State private var editingQueue: DownloadQueue?
    var body: some View {
        List {
            ForEach(model.queues.sorted { $0.order < $1.order }) { queue in
                HStack {
                    Button { Task { await model.toggleQueue(queue) } } label: { Image(systemName: queue.isRunning ? "play.circle.fill" : "pause.circle") }.buttonStyle(.borderless).accessibilityLabel(queue.isRunning ? "Stop \(queue.name)" : "Start \(queue.name)")
                    Text(queue.name)
                    Button { editingQueue = queue } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel("Edit \(queue.name)")
                    Spacer()
                    Text("max \(queue.concurrencyLimit)").font(.caption).foregroundStyle(.secondary)
                    if model.queues.count > 1 { Button { Task { await model.deleteQueue(queue) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(queue.name)") }
                }
            }
            .onMove { offsets, destination in
                let ids = model.queues.sorted { $0.order < $1.order }.map(\.id)
                var reordered = ids; reordered.move(fromOffsets: offsets, toOffset: destination)
                Task { try? await model.store?.reorderQueues(ids: reordered); await model.refresh() }
            }
        }
        .toolbar { Button { showingNewQueue = true } label: { Label("New Queue", systemImage: "plus") } }
        .navigationTitle(LocalizedStringKey("queues.title"))
        .sheet(isPresented: $showingNewQueue) { NewQueueSheet(model: model) }
        .sheet(item: $editingQueue) { QueueEditSheet(model: model, queue: $0) }
    }
}

struct NewQueueSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var concurrency = 1
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form { TextField("Queue name", text: $name); Stepper("Concurrent downloads: \(concurrency)", value: $concurrency, in: 1...64); HStack { Spacer(); Button(LocalizedStringKey("newDownload.cancel")) { dismiss() }; Button("Create") { Task { await model.addQueue(name: name, concurrency: concurrency); dismiss() } }.keyboardShortcut(.defaultAction) } }.padding().frame(width: 420)
    }
}

struct QueueEditSheet: View {
    @ObservedObject var model: AppModel
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
            TextField("Queue name", text: $queue.name)
            Stepper("Concurrent downloads: \(queue.concurrencyLimit)", value: $queue.concurrencyLimit, in: 1...64)
            Toggle("Use schedule", isOn: $scheduleEnabled)
            if scheduleEnabled {
                HStack { TextField("Start HH:mm", text: $startText); TextField("End HH:mm", text: $endText) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) { ForEach(QueueSchedule.Weekday.allCases, id: \.self) { day in Toggle(day.rawValue.prefix(3).capitalized, isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } })) } }
                Text("End earlier than start creates an overnight window.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("When queue finishes", selection: $queue.completionAction) { ForEach(QueueCompletionAction.allCases) { Text($0.rawValue).tag($0) } }
            Text("Power actions are disabled by default and always require confirmation.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if queue.completionAction.isPowerAction { showPowerConfirmation = true } else { save() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 520).alert("Confirm queue completion action", isPresented: $showPowerConfirmation) { Button("Cancel", role: .cancel) {}; Button("Enable") { save() } } message: { Text("This action may quit the app or change computer power state after the queue finishes. It will never run without this confirmation.") }
    }
    private func save() { var value = queue; if scheduleEnabled, let start = QueueEditSheet.seconds(startText), let end = QueueEditSheet.seconds(endText) { value.schedule = QueueSchedule(weekdays: weekdays, startSeconds: start, endSeconds: end) } else { value.schedule = nil }; Task { await model.updateQueue(value); dismiss() } }
    static func seconds(_ text: String) -> Int? { let pair = text.split(separator: ":").compactMap { Int($0) }; guard pair.count == 2, pair[0] >= 0, pair[0] < 24, pair[1] >= 0, pair[1] < 60 else { return nil }; return pair[0] * 3600 + pair[1] * 60 }
    static func time(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60) }
}

struct HistoryList: View { @ObservedObject var model: AppModel; var body: some View { List(model.history) { record in VStack(alignment: .leading) { Text(record.name); Text(record.finishedAt.formatted()).font(.caption).foregroundStyle(.secondary); Button("Reveal in Finder") { NSWorkspace.shared.selectFile(record.folderPath + "/" + record.fileName, inFileViewerRootedAtPath: record.folderPath) }.buttonStyle(.link) } }.toolbar { Button("Clear History") { Task { guard let store = model.store else { return }; try? await store.clearHistory(); await model.refresh() } } }.navigationTitle(LocalizedStringKey("history.title")) } }

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.settings.theme) { ForEach(ThemeMode.allCases) { Text($0.displayName).tag($0) } }
                TextField("Language", text: Binding(get: { model.settings.language ?? "" }, set: { model.settings.language = $0.isEmpty ? nil : $0 }))
                Toggle("Monitor clipboard for links", isOn: $model.settings.clipboardMonitoring)
            }
            Section("Downloads") {
                Stepper("Connections: \(model.settings.threadCount)", value: $model.settings.threadCount, in: 1...64)
                Stepper("Concurrent downloads: \(model.settings.maxConcurrentDownloads)", value: $model.settings.maxConcurrentDownloads, in: 1...64)
                TextField("Download folder", text: $model.settings.defaultDownloadFolder)
                TextField("User-Agent", text: $model.settings.userAgent)
                TextField("Global speed limit bytes/s (0 = unlimited)", value: $model.settings.speedLimit, format: .number)
                Toggle("Delete partial files on cancellation", isOn: $model.settings.deletePartialFileOnDownloadCancellation)
            }
            Section("Proxy and TLS") {
                Picker("Proxy", selection: $model.settings.proxy.mode) { ForEach(ProxySettings.Mode.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                TextField("Proxy host", text: $model.settings.proxy.host)
                TextField("Proxy port", value: $model.settings.proxy.port, format: .number)
                TextField("Proxy user", text: $model.settings.proxy.username)
                SecureField("Proxy password", text: $model.settings.proxy.password)
                Toggle("Allow insecure certificates (not recommended)", isOn: $model.settings.tls.allowInsecureCertificates)
            }
            Section("Integration") {
                Toggle("Local REST service", isOn: $model.settings.integration.enabled)
                TextField("REST port", value: $model.settings.integration.port, format: .number)
                Toggle("Use API key", isOn: $model.settings.integration.authEnabled)
                SecureField("API key", text: $model.settings.integration.apiKey)
                Text("Bound only to 127.0.0.1:\(model.settings.integration.port)").font(.caption).foregroundStyle(.secondary)
            }
            HostOverridesView(model: model)
            Section("Notifications and updates") {
                Toggle("Notification sound", isOn: $model.settings.notifications.soundEnabled)
                Toggle("Completion notifications", isOn: $model.settings.notifications.showCompletionDialog)
                Toggle("Start at login", isOn: $model.settings.autoStartOnBoot)
                Picker("Update channel", selection: $model.settings.updateChannel) { ForEach(UpdateChannel.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                Text("Updates are disabled by default and never install an unsigned or upstream release.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Save Settings") { Task { await model.saveSettings() } }.keyboardShortcut(.defaultAction)
        }.formStyle(.grouped).padding().navigationTitle(LocalizedStringKey("settings.title"))
    }
}

struct MenuBarView: View { @ObservedObject var model: AppModel; var body: some View { Text("\(model.tasks.filter { $0.status.isActive }.count) active downloads"); Divider(); Button("New Download") { model.isShowingNewDownload = true }; Button("Open Window") { NSApp.activate(ignoringOtherApps: true) }; Divider(); Button("Quit") { NSApp.terminate(nil) } } }
struct AppCommands: Commands { @ObservedObject var model: AppModel; var body: some Commands { CommandGroup(after: .newItem) { Button("New Download") { model.isShowingNewDownload = true }.keyboardShortcut("n", modifiers: [.command, .shift]) }; CommandMenu("Downloads") { Button("Start Selected") { if let id = model.selectedTaskID, let task = model.tasks.first(where: { $0.id == id }) { Task { await model.start(task) } } }.keyboardShortcut(.return, modifiers: [.command]); Button("Pause Selected") { if let id = model.selectedTaskID, let task = model.tasks.first(where: { $0.id == id }) { Task { await model.pause(task) } } }.keyboardShortcut("p", modifiers: .command) } } }

struct CategoriesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: DownloadCategory?
    @State private var deleting: DownloadCategory?
    var body: some View {
        List {
            ForEach(model.categories.sorted { $0.order < $1.order }) { category in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.tint)
                    VStack(alignment: .leading) { Text(category.name); Text(category.acceptedFileTypes.isEmpty ? "All file types" : category.acceptedFileTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); if let path = category.defaultFolder { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Button { editing = category } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel("Edit \(category.name)")
                    Button { deleting = category } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(category.name)")
                }
            }
            .onMove { offsets, destination in var ids = model.categories.sorted { $0.order < $1.order }.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination); Task { try? await model.store?.reorderCategories(ids: ids); await model.refresh() } }
        }
        .toolbar { Button { editing = DownloadCategory(id: 0, name: "", order: model.categories.count) } label: { Label("New Category", systemImage: "plus") } }
        .navigationTitle("Categories")
        .sheet(item: $editing) { CategoryEditorSheet(model: model, category: $0) }
        .alert("Delete category?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { if let deleting { Task { await model.deleteCategory(deleting) } } } } message: { Text("Tasks in this category will keep their downloads but lose the category assignment.") }
    }
}

struct CategoryEditorSheet: View {
    @ObservedObject var model: AppModel
    @State var category: DownloadCategory
    @State private var extensions: String
    @State private var hosts: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, category: DownloadCategory) { self.model = model; _category = State(initialValue: category); _extensions = State(initialValue: category.acceptedFileTypes.joined(separator: ", ")); _hosts = State(initialValue: category.acceptedURLPatterns.joined(separator: ", ")) }
    var body: some View {
        Form {
            TextField("Category name", text: $category.name)
            TextField("Extensions (comma-separated)", text: $extensions)
            TextField("Host or URL patterns (comma-separated)", text: $hosts)
            HStack { Text(category.defaultFolder ?? "No default folder").lineLimit(1); Button("Choose…") { chooseFolder() }; if category.defaultFolder != nil { Button("Clear") { category.defaultFolder = nil } } }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { category.acceptedFileTypes = split(extensions); category.acceptedURLPatterns = split(hosts); Task { if category.id == 0 { await model.addCategory(name: category.name, extensions: category.acceptedFileTypes, hosts: category.acceptedURLPatterns, folder: category.defaultFolder) } else { await model.saveCategory(category) }; dismiss() } }.keyboardShortcut(.defaultAction).disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding().frame(width: 560)
    }
    private func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { category.defaultFolder = panel.url?.path } }
}

struct HostOverridesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: HostOverride?
    var body: some View {
        Section("Per-host defaults") {
            ForEach(model.hostOverrides) { value in
                HStack { Text(value.host); Spacer(); Text(value.threadCount.map(String.init) ?? "global").font(.caption); Button { editing = value } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel("Edit host override"); Button { Task { await model.deleteHostOverride(value) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete host override") }
            }
            Button("Add Host Override") { editing = HostOverride(host: "") }
        }.sheet(item: $editing) { HostOverrideEditorSheet(model: model, value: $0) }
    }
}

struct HostOverrideEditorSheet: View {
    @ObservedObject var model: AppModel
    @State var value: HostOverride
    @State private var threads: String; @State private var speed: String; @State private var headers: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, value: HostOverride) { self.model = model; _value = State(initialValue: value); _threads = State(initialValue: value.threadCount.map(String.init) ?? ""); _speed = State(initialValue: value.speedLimit.map(String.init) ?? ""); _headers = State(initialValue: value.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")) }
    var body: some View {
        Form {
            TextField("Host (example.test)", text: $value.host)
            HStack { Text(value.defaultFolder ?? "No default folder").lineLimit(1); Button("Choose…") { chooseFolder() }; if value.defaultFolder != nil { Button("Clear") { value.defaultFolder = nil } } }
            Picker("Default category", selection: $value.categoryID) { Text("None").tag(Int64?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } }
            TextField("Connections", text: $threads); TextField("Speed bytes/s", text: $speed); TextField("Headers Name: Value per line", text: $headers)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { let pairs = headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line -> (String, String)? in let parts = line.split(separator: ":", maxSplits: 1).map(String.init); guard parts.count == 2 else { return nil }; return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)) }; Task { await model.saveHostOverride(host: value.host, headers: Dictionary(uniqueKeysWithValues: pairs), threadCount: Int(threads), speedLimit: Int64(speed), defaultFolder: value.defaultFolder, categoryID: value.categoryID); dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 620)
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { value.defaultFolder = panel.url?.path } }
}
