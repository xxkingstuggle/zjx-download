import SwiftUI
import AppKit
import ZJXDownloadCore

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let coordinator: TaskCoordinator
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建下载…") { openWindow(id: "new-download") }
                .keyboardShortcut("n", modifiers: .command)
            Button("从剪贴板添加") { openWindow(id: "batch-import") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("下载") {
            Button("开始所选任务") { coordinator.start(Array(coordinator.selectedTaskIDs)) }.keyboardShortcut("r", modifiers: .command)
            Button("暂停所选任务") { coordinator.pause(Array(coordinator.selectedTaskIDs)) }.keyboardShortcut(".", modifiers: .command)
            Button("恢复所选任务") { coordinator.resume(Array(coordinator.selectedTaskIDs)) }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("取消所选任务") { coordinator.cancel(Array(coordinator.selectedTaskIDs)) }.keyboardShortcut(".", modifiers: [.command, .option])
            Button("重新下载所选任务") { coordinator.redownload(Array(coordinator.selectedTaskIDs)) }
                .disabled(coordinator.selectedTaskIDs.isEmpty)
            Button("编辑所选任务…") { NotificationCenter.default.post(name: .editSelectedDownloadRequested, object: nil) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(coordinator.selectedTaskIDs.count != 1)
            Divider()
            Button("删除所选任务…") { NotificationCenter.default.post(name: .deleteSelectedDownloadsRequested, object: nil) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(coordinator.selectedTaskIDs.isEmpty)
            Button("复制所选下载地址") {
                guard let id = coordinator.selectedTaskIDs.first, let task = coordinator.task(id) else { return }
                NSPasteboard.general.setString(task.sourceURL, forType: .string)
            }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(coordinator.selectedTaskIDs.count != 1)
            Divider()
            Button("全部暂停") { coordinator.stopAll() }
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
