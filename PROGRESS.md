# 当前交付进度

Git交付入口：用户独立私有仓库 `https://github.com/xxkingstuggle/zjx-download`，默认正式分支 `main`。2026-10-19用户澄清不能只交工作分支；下方早期“只同步任务分支、不改main”为当时处理记录，由本次指令更新。

## 2.0.3 主窗口外观交付（2026-11-17，Asia/Shanghai）

- 已安装 **2.0.3/build20261117.1**。主窗口使用系统窗后透射材质、原生玻璃操作区和独立任务表区。启用「降低透明度」后使用实色窗底。设计见[功能落点](docs/native-rebuild/design-and-coverage.md)。
- Xcode 27 / macOS 27 SDK 下，独立 DerivedData 的 Universal Release 构建完成，最低系统仍为 macOS 26。SwiftPM CLI 两种架构以及 Chrome MV3 2.0.1 隔离构建均成功。构建日志保留 AppIntents 元数据提取跳过的提示。
- App、Native Host、核心框架与 CLI 均为 arm64/x86_64。App 包内仅当前核心框架。App、解包 ZIP 与已安装包通过严格签名检查。签名团队、产品标识和原图标与旧包一致。
- 旧版正常退出并归档后替换 `/Applications/zjx-download.app`。产物位于 `/Users/zjx/Developer/releases/zjx-download/2.0.3/`，构建现场位于 `/Users/zjx/Developer/scratch/codex/zjx-download-glass-20261117/`。详见[安装登记](INSTALL_LEDGER.md)。
- A-001…A-071 待用户验收。此轮未启动新版，未测实际透射、功能和功耗。旧版退出时仍显示 `Network.NWError 22`，见 [BLOCKED.md](BLOCKED.md)。

## 项目知识收尾（2026-11-01，Asia/Shanghai）

本次 Git 收尾纳入 2.0.2 界面/外观与空列表实现、对应 A-068…A-070 验收材料和治理文档修订。现役与历史导航统一到 `docs/README.md`，未改写 clean-room/reverse-analysis 原始规格和证据。

| 事实面 | 状态 | 本轮证据与边界 |
| --- | --- | --- |
| 代码 | verified-current | 当前源码 App 2.0.2、Chrome 2.0.1；核对共享核心、构建入口、桥接路由与回执。编译结果见下；不构成功能验收。 |
| 运行态 | pending | 安装 App 2.0.2/build20261023.1，Universal、严格签名通过；主程序/Host/图标与发布包逐字节一致，ZIP 解压签名通过、发布 SHA256SUMS 全通过。Native Messaging manifest 指向本项目 Host 且仅允许配套扩展。没有启动/请求运行态；NWError 22、Chrome 交接和 A-001…A-070 仍待用户测试。 |
| 文档 | changed-and-verified | 修正 README 的远端/本地分界、贡献与反馈入口、上游捐赠归属；旧审计加历史标识，旧 API 规格标为历史。35 个现役文档本地链接存在性通过；扩大检查后将旧矩阵的 5 个已移除源码链接改为明确历史引用，剩余 44 个本地链接均存在，手测与回填各 70 项。 |
| 规则 | changed-and-verified | 修正修复/手测文件相对路径；2026-11-02 按用户要求移除已退役的全机政策依赖，项目约定、协作配置及执行禁令其余内容保留。 |
| 记忆 | out-of-scope | Codex 生成记忆只读（generated-read-only）；未写任何平台记忆。 |
| 工作区 | changed-and-verified | 单一 worktree、无 stash；2.0.2 代码提交 `fbc865898e2772b5cb547d312f07c67158b39f93` 与收尾文档均在 `origin/main`，跟踪工作区干净。旧分支和必要诊断现场保留。 |

