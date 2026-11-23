# 新实现设计与功能落点

更新时间：2026-11-17（补充主窗口外观）

## 设计决策

- 数据事实只有一份：Mac 界面、Chrome、CLI 都调用同一个 TaskCoordinator 和 TaskStore。
- 新任务和状态按稳定 JSON schema 保存到应用支持目录；下载内容放用户选定目录，临时数据与任务记录分离。
- 旧格式只读预览；用户明确确认后导入到新 schema。旧 state.json、目录书签和 Keychain 条目保留原位，提供新数据导出/回退路径；开发构建不读取或迁移日用数据。
- HTTP(S) 由一套传输引擎执行；Range、来源校验、临时文件原子完成、重试与校验都由真实响应和文件结果决定。
- 队列由独立调度器控制；UI/REST/Native Messaging/CLI 的增删改查和开始/暂停均落到共享任务状态。
- Chrome MV3 只用配套扩展与本项目 Native Messaging host；host 通过应用前台/后台 API 交接，应用不创建独立常驻守护进程。
- 系统能力通过 macOS API：原生目录选择、Keychain、菜单栏、通知、登录项、文件打开、睡眠断言和摘要算法。当前 App 未启用 App Sandbox；下载位置保存为普通 POSIX 路径，由 macOS 文件访问权限和实际文件操作决定可用性，不保存 security-scoped bookmark。
- 主窗口以 AppKit `NSVisualEffectView` 的 `underWindowBackground` 与 `behindWindow` 显示窗后背景，搜索与操作区采用 SwiftUI 原生玻璃，任务表保留系统表格底色。系统启用「降低透明度」时使用实色窗底。见 A-071。
- HTTP HLS 仅承诺有限、未加密、TS media playlist。Chrome 可以解析 master 清单并向 App 发送选定 media URL；DRM、独立音轨和直播录制保持明确不支持。
- 原项目源文件、构建缓存及内部类型不作为新实现依赖。兼容读取标准 JSON/Chrome wire 与历史数据格式不等于复用旧业务代码。

## 实现文件职责

| 文件 | 职责 |
|---|---|
| Sources/ZJXDownloadCore/Models.swift | 任务、分类、队列、网络和设置值类型 |
| Sources/ZJXDownloadCore/StateStore.swift | 原子持久化、旧格式只读预览、确认后迁移、备份与回退 |
| Sources/ZJXDownloadCore/TaskCoordinator.swift | UI/接口/CLI共享任务命令与状态更新 |
| Sources/ZJXDownloadCore/DownloadEngine.swift | HTTP(S)、URLSession 恢复、重试、文件冲突与完整性 |
| Sources/ZJXDownloadCore/SegmentedDownloadService.swift | 有可靠版本标识的并行 Range、检查点复用、来源验证和安全合并 |
| Sources/ZJXDownloadCore/HLSService.swift | 有限 TS Media Playlist、来源校验后的分段恢复与顺序合并 |
| Sources/ZJXDownloadCore/QueueScheduler.swift | 队列顺序、并发和星期计划 |
| Sources/ZJXDownloadCore/NetworkConfiguration.swift; Sources/ZJXDownloadCore/ProcessDNSResolver.swift; Sources/ZJXDownloadNetworkShim/ProcessDNSShim.c | 代理、系统 DNS、进程级 DoH、TLS、User-Agent、主机匹配和限速 |
| Sources/ZJXDownloadCore/IntegrationServer.swift | loopback REST、认证、requestId 去重、Chrome/CLI交接 |
| Sources/ZJXDownloadCore/SecurityStores.swift | Keychain 凭据及敏感请求头；目录以原生选择器和普通路径表示 |
| Sources/ZJXDownloadCore/InputImport.swift | URL、JSON/cURL、批量文本与编号网址解析 |
| Sources/ZJXDownloadCore/ExchangeCodec.swift | HTTP来源 JSON/cURL 导入导出 |
| Sources/ZJXDownloadCore/ChecksumService.swift | SHA/MD5 文件校验与取消 |
| Sources/ZJXDownloadCore/UpdateService.swift; Sources/ZJXDownloadApp/SettingsViews.swift; scripts/apply-macos-update | HTTPS 更新清单、架构与 SHA-256 校验、签名团队验证、用户确认后安全替换和回滚副本 |
| Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadApp/MainWindow.swift | 错误分类、脱敏和可复制诊断 |
| Sources/ZJXDownloadApp/MainWindow.swift | 原生任务表、侧栏、筛选、多选和文件操作 |
| Sources/ZJXDownloadApp/DownloadComposer.swift | URL、批量、凭据、冲突和目录选择表单 |
| Sources/ZJXDownloadApp/CategoryViews.swift | 分类规则、目录和恢复默认 |
| Sources/ZJXDownloadApp/QueueViews.swift | 队列编辑、排序、计划和完成动作 |
| Sources/ZJXDownloadApp/SettingsViews.swift | 外观、基础网络、浏览器集成、逐主机和 Range 分片设置 |
| Sources/ZJXDownloadApp/TaskDetailViews.swift | 进度、属性、单项设置和完成结果 |
| Sources/ZJXDownloadApp/TaskDetailViews.swift | 校验结果与摘要编辑 |
| Sources/ZJXDownloadApp/SystemIntegration.swift | Finder、打开方式、通知、登录项、防睡眠和电源动作 |
| Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift | 单实例、启动/退出和恢复状态 |
| Sources/ZJXDownloadApp/AppCommands.swift | 菜单、快捷键、状态栏命令 |
| Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/TaskDetailViews.swift | 任务错误与 App 级错误呈现 |
| Sources/ZJXDownloadApp/AboutView.swift | 关于、许可与上游署名；本地界面文案为简体中文，其他语言使用中文回退 |
| Sources/ZJXDownloadNativeHost/NativeHost.swift; Sources/ZJXDownloadCore/NativeHostProtocol.swift | Chrome Native Messaging 4字节长度协议适配器 |
| Sources/ZJXDownloadCLI/main.swift | 同一任务 API 的桌面命令行 |
| browser-extension/src/background.js; browser-extension/src/content.js; browser-extension/src/app-api.js; browser-extension/src/options.js; browser-extension/src/popup.js; browser-extension/src/storage.js | MV3 后台、弹窗、设置、右键、接管、媒体和交接 |

