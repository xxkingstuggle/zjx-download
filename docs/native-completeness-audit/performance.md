# 性能证据与验证计划

## 2026-10-04 当前验证覆盖

RC2隔离verifier的256MiB、8-range任务已实测暂停、退出进程、用相同隔离state重启、继续并完成。最终文件SHA与fixture一致；证据和运行环境见 `evidence/run/recovery-paused-before-restart-20261004.json`、`recovery-range-fixture-20261004.log` 及 `chrome-download-closeout-20261004.md`。RC3另以慢速128MiB fixture在UI取消任务，状态为`cancelled`；未采活动下载期间CPU/磁盘曲线。

性能目标按用户最新要求作为优化目标，不通过降低阈值宣称达标。可复用的10k数据显示footprint约251.4MiB，高于200MiB目标；10k实际搜索P95本轮未复测。详情见下方历史采样记录。

## 2026-10-03 配对吞吐复测（23:32 CST）

用初始提交 `b08780522b955c28a851ec628123e29946caf30e` 的归档源码与当前 Release 代码，在同一台 Apple Silicon Mac 上交替进行5轮；每轮每档连接数各含5个4MiB loopback 样本，每档共25个。引擎结果文件 SHA 全部为 `59f41f46fe52079f24edc303087a25634c91bee7491b53d99695c39c4d934696`。P95按 nearest-rank 算法取25个样本的第24个。

| 连接数 | 基线 median / P95 / 范围 MiB/s | 当前 median / P95 / 范围 MiB/s | median变化 |
|---:|---:|---:|---:|
| 1 | 112.38 / 133.96 / 65.16–137.33 | 112.18 / 140.65 / 64.38–148.82 | -0.18% |
| 4 | 112.46 / 142.48 / 111.73–154.15 | 112.32 / 136.04 / 111.35–138.24 | -0.12% |
| 8 | 112.39 / 142.38 / 111.47–146.01 | 116.35 / 153.45 / 111.70–153.49 | +3.52% |

三档的聚合中位数均未出现超过5%的下降，满足任务书中的候选吞吐目标。该结果只适用于本机 loopback fixture；分轮数据可见波动，不能代表真实网络或磁盘负载。URLSession临时文件速度 median 为基线926.26、当前806.27 MiB/s，但它只计到文件生成，引擎计时还包含 HEAD 探测、状态/分片IO和合并，不作直接性能比较。原始测试日志和口径见 [配对对照证据](evidence/run/throughput-paired-comparison-20261003.md) 及10个 `throughput-paired-*.log`。

此前仅测候选版本的单轮结果保留作原始记录，不再作为与旧代码的吞吐比较结论。

## 2026-10-03 RC2早先单版本实测记录

性能门槛仍是候选目标，没有被用户确认成硬条件。测试样本的采样方式、任务数、窗口和工具调用必须与数字一起解释。