- 本轮实际构建：全新 scratch/DerivedData 下 Xcode Release `ARCHS=arm64 x86_64`、`ONLY_ACTIVE_ARCH=NO`、`CODE_SIGNING_ALLOWED=NO` 返回 0 / BUILD SUCCEEDED；App 主程序为双架构，包内仅 ZJXDownloadCore.framework。SwiftPM `--product zjx-download-cli` 分别以 arm64、x86_64 和独立 scratch 构建，均返回 0 / Build complete；Chrome build:chrome 返回 0。新构建未签名、未安装；已安装包及发布 ZIP 的签名核对独立完成。未运行功能/UI/下载/故障/性能测试、swift test 或 npm test。构建保留 warning：AppIntents 元数据提取因无 AppIntents.framework 依赖被跳过（两个架构各一次）；未因此改源码或构建配置。
- Git/远端：2.0.2 源码提交 `fbc865898e2772b5cb547d312f07c67158b39f93`（`feat: deliver macOS 2.0.2 interface improvements`）和后续收尾文档均直接推送至 `origin/main`。最终 `git ls-remote` 与 GitHub API 核对远端默认 main 已包含当前收尾；`gh pr list --state all` 为空，改动直接进入默认主线，无 PR。未写 upstream。
- 发布终态：已安装在本机（见安装登记）；没有创建 tag/Release。GitHub 最新 Release 为 `v0.2.2`（2026-09-14），当前版本 2.0.2 尚无对应 Release。CI workflow 未运行，功能、App UI、Chrome 接口和下载仍未 runtime 验收。
- 安全：机械枚举 134 个 tracked 文件（其中 48 个 Markdown）及工作区文档；tracked 私钥、GitHub token、AWS key 特征扫描未命中。这是有限模式检查，不证明不存在所有 secret。
- 发布流程 warning：现存 macos-14/latest-stable、ad-hoc 签名 workflow 没有当前完整交付验证；本次不触发或重写发布流程。完整现役 OpenAPI 文件尚缺，已明确指向源码合同，避免沿用旧 plain OK 回执。
- 清理结果：删除本轮新建 scratch 中可重建的 Xcode DerivedData（267.9 MiB）、ZIP 解包核验副本（17.4 MiB）及 SwiftPM arm64/x86_64 scratch build 缓存（92.2/98.7 MiB），共约 476.2 MiB；保留 App/CLI/Chrome build 输出、校验日志（scratch 余 335,110 bytes）。
- 保留候选：`.build/` 约 21 MiB 含历史隔离/性能验收资料及合成下载样本；`.agent-work/` 约 137 MiB 含历史/会话材料；`browser-extension/dist/` 约 1.6 MiB 是当前手测加载路径的生成包；旧 scratch 中 status/hotfix/repair/ui 约 27 MiB 含唯一诊断日志。以上均保留。旧源码/App/发布物为恢复资产；旧分支仍未逐提交等价审计，均未删除。
- 本次被明确授权的清理已完成；以上历史现场继续保留。当前构建与校验日志在 `/Users/zjx/Developer/scratch/codex/zjx-download-neat-20261101/`。没有访问或迁移日用任务、设置、Keychain 和下载内容。

## 界面与外观交付（2026-10-23）

