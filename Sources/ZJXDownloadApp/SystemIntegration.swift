import SwiftUI
import AppKit
import ServiceManagement
import IOKit
import IOKit.pwr_mgt
import UserNotifications
import ZJXDownloadCore

struct SystemIntegration: View {
    @Bindable var coordinator: TaskCoordinator
    @State private var status = ""
    @State private var notificationStatus = ""
    var body: some View {
        Section("macOS 集成") {
            Toggle("登录时打开", isOn: Binding(get: { coordinator.data.settings.loginItemEnabled }, set: updateLoginItem))
            Toggle("在菜单栏显示", isOn: Binding(
                get: { coordinator.data.settings.menuBarEnabled },
                set: setMenuBarEnabled
            ))
            Toggle("启用 macOS 系统通知", isOn: Binding(
                get: { coordinator.data.settings.systemNotificationsEnabled },
                set: updateNotifications
            ))
            Text(status).font(.caption).foregroundStyle(.secondary)
            Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
            Text("登录项使用 macOS ServiceManagement。文件选择、Finder 操作、剪贴板、菜单栏和原生键盘命令由 AppKit / SwiftUI 提供。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            refreshLoginItemStatus()
            refreshNotificationStatus()
        }
    }
    private func setMenuBarEnabled(_ enabled: Bool) {
        guard enabled != coordinator.data.settings.menuBarEnabled else { return }
        Task { @MainActor in
            guard enabled != coordinator.data.settings.menuBarEnabled else { return }
            coordinator.updateSettings { $0.menuBarEnabled = enabled }
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let isEnabled = SMAppService.mainApp.status == .enabled
            coordinator.updateSettings { $0.loginItemEnabled = isEnabled }
            status = isEnabled ? "macOS 已启用登录项。" : (enabled ? "登录项等待系统批准。" : "登录项已关闭。")
        } catch { status = "无法更新登录项：\(error.localizedDescription)" }
    }

    private func refreshLoginItemStatus() {
        let serviceStatus = SMAppService.mainApp.status
        let enabled = serviceStatus == .enabled
        if coordinator.data.settings.loginItemEnabled != enabled {
            coordinator.updateSettings { $0.loginItemEnabled = enabled }
        }
        switch serviceStatus {
        case .enabled: status = "macOS 已启用登录项。"
        case .requiresApproval: status = "登录项等待系统批准；请在系统设置的登录项中确认。"
        case .notFound: status = "当前运行位置无法注册登录项。"
        case .notRegistered: status = "登录项未启用。"
        @unknown default: status = "登录项状态未知。"
        }
    }

    private func updateNotifications(_ enabled: Bool) {
        guard enabled else {
            coordinator.updateSettings { $0.systemNotificationsEnabled = false }
            notificationStatus = "系统通知已关闭。"
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                coordinator.updateSettings { $0.systemNotificationsEnabled = granted }
                notificationStatus = granted ? "系统通知已授权。" : "系统通知未获授权；请在系统设置中允许后再启用。"
                if let error { notificationStatus = "系统通知授权失败：\(error.localizedDescription)" }
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorizationStatus = settings.authorizationStatus
            Task { @MainActor in
                switch authorizationStatus {
                case .authorized, .provisional, .ephemeral: notificationStatus = "macOS 已允许系统通知。"
                case .denied: notificationStatus = "macOS 已拒绝系统通知；可在系统设置中更改。"
                case .notDetermined: notificationStatus = "启用系统通知时会请求 macOS 授权。"
                @unknown default: notificationStatus = "系统通知授权状态未知。"
                }
            }
        }
    }
}

@MainActor
final class GlobalSpeedModeMonitor {
    private let coordinator: TaskCoordinator
    private var mode: GlobalSpeedLimitMode = .off
    private var isStarted = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(coordinator: TaskCoordinator) { self.coordinator = coordinator }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        updateSampling()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        stopSampling(resetActivity: true)
    }

    func setMode(_ mode: GlobalSpeedLimitMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        guard isStarted else { return }
        updateSampling()
    }

