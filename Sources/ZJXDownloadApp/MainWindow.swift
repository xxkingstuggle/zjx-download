import SwiftUI
import AppKit
import ZJXDownloadCore

struct MainWindow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.openWindow) private var openWindow
    @Bindable var coordinator: TaskCoordinator
    @Bindable var server: IntegrationServer
    let statusEventRelay: TaskStatusEventRelay
    @State private var filter = TaskFilter.all
    @State private var query = ""
    @State private var showingComposer = false
    @State private var editingTaskID: Int64?
    @State private var showingImporter = false
    @State private var showingQueues = false
    @State private var showingCategories = false
    @State private var showingChecksum = false
    @State private var checksumFile: URL?
    @State private var showingDeleteAlert = false
    @State private var deleteFiles = false
    @State private var errorText: String?
    @State private var sortOrder: [KeyPathComparator<DownloadRecord>] = [KeyPathComparator(\.createdAt, order: .reverse)]
    @AppStorage("zjx-download.main-table.columns") private var columnCustomization = TableColumnCustomization<DownloadRecord>()
    @AppStorage("zjx-download.main-table.sort-key") private var storedSortKey = "createdAt"
    @AppStorage("zjx-download.main-table.sort-order") private var storedSortOrder = "reverse"
    private var tasks: [DownloadRecord] {
        coordinator.data.tasks.filter { task in
            filter.includes(task) &&
            (query.isEmpty || task.displayName.localizedCaseInsensitiveContains(query) || task.sourceURL.localizedCaseInsensitiveContains(query))
        }.sorted(using: sortOrder)
    }

    private var categoryTaskCounts: [Int64: Int] {
        coordinator.data.tasks.reduce(into: [:]) { counts, task in
            if let categoryID = task.categoryID { counts[categoryID, default: 0] += 1 }
        }
    }

    var body: some View {
        NavigationSplitView {
            let categoryCounts = categoryTaskCounts
            List(selection: $filter) {
                Section("任务") {
                    Label("全部", systemImage: "tray.full.fill").tag(TaskFilter.all)
                    ForEach(DownloadStatus.allCases, id: \.self) { status in
                        Label(status.title, systemImage: status.symbol).tag(TaskFilter.status(status))
                    }
                }
                Section("分类") {
                    ForEach(coordinator.data.categories.sorted { $0.order < $1.order }) { category in
                        Label("\(category.name) · \(categoryCounts[category.id, default: 0])", systemImage: category.symbol).tag(TaskFilter.category(category.id))
                    }
                    Button { showingCategories = true } label: { Label("管理分类…", systemImage: "slider.horizontal.3") }
                }
                Section("队列") {
                    ForEach(coordinator.data.queues.sorted { $0.order < $1.order }) { queue in
                        Label(queue.name, systemImage: queue.isRunning ? "play.fill" : "list.number").tag(TaskFilter.queue(queue.id))
                    }
                    Button { showingQueues = true } label: { Label("管理队列…", systemImage: "list.bullet.rectangle") }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(ProductIdentity.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingComposer = true } label: {
                        if coordinator.data.settings.showToolbarLabels { Label("新建下载", systemImage: "plus") }
                        else { Image(systemName: "plus") }
                    }.help("新建下载")
                }
            }
        } detail: {
            let visibleTasks = tasks
            VStack(spacing: 0) {
                if let startupError = coordinator.startupError {
                    Label(startupError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.red.opacity(0.08))
                }
                HStack {
                    Text(filter.title).font(.title2.weight(.semibold))
                    Spacer()
                    TextField("搜索名称或网址", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Button { showingImporter = true } label: { Label("批量导入", systemImage: "text.badge.plus") }
                    SettingsLink { Image(systemName: "gearshape") }.help("设置")
                }.padding(.horizontal)
                    .padding(.vertical, coordinator.data.settings.compactToolbar ? 6 : 14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                if visibleTasks.isEmpty {
                    emptyTaskList
                } else {
                    taskTable(visibleTasks)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                HStack {
                    Text("\(visibleTasks.count) 项").foregroundStyle(.secondary)
                    if let port = server.listeningPort { Label("本机接口 127.0.0.1:\(port)", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(.secondary) }
                    else if let lastError = server.lastError { Label(lastError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("开始") { coordinator.start(Array(coordinator.selectedTaskIDs)) }.disabled(coordinator.selectedTaskIDs.isEmpty)
                    Button("暂停") { coordinator.pause(Array(coordinator.selectedTaskIDs)) }.disabled(coordinator.selectedTaskIDs.isEmpty)
                    Button("取消") { coordinator.cancel(Array(coordinator.selectedTaskIDs)) }.disabled(coordinator.selectedTaskIDs.isEmpty)
                    Button(role: .destructive) { showingDeleteAlert = true } label: { Text("删除…") }.disabled(coordinator.selectedTaskIDs.isEmpty)
                }.padding(.horizontal).padding(.vertical, 10).background(.bar)
                if let message = coordinator.lastActionMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal) }
            }
            .navigationTitle("")
            .background {
                if !reduceTransparency {
                    WindowGlassBackdrop().ignoresSafeArea().allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showingComposer) { DownloadComposer(coordinator: coordinator) }
            .sheet(isPresented: Binding(get: { editingTaskID != nil }, set: { if !$0 { editingTaskID = nil } })) {
                if let editingTaskID { DownloadComposer(coordinator: coordinator, editingTaskID: editingTaskID) }
            }
            .sheet(isPresented: $showingImporter) { BatchImportView(coordinator: coordinator) }
            .sheet(isPresented: $showingQueues) { QueueViews(coordinator: coordinator) }
            .sheet(isPresented: $showingCategories) { CategoryViews(coordinator: coordinator) }
            .sheet(isPresented: $showingChecksum) { ChecksumViews(initialFile: checksumFile) }
            .alert("删除下载任务", isPresented: $showingDeleteAlert) {
                Toggle("同时删除已完成文件", isOn: $deleteFiles)
                Button("取消", role: .cancel) { deleteFiles = false }
                Button("删除任务", role: .destructive) {
                    let errors = coordinator.remove(Array(coordinator.selectedTaskIDs), removeCompletedFiles: deleteFiles)
                    if !errors.isEmpty { errorText = errors.joined(separator: "\n") }
                    deleteFiles = false
                }
            } message: { Text("未完成任务会删除其可恢复的临时数据。已完成文件默认保留。") }
            .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
            .confirmationDialog("来自 Chrome 的下载请求", isPresented: Binding(
                get: { coordinator.pendingImportReview != nil },
                set: { showing in
                    guard !showing, let id = coordinator.pendingImportReview?.id else { return }
                    DispatchQueue.main.async { coordinator.resolveImportReview(id, accepted: false) }
                }
            ), titleVisibility: .visible) {
                if let review = coordinator.pendingImportReview {
                    Button("添加 \(review.totalCount) 项") { coordinator.resolveImportReview(review.id, accepted: true) }
                    Button("拒绝请求", role: .destructive) { coordinator.resolveImportReview(review.id, accepted: false) }
                }
            } message: {
                if let review = coordinator.pendingImportReview {
                    let names = review.items.map { "\($0.title) · \($0.source)" }.joined(separator: "\n")
                    Text(names + (review.totalCount > review.items.count ? "\n另有 \(review.totalCount - review.items.count) 项" : ""))
                }
            }
            .onAppear {
                restoreTableSort()
                let openWindow = openWindow
                statusEventRelay.registerPresentationHandler({ taskID in
                    openWindow(id: "task-detail", value: taskID)
                    NSApp.activate(ignoringOtherApps: true)
                }, showMain: { showDownloadMainWindow(using: openWindow) })
            }
            .onChange(of: sortOrder) { _, value in saveTableSort(value) }
            .onReceive(NotificationCenter.default.publisher(for: .newDownloadRequested)) { _ in showingComposer = true }
            .onReceive(NotificationCenter.default.publisher(for: .pasteDownloadRequested)) { _ in
                if let value = NSPasteboard.general.string(forType: .string) { NotificationCenter.default.post(name: .importTextRequested, object: value) }
                showingImporter = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedDownloadsRequested)) { _ in
                guard !coordinator.selectedTaskIDs.isEmpty else { return }
                showingDeleteAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSelectedDownloadRequested)) { _ in
                guard coordinator.selectedTaskIDs.count == 1, let id = coordinator.selectedTaskIDs.first,
                      let task = coordinator.task(id), !task.status.isActive, task.status != .completed else { return }
                editingTaskID = id
            }
            .onReceive(NotificationCenter.default.publisher(for: .checksumRequested)) { note in
                checksumFile = note.object as? URL; showingChecksum = true
            }
            .onChange(of: coordinator.pendingImportReview?.id) { _, id in
                guard id != nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.title == ProductIdentity.name })?.makeKeyAndOrderFront(nil)
            }
        }
        .containerBackground(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear, for: .window)
    }

    private var emptyTaskList: some View {
        ContentUnavailableView {
            if coordinator.data.tasks.isEmpty {
                Label("还没有下载任务", systemImage: "arrow.down.circle")
            } else {
                Label(query.isEmpty ? "此视图暂无任务" : "没有匹配的任务", systemImage: "magnifyingglass")
            }
        } description: {
            if coordinator.data.tasks.isEmpty {
                Text("添加下载链接，或批量导入已有链接。")
            } else if query.isEmpty {
                Text("可以在侧栏选择其他状态、分类或队列。")
            } else {
                Text("试试其他名称或网址，或清除搜索查看当前视图。")
            }
        } actions: {
            if coordinator.data.tasks.isEmpty {
                Button("新建下载") { showingComposer = true }.buttonStyle(.borderedProminent)
                Button("批量导入") { showingImporter = true }
            } else if !query.isEmpty {
                Button("清除搜索") { query = "" }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskTable(_ rows: [DownloadRecord]) -> some View {
        Table(rows, selection: $coordinator.selectedTaskIDs, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("状态") { task in Label(task.status.title, systemImage: task.status.symbol).labelStyle(.titleOnly).foregroundStyle(task.status.color) }
                .width(78).customizationID("status")
            TableColumn("文件名", value: \.displayName) { task in VStack(alignment: .leading, spacing: 3) { Text(task.displayName).lineLimit(1); if task.status == .downloading { ProgressView(value: task.progress).controlSize(.small) } } }
                .customizationID("display-name")
            TableColumn("进度", value: \.receivedBytes) { task in Text(progressText(task)).monospacedDigit().foregroundStyle(.secondary) }.width(90)
                .customizationID("progress")
            TableColumn("速度") { task in
                let metric = coordinator.liveMetrics[task.id]
                let speed = coordinator.data.settings.averageSpeedEnabled
                    ? metric?.averageBytesPerSecond ?? 0 : metric?.bytesPerSecond ?? 0
                Text(ByteFormatting.speed(safeByteRate(speed), unit: coordinator.data.settings.speedUnit)).foregroundStyle(.secondary)
            }.width(100).customizationID("speed")
            TableColumn("保存位置", value: \.destinationDirectory) { task in Text(task.destinationDirectory).lineLimit(1).foregroundStyle(.secondary) }
                .customizationID("destination")
            TableColumn("创建时间", value: \.createdAt) { task in
                if coordinator.data.settings.useRelativeDates {
                    Text(task.createdAt, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text(task.createdAt.formatted()).foregroundStyle(.secondary)
                }
            }.width(110).customizationID("created-at")
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("开始") { coordinator.start(Array(ids)) }
            Button("暂停") { coordinator.pause(Array(ids)) }
            Button("恢复") { coordinator.resume(Array(ids)) }
            Button("在 Finder 中显示") { if let id = ids.first, let task = coordinator.task(id) { NSWorkspace.shared.activateFileViewerSelecting([task.outputURL]) } }
            Button("复制下载地址") { if let id = ids.first, let task = coordinator.task(id) { NSPasteboard.general.setString(task.sourceURL, forType: .string) } }
            Button("详情…") { if let id = ids.first { openTaskDetail(id) } }
            Button("编辑…") { if let id = ids.first, ids.count == 1 { editingTaskID = id } }
                .disabled(ids.count != 1 || ids.first.flatMap(coordinator.task).map { $0.status.isActive || $0.status == .completed } != false)
        } primaryAction: { ids in if let id = ids.first { openTaskDetail(id) } }
    }

    private func openTaskDetail(_ id: Int64) {
        openWindow(id: "task-detail", value: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func progressText(_ task: DownloadRecord) -> String {
        if let total = task.totalBytes, total > 0 {
            let fraction = Double(task.receivedBytes) / Double(total)
            let percent = fraction.isFinite ? min(100, max(0, fraction * 100)) : 0
            return "\(Int(percent.rounded()))%"
        }
        return ByteFormatting.size(max(0, task.receivedBytes), unit: coordinator.data.settings.sizeUnit)
    }

    private func safeByteRate(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value.rounded(.towardZero))
    }

    private func restoreTableSort() {
        let order: SortOrder = storedSortOrder == "forward" ? .forward : .reverse
        switch storedSortKey {
        case "displayName": sortOrder = [KeyPathComparator(\.displayName, order: order)]
        case "receivedBytes": sortOrder = [KeyPathComparator(\.receivedBytes, order: order)]
        case "destinationDirectory": sortOrder = [KeyPathComparator(\.destinationDirectory, order: order)]
        default: sortOrder = [KeyPathComparator(\.createdAt, order: order)]
        }
    }

    private func saveTableSort(_ value: [KeyPathComparator<DownloadRecord>]) {
        guard let comparator = value.first else { return }
        if comparator.keyPath == \DownloadRecord.displayName { storedSortKey = "displayName" }
        else if comparator.keyPath == \DownloadRecord.receivedBytes { storedSortKey = "receivedBytes" }
        else if comparator.keyPath == \DownloadRecord.destinationDirectory { storedSortKey = "destinationDirectory" }
        else if comparator.keyPath == \DownloadRecord.createdAt { storedSortKey = "createdAt" }
        else { return }
        storedSortOrder = comparator.order == .forward ? "forward" : "reverse"
    }
}

private enum TaskFilter: Hashable, Identifiable {
    case all, status(DownloadStatus), category(Int64), queue(Int64)
    var id: String { switch self { case .all: "all"; case .status(let value): "status-\(value.rawValue)"; case .category(let id): "category-\(id)"; case .queue(let id): "queue-\(id)" } }
    var title: String { switch self { case .all: "全部任务"; case .status(let status): status.title; case .category(let id): "分类 \(id)"; case .queue(let id): "队列 \(id)" } }
    var status: DownloadStatus? { if case .status(let status) = self { status } else { nil } }
    func includes(_ task: DownloadRecord) -> Bool {
        switch self {
        case .all: true
        case .status(let status): task.status == status
        case .category(let id): task.categoryID == id
        case .queue(let id): task.queueID == id
        }
    }
}

private struct WindowGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentWindowEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class TransparentWindowEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        window?.isOpaque = false
    }
}

private extension DownloadStatus {
    var symbol: String { switch self { case .queued: "clock"; case .preparing: "arrow.trianglehead.2.clockwise"; case .downloading: "arrow.down.circle.fill"; case .paused: "pause.circle"; case .failed: "exclamationmark.circle"; case .completed: "checkmark.circle.fill"; case .cancelled: "xmark.circle" } }
    var color: Color { switch self { case .completed: .green; case .failed: .red; case .downloading: .blue; default: .secondary } }
}

extension Notification.Name { static let importTextRequested = Notification.Name("zjx.download.import.text") }