- 用户反馈：设置界面混乱、内容裁切，外观不跟随系统；截图底部仍有 `Network.NWError 22 — Invalid argument`。
- 确认源码问题：`.system` 按主题名强制成深/浅色；720×620 固定设置页中大量未分组 Form 没有可用的滚动布局。修复为继承系统外观、强调色独立，并统一主窗口齿轮与菜单的原生 Settings 入口。
- Luna 负责 SettingsViews：侧栏分为常规、下载、网络、集成、浏览器、旧数据、更新；可调整窗口尺寸，各页使用 grouped Form；声音路径和按钮分行。主代理审核确认原 43 个应用设置绑定、8 个浏览器绑定及数组绑定均保留，凭据、导入、更新和逐主机实现保持。
- 主代理补齐：空任务列表/无匹配搜索提示、清除搜索不重置分类/队列；关于页使用同一外观偏好；版本更新为 2.0.2/build20261023.1。
- 实际核对：全新 DerivedData 下 Xcode Release Universal `BUILD SUCCEEDED`；CLI arm64、x86_64 均 exit 0 并合并；Chrome 构建 exit 0（仍 2.0.1，无源码变更）。未运行 swift test/npm test、App/UI/下载/性能或浏览器测试。
- 产物：`/Users/zjx/Developer/releases/zjx-download/2.0.2-ui-20261023/`；App/Host/Core/CLI 均 Universal，包内仅当前 ZJXDownloadCore.framework，Apple Development / Team ZNSTKHPLY3，严格签名核验通过，原图标 SHA-256 保持。
- 安装：确认 App/Host/CLI 均无运行进程后替换 `/Applications/zjx-download.app`，未启动。原 2.0.1 完整保留于 `/Users/zjx/Developer/releases/zjx-download/archive/20261023-pre-ui-20261023.1/`，附恢复说明；见 INSTALL_LEDGER.md。没有读取、清理或迁移现用任务、设置、凭据和下载文件。
- 验收：新增 A-068 设置滚动/尺寸、A-069 系统外观切换、A-070 空列表；本版 A-001…A-070 全部待用户测试，优先复验 A-047、A-068…A-070。NWError 22 未修复，Chrome 交接尚不能认定可用。
- 协作：AGY 预检再次因 `unknown model/group relationship` 阻塞，无源码改动；用户随后授权 Codex 接手并明确要求 Luna 执行，未绕过门禁或改模型配置。
- 保留：`/Users/zjx/Developer/scratch/codex/zjx-download-ui-20261023/` 的构建/签名包核对现场与日志，及前次状态盘点 scratch；按项目规则未清理构建诊断。AGY 失败任务记录保留，未接受失败结果。

## 上次交付概要（历史）

2026-10-18 19:42：安装 **2.0.1/build20261018.2**。5个Luna已全部交付，主代理已审核接缝、修正编译问题，完成干净路径 Release Universal App、双架构CLI和Chrome构建、签名与安装。未启动App/Chrome，功能与性能仍全部待用户测试。

## 本轮修复交付（2026-10-18）

- 完成：01界面/生命周期、02状态/持久化、03传输/后台文件处理、04Chrome交接、05桥接/CLI；R-01…R-17及接缝实现见repair-review-20261018.md与5份worker记录。
- 主代理补齐：同ID导入等待、部分持久化回执、绝对期限与审批取消、窗口关闭后入口、表单取消、cURL/范围边界、更新器团队/图标绑定、MV3模块声明；修正统一构建暴露的返回类型/Sendable捕获/参数顺序问题。
- 实际构建：Xcode Release x86_64+arm64 exit0（BUILD SUCCEEDED）；SwiftPM CLI arm64、x86_64均exit0；npm run build:chrome exit0。所有失败尝试日志保留，未将构建成功当功能通过。
- 签名/安装：Apple Development，TeamIdentifier ZNSTKHPLY3；codesign --verify --deep --strict通过；名称、Bundle ID和icns字节不变。App/Native Host/Framework/CLI均双架构；仅ZJXDownloadCore.framework，无旧框架残留。
- 安装：/Applications/zjx-download.app。旧2.0.0/build20261018.1原包完整保留于 /Users/zjx/Developer/releases/zjx-download/archive/20261018-pre-repair-20261018.2/zjx-download.app，附RECOVERY.md。
- 产物：/Users/zjx/Developer/releases/zjx-download/2.0.1-repair-20261018/。现用state-v2与legacy state安装前后SHA-256一致；源图标8文件一致；未迁移、清空任务或访问凭据。
- Chrome：产物2.0.1；固定ID ikfafcgjoghicpkoolbofdaoonendhak；既有专属Native Messaging注册仍指向安装路径，未改注册或日用Chrome。需用户重新加载新版扩展。
- 手测：A-001…A-067全部“待用户测试”，含A-054启动卡死/同值保存及A-066/067取消、期限和文件提交边界。详细表与回填模板在docs/native-rebuild/。
- 下一步：用户先测A-053/A-054与A-002，再按完整表验收；按编号反馈bug后修复。卡死实际触发链和性能改善尚无运行证据，不声明已验收。
- 当前实施/构建/安装阻塞：无。功能/性能验收：待用户测试。2026-10-19用户授权提交/推送，执行记录见文末；继承Git改动和旧规格保持原样，scratch构建与诊断保留以便追查。

