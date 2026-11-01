# 功能差距矩阵

> 历史记录：本文属于 2026-10-18 替换前的实现/审计阶段，保留用于追溯。文中的“当前”、测试结果和执行任务不适用于现役实现；现役入口见 [文档索引](../README.md)，执行边界以根目录 AGENTS.md 为准。

当前权威状态更新：2026-10-04 RC3。范围为 macOS 原生桌面和 `zjx-download` Chrome 扩展；Firefox、Android、网站排除。`swift test` 100/100、0失败、9.738s；原99项保留，新增1项覆盖正在进行的Range请求取消状态。生产Universal Release app与隔离verifier均构建成功，verifier缺隔离参数退出78。候选包位于 `<local-releases>/1.0.0-20261004-rc3/`。

## 2026-10-04 RC3 当前证据矩阵（权威）

| 范围 | 已有实现与当前证据 | 尚未验证或限制 |
|---|---|---|
| 桌面主窗、列表、Inspector、操作菜单、设置与分类/队列 | 当前实现和已有隔离UI/回归证据见下方历史功能详表；NSTableView真实10k首尾可达、过滤/清空、列状态重启和菜单/校验已有记录。RC3本轮增加正在执行的HTTP Range取消状态回归。 | 不重复已有界面场景。当前构建的全键盘与完整VoiceOver未验；设置通知/声音、登录项的系统副作用保持隔离禁用。 |
| Range暂停、退出、重启、续传 | RC2隔离verifier的256MiB/8-range任务在约158MiB暂停，完整退出后同state重启并续传；最终文件268435456 bytes，SHA-256 `6529a3dd961e75d46621989a1873086d6ab7977a8eb9ab957eafa705bb143b8f`，256个1MiB Range响应覆盖完整文件，part清零。原始过程见 `evidence/run/recovery-paused-before-restart-20261004.json`、`recovery-range-fixture-20261004.log`；最终文件留在ignored `.build/luna-isolated/recovery-active-range-profile-20261004/downloads/Programs/restart-resume.bin`。 | 使用RC2 app构建；RC3相关恢复代码未变，未重复整条长下载。 |
| RC3取消与隔离启动 | 当前RC3 verifier UI取消128MiB慢Range任务时，状态为`cancelled`，停止时已接收48MiB；取消竞态定向测试和完整100项Swift回归均通过。取消文件保留是因为测试profile的`deletePartialFileOnDownloadCancellation=false`。无隔离参数启动退出78且哨兵hash未变、未建state。见 `evidence/run/rc3-cancel-fixture-20261004.log`、`rc3-fail-closed-20261004.log`。 | 带删除开关时的清理由现有测试覆盖；本轮UI样本设置为保留分片。未启动生产bundle。 |
| Chrome品牌界面与下载闭环 | 用户已手动加载扩展。通过Chrome工具栏真实打开popup/options并检查品牌文字、状态和四组设置；普通测试页右键调用`使用 zjx-download 下载`。扩展携带合成Cookie请求进入隔离app非静默确认，再由app开始并完成任务；2079 bytes文件SHA与fixture一致：`6271467510faa3895a1195dbc644eebe18f3f19ca6d6bfb6a2d3ceec94126915`。连接设置未更改。过程见本地证据记录。 | CUA策略拒绝管理页和直接扩展URL访问，无法将已加载实例的版本/文件hash映射到候选ZIP。此次下载由RC2 verifier承接；网络协议/扩展源码未在RC3变更。当前版本多排列、最新构建的选区/HLS未重跑；旧证据单独标注。 |
| Chrome包、构建与品牌资源 | 当前dist的解包目录与RC3 `chrome-unpacked/`逐项一致；扩展包manifest版本1.5.0、zjx-download品牌、图标16/32/48/96/128、原作者和许可归属保留。此前的4套npm测试、manifest 15资源和Chrome build/pack均通过。 | 浏览器工具不允许进入Chrome管理页核对实际安装包。未运行所有错误key/端口与silent组合。 |
| 设置、网络、更新和系统集成 | 既有回归与隔离验收覆盖REST鉴权、Keychain主机凭据、PAC/DNS/目录等消费者和关键状态持久化；完整模块入口见历史详表。 | HTTPS更新成功/坏hash UI、通知/自定义声音/进度窗、登录项未触碰生产权限；完整VoiceOver未验。10k footprint约251.4MiB，高于200MiB优化目标；搜索UI P95未用五轮实测。性能明细见 `performance.md`。 |
| Release候选 | 生产bundle `com.zjx.download`，架构`x86_64 arm64`；隔离bundle `com.zjx.download.verify.rc3_20261004`，marker YES；Chrome ZIP、解包目录、许可证与本地说明齐备。100项Swift与两种Release构建结果见 `evidence/tests/swift-test-final-20261004.log`、`evidence/build/`。 | 未公证、未安装到`/Applications`、未发布。系统副作用和上述真实生产条件未验证。 |

下方旧矩阵记录为历史快照，不能覆盖本节较新的现场结果。旧截图只证明截图对应的构建和场景；未覆盖的行为仍标记未验。

## Previous overlay at 2026-10-03 23:40 CST (superseded)