    private func updateSampling() {
        guard isStarted, mode == .backgroundInteraction else {
            stopSampling(resetActivity: true)
            return
        }
        guard timer == nil else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func stopSampling(resetActivity: Bool) {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if resetActivity { coordinator.updateSystemActivity(appIsActive: true, idleInterval: .infinity) }
    }

    private func refresh() {
        guard isStarted, mode == .backgroundInteraction else { return }
        guard let application = NSApp else { return }
        coordinator.updateSystemActivity(appIsActive: application.isActive, idleInterval: Self.systemIdleInterval())
    }

    private static func systemIdleInterval() -> TimeInterval {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard entry != IO_OBJECT_NULL else { return .infinity }
        defer { IOObjectRelease(entry) }
        let property = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
        guard let nanoseconds = property?.takeRetainedValue() as? NSNumber else { return .infinity }
        return nanoseconds.doubleValue / 1_000_000_000
    }
}

@MainActor
enum SystemCompletionActions {
    private static var confirmationPanel: NSPanel?
    private static var confirmationTimer: Timer?
    private static var confirmationPrompt: CompletionActionPrompt?
    private static var confirmationCloseDelegate: CompletionPromptCloseDelegate?

    static func playCompletionSound(settings: AppSettings) {
        playSound(path: settings.successSoundPath, fallbackName: "Glass", enabled: settings.soundEnabled)
    }

    static func playStartSound(settings: AppSettings) {
        playSound(path: settings.normalSoundPath, fallbackName: "Pop", enabled: settings.soundEnabled)
    }

    private static func playErrorSound(settings: AppSettings) {
        playSound(path: settings.errorSoundPath, fallbackName: "Basso", enabled: settings.soundEnabled)
    }

    private static func playSound(path: String, fallbackName: String, enabled: Bool) {
        guard enabled else { return }
        if !path.isEmpty, let sound = NSSound(contentsOfFile: path, byReference: true) { sound.play() }
        else { NSSound(named: NSSound.Name(fallbackName))?.play() }
    }

    static func taskCompleted(_ fileName: String, settings: AppSettings) {
        playCompletionSound(settings: settings)
        postNotification(title: "下载完成", body: fileName, settings: settings)
    }

    static func taskFailed(_ fileName: String, message: String, settings: AppSettings) {
        playErrorSound(settings: settings)
        postNotification(title: "下载失败：\(fileName)", body: message, settings: settings)
    }

    private static func postNotification(title: String, body: String, settings: AppSettings) {
        guard settings.systemNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if settings.soundEnabled { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                       content: content, trigger: nil))
    }

