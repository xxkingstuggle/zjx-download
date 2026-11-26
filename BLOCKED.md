# 阻塞与交付边界

更新于 2026-11-25（分支 `zjx/hackathon-polish`，未覆盖 `/Applications/zjx-download.app`）。

## 当前阻塞

`/Applications/zjx-download.app` 现役安装仍为 `2.0.4/build20261117.2`（本轮未替换、未触碰日用 `Application Support` 与钥匙串）。`zjx/hackathon-polish` 分支已完成静态重构、单测补齐及隔离沙箱真机动态验收，但尚未合入 `main`、未做 Universal Release 签名安装。

### 2026-11-25 Round 3 隔离沙箱动态验收已闭合项（分支 `zjx/hackathon-polish`）

- **A-053 / A-054（冷启、空闲功耗与服务生命周期）**：通过 `open -n -F -g --env CFFIXED_USER_HOME=<sandbox>` 启动隔离 Debug 版 `zjx-download.app`，主窗口正常挂载上屏（`layer=0`, `1249×923`），`~/Library/Logs/DiagnosticReports` 新增 0 崩溃；0 任务静置 10 秒（5 次 × 2 秒 `ps` 采样）实测**平均 CPU `0.00%`（峰值 `0.0%`）、平均 RSS `136.7 MB`（`136.6–136.9 MB`）**；`PUT /settings/extension` 热更新配置前后 `lsof` 监听句柄完全不变（`FD 5u`、`DEVICE 0xd5eadd34347d394`）；`zjx-download-cli gui exit` 正常退出。
- **A-041（仅回环监听与鉴权热更新 — 后端与 CLI 层）**：实测仅绑定 `127.0.0.1:15199`（无 `*:port` 或 IPv6 暴露）；单测 `testIntegrationServerHotReloadAuthAndStatusTasksEndpoints` 实测开启 `apiRequiresKey` 与轮换 API Key 时 `lsof` 监听 socket FD/DEVICE 及 `activeListenerGeneration` 全程不变，无密钥 / 旧密钥立即 `401`、新密钥立即 `200 pong`。
- **A-008 / A-013 / A-044 / A-055（CLI 驱动分片续传、无 Range 回退与零残留）**：实测 6 MiB 4 连接分片下载中途暂停（`range-parts-1/` 存在且已提交断点 `524,288 B`）→ 恢复完成 → SHA-256 100% 匹配 → **`range-parts-1/` 与 `staging/` 残留为 0**；1 MiB 无 Range 源自动单连接回退完成且 SHA-256 匹配。
- **A-030 / A-031（HLS 点播合并与直播拒收）**：UTF-8 BOM + 3 片 TS 点播清单合并完成且 SHA-256 匹配，`hls-3/` 零残留；无 `#EXT-X-ENDLIST` 直播清单明确失败拒收，不挂起。
- **自动化与扩展渲染门禁**：`swift test` 22/22 通过（`0.465s`）；`node --test browser-extension/tests/extension-logic.test.mjs` 5/5 通过（`53.7ms`）；`node browser-extension/scripts/build-chrome.mjs` 构建完整；无头 Chrome CDP（本地回环静态服务 + MV3 `chrome.*` 测试桩 + 模拟本地 API）验证 `popup.html`（含活跃任务卡片）与 `options.html` 深浅色令牌切换正常，0 未捕获异常、0 `console.error`、0 资源缺失。

### 仍待用户实机 / 正式发版验收项（未虚报）

- **Chrome 真实扩展加载与手点交互（A-036…A-040、A-042、A-043、A-052、A-060）**：新版品牌 Chrome 命令行默认屏蔽 `--load-extension`，本次未在日用 Chrome 手动加载扩展点按浮窗、自动接管、Native Messaging 唤起与快捷键。
- **macOS 视觉观感与人机交互（A-002…A-007、A-012、A-014…A-029、A-032…A-035、A-045…A-051、A-068…A-071）**：Liquid Glass 透射、深浅色主观对比度、「降低透明度」系统切换、跨完全重启恢复（A-007）、真实钥匙串设置页交互及正式签名包替换后回归，均待合入并做 Universal Release 安装后由用户实机验收。

以下为 2026-11-17 2.0.4 安装时记录：

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
