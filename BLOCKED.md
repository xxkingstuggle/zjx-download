# 阻塞与交付边界

更新于 2026-11-17。

## 当前阻塞

2.0.4/build20261117.2 已构建、签名并安装。主窗口透射、浅色与深色对比度和降低透明度效果待用户按 A-071 验收，功耗未测。

- 2.0.3 的 `Network.NWError 22 — Invalid argument` 来自监听器初始化时重复指定端口。源码已修复，实际监听及 Chrome/CLI 交接待用户按 A-041、A-042 验收。
- A-001…A-071 均待用户测试。本轮未启动新版或 Chrome，未执行功能、UI、下载或性能自测。
- 2.0.2 修复了 `.system` 随主题强制切换深浅色及设置窗口无法完整滚动的问题，验收编号为 A-068…A-070。

以下为上一轮 2.0.1 修复的验收记录：

- 用户报告的空任务启动卡死和巨大开销：相关源码修复已交付2.0.1/build20261018.2；实际启动、性能与功能验收仍**待用户测试**，不能视作已解决验收。
- 主代理没有启动App/Chrome，也没有运行下载、故障/性能或功能测试；A-001…A-067全部待用户测试。
- 本轮已知R-01…R-17均有源码修复，主代理跨模块审核和编译核对完成。见repair-review-20261018.md、5份worker记录；构建成功不证明业务正确。

## 交接与发布待办（2026-11-01）

- 2.0.2 源码提交 `fbc865898e2772b5cb547d312f07c67158b39f93`、安装登记及后续治理文档均已直接推送到正式 `origin/main`。最终以 `git ls-remote` 和 GitHub API 核对，默认 main 包含本次完整收尾，本地干净；无 PR，改动直接进入主线。
- GitHub `gh release list` 显示最新 Release 仍为 `v0.2.2`（2026-09-14），截至核查时没有 2.x Release；本轮未创建 tag 或 Release。`.github/workflows/release.yml` 尚未验证满足当前 SDK/Swift、双架构 CLI、Chrome 和签名交付要求；详见[文档入口](docs/README.md)。本轮未触发 CI、tag 或 Release；后续发布前需独立修订、验证。
- 当前 API 的源码合同已在文档入口明确；根目录 REST-API.yml 仅为上游历史规格，完整现役 OpenAPI 描述尚未建立，不应据旧文件生成当前客户端。

## 已确认的产品边界

- 界面文案提供简体中文；系统语言没有对应翻译时回退简体中文。
- 比例选项映射到 macOS Dynamic Type 档位，按原生文字尺寸行为调整，不缩放整个窗口。
- App 未启用 App Sandbox；目录使用原生选择器和普通路径，不保存 security-scoped bookmark。
- HLS 范围限于规格和原版证据确认的未加密 TS media playlist；DRM、独立音轨及直播录制不属于支持范围。

## 用户报告的崩溃

- 报告：App 2.0.0 (20261018) 在 macOS 27.0.1 启动时触发 `EXC_BREAKPOINT (SIGTRAP)`，栈顶为 `GlobalSpeedModeMonitor.init(coordinator:)`。
- 定位：崩溃地址对应 Swift 生成的 nil 陷阱；前一条指令检查 `NSApp`，为空时跳至陷阱。该初始化在 SwiftUI 构造 App 期间执行，早于 `NSApplication` 建立。
- 修复：活动采样先确认 `NSApp` 已存在；没有时跳过本次，之后由已注册定时器/通知重试。用户需按 A-053 验证。
- 目标更新：build 20261018.1；已安装，签名核验通过。

这些边界已在 [功能落点表](docs/native-rebuild/design-and-coverage.md) 和 [手测表](docs/native-rebuild/manual-test-checklist.md) 中说明。功能落点/构建成功不代表用户验收通过。

## 交付核对

- `/Applications/zjx-download.app` 为 `2.0.4/build20261117.2`，Universal x86_64/arm64，Apple Development / Team ZNSTKHPLY3，已通过严格签名校验。
- Chrome 扩展仍为 2.0.1。此轮在隔离目录构建，未修改日用 Chrome 或 Native Messaging 注册。
- 正式安装包位于 `/Applications/zjx-download.app`，扩展构建产物位于 `browser-extension/dist/chrome/`。
- 本轮只替换 App 包，没有访问、修改或迁移任务、设置、凭据及下载文件。安装 icns SHA-256 与旧包一致；更早的数据哈希记录只代表当时安装，不作为本次数据检查。

## 历史记录

- 本轮早期记录过更新器未自动替换/未验签；已按当前代码复核并更正：更新器核对 HTTPS、SHA-256、签名团队、产品身份、版本和架构，替换前保留回滚副本。
- 本轮曾在增量构建产物中发现旧框架残留及错误的绝对加载路径；该包未安装，改用独立 DerivedData 重新构建，最终安装包只含 `ZJXDownloadCore.framework`，由 `@rpath` 加载。
- 旧交付的历史验收缺口仍可从 `docs/native-completeness-audit/` 查询；旧测试结果不代表本轮实现通过。