## 恢复阶段记录（历史，已由以上交付更新）

更新：2026-10-18。当前安装为2.0.0/build20261018.1。用户随后报告空任务启动卡死和巨大开销；已授权继续审查并由5个Luna子代理实施修复。代码审查发现状态/设置回写、立即开始、文件I/O和接收语义缺陷，用户已明确恢复任务；本轮源码仍在集成、尚未构建/安装，不能按既有构建记录视为可用或完成验收。

## 本轮修复

- 任务书：docs/native-rebuild/repair-plan-20261018.md；发现：repair-findings-20261018.md。
- 已完成：按第一性原理区分已确认源码缺陷、运行报告与未确认循环入口；确认0任务小状态不能用大列表解释启动卡死。
- 下一步：按暂停交接续跑：02/03已恢复、04已启动，05待槽位；完成所有源码，随后主代理审查接缝和统一构建/交付。用户功能/性能手测仍为待测，不启动App自测。
- 当前阻塞：启动卡死尚未修复验收；本轮修改/构建/安装状态随记录更新。旧源码、旧包和用户数据保留。

## 恢复记录（2026-10-18）

- 用户明确恢复；已读暂停交接、当前机器政策及MACHINE_STATE，核对分支/worktree/stash，仍在原checkout保护继承改动。
- 01/02/03已交付，主代理正在审查集成；04与05已启动并对齐接收协议。Swift源语法解析已通过，尚未做统一类型检查/构建。
- 继续禁止功能/性能自测；构建、签名和安装由主代理统一完成，所有用户手测待测。

## 暂停交接（2026-10-18T12:57:43+08:00）

- 用户明确要求：“先暂停任务吧，额度快没了，等额度有额度了，我再继续任务”。已停止任务；不要自动续跑或设提醒。
- 子代理状态已核对：Luna-01 已交付（尚未统一编译审核）；Luna-02、03 已 interrupt，当前 interrupted；Luna-04、05 尚未启动。没有运行中的子代理或构建会话。
- 保留所有在途源码和继承改动，不撤回、不暂存、不提交、不清场。当前源码处于未集成状态，可能暂时不能编译；不得直接打包覆盖现用 App。
- 当前安装仍为 2.0.0/build20261018.1：/Applications/zjx-download.app。本轮仅源码版本预置为2.0.1/build20261018.2；没有新构建、新签名、新安装，没有启动 App 或操作 Chrome，没有改现用任务数据。
- Luna-01：worker-01-app.md 有完整交付；App 生命周期唯一持有服务/监视器/事件 relay，绑定幂等、列表减少扫描，数值边界和摘要取消已修。仍需05把 IntegrationServer 标为 @Observable 并实现 restart 幂等/generation；关闭全部主窗口后的详情 opener 需用户手测。
- Luna-02：状态/持久化文件已有部分改动，尚未交付。ImportRequestItemResult/ImportRequestResult + importRequestDetailed 为 additive 接口（Codable/Sendable、0基index、taskID/error、acceptedTaskIDs/count/accepted）；幂等记录扩展可选字段。继续前核对该实现及文件提交 transaction、取消/世代、节流、只读恢复所有分支，不把在途代码当完成。
- Luna-03：传输4文件已有部分改动，尚未交付。DownloadEngine 回调已加入 UInt64 generation；02/03 的 wire/start/pause/Range/HLS 接缝可能仍不一致。继续时先核对真实源码，再补完有界进度/限速、后台合并/预分配、跨来源凭据和取消清理，不重复覆盖已做内容。
- 04待启动：Chrome src/scripts；严格解码接收/Native ping、部分接收、requestId回退、自动接管安全和监听缓存。manifest/package 版本已由主代理改为2.0.1，公钥/图标不得变。
- 05待启动：IntegrationServer/NativeHostProtocol/NativeHost/CLI；使用02 detailed API，修Listener @Observable/幂等/旧回调、请求长度/来源/超时、真实ID/CLI确认超时和帧边界。01要求App级共享服务，不能退回每窗另建。
- 主代理已改：InputImport 多行cURL/引号分词与GET边界、范围溢出/补零上限；ExchangeCodec 输出-o；ChecksumService块读取消检查；apply-macos-update绑定当前团队/图标并修zsh只读status回滚。仅做了脚本语法/差异/敏感标记检查，尚无Swift编译结果。
- 手测表与回填模板已扩至A-001…A-065，全部待用户测试；A-025已移除不存在的内置模拟器要求。版本文档当前含草稿，最终交付必须同步README/PROGRESS/BLOCKED/Chrome说明与实际产物。
- 续跑资料：repair-plan-20261018.md（2460字计划）、repair-findings-20261018.md（R-01…R-15）、repair-review-20261018.md（主代理审核记录）、worker-01/02/03记录。
- 本轮diff依据：.agent-work/performance-repair-20261018/baseline.json（保留初始源码文本/哈希，勿覆盖）；暂停源码清单：paused-source-manifest.json；现用数据仅哈希快照 user-state-before.json；图标资源指纹 identity-assets-before.json。
- 后续构建：全部源码稳定后统一执行干净DerivedData的xcodebuild Release、SwiftPM CLI universal、npm run build:chrome和语法检查。不要用旧默认DerivedData（此前曾带入ABDownloadManagerCore旧框架）。仍禁止功能/下载/UI/性能自测，由用户手测。
- 发布/安装仍有用户原授权；成功构建和签名后保留旧App再装，仅核对身份/图标/签名，不启动验收；若App有活动写入，不强杀。当前没有实施这些步骤。

