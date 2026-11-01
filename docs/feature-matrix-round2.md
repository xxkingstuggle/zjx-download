# Round 2 feature matrix (independent audit)

> 历史记录：本文属于 2026-10-18 替换前的实现/审计阶段，保留用于追溯。文中的“当前”、测试结果和执行任务不适用于现役实现；现役入口见 [文档索引](README.md)，执行边界以根目录 AGENTS.md 为准。

本矩阵不把静态代码存在当成通过。状态只使用：`UNAUDITED`、`IMPLEMENTED_UNVERIFIED`、`VERIFIED`、`FAILED`、`NOT_APPLICABLE_WITH_EVIDENCE`。

证据目录：`.build/audit-round2/`（worker 证据）和 `.build/audit-round2-independent-20260914/`（本轮独立证据）。

| 能力 | Original behavior | Current implementation | Runtime verified | Edge cases verified | Evidence | Status |
|---|---|---|---|---|---|---|
| 最小窗口布局 | 侧栏、下载列表、工具栏在最小可用窗口可操作 | `NavigationSplitView` 可收起；Inspector 窄宽度改为 sheet；AppKit `contentMinSize` 为 544×420；详情用普通 `HStack` 避免 `HSplitView` 硬下限 | 独立 Release app，AX 设置 500/520/543/544/545/560/580/620/700/800/900/1024/1280/1440/1600；低于 544 被夹到 544；`.build/.../window-544.png` | 中文空状态和有任务列表截图；Inspector 组合未由本轮独立脚本重新覆盖 | `.build/audit-round2-independent-20260914/window-544.png`, `window-1024.png` | IMPLEMENTED_UNVERIFIED |
| 外观 Light/Dark | Light、Dark 覆盖系统并作用于主界面 | `ThemeMode` → `AppearanceOverride` → scene `preferredColorScheme` | 独立副本以持久化 `light`/`dark` 启动并截屏，中文 UI 随主题改变 | Settings/sheet/popover 与运行时系统切换未完整覆盖 | `.build/.../appearance-light.png`, `appearance-dark.png`, `AppearanceTests.swift` | IMPLEMENTED_UNVERIFIED |
| 外观 System/重启 | System 实时跟随 macOS，重启保持选择 | `.system` 映射为 `nil`，设置由 `AppStateStore` 持久化 | 纯映射和 Codable round-trip 通过 | 未改变用户 macOS 全局外观；System→Light→Dark→System live 切换未验证 | `AppearanceTests.swift` | IMPLEMENTED_UNVERIFIED |
| 中文/英文资源 | 所有显示字符串来自本地化表 | zh-Hans/en 表，新增 toolbar/sidebar key | 58 测试含 4 个本地化表检查；独立 Release 截图显示中文 | English 长文本与所有弹窗未逐项 UI 验证 | `LocalizationTests.swift`, `appearance-*.png` | VERIFIED |
| 创建下载、URL 校验 | 新建任务并拒绝无效 URL | `NewDownloadSheet`、批量 URL 展开、校验逻辑 | 集成测试覆盖基础创建路径 | 批量组合状态和 UI 错误提示未全覆盖 | `IntegrationTests.swift`, `ModelTests.swift` | IMPLEMENTED_UNVERIFIED |
| redirect / Range | 跟随重定向；服务器支持 Range 时分段下载 | `HTTPClient`/`DownloadEngine` 支持 Range 与 fallback | 测试通过 | HTTPS、跨主机 redirect、无 Range 重连边界未全覆盖 | `IntegrationTests.testNoRangeFallbackAndRedirect`, `testHTTPProbeAndRangeDownload` | VERIFIED |
| 持久化恢复 | 退出/重启恢复任务和元数据 | `AppStateStore` + sidecar part state | 测试通过 | 真正进程退出后恢复和旧版本迁移未完整验证 | `IntegrationTests.testPersistenceRecoversActiveTasks` | IMPLEMENTED_UNVERIFIED |
| 临时文件/取消清理 | 取消、失败和退出不留下错误的临时文件 | `.abpart` sidecar、取消/abort 清理 | 取消与 abort 测试通过 | 断电、磁盘满、权限拒绝未覆盖 | `IntegrationTests.testCancelCleansPartFiles`, `testAbortCleansPartFiles` | VERIFIED |
| checksum/文件完整性 | 下载后校验大小/hash | 下载引擎合并后校验，独立 checksum 工具 | checksum 边界测试通过 | 大文件、错误 hash UI、批量校验未覆盖 | `IntegrationTests.testChecksumAndScheduleBoundaries` | IMPLEMENTED_UNVERIFIED |
| pause/resume/retry/cancel | 可暂停、恢复、重试、取消并正确更新状态 | `DownloadEngine`、`TaskSelection`、scheduler | 状态选择和部分引擎测试通过 | 断网重连、服务器无 Range 的 resume 未完整覆盖 | `SelectionTests.swift`, `IntegrationTests.swift` | IMPLEMENTED_UNVERIFIED |
| Queue | 队列并发和停止/启动意图 | `QueueScheduler`、队列 UI | scheduler 测试通过 | 完成后 quit/sleep/shutdown action 仍未执行验证 | `IntegrationTests.testSchedulerHonorsQueuedIntentAndStoppedQueue` | IMPLEMENTED_UNVERIFIED |
| History | 完成记录、查看和清空历史 | `HistoryList`、`AppStateStore` history | 静态实现存在 | Finder reveal、批量清理和重启后的 UI 未覆盖 | `docs/audit-upstream-notes.md` | IMPLEMENTED_UNVERIFIED |
| Selection/batch actions | 多选、全选、批量动作只作用于可见项 | `selectedIDs`、primary anchor、batch APIs | 25 个 SelectionTests 通过 | Command-click/Shift-click/right-click/resize 组合未完整 UI 验证 | `SelectionTests.swift` | VERIFIED |
| REST integration | 本地 API 添加任务、列队列、鉴权 | `RESTService` loopback + optional API key | REST compatibility test 通过 | 外部浏览器扩展/native messaging 未实现 | `IntegrationTests.testRESTCompatibility` | IMPLEMENTED_UNVERIFIED |
| Proxy/TLS | system/manual proxy，TLS 策略 | `ProxySettings`/`HTTPClient`，允许不安全证书开关 | 代理 credential 纯模型测试通过 | PAC、bypassList 实际请求和证书失败 UI 未覆盖 | `ModelTests.testProxyCredentialsAreOnlyDerivedForProxyChallenge` | IMPLEMENTED_UNVERIFIED |
| 失败/404/500/断开/慢速/unknown length | 错误可见、可重试，不破坏文件 | 基础失败路径存在 | 本轮未获得全部 fixture 端点的独立通过证据 | 404/500、断开、慢速、unknown length fixture 仍需补测 | `docs/audit-upstream-notes.md` | UNAUDITED |
| 删除语义 | 删除任务可选择同时删文件，支持批量范围 | confirm sheet + `alsoDeleteFiles` | 部分 selection 分类测试通过 | delete-missing/all-finished/all-unfinished/entire-list 菜单缺失 | `docs/audit-upstream-notes.md` | IMPLEMENTED_UNVERIFIED |
| 更新/通知设置 | 更新检查、通知音效和进度对话框 | 部分设置模型和完成通知 | 未验证 | 多个设置字段目前没有消费者；更新器未接入 app | `docs/audit-upstream-notes.md` | FAILED |
| 图标/Bundle/Universal | macOS app 有图标、正确 bundle、可构建双架构 | Xcode asset catalog + `com.zjx.download` | Release 构建成功；两主 Mach-O 均 arm64+x86_64；`AppIcon.icns` 存在 | 签名/安装/发布未在本轮执行 | `xcodebuild` output, `file`, `lipo`, `AppIcon.icns` | VERIFIED |

## 本轮未修复的高优先级问题

- `docs/audit-upstream-notes.md` 记录的上游能力缺口仍存在：搜索/过滤、浏览器扩展、PAC、批量 checksum、删除范围菜单、更新器、队列电源动作等；不能称为完整复刻。
- System 外观的 macOS 全局实时切换、Settings/sheet/popover 全组合和人工可用性仍需人工/专门 UI 自动化验证。
- 失败/404/500/断开/慢速/unknown-length fixture 的完整独立测试没有形成通过证据。
