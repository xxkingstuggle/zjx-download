# zjx-download 项目规则

## 开始与续跑

- 先读 `PROGRESS.md` 的最新交付记录，再核对实际 Git、安装包和阻塞状态；历史记录不能当作当前验收。
- 本机开发前读 `~/.codex/skills/machine-development-policy/SKILL.md`，并读取唯一机器政策 `~/.config/agent-governance/DEVELOPMENT_POLICY.md` 和 `MACHINE_STATE.md`。
- 正式源码在 `/Users/zjx/Developer/repos/zjx-download`；分支使用 `zjx/` 前缀。发布物放 `~/Developer/releases/zjx-download/<版本>/`；构建/诊断放 `~/Developer/scratch/codex/<任务>/`。

## 项目与边界

- macOS 26+ 原生下载器及 Chrome MV3 扩展；SwiftUI/AppKit、Swift 6.2+、Apple 网络 API；Chrome 使用原生 JavaScript ES 模块。
- App、Chrome、CLI通过同一核心和任务状态工作。名称/可执行文件/scheme为 `zjx-download`，Bundle ID为 `com.zjx.download`，图标原字节与署名许可保留。
- App：`Sources/ZJXDownloadApp`；核心：`Sources/ZJXDownloadCore`；CLI/Native Host/网络shim分别在同名目录；扩展：`browser-extension/src`。
- 当前设计/落点在 `docs/native-rebuild/design-and-coverage.md`，修复审核在 `repair-review-20261018.md`，用户验收在 `manual-test-checklist.md`。
- `docs/clean-room-rebuild/`、`docs/reverse-analysis-evidence/`是保留的原始规格/证据，不改写；其中旧阶段“不开发/不替换/不安装/必须全功能自测”限制已由用户后续任务书覆盖。

## 数据与执行

- 不清空、删除或自动迁移现用任务、设置、队列、分类、凭据、目录授权及下载文件；兼容/迁移操作由用户在手测环境确认。
- 本任务禁止执行者进行功能/UI/真实下载/故障/性能自测；不跑 `swift test`、`npm test`，不为验收启动App或操作日用Chrome。
- 必须实际构建；编译、签名、身份/图标与产物核对不等于功能验收。手测状态只能根据用户结果更新。
- 安装目标仅 `/Applications/zjx-download.app`；替换前保留旧包，并确认App/Host安全退出，不强杀写入进程。构建失败或包不完整不得覆盖。
- Chrome只使用本项目专属Native Messaging注册；不改其他App、全局工具链、PATH或常驻服务。

## 构建入口

```sh
xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
swift build -c release --product zjx-download-cli
npm --prefix browser-extension run build:chrome
```

发布构建使用新的独立DerivedData路径、arm64+x86_64双架构，并检查包内只含当前核心框架。签名后核对App及ZIP解压包。

## Git与收尾

- 保留继承改动，先审差异与secret；不提交缓存、构建包、日用数据、凭据或 `.agent-work/`。
- 用户于2026-10-19授权本轮提交并推送GitHub；同步 `origin` 的任务分支，不向 `upstream` 推送，不force push，不默认合并main/发Release。
- 未获新授权不扩大Git发布范围。后续重要提交按用户授权和机器政策同步，禁止把未提交/未推送说成已备份。
- 有活动子代理时等待完成并审交付；用户明确暂停则记录断点并停工。
- 更新README、PROGRESS、BLOCKED及受影响说明；保留历史和待用户测试状态。安装变更登记 `INSTALL_LEDGER.md`。
- 构建缓存与诊断现场先列清单，未获明确清理授权不删除；归档、发布包和用户数据不作缓存处理。