| ID / feature | Current implementation and code entry | Current runtime/test evidence | Remaining verification |
|---|---|---|---|
| M1 主窗口/侧栏/列表/搜索 | `ABDownloadManagerApp.swift`; direct virtualized `NativeDownloadTaskTable.swift` | RC2空profile显示原生窗口/侧栏；10k fixture首屏15项、末尾ID10000可达，唯一名称搜索1项、清空恢复；主题system/light保存。 | 10k一次AX树读请求120s超时；UI搜索响应多轮P95、Inspector/最小窗口和实测键盘未完成。 |
| M2 表格列/排序/多选 | NSTableView列状态与稳定task id存储 | `startedAt`列显隐、file列宽222和`createdAt`排序经两次重启读回；过滤结果单项选择及右键选择校验可执行。10k具体见 `native-current-10000-table-runtime-20261003.md`。 | 10k筛选清空后选择保留未知；Command/Shift range、重排显隐/宽度视觉与当前RC2全键盘路径待测。 |
| M3 新建/编辑/REST确认队列 | `NewDownloadSheet`、`RESTAddConfirmationQueue` | RC2主机认证表单新增受保护loopback URL，真实完成37B下载；99项回归覆盖REST非静默确认路由、按序与取消语义。 | 本轮未实际跑REST确认弹窗的确认与取消两条UI对照，也未跑批量输入/编辑错误保留。 |
| M4 单项/批量命令/右键/删除 | `AppCommands`、`NativeDownloadTaskTable` row context menu | 当前RC2实际右键行显示Open/Reveal/Edit/Redownload/Start/Pause/Retry/copy/checksum/queue/category/cancel/delete；选中checksum预填当前文件，UI SHA结果=`df422c…f0ef`。旧菜单构建真实展示删除范围命令和保留文件确认。 | 删除各范围、重下载/重试/多选菜单动作尚未在本轮逐一执行；Finder/剪贴板外部副作用未验。 |
| M5 队列/计划/完成动作 | `QueueCompletionActionRunner` + macOS executor；Queue编辑Sheet | 核心runner假执行器回归覆盖每周期最多一次；任务菜单的组命令之前在隔离UI显示。 | 队列编辑、时间窗保存重启未复验；系统退出/睡眠/关机保护动作只测adapter，不触发真实操作。 |
| M6 默认类别/规则/重分 | `DefaultCategories`、`AppStateStore`、Category UI | 回归覆盖迁移/重置/规则；此前实际auto-category开关对同URL真实落盘路径生效/关闭，8段PAC下载完成。 | 新建类别/批量重分/重置 defaults 的本轮UI保存重启未全跑。 |
| M7 引擎恢复/错误/历史 | `DownloadEngine`、`HTTPClient`、History/Inspector | 99项回归覆盖Range、无Range、认证、checksum、恢复与分片清理；本轮Basic auth server先401再完成，服务器记录各Range段均authorized。 | 断流/500/磁盘满/权限失败及进程异常恢复的当前Release端到端未跑；历史导出不属于已确认上游功能。 |
| S1 网络/认证/目录/类别设置消费者 | `AppSettings`、`HTTPClient`、`AppStateStore`、`KeychainCredentialStore` | PAC+8段下载和bookmark跨重启已有隔离实测；RC2 host凭据经独立Keychain namespace用于真实受保护loopback下载，host 401/200、37B落盘hash通过，测试后删除host override；REST key缺/错401、对200，跨App重启仍生效，关闭后匿名200且state JSON无密钥；auto-category与Last-Modified已有实测。 | DNS真实外网DoH/DoT未测；代理bypass额外实际请求、逐host覆盖其他字段仍待；通知声音/完成通知/登录项因验证marker保护而disabled，未改系统权限。 |
| S2 更新器/通知/辅助功能/本地化 | `SecureUpdatePolicy`、notification consumer、30份`.strings` | 回归验证HTTPS/manifest/hash/redirect策略；隔离UI HTTP地址拒绝并正确显示简体中文；RC2显示主题/语言控件。 | 成功HTTPS UI下载/hash失败UI需受信TLS夹具；通知权限/自定义音/进度提示及登录项未验；VoiceOver、完整键盘及英文真实UI未完成。 |
| C1 Chrome品牌与资源 | `browser-extension` manifest、locale、icons、README、LICENSE/NOTICE | 当前 `npm test` 四套通过、15个manifest资源检查通过、`pack:chrome`生成Chrome ZIP；品牌检查保留上游作者/Apache来源。 | 本轮不操作任何Chrome；最新构建工具栏/弹窗/安装图标在真实浏览器渲染未验。 |
| C2 Chrome输入/headers/cookie/HLS/回退 | `browser-extension` content/background/REST | 固定协议实现与旧构建右键、Cookie、选区、HLS、静默及断连证据留档；不冒充当前品牌UI验证。 | 最新brand build的真实加载、请求/响应→任务→文件链全部未复验。 |
| C3 Chrome设置/鉴权/静默组合 | options popup/storage/CORS | 四组Options保留旧配置，inline连接状态和隐藏密钥；`npm test`检查链接提取/回退/文案/a11y。 | 当前Chrome存储重启、端口冲突/错误key/缺key/静默组合/键盘未验。 |
| C4 Chrome面板视觉/语言 | `styles.css`、Popup/Options/Selection/Media组件 | CSS系统明暗/系统字体/focus、360px弹窗、四组设置和中英文键已静态/构建检查。 | 当前品牌真实浅/深、窄宽、键盘及四类页面截图未验；此前Chrome隔离启动重定向风险仍有效。 |
| P1 CPU/RSS/交互/吞吐/长期 | NSTableView虚拟化；filtered/sorted projection | 10k no-AX post-event 90样本CPU median/P95 0.1%/0.2%、RSS67.6MiB、footprint251.4MiB；RC2单任务90样本0.2%/0.2%；约11分钟600样本CPU median/P95 0.3%/0.4%、top MEM126–131MiB、结束RSS92.8MiB、footprint130.8MiB/peak180.2MiB。初始提交对比当前候选，各25个engine样本：1/4/8连接median变化-0.18%/-0.12%/+3.52%，所有payload SHA一致；详见 `performance.md`。 | 10k footprint超过候选值；11分钟趋势含设置交互；10k搜索多轮时延、pause/restart/cold-start仍待；全AX读取超时且完整VoiceOver未验。 |
| D1 候选包/证据 | RC2 universal生产 app + 独立verifier + Chrome ZIP | Swift 99/99、Chrome npm/build/manifest/pack通过；生产universal与独立verifier Release构建，候选app副本ad-hoc deep签名并通过strict verify；ZIP CRC、归档可执行文件、Chrome包目录逐文件一致性通过。verifier缺隔离env退出78，完整env REST有效。包位于 `<local-releases>/1.0.0-20261003-rc2/`，hash清单已生成。 | app未公证、未安装/发布；生产bundle只构建未运行。Chrome真实UI不安全时保持未验；系统通知与登录项权限未改。 |