## 前次交付状态（历史）

- 已完成：已读开发治理规则与机器状态；核对仓库原分支/提交、Git 状态、worktree、stash、旧执行记录、应用进程与安装位置。
- 已完成：旧提交及完整可达历史归档为 Git bundle；原测试和两份未跟踪规格/证据目录已复制并校验，归档说明与恢复步骤齐全。
- 已完成：建立实施分支 `zjx/clean-room-native-rebuild`；原分支 `feat/macos-native-liquid-glass` 保留。
- 已完成：记录产品身份、图标指纹、构建入口和任务顺序，见 [开工回执](docs/native-rebuild/start-receipt.md)。
- 已完成：已读桌面、网络/队列/REST/CLI、Chrome 和跨模块验收规格；80组索引逐项映射到新模块和 A-001…A-052 手测编号，见 [设计与落点表](docs/native-rebuild/design-and-coverage.md)。
- 已完成：新 Swift 核心、HTTP/Range/HLS 传输、持久化/旧格式显式预览与迁移、队列、分类、REST、CLI、Native Messaging 和 Chrome MV3 均已替换旧业务实现。
- 已完成：新增编辑任务/批量预览、队列与分类管理、退出确认、单实例锁、系统声音/通知/登录项，以及表格列/排序状态保存。
- 已完成：最终 Xcode Release Universal 构建、Chrome MV3 构建、Apple Development 签名、ZIP 打包和严格签名核对。
- 已完成：SwiftPM arm64 与 x86_64 Release CLI 构建并合并为 Universal `bin/zjx-download-cli`；单独签名，不安装到全局 PATH。
- 已安装：`/Applications/zjx-download.app`；Bundle ID `com.zjx.download`、名称 `zjx-download`、版本 `2.0.0`、build `20261018.1`、架构 x86_64/arm64，TeamIdentifier `ZNSTKHPLY3`。Hotfix App 未启动。
- 已配置：用户级 Chrome Native Messaging manifest，仅允许扩展 `ikfafcgjoghicpkoolbofdaoonendhak`，指向 App 内 Native Host；未操作或重启 Chrome。
- 已交付：`/Users/zjx/Developer/releases/zjx-download/2.0.0-clean-room-20261018/`，含签名 App、App ZIP、Universal CLI、Chrome ZIP、许可/署名、版本说明、SHA-256 清单和测试文档。
- 已归档：干净构建输出与未发布的早期增量产物位于 `/Users/zjx/Developer/releases/zjx-download/archive/20261018-060321-release-diagnostics/`；最终发布目录不含 DerivedData/cache。
- 已知实现边界：简体中文界面及系统语言回退、Dynamic Type 比例档位、未启用 App Sandbox；详见 [阻塞与边界](BLOCKED.md)。
- 当前阻塞：用户报告build20261018.1启动卡死；当前修复见本轮记录。此前“无阻塞”只代表当时构建安装状态，已被这次用户反馈更新。

