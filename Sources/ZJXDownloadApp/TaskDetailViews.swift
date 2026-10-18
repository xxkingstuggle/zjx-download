import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZJXDownloadCore

struct TaskDetailViews: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    let taskID: Int64
    @State private var editMode = false
    @State private var error: String?
    @State private var showingEditor = false
    @State private var page: TaskPage = .info
    @State private var speedLimitText: String
    @State private var connectionCountText: String

    private var task: DownloadRecord? { coordinator.task(taskID) }

    init(coordinator: TaskCoordinator, taskID: Int64) {
        self.coordinator = coordinator
        self.taskID = taskID
        let task = coordinator.task(taskID)
        _speedLimitText = State(initialValue: ByteFormatting.speedLimitInput(
            bytesPerSecond: task?.speedLimitBytesPerSecond ?? 0, unit: coordinator.data.settings.speedUnit))
        _connectionCountText = State(initialValue: String(task?.connectionCount ?? 0))
    }

    var body: some View {
        Group {
            if let task {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(task.progress.map { "\(Self.progressPercent($0))% · " } ?? "")
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text(task.displayName).font(.title2.bold()).lineLimit(1)
                        Spacer()
                        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    if task.status == .completed {
                        completedPage(task)
                    } else {
                        Picker("页面", selection: $page) {
                            ForEach(TaskPage.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        switch page {
                        case .info: informationPage(task)
                        case .speed: speedPage(task)
                        case .completion: completionPage(task)
                        }
                        HStack {
                            if task.status.isActive {
                                Button("暂停") { coordinator.pause([task.id]) }
                                Button("取消下载", role: .destructive) { coordinator.cancel([task.id]) }
                            } else if task.status.canResume {
                                Button(task.status == .failed ? "重试" : "开始/恢复") { coordinator.start([task.id]) }
                            }
                            Button("编辑任务…") { showingEditor = true }
                                .disabled(task.status.isActive)
                            Spacer()
                            Button("复制地址") { NSPasteboard.general.setString(task.sourceURL, forType: .string) }
                            Button("复制 JSON") { copyExchange(task) }
                            Button("复制 cURL") { copyCurl(task) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let recovery = task.legacyRecoveryNote { Text(recovery).foregroundStyle(.orange).textSelection(.enabled) }
                }
                .padding(22)
                .frame(minWidth: 620, minHeight: 360)
            } else { ContentUnavailableView("任务不存在", systemImage: "questionmark.folder") }
        }
        .onChange(of: task?.status) { oldValue, newValue in
            guard oldValue?.isActive == true, newValue == .completed, let task else { return }
            if !(task.showCompletionWindow ?? coordinator.data.settings.showCompletionWindow) { dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checksumResult)) { note in if let value = note.object as? String { error = value } }
        .sheet(isPresented: $showingEditor) {
            if let task { TaskEditView(coordinator: coordinator, task: task) }
        }
    }

    @ViewBuilder private func informationPage(_ task: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = task.progress { ProgressView(value: progress) }
            else { ProgressView() }
            LabeledContent("状态", value: task.status.title)
            LabeledContent("已下载", value: ByteFormatting.size(task.receivedBytes, unit: coordinator.data.settings.sizeUnit))
            if let total = task.totalBytes { LabeledContent("文件大小", value: ByteFormatting.size(total, unit: coordinator.data.settings.sizeUnit)) }
            if let metric = coordinator.liveMetrics[task.id] {
                let speed = coordinator.data.settings.averageSpeedEnabled ? metric.averageBytesPerSecond : metric.bytesPerSecond
                LabeledContent("速度", value: ByteFormatting.speed(Self.safeByteRate(speed), unit: coordinator.data.settings.speedUnit))
                if let total = task.totalBytes, speed > 0 {
                    LabeledContent("剩余时间", value: Self.remainingTime(total: total, received: task.receivedBytes, speed: speed))
                }
            }
            LabeledContent("来源", value: task.sourceURL)
            LabeledContent("保存位置", value: task.outputURL.path)
            if let message = task.lastError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            let segments = coordinator.segmentedEngine.progressSegments(taskID: task.id)
            if !segments.isEmpty {
                Text("Range 分段").font(.headline)
                Table(segments) {
                    TableColumn("序号") { Text("\($0.index + 1)") }.width(55)
                    TableColumn("状态") { Text($0.status) }.width(80)
                    TableColumn("已接收") { Text(ByteFormatting.size($0.receivedBytes, unit: coordinator.data.settings.sizeUnit)) }
                    TableColumn("分段大小") { Text(ByteFormatting.size($0.totalBytes, unit: coordinator.data.settings.sizeUnit)) }
                }
                .frame(minHeight: 100)
            }
            Spacer(minLength: 0)
        }
    }

    private func speedPage(_ task: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("任务限速（\(ByteFormatting.speedUnitLabel(coordinator.data.settings.speedUnit))，0 为不限速）", text: $speedLimitText)
            TextField("连接数（0 使用逐主机/全局设置）", text: $connectionCountText)
            Text("单流 HTTP 下载按来源连接；连接数只影响使用并行 Range 的任务。活动任务的限速会即时更新。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("保存速度设置") { saveTransferSettings(task) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func completionPage(_ task: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("开始时自动打开进度窗口", selection: Binding(
                get: { WindowChoice(value: task.showProgressWindow) },
                set: { saveWindowSettings(task, progress: $0.value, completion: task.showCompletionWindow) }
            )) {
                ForEach(WindowChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("完成时打开结果窗口", selection: Binding(
                get: { WindowChoice(value: task.showCompletionWindow) },
                set: { saveWindowSettings(task, progress: task.showProgressWindow, completion: $0.value) }
            )) {
                ForEach(WindowChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("任务完成后执行", selection: Binding(
                get: { task.completionAction ?? .none },
                set: { saveCompletionAction(task, action: $0) }
            )) {
                Text("无动作").tag(CompletionAction.none)
                Text("退出 App").tag(CompletionAction.quit)
                Text("让 Mac 睡眠").tag(CompletionAction.sleep)
                Text("关机").tag(CompletionAction.shutdown)
            }
            Text("系统动作会先显示 30 秒倒计时；你可以取消或立即执行。若其他任务仍在传输，动作会被跳过。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func completedPage(_ task: DownloadRecord) -> some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: task.outputURL.path)).resizable().frame(width: 64, height: 64)
            Text(task.displayName).font(.title3.weight(.semibold)).lineLimit(2)
            Text(ByteFormatting.size(task.receivedBytes, unit: coordinator.data.settings.sizeUnit)).foregroundStyle(.secondary)
            Text(task.outputURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("打开") { NSWorkspace.shared.open(task.outputURL) }.keyboardShortcut(.defaultAction)
                Button("选择应用打开…") { openWithSelectedApplication(task.outputURL) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([task.outputURL]) }
                Button("校验文件…") { NotificationCenter.default.post(name: .checksumRequested, object: task.outputURL) }
            }
            Text("可将上方文件图标拖到其他应用。")
                .font(.caption).foregroundStyle(.secondary)
                .onDrag { NSItemProvider(object: task.outputURL as NSURL) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveTransferSettings(_ task: DownloadRecord) {
        guard let limit = ByteFormatting.parseSpeedLimit(speedLimitText, unit: coordinator.data.settings.speedUnit),
              let connections = Int(connectionCountText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...256).contains(connections) else {
            error = "限速必须是可换算的非负数，连接数必须为 0 到 256。"
            return
        }
        do {
            try coordinator.updateTaskTransferSettings(task.id, speedLimitBytesPerSecond: limit,
                                                       connectionCount: connections == 0 ? nil : connections)
            error = nil
        } catch let caught { error = caught.localizedDescription }
    }

    private func saveWindowSettings(_ task: DownloadRecord, progress: Bool?, completion: Bool?) {
        do {
            try coordinator.updateTaskPresentation(task.id, showProgressWindow: progress,
                                                   showCompletionWindow: completion,
                                                   completionAction: task.completionAction ?? .none)
            error = nil
        } catch let caught { error = caught.localizedDescription }
    }

    private func saveCompletionAction(_ task: DownloadRecord, action: CompletionAction) {
        do {
            try coordinator.updateTaskPresentation(task.id, showProgressWindow: task.showProgressWindow,
                                                   showCompletionWindow: task.showCompletionWindow,
                                                   completionAction: action)
            error = nil
        } catch let caught { error = caught.localizedDescription }
    }

    private func openWithSelectedApplication(_ file: URL) {
        let panel = NSOpenPanel()
        panel.title = "选择用于打开文件的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let application = panel.url else { return }
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func remainingTime(total: Int64, received: Int64, speed: Double) -> String {
        guard total > 0, received >= 0, speed.isFinite, speed > 0 else { return "未知" }
        guard received < total else { return "0秒" }
        let estimated = Double(total - received) / speed
        let maximumDisplayable = 100.0 * 365.25 * 24 * 60 * 60
        guard estimated.isFinite, estimated < maximumDisplayable else { return "超过 100 年" }
        let seconds = max(0, Int(estimated.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(remainder)秒" }
        return "\(remainder)秒"
    }

    private static func safeByteRate(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value.rounded(.towardZero))
    }

    private static func progressPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(1, max(0, value)) * 100).rounded())
    }

    private func copyExchange(_ task: DownloadRecord) {
        do {
            guard let headers = try exportCredentialHeaders(task) else { return }
            let bytes = try ExchangeCodec.json(for: [task], secrets: [task.id: headers])
            NSPasteboard.general.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
        } catch { self.error = error.localizedDescription }
    }

    private func copyCurl(_ task: DownloadRecord) {
        do {
            guard let headers = try exportCredentialHeaders(task) else { return }
            NSPasteboard.general.setString(ExchangeCodec.curl(for: task, secrets: headers), forType: .string)
        } catch { self.error = error.localizedDescription }
    }

    private func exportCredentialHeaders(_ task: DownloadRecord) throws -> [String: String]? {
        guard let account = task.credentialAccount, let data = try coordinator.credentials.readData(account: account),
              let headers = try JSONSerialization.jsonObject(with: data) as? [String: String], !headers.isEmpty else { return [:] }
        let alert = NSAlert()
        alert.messageText = "是否将认证信息复制到剪贴板？"
        alert.informativeText = "Cookie 和 Authorization 可能允许访问你的账户。只向可信目标粘贴包含认证信息的内容。"
        alert.addButton(withTitle: "不包含认证信息")
        alert.addButton(withTitle: "包含认证信息")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return [:]
        case .alertSecondButtonReturn: return headers
        default: return nil
        }
    }

}

private enum TaskPage: String, CaseIterable, Identifiable {
    case info = "信息"
    case speed = "速度"
    case completion = "完成时"
    var id: String { rawValue }
}

private enum WindowChoice: String, CaseIterable, Identifiable {
    case inherit, enabled, disabled
    init(value: Bool?) { self = value == nil ? .inherit : (value == true ? .enabled : .disabled) }
    var value: Bool? { switch self { case .inherit: nil; case .enabled: true; case .disabled: false } }
    var title: String { switch self { case .inherit: "跟随全局"; case .enabled: "开启"; case .disabled: "关闭" } }
    var id: String { rawValue }
}

private struct TaskEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    let task: DownloadRecord
    @State private var name: String
    @State private var source: String
    @State private var page: String
    @State private var destination: String
    @State private var headersText: String
    @State private var speedLimit: String
    @State private var connectionCount: String
    @State private var authorization: String = ""
    @State private var clearCredentials = false
    @State private var error: String?

    init(coordinator: TaskCoordinator, task: DownloadRecord) {
        self.coordinator = coordinator
        self.task = task
        _name = State(initialValue: task.displayName)
        _source = State(initialValue: task.sourceURL)
        _page = State(initialValue: task.pageURL ?? "")
        _destination = State(initialValue: task.destinationDirectory)
        _speedLimit = State(initialValue: ByteFormatting.speedLimitInput(bytesPerSecond: task.speedLimitBytesPerSecond,
                                                                          unit: coordinator.data.settings.speedUnit))
        _connectionCount = State(initialValue: String(task.connectionCount ?? 0))
        let headers = task.requestHeaders.filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
        _headersText = State(initialValue: headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑下载").font(.title2.bold())
            Form {
                TextField("文件名", text: $name)
                TextField("下载地址", text: $source)
                TextField("来源页面（可选）", text: $page)
                HStack { TextField("保存文件夹", text: $destination); Button("选择…") { chooseFolder() } }
                TextField("任务限速（\(ByteFormatting.speedUnitLabel(coordinator.data.settings.speedUnit))，0 为不限速）", text: $speedLimit)
                TextField("任务连接数（0 使用逐主机/全局设置，最大 256）", text: $connectionCount)
                Text("普通请求头（每行 名称: 值）")
                TextEditor(text: $headersText).font(.system(.body, design: .monospaced)).frame(minHeight: 72)
                SecureField("Authorization（留空保留原值）", text: $authorization)
                if task.credentialAccount != nil {
                    Toggle("清除该任务已保存的认证信息", isOn: $clearCredentials)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存并从头恢复") { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 660, height: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    private func save() {
        guard let sourceURL = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              NetworkConfiguration.validate(sourceURL) else { error = "请输入有效的 HTTP 或 HTTPS 地址。"; return }
        let cleanPage = page.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageURL = cleanPage.isEmpty ? nil : URL(string: cleanPage)
        if !cleanPage.isEmpty {
            guard let pageURL, NetworkConfiguration.validate(pageURL) else { error = "来源页面必须是有效的 HTTP(S) 地址。"; return }
        }
        guard let limit = ByteFormatting.parseSpeedLimit(speedLimit, unit: coordinator.data.settings.speedUnit) else {
            error = "任务限速必须是可精确换算为字节/秒的非负数。"; return
        }
        guard let connections = Int(connectionCount.trimmingCharacters(in: .whitespacesAndNewlines)), (0...256).contains(connections) else {
            error = "任务连接数必须是 0 到 256 的整数。"; return
        }
        var headers: [String: String] = [:]
        for line in headersText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { error = "请求头必须使用 名称: 值 格式。"; return }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n"),
                  !NetworkConfiguration.sensitiveHeaderNames.contains(key.lowercased()) else {
                error = "认证头请使用单独的 Authorization 字段；请求头不能换行。"; return
            }
            headers[key] = value
        }
        let auth = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !auth.isEmpty { headers["Authorization"] = auth }
        do {
            try coordinator.editTask(task.id, name: name, sourceURL: sourceURL, pageURL: pageURL,
                headers: headers, destination: URL(fileURLWithPath: destination, isDirectory: true),
                speedLimitBytesPerSecond: limit,
                connectionCount: connections == 0 ? nil : connections,
                clearStoredCredentials: clearCredentials)
            dismiss()
        } catch let caught { error = caught.localizedDescription }
    }
}

struct ChecksumViews: View {
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var algorithm = "SHA-256"
    @State private var expected = ""
    @State private var calculated = ""
    @State private var busy = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var calculationGeneration: UInt64 = 0
    init(initialFile: URL? = nil) { _file = State(initialValue: initialFile) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文件校验").font(.title2.bold())
            HStack { Text(file?.path ?? "请选择本地文件").lineLimit(1).foregroundStyle(.secondary); Button("选择文件…") { chooseFile() }.disabled(busy) }
            Picker("算法", selection: $algorithm) { ForEach(["SHA-256", "SHA-512", "SHA-1", "MD5", "CRC-32"], id: \.self) { Text($0) } }.disabled(busy)
            TextField("期望摘要（可选）", text: $expected).textFieldStyle(.roundedBorder).disabled(busy)
            HStack { Text("计算结果"); Text(calculated).textSelection(.enabled).font(.system(.body, design: .monospaced)); Spacer(); Button("复制") { NSPasteboard.general.setString(calculated, forType: .string) }.disabled(calculated.isEmpty) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("关闭") { dismiss() }; Button(busy ? "计算中…" : "计算") { calculate() }.keyboardShortcut(.defaultAction).disabled(file == nil || busy) }
        }.padding(22).frame(width: 620, height: 280)
        .onAppear { if file != nil { calculate() } }
        .onDisappear {
            calculationGeneration &+= 1
            work?.cancel()
            work = nil
            busy = false
        }
    }
    private func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { file = panel.url; calculated = ""; error = nil }
    }
    private func calculate() {
        guard let file, !busy else { return }
        calculationGeneration &+= 1
        let generation = calculationGeneration
        busy = true; error = nil; calculated = ""
        let selectedAlgorithm = algorithm
        let expectedValue = expected
        work = Task {
            do {
                let calculation = Task.detached(priority: .utility) {
                    try ChecksumService.calculate(file: file, algorithm: selectedAlgorithm)
                }
                let value = try await withTaskCancellationHandler(
                    operation: { try await calculation.value },
                    onCancel: { calculation.cancel() }
                )
                guard !Task.isCancelled, generation == calculationGeneration else { return }
                calculated = value; busy = false
                if !expectedValue.isEmpty { error = expectedValue.caseInsensitiveCompare(value) == .orderedSame ? "摘要匹配。" : "摘要不匹配。" }
                work = nil
            } catch {
                guard !Task.isCancelled, generation == calculationGeneration else { return }
                self.error = error.localizedDescription; busy = false; work = nil
            }
        }
    }
}

extension Notification.Name {
    static let checksumRequested = Notification.Name("zjx.download.checksum.requested")
    static let checksumResult = Notification.Name("zjx.download.checksum.result")
}