| 场景 | 二进制/任务 | 结果 | 口径和限制 |
|---|---|---|---|
| Release 空闲 UI（更新错误本地化续做） | verifier `com.zjx.download.verify.updaterLocalized20261003`，SHA `208e04a497ab799946e365be22ae2c33d0f96cd9d69b9ab16bee5f86803e3c77`；主窗下载页可见、0 tasks、无活动下载；PID 9022 | `top -l 90 -s 1 -pid 9022 -stats pid,cpu,mem,threads` 在约97秒窗里记录85行进程样本；CPU median 0.1%、nearest-rank P95 0.1%、min 0%、max 0.2%；top MEM 84–91M。窗后 `ps` RSS 99,152 KiB（96.8 MiB）；`vmmap -summary` physical footprint 84.3 MiB、peak 139.7 MiB | 采样期间没有 CUA/AX、输入、滚动或下载。窗口可见但列表为空，测量在之前的一次 AX Settings 操作后开始；peak 可能含启动/设置页面开销。`top` 请求90轮但只有85行匹配进程，统计按85行报告。不能外推到10k任务。原始证据：`evidence/performance/top-idle-updater-localized-empty-20261003.log`、`ps-idle-updater-localized-empty-20261003.log`、`vmmap-idle-updater-localized-empty-20261003.log` |
| Release 空闲 UI（当前选择恢复修复 build3） | bundle `com.zjx.download.lunaaudit.selectionrestore3`；binary SHA-256 `747b35c7b1b3a56d78686a76f50495632f248eacf9f4ca8d5f73dd20ecf37103`；主窗可见，17 tasks，0 active；PID 36345 | `top -l 90 -s 1 -pid 36345 -stats pid,cpu,mem,threads`：CPU 中位数 0.1%、nearest-rank P95 0.1%、min 0%、max 0.9%；top MEM 90个样本均显示104MiB。`sample`当前physical footprint 103.6MiB、peak 168.2MiB；`ps`单次RSS在采样结束后先后读到124,320KiB、74,688KiB（约121.4MiB、73.0MiB），二者是不同时间点 | 90秒窗口未调用 CUA/AX；同一进程此前做过17行AX操作，因此 footprint peak 可能含此前事件。本轮执行90秒期间没有下载、搜索、滚动或输入；CPU符合候选空闲值。证据：`top-idle-17tasks-selection-restore3-20261003.log`、`ps-idle-17tasks-selection-restore3-20261003.txt`（最后一次ps）、`sample-idle-17tasks-selection-restore3-20261003.txt`、`vmmap-idle-17tasks-selection-restore3-20261003.txt` |
| Release 空闲 10k 模型（前一版 build2） | bundle `com.zjx.download.lunaaudit.menucomplete2`；同机 build2；10,000任务；重启后不调用 CUA/AX；PID 30709 | 90个 top 样本 CPU 中位数/P95 0.2%/0.2%，min0%、max0.4%；top MEM 约92–104MiB；`ps` RSS 111,312KiB（108.7MiB）；物理footprint约91.7MiB，peak约127.9MiB | 这是选择回归补丁前的 build2，不能单独代替 build3 10k验证。证据 `top-idle-10000-fresh-noax-current-build2-20261003.log`、`ps-idle-10000-nstable-fresh-noax.txt`、`vmmap-10000-fresh-noax-current-build2-20261003.txt` |
| 10k全AX树工具成本观察 | build3，PID 35042；10,000任务；调用 CUA 后 | 操作树读取约120秒无返回，随后截图等待超时；`top` CPU 从0升至80–99%单核、MEM约245MiB；`sample` 当前 footprint245.5MiB、peak278.5MiB | 原始栈有 `_AXXMIGCopyAttributeValue`、`NSTableViewCellMockElement.accessibilityChildrenAttribute`、`NSTableView.viewAtColumn:row:makeIfNecessary`，并在全量AX请求期间创建约400个可见 cell view。此数据是全量 macOS AX 工具枚举造成的调用负载，不能当正常无AX空闲。也不能忽略：当前任务仍需真实 VoiceOver/辅助技术与大量数据的验收。证据 `top-cua-ax-stall-build3-20261003.log`、`sample-cua-ax-stall-build3-20261003.txt`、`vmmap-cua-ax-stall-build3-20261003.txt` |
| Release 10k UI（localized updater build，AX超时后的稳定窗口） | bundle `com.zjx.download.verify.tenk20261003`，SHA `afc9a0a881f584ef01c6219de64ce14bf8225e7a7866d10c92a95de3dd2866fd`；10,000条合成任务；PID 16793 | 前一次完整AX读取超时后，没有继续调用AX；`top -l 90 -s 1 -pid 16793 -stats pid,cpu,mem,threads`得到90行样本，CPU中位数0.1%、nearest-rank P95 0.2%、min0%、max0.2%，top MEM各样本251M。窗口结束`ps` RSS 69,184KiB（67.6MiB）；`vmmap -summary` physical footprint/peak均251.4MiB | 这是AX超时之后的90秒无工具访问窗口，不是新启动的冷基线。CPU候选空闲目标通过；RSS候选200MiB通过，但footprint/top MEM仍约251MiB，且在先前AX高负载后采样，不能据此宣布10k内存目标整体通过。90样本、ps和vmmap原始日志分别为 `evidence/performance/top-idle-current-10000-stable-after-ax-20261003.log`、`ps-idle-current-10000-stable-after-ax-20261003.log`、`vmmap-idle-current-10000-stable-after-ax-20261003.log` |
| RC2 Release 单任务空闲 | verifier `com.zjx.download.verify.rc2_20261003`，binary SHA `b564d8ee9e77b3beb88d40c719d016fa9bfa5985c0d587f7169ee763386c4887`；主窗口可见，1条完成的合成下载；PID 23230 | `top -l 90 -s 1 -pid 23230 -stats pid,cpu,mem,threads` 得到90条进程样本：CPU median 0.2%、nearest-rank P95 0.2%、min 0%、max 2.0%；top MEM median/min/max均126M。随后 `ps` RSS 172,144KiB（168.1MiB）；`vmmap -summary` physical footprint 126.1MiB、peak 180.2MiB | 采样约99秒，窗口可见，无CUA/AX调用、输入或下载；此前做过主题/API key/主机认证/校验和操作。CPU候选空闲值通过；该单任务样本的RSS与footprint候选200MiB均在限内，但不是10k冷基线，也不代表10分钟趋势。原始文件：`evidence/performance/top-idle-rc2-one-task-20261003.log`、`ps-idle-rc2-one-task-20261003.log`、`vmmap-idle-rc2-one-task-20261003.log` |
| RC2 单任务约11分钟进程趋势 | 同一 verifier/PID 23230；主窗可见，1条完成fixture任务；`top`日志时间23:03:22–23:14:18 | `top -l 600 -s 1`采得600个PID行：CPU median 0.3%、nearest-rank P95 0.4%、min0%、max40.1%；top MEM median128M、范围126–131M。`ps`结束后RSS 95,008KiB（92.8MiB）；`vmmap` footprint130.8MiB、peak180.2MiB | 该窗口无活动下载，但中间操作过一项设置语言并保存，且期间有小规模CUA/AX设置树读取；故属稳定趋势窗口而非纯idle。>2%共17样本，最大值不做归因；中位/P95和内存没有持续上涨迹象，但单任务结果不外推至10k。原始文件 `evidence/performance/top-trend-rc2-one-task-20261003.log`、`ps-trend-rc2-one-task-20261003.log`、`vmmap-trend-rc2-one-task-20261003.log` |
| Release引擎吞吐（初次候选单版本测量，已由配对复测补充） | Release XCTest `IntegrationTests/testReleaseRangeThroughputOneFourEightConnectionsAgainstURLSession`；4MiB loopback fixture | 初次单版本结果保留：engine 1/4/8连接 median112.09/117.67/112.08 MiB/s；URLSession median811.65 MiB/s。 | 初次测量没有旧代码对照，不能单独判断回归；以文档开头2026-10-03配对测试表为当前结论。URLSession计时只覆盖文件下载，engine还包括HEAD探测、状态/part IO与合并，不直接比较 |