### 2026-10-18 用户报告启动崩溃

- 已完成：根据用户提供的 macOS 崩溃报告定位到 `GlobalSpeedModeMonitor.init(coordinator:)`。ARM64 崩溃地址对应生成的 `brk #1`；前一条指令因 `NSApp == nil` 跳转到该陷阱。触发时 SwiftUI 正在构造 App，AppKit 应用对象尚未就绪。
- 已完成：在系统活动刷新中对 `NSApp` 做可选检查；AppKit 未就绪时跳过本次采样，已注册的定时器和通知后续继续更新。
- 已完成：干净 Xcode Release Universal 构建成功；签名和安装包身份核对通过；旧安装包已归档到 `/Users/zjx/Developer/releases/zjx-download/archive/20261018-pre-hotfix-20261018.1/zjx-download.app`；新包已安装到 `/Applications/zjx-download.app`。
- 产物：`/Users/zjx/Developer/releases/zjx-download/2.0.0-hotfix-20261018.1/`；首轮增量构建遗留旧框架的候选包保存在 `/Users/zjx/Developer/releases/zjx-download/archive/20261018-122900-hotfix-incremental-diagnostics/rejected-incremental-package/`，未安装。
- 下一步：用户手测 A-053 并提交结果；所有 A-001…A-053 状态仍为“待用户测试”。
- 用户验收：A-001…A-053 均为“待用户测试”；此修复未做功能自测。

## 历史记录

### 2026-10-18 启动

- 基线：`feat/macos-native-liquid-glass` / `0f1245261f429bd6378b43603b2a6f45eb263ef3`；tracked 工作树干净，只有 `docs/clean-room-rebuild/` 与 `docs/reverse-analysis-evidence/` 未跟踪。
- 归档：`/Users/zjx/Developer/releases/zjx-download/archive/20261018-040041-pre-clean-room/`。
- 归档校验：bundle 已由 `git bundle verify` 验证；文件校验清单 `FILE-MANIFEST.sha256`；旧测试目录 `legacy-Tests/`。
- 原应用安装状态：`/Applications/zjx-download.app` 不存在；未发现同名运行进程。

### 2026-10-18 规格落点

- 完成80组功能编号映射，逐项列出目标实现文件及适用用户手测编号；G-014标为阶段条款，D-025的Linux入口标为平台差异。
- 完成单一任务事实、只读旧格式预览/显式迁移、HTTP传输、队列、loopback集成与原生系统能力设计；未访问日用数据、Keychain或Chrome状态。
- 下一步：开始新实现。功能验收仍为待用户测试；当前阻塞无。

### 上一交付状态（2026-10-04，保留）

- Native macOS 26 SwiftUI/AppKit application and branded Chrome companion.
- Native task table, queues/categories, settings consumers, Keychain credentials, REST confirmation, secure update checks and Chrome interface implemented.
- 100 Swift tests passed; Chrome tests and build passed.
- Real Chrome context-menu download completed with matching file hash. A 256 MiB task resumed after app restart; cancellation status regression fixed.
- Universal app, isolated verifier and Chrome package validated locally. Not installed, notarized or published.
- Prior feature matrix: `docs/native-completeness-audit/feature-matrix.md`; prior verification notes: `BLOCKED.md`. These are historical records, not current clean-room acceptance.

### 2026-10-18 新实现与交付准备

- 新实现已替换 App、核心和 Chrome 扩展旧业务源码；产品身份仍为 `zjx-download` / `com.zjx.download`，版本 `2.0.0`，最低系统 macOS 26。
- 完成批量预览/选择、分类编辑/排序/恢复默认、队列排序/成员管理、任务编辑重置确认、声音选项、登录项状态读取、退出确认、单实例文件锁，以及任务表列/排序持久化。
- 干净 DerivedData 重建修复旧增量产物的绝对 framework load path；最终包只含 `ZJXDownloadCore.framework`，由 `@rpath` 加载。
- 最终 Release 构建和安装身份核对通过；签名为本机 Apple Development、未公证；Native Messaging manifest 校验通过。
- 手测表为 A-001…A-052；各项状态全部为“待用户测试”。安装未启动 App，也未迁移或读取现用数据。

