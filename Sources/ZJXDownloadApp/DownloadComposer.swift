import SwiftUI
import AppKit
import ZJXDownloadCore

struct DownloadComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    var editingTaskID: Int64? = nil
    @State private var address = ""
    @State private var page = ""
    @State private var name = ""
    @State private var folder = ""
    @State private var headersText = ""
    @State private var checksum = ""
    @State private var speedLimit = "0"
    @State private var connectionCount = "0"
    @State private var queueID: Int64? = 0
    @State private var kind = TransferKind.http
    @State private var startNow = true
    @State private var conflict = ConflictPolicy.rename
    @State private var error: String?
    @State private var busy = false
    @State private var submissionWork: Task<Void, Never>?
    @State private var clearStoredCredentials = false
    @State private var showEditResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(editingTaskID == nil ? "新建下载" : "编辑下载").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }
            Form {
                Picker("类型", selection: $kind) { Text("HTTP / HTTPS").tag(TransferKind.http); Text("HLS TS 清单").tag(TransferKind.hls) }
                    .disabled(editingTaskID != nil)
                TextField("下载地址", text: $address).textFieldStyle(.roundedBorder)
                TextField("来源页面（可选）", text: $page).textFieldStyle(.roundedBorder)
                TextField("文件名（自动识别）", text: $name).textFieldStyle(.roundedBorder)
                LabeledContent("下载目录") {
                    HStack(spacing: 8) {
                        TextField("默认保存目录", text: $folder).textFieldStyle(.roundedBorder)
                        Button("选择下载目录…", action: chooseFolder)
                        if folder != AppSettings.macDefaultDownloadsDirectory {
                            Button("默认 Downloads") { folder = AppSettings.macDefaultDownloadsDirectory }
                        }
                    }
                }
                TextField("请求头（每行 名称: 值）", text: $headersText, axis: .vertical).lineLimit(3...7).textFieldStyle(.roundedBorder)
                if editingTaskID != nil { Toggle("清除钥匙串中保存的认证信息", isOn: $clearStoredCredentials) }
                TextField("期望摘要（可选，如 SHA-256:…）", text: $checksum).textFieldStyle(.roundedBorder).disabled(editingTaskID != nil)
                TextField("任务限速（\(ByteFormatting.speedUnitLabel(coordinator.data.settings.speedUnit))，0 为不限速）", text: $speedLimit).textFieldStyle(.roundedBorder)
                TextField("任务连接数（0 使用逐主机/全局设置，最大 256）", text: $connectionCount).textFieldStyle(.roundedBorder)
                Picker("队列", selection: $queueID) { ForEach(coordinator.data.queues.sorted { $0.order < $1.order }) { queue in Text(queue.name).tag(Optional(queue.id)) } }.disabled(editingTaskID != nil)
                Picker("文件重名", selection: $conflict) { Text("自动编号").tag(ConflictPolicy.rename); Text("替换").tag(ConflictPolicy.replace); Text("取消此次添加").tag(ConflictPolicy.cancel) }.disabled(editingTaskID != nil)
                Toggle("添加后开始下载", isOn: $startNow).disabled(editingTaskID != nil)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(editingTaskID == nil ? "添加并关闭" : "保存更改") { submit() }.keyboardShortcut(.defaultAction).disabled(busy || address.isEmpty) }
        }
        .padding(22).frame(width: 620, height: 520)
        .onAppear(perform: loadDraft)
        .onDisappear { submissionWork?.cancel(); submissionWork = nil }
        .confirmationDialog("更改会重置未完成进度", isPresented: $showEditResetConfirmation) {
            Button("更改并从头重新下载", role: .destructive) { submit(confirmingEdit: true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("原任务记录会保留，但当前续传分片和进度将被清除。旧文件不会被删除。")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        panel.prompt = "选择保存位置"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func loadDraft() {
        guard let editingTaskID, let task = coordinator.task(editingTaskID) else {
            folder = coordinator.data.settings.defaultDownloadDirectory
            return
        }
        address = task.sourceURL
        page = task.pageURL ?? ""
        name = task.displayName
        folder = task.destinationDirectory
        headersText = task.requestHeaders.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        speedLimit = ByteFormatting.speedLimitInput(bytesPerSecond: task.speedLimitBytesPerSecond, unit: coordinator.data.settings.speedUnit)
        connectionCount = String(task.connectionCount ?? 0)
        queueID = task.queueID
        kind = task.kind
        conflict = task.conflictPolicy
        startNow = false
    }

    private func submit(confirmingEdit: Bool = false) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), NetworkConfiguration.validate(url) else { error = "请输入有效的 HTTP 或 HTTPS 地址。"; return }
        let parsed = headersText.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { result, line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        guard let limit = parsedSpeedLimit() else { error = "任务限速必须是可精确换算为字节/秒的非负数。"; return }
        guard let connections = parsedConnectionCount() else { error = "任务连接数必须是 0 到 256 的整数。"; return }
        if let editingTaskID, !confirmingEdit, let task = coordinator.task(editingTaskID), task.receivedBytes > 0 {
            showEditResetConfirmation = true
            return
        }
        if let editingTaskID {
            let destination = URL(fileURLWithPath: folder, isDirectory: true)
            busy = true; error = nil
            do {
                try coordinator.editTask(editingTaskID, name: name, sourceURL: url,
                                         pageURL: URL(string: page).flatMap { NetworkConfiguration.validate($0) ? $0 : nil },
                                         headers: parsed, destination: destination,
                                         speedLimitBytesPerSecond: limit, connectionCount: connections == 0 ? nil : connections,
                                         clearStoredCredentials: clearStoredCredentials)
                dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
            return
        }
        let request = CreateDownloadRequest(kind: kind, sourceURL: url,
                                            pageURL: URL(string: page).flatMap { NetworkConfiguration.validate($0) ? $0 : nil },
                                            displayName: name.isEmpty ? nil : name,
                                            destinationDirectory: folder.isEmpty ? nil : URL(fileURLWithPath: folder, isDirectory: true),
                                            headers: parsed, queueID: queueID, startImmediately: startNow,
                                            conflictPolicy: conflict, expectedChecksum: checksum.isEmpty ? nil : checksum,
                                            speedLimitBytesPerSecond: limit,
                                            connectionCount: connections == 0 ? nil : connections)
        busy = true; error = nil
        submissionWork = Task {
            do {
                _ = try await coordinator.add(request)
                guard !Task.isCancelled else { return }
                submissionWork = nil
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; busy = false; submissionWork = nil
            }
        }
    }

    private func parsedSpeedLimit() -> Int64? {
        ByteFormatting.parseSpeedLimit(speedLimit, unit: coordinator.data.settings.speedUnit)
    }

    private func parsedConnectionCount() -> Int? {
        guard let value = Int(connectionCount), (0...256).contains(value) else { return nil }
        return value
    }
}

struct BatchImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    @State private var text = ""
    @State private var resultText = ""
    @State private var folder = ""
    @State private var queueID: Int64? = 0
    @State private var startNow = false
    @State private var items: [ImportedDownload] = []
    @State private var selected = Set<Int>()
    @State private var query = ""
    @State private var pattern = ""
    @State private var rangeStart = "1"
    @State private var rangeEnd = "5"
    @State private var padding = "0"
    @State private var busy = false
    @State private var submissionWork: Task<Void, Never>?

    private var visibleIndices: [Int] {
        items.indices.filter { index in
            query.isEmpty || items[index].url.absoluteString.localizedCaseInsensitiveContains(query) ||
                (items[index].suggestedName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量导入").font(.title2.bold())
            Text("粘贴 URL、JSON、cURL 命令或批量链接；带认证头的内容只在添加任务时发送给本机应用。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).border(.quaternary).frame(minHeight: 100, maxHeight: 150)
            HStack {
                TextField("批量网址模式，使用 * 代替序号", text: $pattern).textFieldStyle(.roundedBorder)
                TextField("起始", text: $rangeStart).frame(width: 60)
                TextField("结束", text: $rangeEnd).frame(width: 60)
                TextField("位数（0 不补零）", text: $padding).frame(width: 120)
                Button("生成预览") { appendGenerated() }.disabled(pattern.isEmpty)
            }
            HStack {
                TextField("筛选网址或文件名", text: $query).textFieldStyle(.roundedBorder)
                Button("全选可见") { selected.formUnion(visibleIndices) }.disabled(visibleIndices.isEmpty)
                Button("取消选择") { selected.subtract(visibleIndices) }.disabled(visibleIndices.isEmpty)
                Button("解析文本") { parseText() }
            }
            List {
                ForEach(visibleIndices, id: \.self) { index in
                    Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items[index].suggestedName ?? items[index].url.lastPathComponent).lineLimit(1)
                            Text(items[index].url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }.overlay {
                if items.isEmpty { ContentUnavailableView("尚无预览项目", systemImage: "list.bullet.rectangle") }
            }
            HStack(spacing: 8) {
                Text("下载目录：").foregroundStyle(.secondary)
                TextField("默认保存目录", text: $folder).textFieldStyle(.roundedBorder)
                Button("选择下载目录…") { chooseBatchFolder() }
                if folder != AppSettings.macDefaultDownloadsDirectory {
                    Button("默认 Downloads") { folder = AppSettings.macDefaultDownloadsDirectory }
                }
            }
            HStack {
                Picker("队列", selection: $queueID) { ForEach(coordinator.data.queues) { Text($0.name).tag(Optional($0.id)) } }
                Toggle("添加后开始", isOn: $startNow)
                Spacer()
                Button("取消") { dismiss() }
                Button(busy ? "正在添加…" : "添加已选 \(selected.count) 项") { addSelected() }
                    .keyboardShortcut(.defaultAction).disabled(busy || selected.isEmpty)
            }
            if !resultText.isEmpty { ScrollView { Text(resultText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 100) }
        }.padding(20).frame(width: 820, height: 720)
        .onAppear {
            if folder.isEmpty { folder = coordinator.data.settings.defaultDownloadDirectory }
            if text.isEmpty { text = NSPasteboard.general.string(forType: .string) ?? "" }
        }
        .onDisappear { submissionWork?.cancel(); submissionWork = nil }
        .onReceive(NotificationCenter.default.publisher(for: .importTextRequested)) { note in if let text = note.object as? String { self.text = text } }
    }

    private func chooseBatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        panel.prompt = "选择保存位置"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func parseText() {
        let parsed = InputImport.parse(text)
        var seen = Set(items.map { $0.url.absoluteString })
        items.append(contentsOf: parsed.items.filter { seen.insert($0.url.absoluteString).inserted })
        selected.removeAll()
        resultText = "解析到 \(parsed.items.count) 项；新增预览 \(items.count) 项。\n" + parsed.errors.joined(separator: "\n")
    }

    private func appendGenerated() {
        guard let start = Int(rangeStart), let end = Int(rangeEnd), let width = Int(padding) else {
            resultText = "起止值与补零位数必须是整数。"; return
        }
        do {
            let generated = try InputImport.expand(pattern: pattern, start: start, end: end, padding: width)
            var seen = Set(items.map { $0.url.absoluteString })
            items.append(contentsOf: generated.filter { seen.insert($0.absoluteString).inserted }.map {
                ImportedDownload(url: $0, headers: [:], username: nil, password: nil,
                                 downloadPage: nil, suggestedName: nil, userAgent: nil)
            })
            selected.removeAll()
            resultText = "已添加 \(generated.count) 个地址到预览；请勾选要创建的任务。"
        } catch { resultText = error.localizedDescription }
    }

    private func addSelected() {
        let destination = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : URL(fileURLWithPath: folder, isDirectory: true)
        let requests = selected.sorted().compactMap { index -> CreateDownloadRequest? in
            guard items.indices.contains(index) else { return nil }
            let item = items[index]
            return CreateDownloadRequest(sourceURL: item.url, pageURL: item.downloadPage,
                                         displayName: item.suggestedName, destinationDirectory: destination,
                                         headers: item.headers,
                                         queueID: queueID, startImmediately: startNow)
        }
        guard !requests.isEmpty else { return }
        busy = true
        submissionWork = Task {
            let result = await coordinator.addMany(requests)
            guard !Task.isCancelled else { return }
            submissionWork = nil
            resultText = "新增：\(result.added.count)\n失败：\(result.errors.count)\n" + result.errors.joined(separator: "\n")
            selected.removeAll()
            busy = false
            if result.errors.isEmpty { dismiss() }
        }
    }
}