## Earlier detailed matrix at 2026-10-03 20:24 CST (stale; superseded by overlay above)

“源码完成”与“真实运行通过”分开记录。截图和日志仅证明其中显示的场景；没有覆盖的交互保持“未验”。候选性能数值沿用原任务书，不是用户确认的硬阈值。

| ID | 能力范围 | 当前实现与代码入口 | 真实证据 / 当前状态 | 剩余验收或差距 |
|---|---|---|---|---|
| M1 | 主窗口、侧栏、下载列表、搜索/筛选 | `ABDownloadManagerApp.swift` + `NativeDownloadTaskTable.swift`；AppKit `NSTableView` data source/delegate、复用 cell、稳定 task ID、可见行更新；搜索和状态/队列/类别投影 | build2/3 的真实主窗和10k旧运行证据见 `evidence/ui/`；build3 17行 fixture 通过 CUA 筛选失败→全部，记录 `native-selection-filter-sort-build3-20261003.txt` | 10k 行首尾及搜索/清空仍沿用 build2 实测，build3 有全AX树导致约99% CPU的单次异常，需和无AX空闲样本分开看；完整正常滚动/搜索性能未达100ms候选 |
| M2 | 表头排序、列宽/显隐/顺序持久化、多选/右键 | NSTableView 原生表头和 selection；列状态写入隔离 UserDefaults；`AppCommands` 和 row context menu | build3真实 CUA：Command+A 选17项；筛失败后只留2项；重置显示全部时仅两项仍被选中；文件排序后稳定 task ID 选择保留；Started Time 显示状态写入 UserDefaults。日志 `native-selection-filter-sort-build3-20261003.txt` | Shift/Command-click 修饰键组合和 17 行上下文菜单已由先前证据覆盖但需按当前构建对齐；列宽拖动本轮未更改显示/状态，运行时宽度保存仍未验；列显隐跨重启曾在build2通过，本轮build3还需重启复核 |
| M3 | 新建、编辑、批量模式、REST确认队列 | 原生 `NewDownloadSheet` 接受headers/校验/速度/队列/类别/冲突策略；`RESTAddConfirmationQueue` 按序展示；非静默取消不入库 | 95项 Swift 回归覆盖解析、设置草稿与队列；`evidence/ui/rest-confirmation-app-ax.txt` | Chrome silentAdd false 已观察新建确认；尚需真实确认与取消两条对比app task state，并验证批量 pattern-only及错误输入保留 |
| M4 | 单项/批量操作、下载表格菜单 | `AppCommands` 已接队列组开始/停止、停止全部、删除缺失/已完成/未完成/可见/全表；NSTableView context menu 提供重新下载、校验、打开、Finder reveal、复制格式、编辑、队列/类别移动 | 当前build2 Tasks菜单通过真实AX显示上述全套命令，单项操作选择门控实测；Help菜单当前真实显示本项目链接/开源/翻译/更新/关于。旧build1右键菜单实际校验 SHA-256 `8fda91927cd7bdcf775be18baff12d1b2192903cf951b84fa055de272d608d79` 并重下载 24,012 bytes 文件，证据 `native-redownload-complete-current-20261003.png` | 仅菜单列出不等于所有动作都跑通；删除范围仍未执行，需先比对profile task/file hash；单项/多选右键等继续在隔离app补验 |
| M5 | 队列组、计划、完成动作 | 队列保存/重排/并发/计划；`QueueCompletionActionRunner` 限制每周期至多一次，macOS adapter 承担退出/睡眠/关机动作 | `QueueCompletionTests` 在fake executor上验证；95项回归通过 | UI修改后读取保存并重启；真实系统关机/睡眠不可触发，继续只测隔离fake和平台调用参数 |
| M6 | 分类、默认类别、自动归类 | 六个固定默认分类、扩展名/host rule、新任务选择、批量重分、重置默认；`DefaultCategories`/`AppStateStore` | 95项 Swift 回归覆盖旧profile迁移、默认项、重分、重置 | UI真实新建/重分/重置和重启后归类仍需完整验证 |
| M7 | 删除/取消/恢复、错误状态与修复路径 | Delete scope、取消分片清理、HTTP/校验错误保留任务状态、任务重新下载；Inspector显示错误与文件动作 | 现有引擎恢复/重试/取消/checksum测试；Chrome无Cookie夹具失败截图 `chrome-no-cookies-401-failed-20261003.png` | 单项/批量删除范围、断流/磁盘满/权限错误及中断恢复仍待端到端跑；不要仅凭错误弹窗断言恢复 |
| S1 | 每项app设置的写入与真实消费者 | `SettingsDraft` 保存/取消/失败保留；代理含HTTP/SOCKS/PAC/bypass；DNS system/DoH/DoT；per-host UA/auth；书签目录；类别默认/重置；登录项；通知/声音/进度；更新manifest/下载SHA | 96项测试含新隔离目录校验；实际隔离 Settings UI 证明目录选取后取消无bookmark副作用、路径不匹配不写bookmark、匹配保存并重启回读，见 `evidence/run/folder-bookmark-settings-draft-runtime-20261003.md` | 代理/DNS/host覆盖/通知/更新器的app UI→真实消费者路径仍需逐组验；登录项/系统通知权限不改真实用户域，使用隔离测试或记录具体边界；正式更新源仍未取得 |
| S2 | 本地化、键盘、辅助功能 | 30份 `.strings` 中可见产品名已改为 `zjx-download`；下载表格有行/列可访问标签、菜单有标准macOS键位 | 更新后的30文件品牌回归由 `browser-extension/tests/brand.test.cjs` 扫描；窗口及行截图在 `evidence/ui/` | 尚需 VoiceOver 实际朗读、全键盘路径、系统/浅色/深色、中文/英文切换真实验收；不因源码label宣称AX通过 |
| C1 | Chrome品牌、名称、图标、说明、通知、链接 | `package.json`、Chrome manifest、`_locales/en` + `_locales/zh_CN`、Options/Popup/selection/media UI、context menu、通知；图标从桌面图标导出16/32/48/96/128；项目主页/issues/releases指向用户repo。README/LICENSE与生成的第三方通知文件保留原作者和Apache归属；30份app Localizable可见品牌已替换 | 最新 `npm test`、`npm run build:chrome`、`npm run check:manifest`通过；versioned `zjx-download-chrome-1.5.0.zip` SHA-256 `d55b98670f5ccb4c49bc920ed9edeb1403fec1a6ad517a007e4cd88316f7f2a1`；分发目录见 `<local-releases>/1.0.0-20261003-rc1/`。本轮没有 Chrome 加载验收 | 当前品牌 popup/options/selection/media 的Chrome实时视觉、连接、按键、明暗/窄窗和扩展到app下载链未验；既有 default-profile 重定向影响无法确认，见 BLOCKED |
| C2 | Chrome右键链接/选区、headers/cookie、媒体/HLS | 固定扩展接口与REST兼容；linkgrabber单请求去重、后台返回接受后才取消Chrome原始下载；selection/media popup 已按新样式实现 | `chrome-protected-download-completed-20261003.png`、`chrome-selected-hls-completed-20261003.png` 记录了改造前扩展构建的历史行为；不能证明当前视觉构建仍通过 | 用当前构建重新实测右键、选区、Cookie请求头/HLS、成功入队后Chrome无重复下载，关联请求、任务和文件SHA |
| C3 | Chrome设置/弹窗、静默组合、鉴权、断连回退 | 四组 Options 保留全部配置项与即时保存；端口测试显示页面内状态；API key默认掩码；popup三开关原生checkbox只响应一次；连接文字状态、错误提示和不可达指引 | `npm test`、`npm run build:chrome`通过；旧版Options截图是改造前基线；当前真实Chrome界面尚未加载 | 需真实UI检查测试中/成功/错误key失败、重新连接、键盘切换、settings保存重载、360px/浅深色；现有Cookie/断连/回退证据为旧build历史结果 |
| C4 | Chrome原生工具面板风格与中英文 | `styles.css`跟随系统明暗、系统字体和可见焦点；Options为连接/下载接管/网站规则/高级四组；选择与媒体浮层使用一致的配色、按钮和键盘语义 | 源码/构建与英文、简体中文键覆盖通过；当前 build2 未在浏览器渲染 | 浅/深色、窄窗、键盘、中英界面和四类真实截图未验。默认profile重定向影响不明时不操作Chrome，单项限制不能代替桌面其余验收 |
| P1 | CPU、RSS、搜索、吞吐和长期运行 | `NSTableView`只创建可见复用 cell；过滤排序用稳定投影；下载并发/恢复逻辑由 Core 实现 | build2 10k 重启后的90秒 no-AX样本为 CPU 中位/P95 0.2%/0.2%，`top MEM`约92–104MiB，`ps RSS`约108.7MiB，physical footprint约91.7MiB；build3 17行可见窗口90秒 CPU median/P95 0.1%/0.1%、top MEM104MiB，RSS两次取值73.0–121.4MiB，physical footprint103.6MiB。build3 调用CUA全树读取后单次样本升至约99% CPU、245MiB `top MEM`，sample栈落在AppKit AX cell mock创建路径 | 当前构建10k正常UI输入/滚动、多轮搜索、吞吐/恢复和10分钟趋势未通过。候选CPU/RSS指标仅作目标，AX stall不可冒充常态空闲；见 `performance.md` |