## 2026-10-19 续跑与最终交付核对

- 用户要求继续；5个Luna均已完成，没有运行中的子代理。复核当前安装仍2.0.1/build20261018.2，未启动App或Chrome。
- 已补齐App与Chrome ZIP、SHA256SUMS；App ZIP解压后codesign --verify --deep --strict通过，配套Chrome压缩包manifest版本/ES模块声明正确。
- 源码归原路径；旧源码归档和旧App恢复说明保留；67项手测及回填模板全部待用户测试。App启动卡死实际效果仍由用户验收。
- 当前实施/构建/安装阻塞：无。下一步：用户测试A-053/A-054、A-002，按测试编号返回bug；依据反馈继续修复。

## 2026-10-19 Git与本地治理收尾

- 最新授权：用户明确要求应提交的改动提交GitHub；覆盖本任务此前“不push”的阶段限制。只同步origin任务分支，不改upstream/main，不创建公开Release。
- 核对：origin为用户私有仓库xxkingstuggle/zjx-download；当前分支zjx/clean-room-native-rebuild，原HEAD 0f124526。无其他worktree、stash或活动子代理。
- 范围：提交完整原生替换、Chrome/CLI修复、版本与手测文档，以及原字节保留的规格和审计资料；旧源码/测试删除已有Git历史和外部恢复归档。
- 治理：新增精简AGENTS.md入口；敏感文件及发布目录忽略；机器同源规则只读检查通过（0文件需同步），无需修改全局规则。安装登记已存在。
- 已完成敏感内容和暂存范围核对；源码提交177bdd9a已推送，远端核对一致；文档补充随同分支同步。构建/诊断保留，不擅自清场，不触碰日用数据。

### GitHub同步结果与保留清单

- 完整源码提交：177bdd9a69005eba9fbbcc800969e719750ca666，`feat: replace downloader with native macOS 2.0.1 implementation`；origin任务分支推送成功，ls-remote已核对。
- 范围：275项文件变更；新Mac/Chrome实现、CLI/Host、原规格/审计、67项待用户测试表、规则入口和恢复说明入Git。没有构建包、缓存或真实凭据入Git。
- 机器治理只读检查通过，安装登记已核对；未改全局规则、PATH或服务。工作树/远端最终状态以最新Git检查为准。
- 保留：本次scratch约480MiB（构建日志、签名ZIP解压核对、中间编译）；发布目录约23MiB（交付产物）；.agent-work约137MiB（继承与当前诊断）；继承CLI构建缓存约103/110MiB。均不入Git，未经清场确认不删除。旧源码/旧App归档保留用于恢复。
- 用户数据未操作，功能/性能验收仍全待用户测试；没有因提交运行功能测试或重新安装App。

## 2026-10-19 独立仓库与默认主线更正

- 核对GitHub：仓库归属xxkingstuggle，isFork=false、parent=null、private=true；仓库本身独立，问题是此前默认main仍为旧代码，而新实现仅在工作分支。
- 用户明确要求作为自己的独立项目交付；将本次完整实现接入origin/main，本地也切到main；README和AGENTS以正式主线为准。
- 原main提交afc57634b3c121c6415213242b2b600cccc6fd6e是本次实现的祖先；使用fast-forward保留完整历史，未重置、force push或删除旧分支。原源码/旧App归档不变。
- main包含源码提交177bdd9a及治理提交9c6b54a2；当前提交仅更正规则、仓库入口和交付记录，App源码与构建产物未变，不重新启动或安装App，不触碰用户数据。
- 最终核对：GitHub仓库默认分支main应指向本地HEAD；本地origin/HEAD同步main。实际推送结果以GitHub与ls-remote核对为准。
