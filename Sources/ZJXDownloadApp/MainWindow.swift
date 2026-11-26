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
    @State private var pendingImportText: String?
    @State private var showingQueues = false
    @State private var showingCategories = false
    @State private var showingChecksum = false
    @State private var checksumFile: URL?
    @State private var showingDeleteAlert = false
    @State private var deleteFiles = false
    @State private var errorText: String?
    @State private var dismissedActionMessage: String?
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

    private var statusTaskCounts: [DownloadStatus: Int] {
        coordinator.data.tasks.reduce(into: [:]) { counts, task in
            counts[task.status, default: 0] += 1
        }
    }

    private var filterTitle: String {
        switch filter {
        case .all:
            "全部任务"
        case .status(let status):
            status.title
        case .category(let id):
            coordinator.data.categories.first(where: { $0.id == id })?.name ?? "分类"
        case .queue(let id):
            coordinator.data.queues.first(where: { $0.id == id })?.name ?? "队列"
        }
    }

    private var selectedTasks: [DownloadRecord] {
        let selected = coordinator.selectedTaskIDs
        guard !selected.isEmpty else { return [] }
        return coordinator.data.tasks.filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailColumn
            .navigationTitle("")
            .background {
                WindowGlassBackdrop(isTransparent: !reduceTransparency)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .sheet(isPresented: $showingComposer) { DownloadComposer(coordinator: coordinator) }
            .sheet(isPresented: Binding(get: { editingTaskID != nil }, set: { if !$0 { editingTaskID = nil } })) {
                if let editingTaskID { DownloadComposer(coordinator: coordinator, editingTaskID: editingTaskID) }
            }
            .sheet(isPresented: $showingImporter, onDismiss: { pendingImportText = nil }) {
                BatchImportView(coordinator: coordinator, initialText: pendingImportText)
            }
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
                pendingImportText = NSPasteboard.general.string(forType: .string)
                showingImporter = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedDownloadsRequested)) { _ in
                guard !coordinator.selectedTaskIDs.isEmpty else { return }
                showingDeleteAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSelectedDownloadRequested)) { _ in
                guard coordinator.selectedTaskIDs.count == 1, let id = coordinator.selectedTaskIDs.first,
                      let task = coordinator.data.tasks.first(where: { $0.id == id }),
                      !task.status.isActive, task.status != .completed else { return }
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
            .onChange(of: coordinator.lastActionMessage) { _, next in
                if next != dismissedActionMessage { dismissedActionMessage = nil }
            }
        }
        .containerBackground(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear, for: .window)
    }

    private var sidebarContent: some View {
        let categoryCounts = categoryTaskCounts
        let statusCounts = statusTaskCounts
        return List(selection: $filter) {
            Section("任务") {
                Label("全部", systemImage: "tray.full.fill")
                    .badge(coordinator.data.tasks.count)
                    .tag(TaskFilter.all)
                ForEach(DownloadStatus.allCases, id: \.self) { status in
                    let count = statusCounts[status, default: 0]
                    Label(status.title, systemImage: status.symbol)
                        .badge(count)
                        .tag(TaskFilter.status(status))
                }
            }
            Section("分类") {
                ForEach(coordinator.data.categories.sorted { $0.order < $1.order }) { category in
                    Label(category.name, systemImage: category.symbol)
                        .badge(categoryCounts[category.id, default: 0])
                        .tag(TaskFilter.category(category.id))
                }
                Button { showingCategories = true } label: { Label("管理分类…", systemImage: "slider.horizontal.3") }
            }
            Section("队列") {
                ForEach(coordinator.data.queues.sorted { $0.order < $1.order }) { queue in
                    HStack(spacing: 6) {
                        Image(systemName: queue.isRunning ? "play.circle.fill" : "list.number")
                            .foregroundStyle(queue.isRunning ? Color.green : Color.secondary)
                        Text(queue.name)
                            .lineLimit(1)
                    }
                    .badge(queue.taskIDs.count)
                    .tag(TaskFilter.queue(queue.id))
                }
                Button { showingQueues = true } label: { Label("管理队列…", systemImage: "list.bullet.rectangle") }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(ProductIdentity.name)
    }

    private var detailColumn: some View {
        let visibleTasks = tasks
        let currentSelection = selectedTasks
        let canStartSelection = currentSelection.contains { $0.status.canResume }
        let canPauseSelection = currentSelection.contains { $0.status.isActive || $0.status == .queued }
        let canCancelSelection = currentSelection.contains { $0.status != .completed && $0.status != .cancelled }
        return VStack(spacing: 0) {
            if let startupError = coordinator.startupError {
                Label(startupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08))
            }
            headerBar(visibleCount: visibleTasks.count)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            if visibleTasks.isEmpty {
                emptyTaskList
            } else {
                taskTable(visibleTasks)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(reduceTransparency ? 0.7 : 0.35), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if let message = coordinator.lastActionMessage, !message.isEmpty {
                if message != dismissedActionMessage {
                    toastBanner(message)
                }
            }
            bottomStatusBar(
                visibleCount: visibleTasks.count,
                canStart: canStartSelection,
                canPause: canPauseSelection,
                canCancel: canCancelSelection
            )
        }
    }

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                dismissedActionMessage = message
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.85))
        .overlay(alignment: .top) { Divider() }
    }

    private func bottomStatusBar(visibleCount: Int, canStart: Bool, canPause: Bool, canCancel: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(visibleCount) 项")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            FooterLiveSpeedView(liveState: coordinator.liveState, speedUnit: coordinator.data.settings.speedUnit)
            Divider().frame(height: 14)
            apiStatusBadge
            Divider().frame(height: 14)
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: coordinator.data.settings.defaultDownloadDirectory, isDirectory: true))
            } label: {
                Label(URL(fileURLWithPath: coordinator.data.settings.defaultDownloadDirectory).lastPathComponent, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开默认下载目录：\(coordinator.data.settings.defaultDownloadDirectory)")
            Button("更改…") { chooseDefaultDownloadDirectory() }
                .controlSize(.small)
            Spacer()
            ControlGroup {
                Button("开始") { coordinator.start(Array(coordinator.selectedTaskIDs)) }
                    .disabled(!canStart)
                Button("暂停") { coordinator.pause(Array(coordinator.selectedTaskIDs)) }
                    .disabled(!canPause)
                Button("取消") { coordinator.cancel(Array(coordinator.selectedTaskIDs)) }
                    .disabled(!canCancel)
            }
            .controlSize(.small)
            Button(role: .destructive) { showingDeleteAlert = true } label: { Text("删除…") }
                .controlSize(.small)
                .disabled(coordinator.selectedTaskIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.bar))
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyTaskList: some View {
        Group {
            if coordinator.data.tasks.isEmpty {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 64, height: 64)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(spacing: 6) {
                        Text("准备开始下载")
                            .font(.title3.weight(.semibold))
                        Text("支持多线程 Range 断点续传、HLS 清单抓取，以及 Chrome 扩展与命令行联动。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    HStack(spacing: 10) {
                        Button { showingComposer = true } label: {
                            Label("新建下载", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { showingImporter = true } label: {
                            Label("批量导入", systemImage: "text.badge.plus")
                        }
                        Button {
                            pendingImportText = NSPasteboard.general.string(forType: .string)
                            showingImporter = true
                        } label: {
                            Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                        }
                    }
                    apiStatusPill
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(query.isEmpty ? "此视图暂无任务" : "没有匹配的任务",
                          systemImage: query.isEmpty ? "tray" : "magnifyingglass")
                } description: {
                    if query.isEmpty {
                        Text("可以在左侧切换其他状态、分类或队列。")
                    } else {
                        Text("试试其他文件名或网址关键词，或清除搜索条件。")
                    }
                } actions: {
                    if !query.isEmpty {
                        Button("清除搜索") { query = "" }
                    } else if filter != .all {
                        Button("查看全部任务") { filter = .all }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func headerBar(visibleCount: Int) -> some View {
        let barContent = HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(filterTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("\(visibleCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            Spacer(minLength: 8)
            TextField("搜索名称或网址", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 260)
            Button { showingComposer = true } label: {
                if coordinator.data.settings.showToolbarLabels {
                    Label("新建下载", systemImage: "plus")
                } else {
                    Image(systemName: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .help("新建下载 (⌘N)")
            Button { showingImporter = true } label: {
                if coordinator.data.settings.showToolbarLabels {
                    Label("批量导入", systemImage: "text.badge.plus")
                } else {
                    Image(systemName: "text.badge.plus")
                }
            }
            .help("批量导入 (⇧⌘I)")
            SettingsLink { Image(systemName: "gearshape") }
                .help("设置 (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, coordinator.data.settings.compactToolbar ? 7 : 12)

        if reduceTransparency {
            barContent
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.5)
                )
        } else {
            barContent
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var apiStatusBadge: some View {
        if let port = server.listeningPort {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("127.0.0.1:\(String(port))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("本机集成服务已就绪")
        } else if let lastError = server.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("重试") { server.retryListening() }
                    .controlSize(.mini)
            }
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text("接口已关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var apiStatusPill: some View {
        HStack(spacing: 8) {
            apiStatusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private func taskTable(_ rows: [DownloadRecord]) -> some View {
        Table(rows, selection: $coordinator.selectedTaskIDs, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("状态") { task in
                TaskStatusPill(status: task.status)
            }
            .width(min: 84, ideal: 94, max: 112).customizationID("status")
            TableColumn("文件名", value: \.displayName) { task in
                TaskNameProgressCell(task: task, liveState: coordinator.liveState)
            }
                .customizationID("display-name")
            TableColumn("进度", value: \.receivedBytes) { task in
                TaskProgressCell(task: task, liveState: coordinator.liveState, sizeUnit: coordinator.data.settings.sizeUnit)
            }.width(min: 86, ideal: 102, max: 140)
                .customizationID("progress")
            TableColumn("速度") { task in
                TaskSpeedCell(task: task, liveState: coordinator.liveState,
                              speedUnit: coordinator.data.settings.speedUnit,
                              averageEnabled: coordinator.data.settings.averageSpeedEnabled)
            }.width(min: 92, ideal: 106, max: 136).customizationID("speed")
            TableColumn("保存位置", value: \.destinationDirectory) { task in
                Text(task.destinationDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(task.outputURL.path)
            }
                .customizationID("destination")
            TableColumn("创建时间", value: \.createdAt) { task in
                if coordinator.data.settings.useRelativeDates {
                    Text(task.createdAt, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text(task.createdAt.formatted()).foregroundStyle(.secondary)
                }
            }.width(min: 100, ideal: 120, max: 160).customizationID("created-at")
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            let targets = coordinator.data.tasks.filter { ids.contains($0.id) }
            Button("开始") { coordinator.start(Array(ids)) }
                .disabled(!targets.contains(where: { $0.status.canResume }))
            Button("暂停") { coordinator.pause(Array(ids)) }
                .disabled(!targets.contains(where: { $0.status.isActive || $0.status == .queued }))
            Button("恢复") { coordinator.resume(Array(ids)) }
                .disabled(!targets.contains(where: { $0.status.canResume }))
            Button("重新下载") { coordinator.redownload(Array(ids)) }
                .disabled(targets.isEmpty)
            Button("取消") { coordinator.cancel(Array(ids)) }
                .disabled(!targets.contains(where: { $0.status != .completed && $0.status != .cancelled }))
            Divider()
            Button("在 Finder 中显示") {
                if let id = ids.first, let task = coordinator.task(id) {
                    NSWorkspace.shared.activateFileViewerSelecting([task.outputURL])
                }
            }.disabled(ids.count != 1)
            Button("复制下载地址") {
                if let id = ids.first, let task = coordinator.task(id) {
                    copyToPasteboard(task.sourceURL)
                }
            }.disabled(ids.count != 1)
            Button("详情…") { if let id = ids.first { openTaskDetail(id) } }
                .disabled(ids.count != 1)
            Button("编辑…") { if let id = ids.first, ids.count == 1 { editingTaskID = id } }
                .disabled(ids.count != 1 || targets.first.map { $0.status.isActive || $0.status == .completed } != false)
            Divider()
            Button("删除…", role: .destructive) {
                coordinator.selectedTaskIDs = ids
                showingDeleteAlert = true
            }.disabled(ids.isEmpty)
        } primaryAction: { ids in if let id = ids.first { openTaskDetail(id) } }
    }

    private func openTaskDetail(_ id: Int64) {
        openWindow(id: "task-detail", value: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseDefaultDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: coordinator.data.settings.defaultDownloadDirectory, isDirectory: true)
        panel.prompt = "设为默认下载目录"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.updateSettings { $0.defaultDownloadDirectory = url.path }
        }
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
    let isTransparent: Bool

    func makeNSView(context: Context) -> TransparentWindowEffectView {
        let view = TransparentWindowEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isTransparent = isTransparent
        return view
    }

    func updateNSView(_ view: TransparentWindowEffectView, context: Context) {
        view.isTransparent = isTransparent
    }
}

private final class TransparentWindowEffectView: NSVisualEffectView {
    var isTransparent = true {
        didSet { applyWindowOpacity() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowOpacity()
    }

    private func applyWindowOpacity() {
        isHidden = !isTransparent
        window?.isOpaque = !isTransparent
    }
}

private struct TaskStatusPill: View {
    let status: DownloadStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.caption2.weight(.semibold))
            Text(status.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(status.color.opacity(0.26), lineWidth: 0.5))
    }
}

private struct TaskNameProgressCell: View {
    let task: DownloadRecord
    let liveState: TransferLiveState

    var body: some View {
        let received = liveState.receivedBytes[task.id] ?? task.receivedBytes
        let total = liveState.totalBytes[task.id] ?? task.totalBytes
        let progress: Double? = {
            guard let total, total > 0 else { return nil }
            let value = Double(received) / Double(total)
            return value.isFinite ? min(1, max(0, value)) : nil
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.displayName)
                    .fontWeight(task.status.isActive ? .medium : .regular)
                    .lineLimit(1)
                if task.kind == .hls {
                    Text("HLS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.indigo.opacity(0.14), in: Capsule())
                }
            }
            if task.status.isActive {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            } else if task.status == .paused, let progress, progress > 0 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TaskProgressCell: View {
    let task: DownloadRecord
    let liveState: TransferLiveState
    let sizeUnit: String

    var body: some View {
        let received = max(0, liveState.receivedBytes[task.id] ?? task.receivedBytes)
        let total = liveState.totalBytes[task.id] ?? task.totalBytes
        VStack(alignment: .leading, spacing: 1) {
            if let total, total > 0 {
                let fraction = Double(received) / Double(total)
                let percent = fraction.isFinite ? min(100, max(0, fraction * 100)) : 0
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(task.status == .completed ? .primary : .secondary)
                Text("\(ByteFormatting.size(received, unit: sizeUnit)) / \(ByteFormatting.size(total, unit: sizeUnit))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(ByteFormatting.size(received, unit: sizeUnit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TaskSpeedCell: View {
    let task: DownloadRecord
    let liveState: TransferLiveState
    let speedUnit: String
    let averageEnabled: Bool

    var body: some View {
        if !task.status.isActive {
            Text("—")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } else {
            let metric = liveState.metrics[task.id]
            let speed = averageEnabled ? (metric?.averageBytesPerSecond ?? 0) : (metric?.bytesPerSecond ?? 0)
            if speed.isFinite, speed > 0 {
                let clamped = speed >= Double(Int64.max) ? Int64.max : Int64(speed.rounded(.towardZero))
                Text(ByteFormatting.speed(clamped, unit: speedUnit))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FooterLiveSpeedView: View {
    let liveState: TransferLiveState
    let speedUnit: String

    var body: some View {
        let total = liveState.totalActiveSpeed
        if total.isFinite, total > 0 {
            let clamped = total >= Double(Int64.max) ? Int64.max : Int64(total.rounded(.towardZero))
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text(ByteFormatting.speed(clamped, unit: speedUnit))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }
}

private extension DownloadStatus {
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .preparing: "arrow.trianglehead.2.clockwise"
        case .downloading: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .downloading: .blue
        case .preparing: .indigo
        case .paused: .orange
        case .queued, .cancelled: .secondary
        }
    }
}

extension Notification.Name { static let importTextRequested = Notification.Name("zjx.download.import.text") }
