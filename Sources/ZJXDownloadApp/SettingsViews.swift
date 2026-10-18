import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZJXDownloadCore

struct SettingsWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    @AppStorage("zjx-download.settings-tab") private var tab = "常规"
    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var legacyPreview: LegacyImportPreview?
    @State private var legacyError: String?
    @State private var showMigration = false
    @State private var updateResult: UpdateCheckResult?
    @State private var updateArtifact: URL?
    @State private var updateStatus = ""
    @State private var updateBusy = false
    @State private var showingHostRules = false
    @State private var proxyPasswordInput = ""
    @State private var proxyPasswordStatus = ""
    @State private var soundStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }.padding()
            TabView(selection: $tab) {
                general.tabItem { Label("常规", systemImage: "gearshape") }.tag("常规")
                Group {
                    if showingHostRules {
                        HostRulesSettingsView(coordinator: coordinator) { showingHostRules = false }
                    } else { network }
                }.tabItem { Label("网络", systemImage: "network") }.tag("网络")
                integration.tabItem { Label("集成", systemImage: "point.3.connected.trianglepath.dotted") }.tag("集成")
                behavior.tabItem { Label("行为", systemImage: "slider.horizontal.3") }.tag("行为")
                legacy.tabItem { Label("旧数据", systemImage: "archivebox") }.tag("旧数据")
                updates.tabItem { Label("更新", systemImage: "arrow.down.circle") }.tag("更新")
            }.padding(.horizontal)
        }.frame(width: 720, height: 620)
    }

    private var general: some View {
        Form {
            HStack { TextField("默认保存目录", text: binding(\.defaultDownloadDirectory)); Button("选择…") { chooseDirectory() } }
            Picker("界面主题", selection: binding(\.theme)) {
                ForEach(["Dark", "Light", "Obsidian", "Deep Ocean", "Twilight", "Black", "Light Gray"], id: \.self) { Text($0).tag($0) }
            }
            Picker("外观", selection: binding(\.appearance)) { Text("跟随系统").tag(AppearanceChoice.system); Text("浅色").tag(AppearanceChoice.light); Text("深色").tag(AppearanceChoice.dark) }
            Picker("界面语言", selection: binding(\.language)) {
                Text("跟随系统（缺少翻译时使用简体中文）").tag("system")
                Text("简体中文").tag("zh-Hans")
            }
            Picker("界面字体", selection: Binding(
                get: { coordinator.data.settings.fontName },
                set: { value in coordinator.updateSettings { $0.fontName = value } }
            )) {
                Text("系统默认").tag(nil as String?)
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                    Text(family).tag(Optional(family))
                }
            }
            Picker("文件大小单位", selection: binding(\.sizeUnit)) { Text("二进制（KiB）").tag("binary"); Text("十进制（KB）").tag("decimal") }
            Picker("速度单位", selection: binding(\.speedUnit)) {
                Text("二进制字节/s").tag("bytes")
                Text("十进制字节/s").tag("decimal")
                Text("二进制 bit/s").tag("bits")
                Text("十进制 bit/s").tag("decimal-bits")
            }
            Toggle("显示平均速度", isOn: binding(\.averageSpeedEnabled))
            Toggle("新下载自动分类", isOn: binding(\.autoCategorizeNewDownloads))
            Picker("界面文字比例", selection: binding(\.scalePercent)) {
                ForEach([80, 90, 100, 110, 125, 150, 175, 200], id: \.self) { Text("\($0)%").tag($0) }
            }
            Toggle("紧凑顶部栏", isOn: binding(\.compactToolbar))
            Toggle("工具栏显示文字", isOn: binding(\.showToolbarLabels))
            Toggle("使用相对日期", isOn: binding(\.useRelativeDates))
            Stepper("同时下载上限：\(coordinator.data.settings.maxManualDownloads)", value: binding(\.maxManualDownloads), in: 1...32)
            Stepper("失败重试次数：\(coordinator.data.settings.maximumRetries)", value: binding(\.maximumRetries), in: 0...10)
            Stepper("重试间隔：\(coordinator.data.settings.retryDelaySeconds) 秒", value: binding(\.retryDelaySeconds), in: 1...120)
            Toggle("使用服务器文件时间", isOn: binding(\.useServerTimestamp))
            Toggle("取消时清除部分文件", isOn: binding(\.deletePartialOnCancel))
            Toggle("跟踪已完成文件的移动或删除", isOn: binding(\.trackDeletedFiles))
            Toggle("传输期间防止系统睡眠", isOn: binding(\.preventSleepDuringTransfers))
            Section("声音") {
                Toggle("播放提示音", isOn: binding(\.soundEnabled))
                if coordinator.data.settings.soundEnabled {
                    soundRow("常规提示音", path: \.normalSoundPath)
                    soundRow("成功提示音", path: \.successSoundPath)
                    soundRow("错误提示音", path: \.errorSoundPath)
                    if !soundStatus.isEmpty { Text(soundStatus).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Toggle("任务开始时自动打开进度窗口", isOn: binding(\.showProgressWindow))
            Toggle("下载完成时显示窗口", isOn: binding(\.showCompletionWindow))
            SystemIntegration(coordinator: coordinator)
        }.padding(18)
    }

    private var network: some View {
        Form {
            TextField("User-Agent（留空使用系统默认）", text: binding(\.userAgent))
            Picker("代理", selection: binding(\.proxyMode)) { Text("系统代理").tag(ProxyMode.system); Text("直连").tag(ProxyMode.direct); Text("手动").tag(ProxyMode.manual); Text("PAC").tag(ProxyMode.pac) }
            if coordinator.data.settings.proxyMode == .manual {
                Picker("类型", selection: binding(\.proxyScheme)) { Text("HTTP").tag(ProxyScheme.http); Text("HTTPS").tag(ProxyScheme.https); Text("SOCKS5").tag(ProxyScheme.socks5) }
                TextField("代理服务器", text: binding(\.proxyHost))
                TextField("端口", value: binding(\.proxyPort), format: .number)
                TextField("代理用户名", text: binding(\.proxyUsername))
                HStack {
                    SecureField("代理密码（单独保存在钥匙串）", text: $proxyPasswordInput)
                    Button("保存") { saveProxyPassword() }
                    Button("清除") { clearProxyPassword() }
                }
                if !proxyPasswordStatus.isEmpty { Text(proxyPasswordStatus).font(.caption).foregroundStyle(.secondary) }
                TextField("绕过的主机（逗号分隔）", text: stringArrayBinding(\.proxyBypass))
            }
            if coordinator.data.settings.proxyMode == .pac { TextField("PAC URL", text: binding(\.pacURL)) }
            Toggle("允许无效 TLS 证书", isOn: binding(\.allowInvalidTLSCertificates))
            TextField("全局限速（字节/秒，0 表示不限）", value: binding(\.globalSpeedLimitBytesPerSecond), format: .number)
            Picker("全局限速模式", selection: binding(\.globalSpeedLimitMode)) {
                Text("关闭").tag(GlobalSpeedLimitMode.off)
                Text("始终限速").tag(GlobalSpeedLimitMode.always)
                Text("App 在后台且最近有系统交互时限速").tag(GlobalSpeedLimitMode.backgroundInteraction)
            }
            Stepper("每主机连接数：\(coordinator.data.settings.defaultConnectionCount)", value: binding(\.defaultConnectionCount), in: 1...256)
            TextField("Range 最小分段（字节）", value: binding(\.minimumSegmentSizeBytes), format: .number)
            Toggle("将 Range 任务细分后动态排队", isOn: binding(\.dynamicSegmentation))
            Toggle("并行 Range 使用稀疏预分配", isOn: binding(\.sparseFiles))
            Picker("DNS 解析", selection: binding(\.dnsMode)) {
                Text("系统 DNS").tag(DNSMode.system)
                Text("本应用使用 DoH").tag(DNSMode.doh)
            }
            if coordinator.data.settings.dnsMode == .doh {
                TextField("DoH 服务 HTTPS URL", text: binding(\.dohURL))
            }
            Button("逐主机设置…") { showingHostRules = true }
            Text("未完成文件写入应用私有暂存区；目标下载目录不会出现可能被误认为成品的 .part 文件。")
                .font(.caption).foregroundStyle(.secondary)
            Text("DoH 只作用于本应用进程，不修改 macOS 的系统 DNS；开启后解析失败不会回退明文 DNS。并行 Range 需要来源声明 Range、可靠长度及可比对的版本标识。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var integration: some View {
        Form {
            Toggle("启用本机 API", isOn: binding(\.apiEnabled))
            TextField("监听端口（仅 127.0.0.1）", value: binding(\.apiPort), format: .number).disabled(!coordinator.data.settings.apiEnabled)
            Toggle("要求 API Key", isOn: binding(\.apiRequiresKey)).disabled(!coordinator.data.settings.apiEnabled)
            SecureField("API Key", text: $keyInput).disabled(!coordinator.data.settings.apiRequiresKey)
            HStack { Button("保存 Key") { saveKey() }; Text(keyStatus).foregroundStyle(.secondary) }
            Divider()
            Text("Chrome 扩展使用本机 API；安装说明和扩展版本识别见交付目录的 `docs/native-rebuild/chrome-install.md`。扩展权限只在用户启用相应功能时申请。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var behavior: some View {
        Form {
            TextField("自动接管绕过键", text: extensionBinding(\.bypassKey))
            Toggle("自动接管浏览器文件下载", isOn: extensionBinding(\.autoCapture))
            Toggle("显示网页选区/媒体候选", isOn: extensionBinding(\.showPageWidgets))
            Toggle("发送观察到的请求头和 Cookie", isOn: extensionBinding(\.sendRequestHeaders))
            Toggle("静默添加", isOn: extensionBinding(\.silentAdd))
            Toggle("静默添加后开始下载", isOn: extensionBinding(\.silentStart)).disabled(!coordinator.data.settings.extensionSettings.silentAdd)
            Toggle("关闭已接管的新标签页", isOn: extensionBinding(\.closeCapturedTab))
            TextField("自动接管最小文件大小（KB）", value: extensionBinding(\.minimumSizeKB), format: .number)
            TextField("自动接管扩展名（逗号分隔）", text: extensionArrayBinding(\.extensions))
            TextField("忽略规则（每行一项）", text: extensionArrayBinding(\.ignoredPatterns))
            Text("App 保存浏览器偏好。扩展连接本机 API 时同步这些设置；App 离线时 Chrome 本地副本继续生效，扩展选项页会显示同步状态。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var legacy: some View {
        Form {
            Text("旧任务、分类、队列、设置与历史记录不会自动导入。预览只读取旧 state.json；只有确认后才会复制快照并写入新格式。旧文件和旧下载文件保持原位。")
            Button("预览旧数据") { previewLegacy() }.disabled(!coordinator.legacyStateAvailable)
            if let preview = legacyPreview {
                LabeledContent("旧文件", value: preview.sourceURL.path)
                LabeledContent("任务", value: "\(preview.taskCount)（完成 \(preview.completedCount)，其他 \(preview.unfinishedCount)）")
                LabeledContent("分类 / 队列 / 设置", value: "\(preview.categoryCount) / \(preview.queueCount) / \(preview.settingCount)")
                Button("确认快照并导入") { importLegacy() }.buttonStyle(.borderedProminent)
            }
            if let legacyError { Text(legacyError).foregroundStyle(.red).textSelection(.enabled) }
            if let imported = coordinator.data.importedLegacyAt { Text("已导入：\(imported.formatted())") }
        }.padding(18)
    }

    private var updates: some View {
        Form {
            Toggle("启用手动更新检查", isOn: binding(\.updatesEnabled))
            TextField("HTTPS 更新清单 URL", text: binding(\.updateManifestURL))
                .disabled(!coordinator.data.settings.updatesEnabled)
            HStack {
                Button(updateBusy ? "正在检查…" : "检查更新") { Task { await checkUpdates() } }
                    .disabled(updateBusy || !coordinator.data.settings.updatesEnabled || coordinator.data.settings.updateManifestURL.isEmpty)
                if let result = updateResult, result.updateAvailable {
                    Button(updateBusy ? "正在下载…" : "下载并校验") { Task { await downloadUpdate(result.manifest) } }
                        .disabled(updateBusy)
                }
                if let updateArtifact {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([updateArtifact]) }
                }
                if let result = updateResult, let updateArtifact {
                    Button("替换安装并重启") { installUpdate(result.manifest, artifact: updateArtifact) }
                        .disabled(!canInstallUpdate(result.manifest, artifact: updateArtifact))
                }
            }
            if !updateStatus.isEmpty { Text(updateStatus).textSelection(.enabled).foregroundStyle(.secondary) }
            if let result = updateResult {
                LabeledContent("清单版本", value: result.manifest.version)
                if let notes = result.manifest.releaseNotes, !notes.isEmpty { Text(notes).textSelection(.enabled) }
            }
            Text("更新下载先核对 HTTPS、SHA-256 和当前 Mac 架构。自动替换只接受带签名团队 ID 的 ZIP App 包；安装器会验证产品身份、版本、架构和代码签名，并保留当前 App 回滚副本。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    private func binding<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { coordinator.data.settings[keyPath: path] }, set: { value in coordinator.updateSettings { $0[keyPath: path] = value } })
    }
    private func extensionBinding<Value>(_ path: WritableKeyPath<ExtensionSettings, Value>) -> Binding<Value> {
        Binding(get: { coordinator.data.settings.extensionSettings[keyPath: path] }, set: { value in coordinator.updateSettings { $0.extensionSettings[keyPath: path] = value } })
    }
    private func stringArrayBinding(_ path: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(get: { coordinator.data.settings[keyPath: path].joined(separator: ", ") }, set: { text in coordinator.updateSettings { $0[keyPath: path] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } })
    }
    private func extensionArrayBinding(_ path: WritableKeyPath<ExtensionSettings, [String]>) -> Binding<String> {
        Binding(get: { coordinator.data.settings.extensionSettings[keyPath: path].joined(separator: ", ") }, set: { text in coordinator.updateSettings { $0.extensionSettings[keyPath: path] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } } })
    }
    private func chooseDirectory() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { coordinator.updateSettings { $0.defaultDownloadDirectory = url.path } } }
    private func soundRow(_ title: String, path: WritableKeyPath<AppSettings, String>) -> some View {
        HStack {
            TextField(title + "（WAV，可留空使用系统音效）", text: binding(path)).textFieldStyle(.roundedBorder)
            Button("选择…") { chooseSound(path) }
            Button("试听") { previewSound(coordinator.data.settings[keyPath: path]) }
            Button("清除") { coordinator.updateSettings { $0[keyPath: path] = "" } }
        }
    }
    private func chooseSound(_ path: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav]
        panel.prompt = "选择 WAV 音效"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.updateSettings { $0[keyPath: path] = url.path }
            soundStatus = "音效路径已保存。"
        }
    }
    private func previewSound(_ path: String) {
        if path.isEmpty { NSSound(named: NSSound.Name("Glass"))?.play(); soundStatus = "已试听系统音效。"; return }
        guard FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) else {
            soundStatus = "找不到或无法读取该 WAV 文件。"; return
        }
        sound.play(); soundStatus = "已试听所选音效。"
    }
    private func saveProxyPassword() {
        do {
            try coordinator.credentials.write(proxyPasswordInput, account: coordinator.data.settings.proxyPasswordAccount)
            proxyPasswordInput = ""
            proxyPasswordStatus = "代理密码已保存到钥匙串。"
        } catch { proxyPasswordStatus = "保存失败：\(error.localizedDescription)" }
    }
    private func clearProxyPassword() {
        do {
            try coordinator.credentials.write(nil, account: coordinator.data.settings.proxyPasswordAccount)
            proxyPasswordInput = ""
            proxyPasswordStatus = "已从钥匙串清除代理密码。"
        } catch { proxyPasswordStatus = "清除失败：\(error.localizedDescription)" }
    }
    private func saveKey() {
        do { try coordinator.credentials.write(keyInput.isEmpty ? nil : keyInput, account: coordinator.data.settings.apiKeyAccount); keyStatus = keyInput.isEmpty ? "已移除" : "已保存到钥匙串"; keyInput = "" }
        catch { keyStatus = error.localizedDescription }
    }
    private func previewLegacy() { do { legacyPreview = try coordinator.previewLegacyImport() } catch { legacyError = error.localizedDescription } }
    private func importLegacy() {
        do {
            let result = try coordinator.importLegacyData()
            let notes = result.migrationNotes.isEmpty ? "" : "\n迁移说明：\(result.migrationNotes.joined(separator: "；"))"
            legacyError = "导入任务 \(result.tasksImported) 项；快照：\(result.sourcePreservedAt.path)\(notes)"
        } catch { legacyError = error.localizedDescription }
    }

    @MainActor private func checkUpdates() async {
        guard let url = URL(string: coordinator.data.settings.updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            updateStatus = UpdateServiceError.invalidManifest.localizedDescription; return
        }
        updateBusy = true; updateArtifact = nil
        defer { updateBusy = false }
        do {
            let result = try await UpdateService.check(manifestURL: url, currentVersion: ProductIdentity.version)
            updateResult = result
            updateStatus = result.updateAvailable ? "发现版本 \(result.manifest.version)。" : "当前版本已是最新。"
            coordinator.updateSettings { $0.lastUpdateCheck = .now }
        } catch {
            updateResult = nil
            updateStatus = error.localizedDescription
        }
    }

    @MainActor private func downloadUpdate(_ manifest: UpdateManifest) async {
        updateBusy = true; updateArtifact = nil
        defer { updateBusy = false }
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let folder = downloads.appendingPathComponent("zjx-download Updates", isDirectory: true)
            updateArtifact = try await UpdateService.downloadAndVerify(manifest, to: folder)
            updateStatus = "已下载并通过 HTTPS 与 SHA-256 校验：\(updateArtifact?.lastPathComponent ?? "")。签名团队 ID 缺失或文件不是 ZIP 时，只能手动处理。"
        } catch { updateStatus = error.localizedDescription }
    }

    private func canInstallUpdate(_ manifest: UpdateManifest, artifact: URL) -> Bool {
        guard artifact.pathExtension.lowercased() == "zip", manifest.signingTeamID != nil,
              UpdateService.isCompatibleWithCurrentMac(manifest), !coordinator.hasOutstandingTransfers else { return false }
        let target = URL(fileURLWithPath: "/Applications/zjx-download.app", isDirectory: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/apply-macos-update")
        return Bundle.main.bundleURL.standardizedFileURL == target.standardizedFileURL &&
            FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) &&
            FileManager.default.isExecutableFile(atPath: helper.path)
    }

    @MainActor private func installUpdate(_ manifest: UpdateManifest, artifact: URL) {
        guard canInstallUpdate(manifest, artifact: artifact), let team = manifest.signingTeamID else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "替换并重新打开 zjx-download？"
        confirmation.informativeText = "安装器会先退出 App，校验签名后再替换。当前 App 会保留在 /Applications 作为回滚副本。"
        confirmation.addButton(withTitle: "替换并重启")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/apply-macos-update")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, artifact.path, "/Applications/zjx-download.app", manifest.version,
                             team, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            updateStatus = "已启动签名校验和安全替换。更新日志：~/Library/Logs/zjx-download/update.log"
            NSApp.terminate(nil)
        } catch {
            updateStatus = "无法启动更新安装器：\(error.localizedDescription)"
        }
    }
}

private struct HostRuleDraft: Identifiable {
    let id: UUID
    var pattern: String
    var userAgent: String
    var headersText: String
    var authorizationHeader: String
    var basicUsername: String
    var basicPassword: String
    var credentialAccount: String?
    var clearCredentials: Bool
    var speedLimit: Int64
    var connectionCount: Int

    init(_ rule: HostRule) {
        id = rule.id; pattern = rule.pattern; userAgent = rule.userAgent
        headersText = rule.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        authorizationHeader = ""; basicUsername = ""; basicPassword = ""
        credentialAccount = rule.credentialAccount; clearCredentials = false
        speedLimit = rule.speedLimitBytesPerSecond; connectionCount = rule.connectionCount ?? 0
    }
}

private struct HostCredentialEdit {
    let account: String
    let data: Data?
}

private struct HostRulesSettingsView: View {
    @Bindable var coordinator: TaskCoordinator
    let onBack: () -> Void
    @State private var drafts: [HostRuleDraft]
    @State private var error: String?

    init(coordinator: TaskCoordinator, onBack: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onBack = onBack
        _drafts = State(initialValue: coordinator.data.settings.hostRules.map(HostRuleDraft.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("返回网络设置", action: onBack)
                Text("逐主机设置").font(.title3.bold())
                Spacer()
                Button("新增规则") { drafts.insert(HostRuleDraft(HostRule(pattern: "")), at: 0) }
                Button("保存") { save() }.buttonStyle(.borderedProminent)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("主机模式，例如 files.example.com 或 *.example.com", text: $draft.pattern)
                                Button(role: .destructive) { drafts.removeAll { $0.id == draft.id } } label: { Image(systemName: "trash") }
                            }
                            TextField("User-Agent（留空使用全局值）", text: $draft.userAgent)
                            HStack {
                                Stepper("连接数：\(draft.connectionCount == 0 ? "使用全局" : String(draft.connectionCount))", value: $draft.connectionCount, in: 0...256)
                                TextField("速度上限（B/s，0 不限）", value: $draft.speedLimit, format: .number)
                            }
                            Text("额外请求头（每行 名称: 值；认证头单独存入钥匙串）").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $draft.headersText).font(.system(.body, design: .monospaced)).frame(minHeight: 52, maxHeight: 90).border(.quaternary)
                            HStack {
                                TextField("Basic 用户名", text: $draft.basicUsername)
                                SecureField("Basic 密码", text: $draft.basicPassword)
                            }
                            SecureField("Authorization（留空保留已存值）", text: $draft.authorizationHeader)
                            if draft.credentialAccount != nil {
                                Toggle("清除此规则已保存的认证信息", isOn: $draft.clearCredentials)
                            }
                        }
                        .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.vertical, 4)
            }
        }
        .padding(16)
    }

    private func save() {
        let normalized = drafts.map { $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty }), Set(normalized.map { $0.lowercased() }).count == normalized.count else {
            error = "主机模式不能为空且不能重复。"; return
        }
        do {
            var rules: [HostRule] = []
            var credentialEdits: [String: HostCredentialEdit] = [:]
            for draft in drafts {
                var headers: [String: String] = [:]
                for line in draft.headersText.split(whereSeparator: \.isNewline) {
                    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pieces.count == 2 else { throw ValidationError("额外请求头必须使用 名称: 值 格式。") }
                    let name = String(pieces[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(pieces[1]).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n"),
                          !NetworkConfiguration.sensitiveHeaderNames.contains(name.lowercased()) else {
                        throw ValidationError("认证类请求头请使用钥匙串字段；其它请求头须为单行。")
                    }
                    headers[name] = value
                }
                var account = draft.credentialAccount
                if draft.clearCredentials, let existing = account {
                    credentialEdits[existing] = HostCredentialEdit(account: existing, data: nil)
                    account = nil
                }
                let username = draft.basicUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = draft.basicPassword
                guard username.isEmpty == password.isEmpty else {
                    throw ValidationError("Basic 认证需要同时填写用户名和密码。")
                }
                let typedAuthorization = draft.authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
                guard typedAuthorization.isEmpty || username.isEmpty else {
                    throw ValidationError("请只填写 Basic 认证或 Authorization，不能同时设置。")
                }
                let authorization = username.isEmpty ? typedAuthorization :
                    "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
                if !authorization.isEmpty {
                    account = account ?? "host-\(draft.id.uuidString)-credentials"
                    var secret: [String: String] = [:]
                    if !draft.clearCredentials, let existing = try coordinator.credentials.readData(account: account!) {
                        secret = try JSONSerialization.jsonObject(with: existing) as? [String: String] ?? [:]
                    }
                    secret["Authorization"] = authorization
                    credentialEdits[account!] = HostCredentialEdit(account: account!,
                        data: try JSONSerialization.data(withJSONObject: secret, options: [.sortedKeys]))
                }
                rules.append(HostRule(id: draft.id, pattern: draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                    userAgent: draft.userAgent, headers: headers, credentialAccount: account,
                    speedLimitBytesPerSecond: max(0, draft.speedLimit), connectionCount: draft.connectionCount == 0 ? nil : draft.connectionCount))
            }
            let retainedAccounts = Set(rules.compactMap(\.credentialAccount))
            for old in coordinator.data.settings.hostRules.compactMap(\.credentialAccount) where !retainedAccounts.contains(old) {
                credentialEdits[old] = HostCredentialEdit(account: old, data: nil)
            }
            var originals: [String: Data?] = [:]
            for account in credentialEdits.keys { originals[account] = try coordinator.credentials.readData(account: account) }
            var applied: [String] = []
            do {
                for edit in credentialEdits.values.sorted(by: { $0.account < $1.account }) {
                    try coordinator.credentials.writeData(edit.data, account: edit.account)
                    applied.append(edit.account)
                }
            } catch {
                for account in applied.reversed() { try? coordinator.credentials.writeData(originals[account] ?? nil, account: account) }
                throw error
            }
            coordinator.updateSettings { $0.hostRules = rules }
            error = nil
            onBack()
        } catch let caught { error = caught.localizedDescription }
    }
}
