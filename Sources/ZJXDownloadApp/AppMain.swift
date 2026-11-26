import SwiftUI
import AppKit
import Observation
import ZJXDownloadCore

@main
struct ZJXDownloadApplication: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
    @State private var coordinator: TaskCoordinator
    @State private var speedModeMonitor: GlobalSpeedModeMonitor
    @State private var integrationServer: IntegrationServer
    @State private var statusEventRelay: TaskStatusEventRelay

    init() {
        let value = TaskCoordinator()
        let monitor = GlobalSpeedModeMonitor(coordinator: value)
        monitor.setMode(value.data.settings.globalSpeedLimitMode)
        let server = IntegrationServer(coordinator: value)
        let statusEventRelay = TaskStatusEventRelay(coordinator: value)
        value.onQueueCompletionAction = { action in
            SystemCompletionActions.request(action, reason: "队列已完成")
        }
        value.onTaskCompletionAction = { action in
            SystemCompletionActions.request(action, reason: "此下载已完成")
        }
        value.onIntegrationSettingsChanged = { [weak server] settings in server?.restart(settings: settings) }
        value.onGlobalSpeedLimitModeChanged = { [weak monitor] mode in monitor?.setMode(mode) }
        _coordinator = State(initialValue: value)
        _speedModeMonitor = State(initialValue: monitor)
        _integrationServer = State(initialValue: server)
        _statusEventRelay = State(initialValue: statusEventRelay)
        lifecycleDelegate.configure(coordinator: value, speedModeMonitor: monitor,
                                    integrationServer: server, statusEventRelay: statusEventRelay)
    }

    @SceneBuilder var body: some Scene {
        WindowGroup(ProductIdentity.name, id: "main") {
            MainWindow(coordinator: coordinator, server: integrationServer,
                       statusEventRelay: statusEventRelay)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(colorScheme)
                .tint(themeTint)
                .font(appFont)
                .environment(\.locale, appLocale)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .commands { AppCommands(coordinator: coordinator) }
        WindowGroup("任务进度", id: "task-detail", for: Int64.self) { $taskID in
            if let taskID {
                TaskDetailViews(coordinator: coordinator, taskID: taskID)
                    .preferredColorScheme(colorScheme)
                    .tint(themeTint)
                    .font(appFont)
                    .environment(\.locale, appLocale)
                    .dynamicTypeSize(dynamicTypeSize)
            } else {
                ContentUnavailableView("没有选中的任务", systemImage: "arrow.down.circle")
            }
        }
        .defaultSize(width: 700, height: 500)
        .windowResizability(.contentMinSize)
        Window("新建下载", id: "new-download") {
            DownloadComposer(coordinator: coordinator)
                .preferredColorScheme(colorScheme)
                .tint(themeTint)
                .font(appFont)
                .environment(\.locale, appLocale)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
        Window("批量导入", id: "batch-import") {
            BatchImportView(coordinator: coordinator)
                .preferredColorScheme(colorScheme)
                .tint(themeTint)
                .font(appFont)
                .environment(\.locale, appLocale)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 840, height: 720)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsWindow(coordinator: coordinator, server: integrationServer)
                .preferredColorScheme(colorScheme)
                .tint(themeTint)
                .font(appFont)
                .environment(\.locale, appLocale)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
        Window("关于 zjx-download", id: "about") {
            AboutView()
                .preferredColorScheme(colorScheme)
                .tint(themeTint)
                .font(appFont)
                .environment(\.locale, appLocale)
                .dynamicTypeSize(dynamicTypeSize)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 390)
        .windowResizability(.contentMinSize)
        MenuBarExtra(ProductIdentity.name, systemImage: "arrow.down.circle", isInserted: Binding(
            get: { coordinator.data.settings.menuBarEnabled },
            set: { enabled in
                guard enabled != coordinator.data.settings.menuBarEnabled else { return }
                Task { @MainActor in
                    guard enabled != coordinator.data.settings.menuBarEnabled else { return }
                    coordinator.updateSettings { $0.menuBarEnabled = enabled }
                }
            }
        )) {
            DownloadMenuBarContent(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)
    }

    private var colorScheme: ColorScheme? {
        switch coordinator.data.settings.appearance {
        case .system:
            nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var appLocale: Locale {
        let selected = coordinator.data.settings.language
        if selected == "zh-Hans" { return Locale(identifier: "zh-Hans") }
        if Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh" { return .autoupdatingCurrent }
        return Locale(identifier: "zh-Hans")
    }

    private var appFont: Font? {
        guard let name = coordinator.data.settings.fontName, !name.isEmpty,
              NSFont(name: name, size: 13) != nil else { return nil }
        return .custom(name, size: 13, relativeTo: .body)
    }

    private var themeTint: Color {
        switch coordinator.data.settings.theme {
        case "Obsidian": .purple
        case "Deep Ocean": .cyan
        case "Twilight": .pink
        case "Black": .blue
        case "Light Gray": .gray
        case "Light": .orange
        default: .indigo
        }
    }

    private var dynamicTypeSize: DynamicTypeSize {
        switch coordinator.data.settings.scalePercent {
        case ..<90: .xSmall
        case ..<100: .small
        case ..<110: .medium
        case ..<120: .xLarge
        case ..<150: .xxLarge
        case ..<175: .xxxLarge
        case ..<200: .accessibility1
        default: .accessibility2
        }
    }
}

@MainActor
final class TaskStatusEventRelay {
    private let coordinator: TaskCoordinator
    private var lastSequence: UInt64
    private var isRunning = false
    private var presentationHandler: ((Int64) -> Void)?
    private var mainWindowHandler: (() -> Void)?
    private var presentedImportReviewID: UUID?
    private var pendingPresentationTaskIDs: [Int64] = []
    private var droppedPresentationCount = 0
    private let maximumPendingPresentations = 64

    init(coordinator: TaskCoordinator) {
        self.coordinator = coordinator
        lastSequence = coordinator.taskStatusRevision
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        consumeStatusEvents()
        observeNextRevision()
    }

    func stop() {
        isRunning = false
        presentationHandler = nil
        mainWindowHandler = nil
        pendingPresentationTaskIDs.removeAll()
    }

    func registerPresentationHandler(_ handler: @escaping (Int64) -> Void, showMain: @escaping () -> Void) {
        presentationHandler = handler
        mainWindowHandler = showMain
        presentImportReviewIfNeeded()
        let pending = pendingPresentationTaskIDs
        pendingPresentationTaskIDs.removeAll()
        for taskID in pending { handler(taskID) }
        if droppedPresentationCount > 0 {
            NSLog("zjx-download: deferred detail window queue dropped %ld older presentation(s).", droppedPresentationCount)
            droppedPresentationCount = 0
        }
    }

    private func observeNextRevision() {
        guard isRunning else { return }
        withObservationTracking {
            _ = coordinator.taskStatusRevision
            _ = coordinator.pendingImportReview?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.consumeStatusEvents()
                self.presentImportReviewIfNeeded()
                self.observeNextRevision()
            }
        }
    }

    private func presentImportReviewIfNeeded() {
        guard let reviewID = coordinator.pendingImportReview?.id else {
            presentedImportReviewID = nil
            return
        }
        guard reviewID != presentedImportReviewID, let mainWindowHandler else { return }
        presentedImportReviewID = reviewID
        mainWindowHandler()
        NSApp?.activate(ignoringOtherApps: true)
    }

    private func consumeStatusEvents() {
        let batch = coordinator.taskStatusEvents(after: lastSequence)
        lastSequence = batch.latestSequence
        if batch.hasGap {
            NSLog("zjx-download: status event history overflowed; processing the retained %ld event(s).", batch.events.count)
        }

        for event in batch.events {
            let started = event.newStatus.isActive && event.oldStatus?.isActive != true
            let completed = event.newStatus == .completed && event.oldStatus != .completed
            let failed = event.newStatus == .failed && event.oldStatus != .failed
            if started {
                SystemCompletionActions.playStartSound(settings: coordinator.data.settings)
            }
            if completed && event.oldStatus?.isActive == true {
                SystemCompletionActions.taskCompleted(event.displayName, settings: coordinator.data.settings)
            }
            if failed {
                SystemCompletionActions.taskFailed(event.displayName, message: event.error ?? "下载失败。",
                                                   settings: coordinator.data.settings)
            }

            let shouldPresent =
                (started && (event.showProgressWindow ?? coordinator.data.settings.showProgressWindow)) ||
                (completed && (event.showCompletionWindow ?? coordinator.data.settings.showCompletionWindow))
            if shouldPresent {
                if let index = pendingPresentationTaskIDs.firstIndex(of: event.taskID) {
                    pendingPresentationTaskIDs.remove(at: index)
                }
                if let presentationHandler {
                    presentationHandler(event.taskID)
                } else {
                    if pendingPresentationTaskIDs.count == maximumPendingPresentations {
                        pendingPresentationTaskIDs.removeFirst()
                        droppedPresentationCount += 1
                    }
                    pendingPresentationTaskIDs.append(event.taskID)
                }
            } else if event.newStatus == .completed || event.newStatus == .failed || event.newStatus == .cancelled {
                pendingPresentationTaskIDs.removeAll { $0 == event.taskID }
            }
        }
    }
}

private struct DownloadMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var coordinator: TaskCoordinator

    var body: some View {
        Button("打开主窗口") { showDownloadMainWindow(using: openWindow) }
        Button("新建下载…") { openWindow(id: "new-download"); NSApp.activate(ignoringOtherApps: true) }
        let activeCount = coordinator.taskCount(for: .downloading) + coordinator.taskCount(for: .preparing)
        let liveSpeed = coordinator.liveState.totalActiveSpeed
        if activeCount > 0, liveSpeed.isFinite, liveSpeed > 0 {
            Text("正在下载：\(activeCount) · \(ByteFormatting.speed(Int64(min(liveSpeed, Double(Int64.max))), unit: coordinator.data.settings.speedUnit))")
        } else {
            Text("正在下载：\(activeCount)")
        }
        Button("全部暂停") { coordinator.stopAll() }
            .disabled(!coordinator.hasOutstandingTransfers && coordinator.taskCount(for: .queued) == 0)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 zjx-download") { NSApp.terminate(nil) }
    }
}

@MainActor
func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor
func showDownloadMainWindow(using openWindow: OpenWindowAction) {
    if let window = NSApp?.windows.first(where: { $0.title == ProductIdentity.name }) {
        window.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
    NSApp?.activate(ignoringOtherApps: true)
}