    static func request(_ action: CompletionAction, reason: String) {
        guard action != .none else { return }
        confirmationPrompt?.cancel()
        let prompt = CompletionActionPrompt(action: action, reason: reason)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 245),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "下载完成后的系统动作"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: CompletionActionPromptView(prompt: prompt))
        let closeDelegate = CompletionPromptCloseDelegate { prompt.windowClosed() }
        panel.delegate = closeDelegate
        confirmationPanel = panel
        confirmationPrompt = prompt
        confirmationCloseDelegate = closeDelegate
        prompt.onConfirm = {
            confirmationTimer?.invalidate(); confirmationTimer = nil
            confirmationPanel = nil; confirmationPrompt = nil
            panel.close()
            confirmationCloseDelegate = nil
            perform(action)
        }
        prompt.onCancel = {
            confirmationTimer?.invalidate(); confirmationTimer = nil
            confirmationPanel = nil; confirmationPrompt = nil
            panel.close()
            confirmationCloseDelegate = nil
        }
        prompt.onWindowClose = {
            confirmationTimer?.invalidate(); confirmationTimer = nil
            confirmationPanel = nil; confirmationPrompt = nil
            confirmationCloseDelegate = nil
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        confirmationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                prompt.secondsRemaining -= 1
                if prompt.secondsRemaining <= 0 { prompt.confirm() }
            }
        }
    }

    private static func perform(_ action: CompletionAction) {
        switch action {
        case .none: return
        case .quit: NSApp.terminate(nil)
        case .sleep:
            let powerPort = IOPMFindPowerManagement(kIOMainPortDefault)
            guard powerPort != IO_OBJECT_NULL else { showError("macOS 电源管理接口不可用。"); return }
            let result = IOPMSleepSystem(powerPort)
            IOServiceClose(powerPort)
            if result != kIOReturnSuccess { showError("无法让 Mac 进入睡眠（\(result)）。") }
        case .shutdown:
            var details: NSDictionary?
            let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
            _ = script?.executeAndReturnError(&details)
            if let details { showError("macOS 未执行关机：\(details[NSAppleScript.errorMessage] ?? "System Events 拒绝请求")") }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "队列完成动作未执行"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private final class CompletionActionPrompt: ObservableObject {
    @Published var secondsRemaining = 30
    let action: CompletionAction
    let reason: String
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
    var onWindowClose: () -> Void = {}
    private var finished = false

    init(action: CompletionAction, reason: String) { self.action = action; self.reason = reason }
    func confirm() { guard !finished else { return }; finished = true; onConfirm() }
    func cancel() { guard !finished else { return }; finished = true; onCancel() }
    func windowClosed() { guard !finished else { return }; finished = true; onWindowClose() }

    var actionTitle: String {
        switch action { case .none: "无动作"; case .quit: "退出 zjx-download"; case .sleep: "让 Mac 睡眠"; case .shutdown: "关闭 Mac" }
    }
}

private struct CompletionActionPromptView: View {
    @ObservedObject var prompt: CompletionActionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.actionTitle).font(.title2.bold())
            Text("触发原因：\(prompt.reason)")
            Text("将在 \(prompt.secondsRemaining) 秒后执行。你可以立即执行或取消。")
                .foregroundStyle(.secondary)
            HStack {
                Button("取消") { prompt.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("立即执行") { prompt.confirm() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 245)
    }
}

@MainActor
private final class CompletionPromptCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: TaskCoordinator?
    private var speedModeMonitor: GlobalSpeedModeMonitor?
    private var integrationServer: IntegrationServer?
    private var statusEventRelay: TaskStatusEventRelay?
    private var approvedTermination = false
    private var terminatingDuplicate = false
    private var headlessQuitRequested = false
    private var quitObserver: NSObjectProtocol?

    func configure(coordinator: TaskCoordinator, speedModeMonitor: GlobalSpeedModeMonitor,
                   integrationServer: IntegrationServer, statusEventRelay: TaskStatusEventRelay) {
        self.coordinator = coordinator
        self.speedModeMonitor = speedModeMonitor
        self.integrationServer = integrationServer
        self.statusEventRelay = statusEventRelay
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let coordinator else { return }
        if coordinator.startupError?.contains("另一个 zjx-download 实例") == true {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == ProductIdentity.bundleID && $0.processIdentifier != currentPID
            }
            if let existing {
                existing.activate(options: [.activateAllWindows])
            } else {
                let alert = NSAlert()
                alert.messageText = "zjx-download 已在运行"
                alert.informativeText = "另一实例持有下载数据锁。本次启动不会读取或更改下载数据。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
            terminatingDuplicate = true
            NSApp.terminate(nil)
            return
        }
        guard coordinator.startupError == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(forName: .zjxQuitRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.headlessQuitRequested = true
                NSApp?.terminate(nil)
            }
        }
        statusEventRelay?.start()
        speedModeMonitor?.start()
        integrationServer?.restart(settings: coordinator.data.settings)
        if CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async {
                guard coordinator.pendingImportReview == nil else { return }
                NSApp.hide(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        speedModeMonitor?.stop()
        integrationServer?.stop()
        statusEventRelay?.stop()
        if let coordinator, coordinator.startupError == nil {
            do { try coordinator.store.save(coordinator.data) }
            catch { NSLog("zjx-download: failed to flush state on termination: %@", error.localizedDescription) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedTermination || terminatingDuplicate { return .terminateNow }
        guard let coordinator, coordinator.hasOutstandingTransfers else {
            headlessQuitRequested = false
            return .terminateNow
        }
        if !headlessQuitRequested {
            let alert = NSAlert()
            alert.messageText = "退出 zjx-download 并暂停活动任务？"
            alert.informativeText = "活动任务会保存可用的续传信息。退出前最多等待 30 秒，保存失败时应用会保持打开。"
            alert.addButton(withTitle: "暂停并退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        headlessQuitRequested = false
        coordinator.prepareForTermination { canTerminate in
            self.approvedTermination = canTerminate
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }
}