截至22:35的旧断点记录保留；2026-10-03 23:32的配对测试已补齐旧代码同机吞吐基线，但10k多轮搜索响应/滚动、暂停/恢复、进程重启恢复和冷启动仍未完成。RC2约11分钟CPU/RSS/footprint趋势含设置交互，不能替代纯idle或10k长稳态结果。

## 实测环境

- 时间：2026-10-02（Asia/Shanghai）。Mac16,12 / arm64，macOS 27.0.1 (26A434)，16 GiB RAM；Swift 6.4.0，Xcode 27.0 (27A266a)，macOS 27 SDK。
- 本地提交：`b08780522b955c28a851ec628123e29946caf30e`。本轮没有业务源码修改。
- app、DerivedData、隔离 state、probe 和上游源码抽取位于 ignored 临时目录 `.build/native-completeness-audit/perf-run-20261002-01/`，不进入 git diff；主 app `.app` 没有复制到 `/Applications`。小体积原始日志与 75 个已取用上游文件的 SHA-256 清单已保存到本目录的 [evidence/](evidence/README.md)。

## 当前证据

| 测量 | 实际结果 | 解释边界 |
|---|---|---|
| `swift test` | 58 tests，0 failures，5.093 s；原始输出见 [swift-test.log](evidence/swift-test.log) | Core/unit/integration 测试；不是 SwiftUI 交互、浏览器扩展或性能通过 |
| SwiftPM Release | `swift build -c release` 成功；首次非增量构建约 19.32 s，本轮热缓存复跑 5.86 s，输出见 [swift-build-release.log](evidence/swift-build-release.log) | 产物是 command executable，不是可直接启动的完整 app bundle |
| Xcode Release app | `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -derivedDataPath .build/native-completeness-audit/perf-run-20261002-01/DerivedData build` → `** BUILD SUCCEEDED **`；输出见 [xcodebuild-release.log](evidence/xcodebuild-release.log) | 只在 `.build` 创建、adhoc 签名和 LaunchServices 注册，未安装到 `/Applications` |
| SwiftPM 可执行文件启动 | 失败：`bundleProxyForCurrentProcess is nil: mainBundle.bundleURL file://.build/release/`，栈经过 `UNUserNotificationCenter.current()` / `AppDelegate` | 这个入口没有 macOS app bundle context；真实 app 验收改用 Xcode `.app` |
| Xcode `.app` 启动 | 成功；空隔离 state 下在 `127.0.0.1:25251` 监听；`POST /ping` → 200 `pong`，`GET /queues` → 200 `[Default]`；非法路由 → 404 | 证明本地服务可从真实 app 进程启动；不是完整 extension/API 权限兼容验收 |
| 隔离 | `ABDM_STATE_DIRECTORY` 与 `ABDM_INTEGRATION_PORT` 指向 `.build/.../state`、25251；state JSON 有 1 个默认队列、0 tasks/categories/history；下载目录位于 `.build/.../downloads` | 本轮没有触碰用户的应用支持数据或下载目录；测试端口仅绑定 loopback |
| 可见窗口 | CoreGraphics 只读窗口元数据：app PID 的可见窗口 title “下载”，1100×720；窗口清单只看到主窗口 | 未截图、未点击通知权限、未检查菜单栏图标是否实际可见；菜单栏行为只有源代码证据 |