## 80组功能落点与用户手测编号

A 编号沿用 docs/clean-room-rebuild/40-end-to-end-acceptance.md。G-014 是旧阶段条款，用户本轮已明确覆盖，不计为产品能力；D-025 仅实现 macOS 原生桌面与菜单入口。
| 编号 | 功能/要求 | 新实现落点 | 用户手测编号 |
|---|---|---|---|
| G-001 | [R] 功能入口必须形成完整闭环 | Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadApp/MainWindow.swift | A-002, A-036, A-044 |
| G-002 | [R] 任务记录与文件分别处理 | Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadCore/StateStore.swift | A-017, A-018 |
| G-003 | [R] 执行状态与磁盘事实一致 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/StateStore.swift | A-007, A-009, A-014, A-034, A-035 |
| G-004 | [R] 所有设置都有实际作用和生效范围 | Sources/ZJXDownloadCore/Models.swift; Sources/ZJXDownloadApp/SettingsViews.swift | A-012, A-027, A-043, A-045 |
| G-005 | [R] 表单取消与失败可恢复 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/InputImport.swift | A-003, A-005, A-020 |
| G-006 | [R] 重启有明确结果 | Sources/ZJXDownloadCore/StateStore.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-007, A-010, A-043 |
| G-007 | [R] 批量命令遵守可见范围和选择范围 | Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/AppCommands.swift | A-018, A-022, A-032 |
| G-008 | [R] 浏览器接管有可验证的交接结果 | Sources/ZJXDownloadCore/IntegrationServer.swift; Sources/ZJXDownloadNativeHost/NativeHost.swift | A-036, A-041, A-042 |
| G-009 | [R] 请求凭据限定在下载用途 | Sources/ZJXDownloadCore/SecurityStores.swift; Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadApp/MainWindow.swift | A-026, A-033, A-043 |
| G-010 | [R] 平台操作采用 macOS 可用行为 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift | A-045, A-048 |
| G-011 | [R] 先证实协议范围 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/HLSService.swift | A-030, A-031 |
| G-012 | [R] 错误必须指向下一步操作 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/TaskDetailViews.swift | A-010, A-015, A-020, A-041 |
| G-013 | [R] 易用性按真实任务验证 | Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/SettingsViews.swift | A-047, A-048, A-049 |
| G-014 | [R] 本轮完成文档，不启动开发 | docs/native-rebuild/design-and-coverage.md（旧阶段条款覆盖已由用户任务书明确授权） | —（阶段条款，不是产品能力） |
| G-015 | [S/R] 同一份用户数据只由一个应用实例管理 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift; Sources/ZJXDownloadCore/IntegrationServer.swift | A-050 |
| G-016 | [S/R] 普通启动、后台启动和重新显示主窗分别定义 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift; Sources/ZJXDownloadApp/AppMain.swift | A-001, A-050 |
| G-017 | [S/R] 应用异常有独立于下载错误的反馈 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/TaskDetailViews.swift | A-010, A-045 |
| D-001 | 主页面、入口和筛选 | Sources/ZJXDownloadApp/MainWindow.swift | A-001, A-032, A-047 |
| D-002 | 下载列表、列、排序和选择 | Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadCore/Models.swift | A-032, A-049 |
| D-003 | 菜单命令、快捷键与删除范围 | Sources/ZJXDownloadApp/AppCommands.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-017, A-018, A-032 |
| D-004 | 新建网址与凭据导入 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/InputImport.swift | A-003, A-026, A-033 |
| D-005 | 批量网址生成 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/InputImport.swift | A-005 |
| D-006 | 单条添加下载 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/DownloadEngine.swift | A-002, A-003, A-006, A-014, A-015 |
| D-007 | 重复下载冲突 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-014, A-017 |
| D-008 | 编辑现有下载 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-020 |
| D-009 | 多条链接添加 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadCore/InputImport.swift | A-004, A-005 |
| D-010 | 分类管理 | Sources/ZJXDownloadApp/CategoryViews.swift; Sources/ZJXDownloadCore/Models.swift | A-021 |
| D-011 | 队列界面入口 | Sources/ZJXDownloadApp/QueueViews.swift | A-022, A-023 |
| D-012 | 下载进度、完成窗口和单项设置 | Sources/ZJXDownloadApp/TaskDetailViews.swift | A-002, A-025 |
| D-013 | 设置页面结构和外观 | Sources/ZJXDownloadApp/SettingsViews.swift | A-045, A-047, A-048 |
| D-014 | 通知、登录启动和系统托盘 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift | A-045 |
| D-015 | 默认下载目录和路径选择器 | Sources/ZJXDownloadApp/DownloadComposer.swift; Sources/ZJXDownloadApp/SettingsViews.swift | A-002, A-015 |
| D-016 | 下载引擎设置入口 | Sources/ZJXDownloadApp/SettingsViews.swift; Sources/ZJXDownloadCore/NetworkConfiguration.swift | A-012, A-013, A-026, A-027, A-028, A-029 |
| D-017 | 浏览器集成设置入口 | Sources/ZJXDownloadApp/SettingsViews.swift; Sources/ZJXDownloadCore/IntegrationServer.swift | A-041, A-043 |
| D-018 | 逐主机设置窗口 | Sources/ZJXDownloadApp/SettingsViews.swift; Sources/ZJXDownloadCore/NetworkConfiguration.swift; Sources/ZJXDownloadCore/SecurityStores.swift | A-027, A-028, A-029 |
| D-019 | 文件校验工具 | Sources/ZJXDownloadCore/ChecksumService.swift; Sources/ZJXDownloadApp/TaskDetailViews.swift | A-034 |
| D-020 | 下载错误对话框 | Sources/ZJXDownloadApp/MainWindow.swift; Sources/ZJXDownloadApp/TaskDetailViews.swift; Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadApp/MainWindow.swift | A-003, A-010, A-015, A-041 |
| D-021 | 更新检查与版本提示 | Sources/ZJXDownloadCore/UpdateService.swift; Sources/ZJXDownloadApp/SettingsViews.swift; scripts/apply-macos-update（HTTPS 清单、SHA-256、签名团队验证、产品身份/架构校验、安全替换与回滚） | A-046 |
| D-022 | 关于、致谢、翻译和开源许可 | Sources/ZJXDownloadApp/AboutView.swift; LICENSE; browser-extension/LICENSE（项目/上游/翻译入口、许可与署名信息） | A-047 |
| D-023 | 退出确认 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadApp/AppMain.swift; Sources/ZJXDownloadApp/AppCommands.swift | A-025, A-050 |
| D-024 | 下载完成后的系统电源动作 | Sources/ZJXDownloadApp/SystemIntegration.swift; Sources/ZJXDownloadCore/QueueScheduler.swift | A-025 |
| D-025 | 平台专有桌面入口 | Sources/ZJXDownloadApp/AppCommands.swift（仅macOS原生桌面与菜单入口） | A-001, A-047 |
| D-026 | JSON/cURL 交换格式与任务数据边界 | Sources/ZJXDownloadCore/ExchangeCodec.swift; Sources/ZJXDownloadCLI/main.swift | A-033, A-044 |
| N-001 | HTTP/HTTPS 下载创建、请求字段和命名 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/Models.swift | A-002, A-026 |
| N-002 | Range、并发分片、断点恢复与重试 | Sources/ZJXDownloadCore/SegmentedDownloadService.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift（有验证器时并行；预先分片，活动任务不动态重平衡） | A-007, A-008, A-009, A-010, A-013, A-016, A-019 |
| N-003 | 输出文件、剩余空间、时间戳和部分文件 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift（完整文件原子提交；稀疏预分配/目标目录 .part 后缀未使用） | A-011, A-014, A-015, A-016 |
| N-004 | HLS 下载范围和限制 | Sources/ZJXDownloadCore/HLSService.swift | A-030, A-031 |
| N-005 | 全局与单任务速度、连接和重试设置 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/SegmentedDownloadService.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadApp/SettingsViews.swift（HTTP 限速/连接/重试可用；HLS 限速和活动连接数重配置缺失） | A-012, A-013 |
| N-006 | 代理、DNS、TLS、User-Agent 与 HTTP 协议 | Sources/ZJXDownloadCore/DownloadEngine.swift; Sources/ZJXDownloadCore/HLSService.swift; Sources/ZJXDownloadCore/NetworkConfiguration.swift; Sources/ZJXDownloadApp/SettingsViews.swift（DoH 未接入） | A-027, A-028, A-029 |
| N-007 | 逐主机下载覆盖 | Sources/ZJXDownloadApp/SettingsViews.swift; Sources/ZJXDownloadCore/NetworkConfiguration.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadCore/SecurityStores.swift | A-020, A-028 |
| N-008 | 下载期间防止系统睡眠 | Sources/ZJXDownloadApp/SystemIntegration.swift | A-025 |
| N-009 | 文件校验工具 | Sources/ZJXDownloadCore/ChecksumService.swift | A-034 |
| Q-001 | 队列模型、默认队列和删除 | Sources/ZJXDownloadCore/Models.swift; Sources/ZJXDownloadCore/StateStore.swift; Sources/ZJXDownloadApp/QueueViews.swift | A-006, A-022 |
| Q-002 | 顺序、并发和任务状态流转 | Sources/ZJXDownloadCore/QueueScheduler.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-006, A-022, A-024 |
| Q-003 | 周期计划和空队列策略 | Sources/ZJXDownloadCore/QueueScheduler.swift; Sources/ZJXDownloadApp/QueueViews.swift | A-023 |
| Q-004 | 下载完成动作 | Sources/ZJXDownloadCore/QueueScheduler.swift; Sources/ZJXDownloadApp/SystemIntegration.swift | A-024, A-025 |
| I-001 | 本地 REST 服务线协议 | Sources/ZJXDownloadCore/IntegrationServer.swift; Sources/ZJXDownloadCore/TaskCoordinator.swift | A-041, A-043, A-050 |
| I-002 | 桌面 CLI 命令与能力范围 | Sources/ZJXDownloadCLI/main.swift; Sources/ZJXDownloadCore/IntegrationServer.swift | A-044, A-050 |
| I-003 | 原生消息通信与启动交接 | Sources/ZJXDownloadNativeHost/NativeHost.swift; Sources/ZJXDownloadCore/NativeHostProtocol.swift; Sources/ZJXDownloadCore/IntegrationServer.swift | A-042 |
| N-010 | 磁盘文件删除跟踪与缺失项清理 | Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadCore/StateStore.swift | A-018, A-035 |
| N-011 | 新产品的状态与恢复约定 | Sources/ZJXDownloadCore/TaskCoordinator.swift; Sources/ZJXDownloadCore/DownloadEngine.swift | A-007, A-008, A-009, A-010, A-016, A-019 |
| B-001 | 浏览器安装、权限与入口 | browser-extension/src/manifest.json; browser-extension/src/background.js | A-036, A-037, A-043 |
| B-002 | 配置保存与即时生效 | browser-extension/src/storage.js; browser-extension/src/options.js | A-043, A-045 |
| B-003 | 工具栏弹窗与连接状态 | browser-extension/src/popup.html; browser-extension/src/popup.js; browser-extension/src/background.js | A-041, A-043 |
| B-004 | 右键菜单单项下载 | browser-extension/src/background.js; browser-extension/src/background.js | A-036 |
| B-005 | 右键下载选区内链接 | browser-extension/src/content.js; browser-extension/src/background.js | A-038 |
| B-006 | 拖选文字后的“下载选中链接”快捷条 | browser-extension/src/content.js | A-038 |
| B-007 | 自动接管浏览器下载 | browser-extension/src/background.js; browser-extension/src/content.js; browser-extension/src/background.js | A-037, A-041 |
| B-008 | 新标签页自动关闭 | browser-extension/src/background.js; browser-extension/src/content.js; browser-extension/src/options.js | A-037 |
| B-009 | 绕过自动接管快捷键 | browser-extension/src/background.js; browser-extension/src/content.js; browser-extension/src/options.js | A-037, A-040 |
| B-010 | 站点忽略规则、后缀与大小门槛 | browser-extension/src/options.js; browser-extension/src/background.js; browser-extension/src/content.js | A-037, A-039 |
| B-011 | Cookie、请求头与认证信息 | browser-extension/src/background.js; browser-extension/src/background.js | A-026, A-036, A-039, A-043 |
| B-012 | 静默添加与静默开始 | browser-extension/src/options.js; browser-extension/src/background.js | A-040 |
| B-013 | HTTP 音视频发现 | browser-extension/src/background.js; browser-extension/src/content.js; browser-extension/src/content.js | A-039 |
| B-014 | HLS 清单、质量、音轨与 DRM | browser-extension/src/background.js; browser-extension/src/background.js; browser-extension/src/content.js | A-030, A-031, A-039 |
| B-015 | 网页媒体候选条 | browser-extension/src/content.js; browser-extension/src/content.js | A-039 |
| B-016 | 应用 API 与队列 | browser-extension/src/app-api.js; Sources/ZJXDownloadCore/IntegrationServer.swift | A-041, A-043, A-050 |
| B-017 | Native Messaging 通道 | Sources/ZJXDownloadNativeHost/NativeHost.swift; Sources/ZJXDownloadCore/NativeHostProtocol.swift; browser-extension/src/app-api.js | A-042 |
| B-018 | 设置页字段、默认值与生效点 | browser-extension/src/options.html; browser-extension/src/options.js | A-043 |
| B-019 | 通知与错误提示 | browser-extension/src/background.js; browser-extension/src/content.js | A-041, A-042, A-043 |

## 当前实现差异

功能落点表定义源码位置，不代表验收通过。静态复核确认：更新流程包含 HTTPS 清单、SHA-256、签名团队/身份/架构核对、安全替换与回滚；macOS 睡眠、退出和关机动作有确认倒计时及错误呈现，实际系统结果仍待用户验收。界面文案提供简体中文，系统其他语言回退简体中文；比例设置使用 macOS Dynamic Type 档位；App 未启用 Sandbox，目录使用原生选择器及普通路径，不存 security-scoped bookmark。这三项是当前产品边界/原生实现选择，需在交付说明中明示。任务表通过 SwiftUI Table 持久化列顺序、可见性、尺寸和排序。静态源码落点已覆盖全部 80 组适用编号；功能验收仍须用户执行，初始状态全部保持“待用户测试”。

## 交付状态

功能落点表定义实现位置和用户验收编号，不代表功能已完成或测试通过。实现进度按 PROGRESS.md 追加；用户手测初始状态统一为“待用户测试”。
