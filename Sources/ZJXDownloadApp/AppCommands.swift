import SwiftUI
import AppKit
import ZJXDownloadCore

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let coordinator: TaskCoordinator
    var body: some Commands {
        let selectedSet = coordinator.selectedTaskIDs
        let selectedTasks = coordinator.data.tasks.filter { selectedSet.contains($0.id) }
        let canStartSelected = selectedTasks.contains { $0.status.canResume }
        let canPauseSelected = selectedTasks.contains { $0.status.isActive || $0.status == .queued }
        let canCancelSelected = selectedTasks.contains { $0.status != .completed && $0.status != .cancelled }
        let canEditSelected = selectedTasks.count == 1 && selectedTasks.first.map { !$0.status.isActive && $0.status != .completed } == true
        let hasCompletedTasks = coordinator.taskCount(for: .completed) > 0

        CommandGroup(replacing: .newItem) {
            Button("新建下载…") { openWindow(id: "new-download") }
                .keyboardShortcut("n", modifiers: .command)
            Button("从剪贴板添加") { NotificationCenter.default.post(name: .pasteDownloadRequested, object: nil) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("下载") {
            Button("开始所选任务") { coordinator.start(Array(coordinator.selectedTaskIDs)) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canStartSelected)
            Button("暂停所选任务") { coordinator.pause(Array(coordinator.selectedTaskIDs)) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!canPauseSelected)
            Button("恢复所选任务") { coordinator.resume(Array(coordinator.selectedTaskIDs)) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!canStartSelected)
            Button("取消所选任务") { coordinator.cancel(Array(coordinator.selectedTaskIDs)) }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!canCancelSelected)
            Button("重新下载所选任务") { coordinator.redownload(Array(coordinator.selectedTaskIDs)) }
                .disabled(coordinator.selectedTaskIDs.isEmpty)
            Button("编辑所选任务…") { NotificationCenter.default.post(name: .editSelectedDownloadRequested, object: nil) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!canEditSelected)
            Divider()
            Button("删除所选任务…") { NotificationCenter.default.post(name: .deleteSelectedDownloadsRequested, object: nil) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(coordinator.selectedTaskIDs.isEmpty)
            Button("复制所选下载地址") {
                guard let id = coordinator.selectedTaskIDs.first, let task = coordinator.task(id) else { return }
                copyToPasteboard(task.sourceURL)
            }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(coordinator.selectedTaskIDs.count != 1)
            Divider()
            Button("清除已完成记录") { _ = coordinator.clearCompletedTasks() }
                .disabled(!hasCompletedTasks)
            Button("全部暂停") { coordinator.stopAll() }
                .disabled(!coordinator.hasOutstandingTransfers && coordinator.taskCount(for: .queued) == 0)
        }
        CommandMenu("工具") {
            Button("批量导入…") { openWindow(id: "batch-import") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("下载设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                .keyboardShortcut(",", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("检查更新…") {
                UserDefaults.standard.set("更新", forKey: "zjx-download.settings-tab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Divider()
            Button("关于 zjx-download") { openWindow(id: "about") }
        }
    }
}

extension Notification.Name {
    static let newDownloadRequested = Notification.Name("zjx.download.new")
    static let pasteDownloadRequested = Notification.Name("zjx.download.paste")
    static let deleteSelectedDownloadsRequested = Notification.Name("zjx.download.delete-selected")
    static let editSelectedDownloadRequested = Notification.Name("zjx.download.edit-selected")
}
