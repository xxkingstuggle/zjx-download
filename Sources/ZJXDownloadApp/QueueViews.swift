import SwiftUI
import ZJXDownloadCore

struct QueueViews: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    @State private var newName = ""
    @State private var editingQueueID: Int64?
    @State private var pendingClearQueueID: Int64?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("下载队列").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            List {
                ForEach(Array(coordinator.data.queues.sorted { $0.order < $1.order }.enumerated()), id: \.element.id) { index, queue in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(queue.name).font(.headline)
                            Spacer()
                            Button("上移") { reorder(queue.id, offset: -1) }.disabled(index == 0)
                            Button("下移") { reorder(queue.id, offset: 1) }.disabled(index == coordinator.data.queues.count - 1)
                            Button("重命名") { editingQueueID = queue.id; newName = queue.name }
                            Text(queue.isRunning ? "运行中" : "已停止").foregroundStyle(.secondary)
                        }
                        HStack {
                            Stepper("并发任务：\(queue.concurrency)", value: binding(queue.id, \.concurrency), in: 1...32)
                            Toggle("自动清空时停止", isOn: binding(queue.id, \.schedule.stopWhenEmpty))
                            Picker("队列完成后", selection: binding(queue.id, \.completionAction)) {
                                ForEach(CompletionAction.allCases, id: \.self) { action in Text(action.title).tag(action) }
                            }.frame(width: 180)
                            Spacer()
                            Button(queue.isRunning ? "停止队列" : "启动队列") { queue.isRunning ? coordinator.stopQueue(queue.id) : coordinator.startQueue(queue.id) }
                            Button("清空成员…") { pendingClearQueueID = queue.id }
                            if queue.id != 0 { Button("删除", role: .destructive) { do { try coordinator.deleteQueue(queue.id) } catch { self.error = error.localizedDescription } } }
                        }
                        HStack {
                            Toggle("计划开始", isOn: binding(queue.id, \.schedule.startEnabled))
                            DatePicker("", selection: timeBinding(queue.id, start: true), displayedComponents: .hourAndMinute).labelsHidden().disabled(!queue.schedule.startEnabled)
                            Toggle("计划停止", isOn: binding(queue.id, \.schedule.stopEnabled))
                            DatePicker("", selection: timeBinding(queue.id, start: false), displayedComponents: .hourAndMinute).labelsHidden().disabled(!queue.schedule.stopEnabled)
                        }.font(.caption)
                        HStack { ForEach(Array(zip(1...7, ["一", "二", "三", "四", "五", "六", "日"])), id: \.0) { day, title in
                            Toggle(title, isOn: dayBinding(queue.id, day: day)).toggleStyle(.button).controlSize(.small)
                        } }
                        let members = queue.taskIDs.compactMap { coordinator.task($0) }
                        if !members.isEmpty {
                            ForEach(Array(members.enumerated()), id: \.element.id) { memberIndex, task in
                                HStack {
                                    Image(systemName: task.status.symbol)
                                    Text(task.displayName).lineLimit(1)
                                    Spacer()
                                    Button("↑") { moveTask(task.id, queueID: queue.id, offset: -1) }.disabled(memberIndex == 0)
                                    Button("↓") { moveTask(task.id, queueID: queue.id, offset: 1) }.disabled(memberIndex == members.count - 1)
                                    Button("移出队列") { coordinator.move([task.id], toQueue: nil) }
                                }.font(.caption)
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                TextField(editingQueueID == nil ? "新队列名称" : "队列名称", text: $newName).textFieldStyle(.roundedBorder)
                if let editingQueueID {
                    Button("保存名称") {
                        do { try coordinator.updateQueue(editingQueueID) { $0.name = newName }; self.editingQueueID = nil; newName = "" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") { self.editingQueueID = nil; newName = "" }
                } else {
                    Button("创建") { createQueue() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(20).frame(width: 780, height: 700)
        .confirmationDialog("清空队列成员？", isPresented: Binding(
            get: { pendingClearQueueID != nil }, set: { if !$0 { pendingClearQueueID = nil } }
        )) {
            Button("移除所有成员", role: .destructive) {
                if let pendingClearQueueID { do { try coordinator.clearQueue(pendingClearQueueID) } catch { self.error = error.localizedDescription } }
                pendingClearQueueID = nil
            }
            Button("取消", role: .cancel) { pendingClearQueueID = nil }
        } message: { Text("只移除任务的队列归属，任务记录、进度和已下载文件均保留。") }
    }

    private func binding<Value>(_ id: Int64, _ path: WritableKeyPath<QueueRecord, Value>) -> Binding<Value> {
        Binding(get: { coordinator.data.queues.first(where: { $0.id == id })?[keyPath: path] ?? coordinator.data.queues[0][keyPath: path] },
                set: { value in try? coordinator.updateQueue(id) { $0[keyPath: path] = value } })
    }
    private func dayBinding(_ id: Int64, day: Int) -> Binding<Bool> {
        Binding(get: { coordinator.data.queues.first(where: { $0.id == id })?.schedule.days.contains(day) ?? false }, set: { enabled in
            try? coordinator.updateQueue(id) { if enabled { $0.schedule.days.insert(day) } else if $0.schedule.days.count > 1 { $0.schedule.days.remove(day) } }
        })
    }
    private func timeBinding(_ id: Int64, start: Bool) -> Binding<Date> {
        Binding(get: {
            let queue = coordinator.data.queues.first(where: { $0.id == id })
            var parts = DateComponents(); parts.hour = start ? queue?.schedule.startHour : queue?.schedule.stopHour; parts.minute = start ? queue?.schedule.startMinute : queue?.schedule.stopMinute
            return Calendar.current.date(from: parts) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            try? coordinator.updateQueue(id) { if start { $0.schedule.startHour = parts.hour ?? 0; $0.schedule.startMinute = parts.minute ?? 0 } else { $0.schedule.stopHour = parts.hour ?? 0; $0.schedule.stopMinute = parts.minute ?? 0 } }
        })
    }
    private func createQueue() { do { _ = try coordinator.createQueue(name: newName); newName = "" } catch { self.error = error.localizedDescription } }

    private func reorder(_ id: Int64, offset: Int) {
        var ids = coordinator.data.queues.sorted { $0.order < $1.order }.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        do { try coordinator.reorderQueues(ids) } catch { self.error = error.localizedDescription }
    }

    private func moveTask(_ taskID: Int64, queueID: Int64, offset: Int) {
        do { try coordinator.moveTaskWithinQueue(taskID, queueID: queueID, offset: offset) }
        catch { self.error = error.localizedDescription }
    }
}

private extension DownloadStatus {
    var symbol: String {
        switch self { case .queued: "clock"; case .preparing: "arrow.trianglehead.2.clockwise"; case .downloading: "arrow.down.circle.fill"; case .paused: "pause.circle"; case .failed: "exclamationmark.circle"; case .completed: "checkmark.circle.fill"; case .cancelled: "xmark.circle" }
    }
}

private extension CompletionAction {
    var title: String {
        switch self {
        case .none: "不操作"
        case .quit: "退出应用"
        case .sleep: "睡眠 Mac"
        case .shutdown: "关闭 Mac"
        }
    }
}