`swift test`、构建与 REST 原始输出保存在 [evidence/](evidence/README.md)。隔离 app/probe 源码、state 和二进制仍在 ignored `.build` 临时目录。

### 空闲状态真实 app 采样

测量对象为 Xcode Release `.app` 的 PID `97422`，没有下载任务和类别，主窗口可见。应用运行约 3 分钟后，用 `top -l 20 -s 1 -pid 97422 -stats pid,cpu,mem,threads` 连取 20 个一秒间隔样本。`%CPU` 是 top 给出的进程区间值，按单个 CPU 核心的百分比理解。

| 指标 | 结果 |
|---|---:|
| CPU 中位数 | 5.85% 单核 |
| CPU P95 | 6.8% 单核（nearest-rank，20 个样本） |
| CPU 最小/最大 | 0% / 7.0% 单核；第一个样本为 0% |
| `top` MEM 中位/最大 | 39 MiB / 39 MiB |
| `sample PID 97422 5 1` footprint | physical footprint 39.5 MiB，峰值 63.7 MiB |
| `ps -p 97422 -o pid=,etime=,%cpu=,rss=,state=,command=` 单时点 | RSS 101,680 KiB（约 99.3 MiB）；累计 CPU 2.5% |

`top` MEM、`sample` physical footprint 和 `ps` RSS 是不同内存口径，不互相替代。`ps` 的 CPU 是进程自启动以来的累计平均，与 `top` 一秒区间值不比较。原始文件：[top-warm-idle.log](evidence/top-warm-idle.log)、[sample-cpu.txt](evidence/sample-cpu.txt)。app 主线程的 sample call graph 出现 AppKit/SwiftUI layout 栈；这只说明采样时栈位置，不证明布局是 CPU 热点根因。应在下一阶段用 Instruments Time Profiler / SwiftUI 和 Core Animation instrument 追因。

采样时宿主机内存压力偏高：top 显示约 15 GiB used、6.2 GiB compressor、157 MiB unused。20 秒空闲采样是这台机器的观测值，不是干净系统或其他型号 Mac 的通用基线。应用稳定占用约 6% 单核，值得优先排查；暂不能把它归因于 500 ms 刷新、通知或视图布局中的任一项。

### 列表数据变换微基准

`.build/.../ListSortProbe.swift` 用本地真实 `DownloadTask`，测量与 `AppModel.visibleTasks` 同构的纯 Swift 表达式：过滤 `.cancelled` 后按 `createdAt` 降序。90% 记录可见；每种规模先预热，再量 201 次。数据预建、SwiftUI diff/render、搜索谓词、JSON 读写、状态发布、动画和输入延迟均不在计时范围内。

| Release build | 100 条 | 1,000 条 | 10,000 条 |
|---|---:|---:|---:|
| 中位数 | 0.038 ms | 0.253 ms | 2.106 ms |
| P95 | 0.042 ms | 0.331 ms | 2.202 ms |

| Debug build | 100 条 | 1,000 条 | 10,000 条 |
|---|---:|---:|---:|
| 中位数 | 0.067 ms | 0.408 ms | 4.018 ms |
| P95 | 0.075 ms | 0.540 ms | 4.135 ms |

Raw output 为 [list-sort-debug.log](evidence/list-sort-debug.log) 和 [list-sort-release.log](evidence/list-sort-release.log)；探针源码在 ignored `.build/native-completeness-audit/perf-run-20261002-01/ListSortProbe.swift`。这是微基准，不能替代列表滚动、键入搜索、选择或 macOS UI 性能测量。

