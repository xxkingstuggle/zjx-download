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
    @State private var infoNotice: String?
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
                        ScrollView {
                            switch page {
                            case .info: informationPage(task)
                            case .speed: speedPage(task)
                            case .completion: completionPage(task)
                            }
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
                            Button("复制地址") {
                                copyToPasteboard(task.sourceURL)
                                infoNotice = "已复制下载地址到剪贴板。"
                            }
                            Button("复制 JSON") { copyExchange(task) }
                            Button("复制 cURL") { copyCurl(task) }
                        }
                    }
                    if let infoNotice {
                        Label(infoNotice, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let recovery = task.legacyRecoveryNote { Text(recovery).foregroundStyle(.orange).textSelection(.enabled) }
                }
                .padding(22)
                .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 500)
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
        let metric = coordinator.liveState.metrics[task.id]
        let speed = task.status.isActive
            ? (coordinator.data.settings.averageSpeedEnabled ? (metric?.averageBytesPerSecond ?? 0) : (metric?.bytesPerSecond ?? 0))
            : 0
        VStack(alignment: .leading, spacing: 12) {
            if let progress = task.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if task.status.isActive {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("正在传输（服务器未声明文件总大小）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("总大小未知 · 已接收 \(ByteFormatting.size(task.receivedBytes, unit: coordinator.data.settings.sizeUnit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                metricCard(
                    title: "已下载",
                    value: ByteFormatting.size(task.receivedBytes, unit: coordinator.data.settings.sizeUnit),
                    subtitle: task.totalBytes.map { "共 \(ByteFormatting.size($0, unit: coordinator.data.settings.sizeUnit))" } ?? "大小未知"
                )
                metricCard(
                    title: coordinator.data.settings.averageSpeedEnabled ? "平均速率" : "当前速率",
                    value: speed > 0 ? ByteFormatting.speed(Self.safeByteRate(speed), unit: coordinator.data.settings.speedUnit) : "—",
                    subtitle: task.status.title
                )
                metricCard(
                    title: "预计剩余",
                    value: (task.totalBytes != nil && speed > 0)
                        ? Self.remainingTime(total: task.totalBytes ?? 0, received: task.receivedBytes, speed: speed)
                        : "—",
                    subtitle: task.kind == .hls ? "HLS 分片" : "HTTP 传输"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("来源") {
                    Text(task.sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("保存位置") {
                    Text(task.outputURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            )

            if let message = task.lastError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            let segments = coordinator.segmentedEngine.progressSegments(taskID: task.id)
            if !segments.isEmpty {
                SegmentVisualBar(segments: segments)
                Table(segments) {
                    TableColumn("序号") { Text("\($0.index + 1)").monospacedDigit() }.width(52)
                    TableColumn("状态") { segment in
                        Text(segment.status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(segment.status == "完成" ? Color.green : (segment.status == "下载中" ? Color.accentColor : Color.secondary))
                    }.width(72)
                    TableColumn("已接收") { Text(ByteFormatting.size($0.receivedBytes, unit: coordinator.data.settings.sizeUnit)).monospacedDigit() }
                    TableColumn("分段大小") { Text(ByteFormatting.size($0.totalBytes, unit: coordinator.data.settings.sizeUnit)).monospacedDigit() }
                }
                .frame(minHeight: 110, maxHeight: 180)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        )
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: task.outputURL.path))
                .resizable()
                .frame(width: 68, height: 68)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                )
                .onDrag { NSItemProvider(object: task.outputURL as NSURL) }
                .help("拖动此文件图标到其他应用")
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
            copyToPasteboard(String(decoding: bytes, as: UTF8.self))
            infoNotice = "已复制 JSON 到剪贴板。"
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func copyCurl(_ task: DownloadRecord) {
        do {
            guard let headers = try exportCredentialHeaders(task) else { return }
            copyToPasteboard(ExchangeCodec.curl(for: task, secrets: headers))
            infoNotice = "已复制 cURL 命令到剪贴板。"
            error = nil
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
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存并从头恢复") { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 440, idealHeight: 540)
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
    private enum VerificationState {
        case idle
        case matched
        case mismatched
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var algorithm = "SHA-256"
    @State private var expected = ""
    @State private var calculated = ""
    @State private var busy = false
    @State private var verification: VerificationState = .idle
    @State private var copiedNotice = false
    @State private var work: Task<Void, Never>?
    @State private var calculationGeneration: UInt64 = 0
    init(initialFile: URL? = nil) { _file = State(initialValue: initialFile) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文件校验").font(.title2.bold())
            HStack {
                Text(file?.path ?? "请选择本地文件").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("选择文件…") { chooseFile() }.disabled(busy)
            }
            Picker("算法", selection: $algorithm) { ForEach(["SHA-256", "SHA-512", "SHA-1", "MD5", "CRC-32"], id: \.self) { Text($0) } }.disabled(busy)
            TextField("期望摘要（可选）", text: $expected).textFieldStyle(.roundedBorder).disabled(busy)
            HStack {
                Text("计算结果")
                Text(calculated.isEmpty ? "—" : calculated)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                Spacer()
                Button(copiedNotice ? "已复制" : "复制") {
                    copyToPasteboard(calculated)
                    copiedNotice = true
                }.disabled(calculated.isEmpty)
            }
            switch verification {
            case .idle:
                EmptyView()
            case .matched:
                Label("摘要匹配。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            case .mismatched:
                Label("摘要不匹配，请核对文件完整性。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.medium))
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack { Spacer(); Button("关闭") { dismiss() }; Button(busy ? "计算中…" : "计算") { calculate() }.keyboardShortcut(.defaultAction).disabled(file == nil || busy) }
        }.padding(22).frame(minWidth: 560, idealWidth: 620, minHeight: 280, idealHeight: 310)
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
        if panel.runModal() == .OK { file = panel.url; calculated = ""; verification = .idle; copiedNotice = false }
    }
    private func calculate() {
        guard let file, !busy else { return }
        calculationGeneration &+= 1
        let generation = calculationGeneration
        busy = true; verification = .idle; calculated = ""; copiedNotice = false
        let selectedAlgorithm = algorithm
        let expectedValue = expected.trimmingCharacters(in: .whitespacesAndNewlines)
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
                if !expectedValue.isEmpty {
                    verification = expectedValue.caseInsensitiveCompare(value) == .orderedSame ? .matched : .mismatched
                }
                work = nil
            } catch {
                guard !Task.isCancelled, generation == calculationGeneration else { return }
                verification = .failed(error.localizedDescription); busy = false; work = nil
            }
        }
    }
}

private struct SegmentVisualBar: View {
    let segments: [DownloadSegmentProgress]

    var body: some View {
        let completedCount = segments.filter { $0.status == "完成" }.count
        let totalBytes = max(1, segments.reduce(Int64(0)) { $0 + max(1, $1.totalBytes) })
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Range 分段分布")
                    .font(.headline)
                Spacer()
                Text("\(completedCount) / \(segments.count) 段完成")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let spacing: CGFloat = segments.count > 1 ? 2 : 0
                let usableWidth = max(1, proxy.size.width - spacing * CGFloat(max(0, segments.count - 1)))
                HStack(spacing: spacing) {
                    ForEach(segments) { segment in
                        let share = CGFloat(max(1, segment.totalBytes)) / CGFloat(totalBytes)
                        let cellWidth = max(3, usableWidth * share)
                        let fillRatio: CGFloat = segment.status == "完成"
                            ? 1
                            : min(1, max(0, CGFloat(segment.receivedBytes) / CGFloat(max(1, segment.totalBytes))))
                        let fillColor: Color = segment.status == "完成"
                            ? .green
                            : (segment.status == "下载中" ? .accentColor : .secondary.opacity(0.45))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(fillColor)
                                .frame(width: cellWidth * fillRatio)
                        }
                        .frame(width: cellWidth, height: 12)
                        .help("分段 #\(segment.index + 1) · \(segment.status)")
                    }
                }
            }
            .frame(height: 12)
        }
    }
}

extension Notification.Name {
    static let checksumRequested = Notification.Name("zjx.download.checksum.requested")
    static let checksumResult = Notification.Name("zjx.download.checksum.result")
}