### Chrome 品牌检查范围

`npm run test:brand`逐项断言manifest/package品牌、context menu、选项标题、弹窗、错误、通知、媒体入口、回退说明、项目issues链接、原作者归属、Apache来源commit，以及16/32/48/96/128 PNG尺寸；它扫描30个macOS `.strings`目录并核对英/中文消息键覆盖。`ABDM_*` 隔离环境键、plist marker、REST queue/storage键名、`abdm-*` CSS类及 `com.abdownloadmanager` 协议命名空间属于内部兼容标识，不展示给用户且保留。`README.md`的upstream名称和原作者仅作为法律归属明示保留。

### 历史验收限制

较早一次隔离浏览器启动无法证明浏览器进程与隔离profile的对应关系，可能涉及默认profile访问；原因和影响未知。用户后来明确授权在日常Chrome进行本项目测试。原始运行记录仅保留在本机忽略的证据目录；公开矩阵不保留浏览器标识、进程号、用户目录或fixture下载路径。

## 原始 2026-10-02 审查快照（历史基线，不代表当前）

以下固定提交、逐项上游行为与历史差距仍可用来追踪基线；其中的本地状态和验证结论已经过时，不能代替上表当前核验。

### 固定基线

- 本地：`b08780522b955c28a851ec628123e29946caf30e`，分支 `feat/macos-native-liquid-glass`。
- 桌面上游：`amir1376/ab-download-manager@777ac0a9f5c47e9afeb34e7fddb37c477b9923f3`。固定提交页面：[commit](https://github.com/amir1376/ab-download-manager/commit/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3)。此提交新增可选的“开始时间”和“完成时间”下载列表列；主页面菜单、快捷键、列表、设置、添加、队列、分类等文件均从这个 SHA 读取。GitHub API 的递归树返回 1,737 项、`truncated=false`，并在本机 `.build/native-completeness-audit/perf-run-20261002-01/upstream-main/` 保存了本次抽取的相关源码。
- 浏览器扩展：`amir1376/ab-download-manager-browser-integration@1871203ce9665ea6802e8d1328f8b70c7dc9d948`，固定提交日期 2026-09-29，说明见 [README](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/README.md)。它是单独仓库，不能据此宣称本项目含扩展实现。
- 本轮将范围按 AB Download Manager macOS 桌面端与完整浏览器联动处理。浏览器扩展源码位于独立 companion 仓库；本仓库可先完成 UI、REST API 与协议兼容。当前无须因网站或 Android 范围停等；扩展仓库边界见 [BLOCKED.md](../../BLOCKED.md)。

状态标记：**核心已测/UI 未验**表示核心逻辑有测试或本轮隔离 REST 实测，但没有交互验收；**部分实现**表示有代码但重要上游行为缺失或只做了简化；**缺失**表示当前代码没有对应功能路径；**实现未验**表示能在源码中找到但没有充分运行证据；**平台映射**表示上游能力需以 macOS 对应交互实现。

## 桌面端功能矩阵

| 区域 | 固定上游行为 | 本地实现与证据 | 状态 / 差距 |
|---|---|---|---|
| 主窗口、导航 | 下载、队列、分类、历史与设置；工具栏、列表、类别面板、页脚统计；可调整列表状态 | SwiftUI `NavigationSplitView`；Downloads、Queues、Categories、History、Settings 独立侧栏项；下载页仅“新建、详情、刷新”工具栏。主窗口源码 `ABDownloadManagerApp.swift（历史源码：`../../Sources/ABDownloadManagerApp/ABDownloadManagerApp.swift#L554`；已从现役树移除，需查 Git 历史）`；本轮 CoreGraphics 元数据显示 Release app 有一个屏幕可见的“下载”窗口，1100×720 | **部分实现**：运行窗体已出现；未做截图、视觉、导航或不同尺寸人工验收；上游页面内的类别/队列筛选被拆为侧栏页，缺少同页工作流 |
| 下载表格 | Check、Name、Size、Status、Speed、Time Left、Date Added、Date Started、Date Finished；列可排序、显隐、调整宽度，列表虚拟化；新增时间列默认隐藏 | 本地 `List` 行展示图标、文件名、进度、状态、速度，按创建时间倒序；无表头、列排序/显隐、时间列或列状态存储。参见本地 `DownloadList` 749–798 行；上游 [HomeComponent.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt) 和 [DownloadList.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/sections/DownloadList.kt) | **部分实现**：核心列表数据模型存在；表格能力缺失。上游固定提交的 Started/Finished 时间列也没有本地对应字段展示 |
| 搜索和筛选 | 文本搜索、类别、队列、All/Finished/Unfinished 状态筛选 | 没有搜索框、筛选状态或结果计数；取消任务从活动列表隐藏，其余任务按日期排序 | **缺失**。上游 [FilterState.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/FilterState.kt) |
| 多选 | 复选框、全选、Ctrl/Command+A、Esc 清空、Shift/Command 多选；空白处取消选择；右键对准点击行或当前多选 | SwiftUI `List(selection:)` 绑定 `Set<Int64>`；有可见项全选、计数、批量状态门控、稳定主选择；`SelectionTests` 25 项通过。参见本地 173–254、749–793、800–834 行 | **核心已测/UI 未验**：Command-click、Shift-click、键盘焦点、VoiceOver、多选右键、滚动及窗口缩放组合未用真实 UI 验收 |
| 行、批量和右键操作 | 打开文件/文件夹、恢复、暂停、删除、重新下载、移动队列/类别、复制 URL/cURL/JSON、编辑、校验文件、打开下载详情 | 行双击打开已完成文件，否则选择 Inspector；Inspector 可显示属性、编辑及打开/在 Finder 显示完成文件。上下文菜单和选择菜单仅开始、暂停、重试、取消、删除 | **部分实现**：缺重新下载、移动队列/类别、复制三种格式、选中任务文件夹、选中任务 checksum、下载详情独立页等 |
| 删除 | 删除前区分完成/未完成；可选择同时删除完成文件；菜单批量删除缺失文件、完成、未完成或整表 | 已有删除确认 sheet、可删除已完成文件、未完成任务调用 abort 清理分片；没有上述四种任务范围菜单 | **部分实现**：单项/多选基础语义存在，批量清理操作缺失 |
| 新增、单项编辑 | 单项下载、URL/名称/目录/认证信息编辑、队列/分类、冲突策略；粘贴/剪贴板导入；明确无效输入和错误 | 新建 sheet 支持多行 URL、目录、headers、checksum、速度、队列、类别、冲突策略、立即开始；编辑可改 URL/名称/目录/headers/checksum/速度/队列/类别。参见 305–316、906–983 行 | **部分实现**：未做单独的认证/逐链接凭据表格；无效 URL 在 `addLinks` 被跳过后仍关闭 sheet，用户可能看不到失败；剪贴板同时有自动监控和 `Command+V` 路径，上游“从剪贴板添加”专用动作未实现 |
| 批量 URL | 独立批量页，通配符范围、填充、预览、同一轮配置并验证条目 | 有 `*` 范围/填充 core 与新建 sheet DisclosureGroup。`Add` 只在 `links` 非空时启用，因此只填写 `batchPattern` 无法提交（本地 978 行）；即使通过代码调用 `addBatch`，它只传 pattern、目录、队列、立即开始，headers/checksum/speed/category/conflict 均不传（275 行与 968–975 行） | **有功能且被 UI 阻断**：P0 修复；还需多项配置完整传递和输入校验 |
| 引擎、续传与校验 | HTTP(S)、Range 多段、重试/退避、暂停/恢复、取消、冲突策略、断点状态恢复、checksum、HLS | `DownloadEngine`、`HTTPClient`、`HLSDownloader` 有实现；测试涵盖 range、无 Range fallback/redirect、HLS 拼接、header/auth、checksum、恢复、取消和分片清理。`swift test` 本轮 58/58 通过 | **核心已测/UI 未验**：不是上游引擎逐字节复刻；HTTPS、跨 host 跳转、断电、磁盘满、真实慢网和大体量长任务无本轮 app 运行证据 |
| 队列 | 队列组开始/停止、全部停止；并发数、计划时间与星期、重排、确认后删除；结束后退出/睡眠/关机 | 队列 CRUD、重排、并发、排程及 scheduler 有实现和单测；队列完成动作可在编辑页选择并确认，但没有执行器；单队列删除有 store 防护，多队列删除按钮直接执行且无确认 | **部分实现**：缺菜单级队列组操作、删除确认、队列级额外参数，以及 completion action runner。上游执行器：[OnQueueEventActionRunner.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/onqueuecompletion/OnQueueEventActionRunner.kt) |
| 类别 | 默认类别、名称/扩展名/URL 规则/图标/目录、自动归类、新建下载中选择、重排、恢复默认 | 可自建、编辑、删除、重排；按扩展名和 host/URL 模式在添加时自动归类；初始为空，无默认图标、默认类别、重置或已有任务批量归类。`useCategoryByDefault` 字段未参与判断，类别匹配会直接执行（`AppStateStore.swift` 120–123 行） | **部分实现**：核心规则有代码，默认集和上游设置语义缺失。上游默认集：[DefaultCategories.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/DefaultCategories.kt) |
| 历史 | 本轮固定上游审查未发现独立历史页或历史导出要求；桌面主列表包含完成状态筛选 | 本地额外提供历史记录列表、Finder reveal、清空；真实 Finder 行为未测。单条删除、检索/筛选/导出是可选体验建议，不作为已确认的上游缺口 | **平台扩展；UI 未验** |
| 错误及任务详情 | 每个任务错误原因、状态、操作入口和下载详情页；进度窗 | 行展示状态与百分比/瞬时速度，Inspector 可显示 `errorMessage`；其他错误多进全局 `lastError` alert；无进度独立窗口。通知授权/弹窗没有点击或状态验收 | **部分实现**：错误上下文与恢复路径不完整 |
| 检查和工具 | 校验选择的下载/任意文件；支持页、第三方开源库、翻译者、捐赠、关于、检查更新 | 独立 `ChecksumToolView` 和下载后 expected checksum；无选中任务批量校验；没有上游完整 Help/Tools 菜单及 About/更新器交互 | **部分实现** |
| 更新器 | 检查版本、下载、应用更新、完成通知和更新缓存清理 | `SecureUpdatePolicy` 有 manifest/hash 类型；应用未调用它。设置中的更新频道只是写入；无更新检查或下载流程 | **缺失**：安全策略代码存在不代表更新功能存在 |
| 登录项、通知、剪贴板 | 登录启动；完成/失败通知、进度窗口、自定义音效；可显式从剪贴板添加 | `SMAppService`、系统完成通知、默认系统声音、1 秒剪贴板轮询存在；自定义音效/进度窗字段无消费者。未切设置和系统通知权限 | **部分实现/实现未验** |
| 菜单栏额外入口 | 桌面端 File/Tasks/Tools/Help 菜单、头部操作；Linux 创建桌面项 | `MenuBarExtra` 源码显示活动数、新建、打开、退出；本轮进程窗口清单没有状态栏项证据，因此未验证其屏幕可见性。Linux desktop entry 是 macOS 不适用 | **平台映射**：macOS 菜单栏入口代码存在；需视觉、键盘和菜单状态验收 |
| 原生布局/辅助功能 | 明确焦点、选择、状态、键盘行为及平台菜单 | SwiftUI 语义控件和部分 `accessibilityLabel`；最小窗口宽高 544×420、Inspector 宽度 620 时才作第三列，否则 sheet。没有 VoiceOver/UI 自动化验收 | **实现未验**：不可据静态源码宣称原生外观或可访问性通过 |

### 上游菜单、快捷键逐项对照

主上游 [HomeComponent.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt) 和 [DesktopDownloadActions.kt](https://github.com/amir1376/ab-download-manager/blob/777ac0a9f5c47e9afeb34e7fddb37c477b9923f3/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/DesktopDownloadActions.kt) 定义下表。macOS 快捷键列按上游 `meta` 处理。历史页搜索/导出等体验建议不计入上游 parity 统计。

| 上游菜单/命令 | 本地对照 |
|---|---|
| File：新建、从剪贴板新建、批量新建、退出 | 工具栏新建；批量入口被 Add 按钮条件阻断；自动剪贴板轮询不能替代显式粘贴动作。SwiftUI 系统退出命令按平台默认提供，不包含上游确认/逻辑的代码证据 |
| Tasks：开始队列组、停止队列组、停止全部；删除缺失文件/已完成/未完成/全表 | 无对应自定义 `CommandMenu`；当前只对所选任务提供开始/暂停/重试/取消/删除 |
| Tools：浏览器集成、per-host 设置、设置 | REST 设置和 host override 编辑存在；没有浏览器集成管理页或自定义 Tools 菜单 |
| Help：支持、开源第三方库、翻译、捐赠、检查更新、关于 | 无对应菜单/页面；更新器未接线 |
| 行操作：打开文件/文件夹、恢复、暂停、删除、重新下载、移动队列/类别、复制 URL/cURL/JSON、编辑、checksum、详情 | 只有开始、暂停、重试、取消、删除；Inspector 另有编辑/完成后打开或 Finder reveal |
| Mac 键位：Backspace 删除、⌘N 新建、⌘V 粘贴、⌘C 复制链接、⌘⌥S 设置、⌘Q 退出、⌘O 打开、⌘F 文件夹、⌘E 编辑、⌘P 暂停、⌘R 恢复、⌘I 打开下载详情 | 当前本地新增键位：⌘⇧N 新建、⌘A 全选、⌘⌫ 删除、⌘↩︎ 开始、⌘P 暂停。新建键位不一致；其余上游专用键位缺失或行为未证实。见 `AppCommands` 1160–1204 行 |

### 设置生效矩阵

上游桌面设置由 `DesktopSettingsComponent.kt` 的 Appearance、Download Engine、Browser Integration 分组构成；共覆盖 `CommonSettings.kt` 及 `DesktopSettings.kt` 中的配置项。以下逐一检查本地 `AppSettings` 字段、控件、业务读取点。本地“死设置”表示字段可以保存在 JSON 中，但没有业务读取或设置输入，不能算功能生效。

| 字段/功能 | 本地控件 | 消费点 / 实际效果 |
|---|---|---|
| `theme` | 有 system/light/dark | 根场景 `preferredColorScheme` 使用；未做主题全状态 UI 验收 |
| `language` | 仅简体中文/英语 | 本地化生效；nil 首启被强制设为 `zh-Hans`，不跟随系统语言；资源包中其他语言不能从设置选择 |
| `uiScale`、`showIconLabels`、`useRelativeDateTime` | 无 | Sources 除模型/编解码外无读取；不可调字号/图标文字/相对日期 |
| `clipboardMonitoring` | 有开关 | `ClipboardMonitor` 每秒读取系统剪贴板并导入未立即开始的链接；未做实际剪贴板 UI 验收 |
| `threadCount` | 有全局步进器 | `DownloadEngine.run` 读取全局数；per-host `threadCount` 在 `AppStateStore.addTask` 写入 task.connectionCount，启动时又被全局值覆盖（见缺陷） |
| `maxConcurrentDownloads`、`maxDownloadRetryCount` | 有并发数；无重试数 | 引擎/队列调度使用并发上限及重试退避；重试次数无法在 Settings 调整 |
| `dynamicPartCreation`、`useServerLastModifiedTime`、`appendExtensionToIncompleteDownloads`、`useAverageSpeed` | 无 | 无业务读取；临时文件扩展名固定 `.abpart`；速度按事件瞬时速率展示 |
| `speedLimit`、`userAgent`、`defaultDownloadFolder` | 都有输入 | 引擎限速、HTTP `User-Agent`、任务默认目录读取 |
| `useCategoryByDefault` | 无 | 无消费者；类别匹配无视这个值，总会自动归类 |
| `trackDeletedFilesOnDisk` | 无 | 无消费者；没有磁盘扫描和已删文件状态追踪 |
| `deletePartialFileOnDownloadCancellation` | 有开关 | 取消/abort 路径读取；core 测试覆盖分片清理 |
| `sizeUnit`、`speedUnit` | 无 | 无消费者；显示采用 `ByteCountFormatter`/固定 format，无二进制/十进制单位选择 |
| `autoStartOnBoot` | 有开关 | 保存时调用 `SMAppService.mainApp.register/unregister`；未实际授权或登录后重启验收 |
| `notifications.soundEnabled`、`showCompletionDialog` | 有开关 | OS 完成/失败通知读取并使用系统默认声音；未验证系统授权和通知中心实际展示 |
| `generalSound`、`successSound`、`errorSound`、`showDownloadProgressDialog` | 无 | 无业务读取；没有自定义音频选择或进度对话框 |
| `integration.enabled/port/authEnabled/apiKey` | 有 REST 服务开关、端口、密钥开关/输入 | app 保存后重启本地 REST；隔离 app 的端口 `25251` 本轮实测 `/ping`、`/queues`。`authEnabled=true` 但 key 为空时 `enforcedKey` 返回 nil，实际不启用鉴权 |
| `proxy.mode/scheme/host/port/username/password` | 有 mode、host、port、user/password；无 scheme 选择器 | `HTTPClient` 手动代理凭据和 TLS delegate 有读取；本轮未走真实代理。system/none 路由未做网络验证 |
| `proxy.bypassList` | 无 | 无消费者；没有绕过代理规则 |
| `tls.allowInsecureCertificates` | 有危险开关 | HTTP 客户端读取；没有真实 TLS 请求验证 |
| `updateChannel`、`lastUpdateCheck`、`settingsVersion` | 只有更新频道选择 | `updateChannel` 只从 Picker 写出、`lastUpdateCheck` 无读取、`settingsVersion` 只有未调用迁移器写入；无 app 更新功能 |
| `QueueCompletionAction` | 队列编辑页有选择器和关机动作确认 | 只有持久化及 UI；无退出/睡眠/关机执行路径 |

### 浏览器扩展及接口矩阵

固定 companion SHA 的源码：[README](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/README.md)、[ContextMenus.ts](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/src/contextmenus/ContextMenus.ts)、[DownloadLinkInterceptor.ts](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/src/linkgrabber/DownloadLinkInterceptor.ts)、[MediaOnTab.ts](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/src/media/MediaOnTab.ts)、[Backend.ts](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/src/backend/Backend.ts)、[OptionUi.tsx](https://github.com/amir1376/ab-download-manager-browser-integration/blob/1871203ce9665ea6802e8d1328f8b70c7dc9d948/src/optionsui/OptionUi.tsx)。

| 扩展能力 / 传输接口 | 固定上游行为 | 本地状态 |
|---|---|---|
| Chrome / Firefox | 两套 manifest 和打包脚本；Chrome MV3，Firefox MV2 | `browser-extension/` 已集成固定 SHA companion；两端 Release build 和 manifest 引用资源校验通过。隔离 Firefox 已实际加载并调用 REST；Chrome 已手动 Load unpacked 并显示扩展卡片，最新 UI 重载/连接复验未完成 |
| 页面链接上下文菜单 | “Download With AB DM”对 link/audio/video/image；选择文本的 “Download Selected” | 扩展源码已集成并在 Firefox 真正右键链接完成 Cookie 下载；selected-text popup、Chrome context action 本轮仍待实测 |
| 自动捕获 | 拦截浏览器下载和网络请求；可取最终 URL、来源页、请求 headers，并可阻止浏览器自身重复下载 | 扩展源码和 manifest 已构建；未完成 audio/video/image、HLS、黑名单、浏览器接管与断连 fallback 的真实场景验收 |
| 多媒体 | tab 内探测音视频、HLS playlist 和变体，解析时长/尺寸/码率/分辨率，popup 选择下载；排除不支持的加密/无扩展项 | 引擎与扩展的 HLS 流程均已实现；本轮 HLS fixture、popup 选择和播放列表下载尚未完成真实浏览器验收 |
| 扩展弹窗和选项页 | 连接状态、自动捕获开关、popup 开关、silent add/start、more settings；选项包括端口、API key、send headers、扩展名、URL 黑名单、最低尺寸、捕获异常时回退、关闭已捕获新标签、快捷键绕过 | 两份 manifest 与本地包已构建；Firefox 端口和 Test ping 已通过。修复 Test 使用后台陈旧 Port 的 draft race，尚未在新包真实 UI 回归；其余选项逐项消费者和组合场景继续验收 |
| Cookie / 请求信息 | 扩展通过 `cookies` 权限获取 Cookie，并添加 Host/User-Agent/请求头；可按选项停用 | 已通过隔离 Firefox 真实 Cookie header 验收：fixture 仅在正确 cookie 时返回 payload；仍需验证 no-cookie 选项和更多 headers 组合 |
| HTTP API | 扩展用 `POST /ping`、`POST /add`；另有 native messaging 优先/HTTP fallback；默认端口为 15151，扩展 API key 由配置传入 | `RESTService` 有 `POST /ping`、`POST /add`、`POST /start-headless-download`、`GET /queues`、OPTIONS；只监听 `127.0.0.1`，支持 `X-Api-Key`。本轮真实 app 的隔离端口 REST 通了，但没连接 extension |
| silent add/start | 扩展选项生成 `options.silentAdd/silentStart`，单项 capture 成功后可发扩展通知 | `silentAdd=false` 现在进入原生 New Download sheet，预填字段、确认后创建/取消不入库；多个请求按序排队。`silentAdd=true` 直接入队，`silentStart` 确认时预选开始或静默时开始；队列/选项回归通过。新隔离 App 的真实 GUI 交互、扩展通知和全部开关组合仍待跑 |

### 已确认缺陷（实现前 P0 修复）

1. **批量下载 UI 无法单独提交。** `NewDownloadSheet` Add 在 ABDownloadManagerApp.swift（历史源码：`../../Sources/ABDownloadManagerApp/ABDownloadManagerApp.swift#L968`；已从现役树移除，需查 Git 历史） 的禁用条件只看 `links`；复现：打开新建 → 留空 Links → 仅填写 Batch pattern/start/end → Add 按钮仍 disabled。`addBatch` 调用与 `DownloadRequest` 构造也漏传 headers、checksum、speed、category、conflict。
2. **per-host 并发覆盖。** AppStateStore.swift（历史源码：`../../Sources/ABDownloadManagerCore/Persistence/AppStateStore.swift#L137`；已从现役树移除，需查 Git 历史） 添加任务时用匹配 host 的 `threadCount` 写入 `task.connectionCount`；DownloadEngine.swift（历史源码：`../../Sources/ABDownloadManagerCore/Engine/DownloadEngine.swift#L142`；已从现役树移除，需查 Git 历史） 开始时再无条件以全局 `settings.threadCount` 重设。复现：配置 host override 线程数 2、全局线程数 8；为该 host 建任务，再启动；创建时显示 2，执行前被写成 8。未运行网络下载验证，但覆盖顺序在源码可确认。
3. **启用鉴权但密钥为空时实际无鉴权。** AppSettings.swift（历史源码：`../../Sources/ABDownloadManagerCore/Settings/AppSettings.swift#L178`；已从现役树移除，需查 Git 历史） 只有 `authEnabled && !apiKey.isEmpty` 才返回 enforcedKey；本地 Settings 允许打开鉴权并保存空字段。修复需阻止空密钥或生成密钥，再用无 key/错 key/正确 key 的 API 验收。
4. **更新、队列结束动作、多个 Settings 是“可存不能用”。** 禁止把数据模型/Picker 存在当完成；上述更新器、`QueueCompletionAction` 和死字段应接通真实逻辑或从兼容配置中明确迁移。

## 审查边界

全矩阵是对固定源代码和本地源代码的差异审查，不声称上游每一项都经原应用 UI 重跑。我们没有运行上游 desktop app，也没有将浏览器扩展装到浏览器。该扩展源固定到 SHA，但扩展行为与当前 REST 的完整交互仍未做 E2E。小体积原始测试、REST、CPU/RSS、微基准日志及实际取样文件清单见 [evidence/](evidence/README.md)。