## 截至 2026-10-03 的性能缺项快照（部分由上文10-04更新）

- 没有 1,000/10,000 行真实首屏与滚动帧率、5轮输入到筛选结果时延、10k键盘多选/全量VoiceOver读取性能；一次10k完整AX树读取超时。
- Release Core engine 的1/4/8连接旧代码对照已完成：当前5轮配对测量的聚合中位数变化为-0.18%/-0.12%/+3.52%，候选≤5%吞吐目标通过本机fixture。仍没有活动下载磁盘/CPU曲线或队列持续吞吐实测。暂停/退出/重启/恢复已于2026-10-04补验；11分钟单任务趋势包含设置交互，未作为严格idle达标证据。
- 没有冷启动时长或节能活动监视器证据。当前RC2主窗/中英文设置有真实截图，但最小窗口、暗色/System完整路径仍需验；10k AX工具全树读取不能证明VoiceOver可用。
- 本轮没有启动或操作Chrome；REST探针与Chrome包构建不代表Chrome连通。未用Instruments确认CPU峰值或10k footprint根因。

## 实施后的建议门槛

这些是候选验收目标，不是当前数据，也不是上游官方数字或已获用户确认的承诺。所有 UI 指标在同一 Mac、Release build、相同数据集与窗口尺寸下至少运行 5 轮，报告中位数/P95、样本分布、宿主机 load 和 Instruments trace。

1. 空闲下载列表、主窗口可见、无任务/无扩展请求，稳定 90 秒后 CPU 中位数 ≤1% 单核、P95 ≤2%；记录 physical footprint 和 RSS 两种数值。
2. 冷启动到可输入下载地址 P95 ≤2 秒；收到下载进度时输入/滚动无肉眼停顿。首次启动权限弹窗单独计时和说明。
3. 1k 与 10k 行虚拟化数据集：列表首次可用、排序、过滤和搜索 P95 ≤100 ms；连续 60 秒滚动丢帧情况用 Core Animation Instruments 记录，不以微基准代替。
4. 在 10k 任务下增量刷新不重建全表；持续 10 分钟 idle/任务更新，RSS 与 footprint 不持续线性增长。候选 RSS 上限为 200 MiB，须注明进程、idle 或 10k 数据集、窗口状态和采样方法；当前 idle `ps` RSS 约 99.3 MiB，仅作同机参考。一个任务的进度 UI 发布最多约 4 次/秒；磁盘状态提交合并进度，只在断点/状态转换保证可恢复，崩溃恢复测试不得丢最后一次保证点。
5. 本地可控 range fixture 分别测试 1/4/8 connections、暂停/恢复及无 Range 回退，记录 app payload throughput、峰值 CPU、磁盘写入和直接 `URLSession` 基线。候选门槛是同机同 fixture 下，Release throughput 相对本轮当前代码实测基线不下降超过 5%；2026-10-03配对样本已补齐起始提交对照，暂停/恢复和活动下载曲线仍需另测。网络服务应在本机 fixture，避免互联网随机性。

## 复测命令与步骤

```sh
swift test
swift build -c release
xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -derivedDataPath .build/native-completeness-audit/perf-run-20261002-01/DerivedData build
ABDM_STATE_DIRECTORY="$PWD/.build/native-completeness-audit/perf-run-20261002-01/state" ABDM_INTEGRATION_PORT=25251 .build/native-completeness-audit/perf-run-20261002-01/DerivedData/Build/Products/Release/zjx-download.app/Contents/MacOS/zjx-download
top -l 20 -s 1 -pid <app-pid> -stats pid,cpu,mem,threads
sample <app-pid> 5 1
```

本轮真实 app 运行时实际执行了 `curl --max-time 4 -sS -i -X POST http://127.0.0.1:25251/ping`、`curl --max-time 4 -sS -i http://127.0.0.1:25251/queues` 和 `curl --max-time 4 -sS -i http://127.0.0.1:25251/no-such-route`；响应依次为 200、200、404。原始输出见 [rest-live-probe.log](evidence/rest-live-probe.log)。测试前生成隔离 state/downloads 并确认 `lsof -nP -iTCP:25251 -sTCP:LISTEN` 属于本次 app；测试结束退出 app，确认端口关闭。UI 性能必须另用 AX/真实界面脚本或手动验收，保存截图和 Instruments 原始 trace。
