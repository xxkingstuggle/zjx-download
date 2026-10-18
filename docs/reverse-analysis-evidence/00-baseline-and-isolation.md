# 原项目审计材料：基线与隔离说明

> 2026-10-18授权更新：用户允许查看旧项目及本审计材料；此前严格隔离的访问限制已取消。事实记录保留，新业务实现须独立设计编写。

本目录保存功能分析和源码证据，执行者现在可以查阅。源码定位、版本差异和推导记录属于审计材料。先读当前方向与功能规格，再按需要查阅本目录和旧源码。

## 本轮身份核实

日期：2026-10-17（用户时区 Asia/Shanghai）。

| 对象 | 当前固定基线 | 官方位置 |
|---|---|---|
| 原桌面项目 | `e329495b6630b18e4b41d7682da33318b0f9ea18`，提交日期 2026-10-15 | https://github.com/amir1376/ab-download-manager/tree/e329495b6630b18e4b41d7682da33318b0f9ea18 |
| 桌面稳定发布 | `v1.11.1`，发布 2026-10-14，tag commit `08bfd440a30d367ae369739d866d30f8c1d4b3af` | https://github.com/amir1376/ab-download-manager/releases/tag/v1.11.1 |
| 官方扩展 | `658a0c70188d78033f478ba51c102a273322166f`，提交日期 2026-10-13 | https://github.com/amir1376/ab-download-manager-browser-integration/tree/658a0c70188d78033f478ba51c102a273322166f |
| 扩展稳定发布 | `v1.5.0`，发布 2026-07-27 | https://github.com/amir1376/ab-download-manager-browser-integration/releases/tag/v1.5.0 |
| 当前用户项目 | `xxkingstuggle/zjx-download`，本轮开始 HEAD `0f1245261f429bd6378b43603b2a6f45eb263ef3`，分支 `feat/macos-native-liquid-glass` | https://github.com/xxkingstuggle/zjx-download |

官方元数据用 GitHub API 读取。当前用户项目 `git remote -v` 确认 upstream 指向原桌面项目。读取当前 README 和既有审计只用于确定来源及历史范围，没有把当前 Swift 实现当作原功能证据。

本轮仅 fetch 官方桌面 master 的对象和远程跟踪引用，未切换当前分支，未修改当前 App/扩展源码。扩展按固定 commit 获取文件供分析；未安装扩展或依赖。初始工作区干净，stash 空，只有当前 checkout。

## VS-001：桌面稳定版到固定 master

`git log 08bfd440..e329495b` 仅有 `e329495b add download location to download list table (#1483)`。差异为两个列表界面文件，28 行新增。故“下载位置列”明确属于所选 master 基线的能力，不谎称已包含于 v1.11.1 安装包。其他条目的源码确认以所选 master 为准；本轮不声称已运行稳定安装包验证。

## VS-002：旧审计不能直接复用为事实

旧任务冻结过桌面 `777ac0a9...` 与扩展 `1871203c...`。本次原项目已经新增 JSON 导入导出、CLI、原生消息、认证、DoH、限速模式等，须重新读取当前固定源。旧文档中“没有导出/没有原生消息”等判断不得带入当前规格。

## VS-003：来源与推断边界

- 官方 README 用于确认产品身份和仓库关系，不从宣传语推断详细行为。
- 功能证据优先使用固定 commit 的入口声明、输入检查和实际消费者调用链；具体定位见领域证据文件。
- `[S]` 为源码级确认；`[R]` 为新规格约定；`[U]` 为未确认细节。没有运行证据就不能写“原版实测通过”。
- 未安装或运行原版，未构建现有项目，未操作真实下载数据、账户、生产 App 或 Chrome。
- 此前曾规划严格隔离；该限制已由2026-10-18的用户授权取代。可在理解旧源码和历史的基础上独立重写。

## 公开主来源

- 桌面 README：https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/README.md
- 桌面 CHANGELOG：https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/CHANGELOG.md
- 扩展 README：https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/README.md

许可证身份只作来源登记：原桌面 README/仓库许可证为 Apache-2.0。素材、翻译、第三方库的使用与声明在未来真正选择复用材料时另核，不从本轮功能拆解推断可直接复制所有资产。

## 根审计补充：进程与应用级错误

以下定位均在固定桌面 commit `e329495b6630b18e4b41d7682da33318b0f9ea18`，已通过 `git show` 阅读并核对行号。

| 证据 | 规格 | 固定来源与行 | 可确认事实及限制 |
|---|---|---|---|
| GS-001 | G-015 | [SingleInstanceManager.kt L6-L30](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/utils/singleInstance/SingleInstanceManager.kt#L6-L30) | 同一配置域申请实例锁、提供既有实例服务及唤醒入口；本轮未实际双开，不据此声称系统级绝无竞态 |
| GS-002 | G-016 | [Ui.kt L74-L94](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/ui/Ui.kt#L74-L94)、[L203-L230](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/ui/Ui.kt#L203-L230) | 非静默启动打开主窗；mac图标事件恢复主窗；tray命令和Dock切换源码存在。目标产品无需复刻Dock隐藏的内部机制；真实桌面激活效果未测 |
| GS-003 | G-017 | [GlobalAppExceptionHandler.kt L48-L82](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/utils/GlobalAppExceptionHandler.kt#L48-L82)、[L128-L140](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/utils/GlobalAppExceptionHandler.kt#L128-L140)、[ErrorUi.kt L77-L107](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/ui/error/ErrorUi.kt#L77-L107)、[L141-L160](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/ui/error/ErrorUi.kt#L141-L160) | 异常显示/复制诊断/关闭路径。原版复制堆栈与版本平台；目标脱敏是R，非原版已证明行为 |

## 覆盖检查用的源码目录盘点

固定版本桌面与共享 pages 包含：about、addDownload、batchdownload、category、checksum、confirmexit、credits、downloaderror、editdownload、enterurl、extenallibs、home、newQueue、perhostsettings、poweractionalert、queue、settings、singleDownloadPage、updater。大小写变体合并为相同功能域，不能把目录数量当作功能完成数。

公共 App 设置接口统计为 38 个字段，桌面另加 3 个字段；代理、DNS、逐主机、队列、目录登记等在独立存储中，不能只核对上述 41 字段就声称设置完整。领域文档应按真实界面字段与消费者补齐。
