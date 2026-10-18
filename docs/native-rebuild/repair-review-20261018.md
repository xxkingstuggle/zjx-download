# 2.0.1 修复集成审核记录

## 范围与证据边界

- 任务书：repair-plan-20261018.md；证据索引：repair-findings-20261018.md。
- 实施：5 个 Luna 分批负责互斥源码，主代理负责接缝审查、输入导入/更新安装器、构建与交付。
- 当前阶段：5个Luna全部交付；主代理已完成接口/取消/回执/期限与文件提交接缝审核、统一编译修复、构建签名和安装。现安装2.0.1/build20261018.2；功能/性能未验收。
- 没有运行 App、Chrome、真实下载或功能/性能测试；用户报告的卡死根因链仍需手测/现场堆栈确认。
- 不修改现用数据；开发开始前记录 state-v2 和 legacy state 的哈希，只供安装后比对，不复制数据内容到源码。
- 继承约200项未提交修改，保留原样；本次源文件快照在忽略目录 .agent-work/performance-repair-20261018/baseline.json，仅供差异审核。

## 主代理独立修复

1. InputImport：将续行合并后按 shell 引号分词（仅解析、从不执行），支持本项目 cURL 的 URL、请求头、Basic 认证、User-Agent、Referer、输出名。未闭合引号、不支持方法/参数、shell 操作明确失败；不把 header 中的网址误当下载地址。ExchangeCodec 同步输出 -o 名称。
2. 批量范围：先用 end-start 上限判定，避免 +1 溢出；补零位数限制 0…64，模板必须含 *。
3. 更新器：候选必须与已安装 App 的 Bundle ID、签名团队和 AppIcon.icns 原字节一致；修复 zsh rollback 对只读 status 的赋值。
4. ChecksumService：每块读取前检查 Task 取消，由 App 侧取消传入的独立摘要任务，关闭窗口后停止无用 I/O。

5. 关闭主窗口后的入口：菜单栏与快捷键改用命名Window/WindowGroup；新建和导入有独立原生窗口；API设置变化由Coordinator成功保存后的回调交给App级服务；quit与Chrome确认由App级订阅处理。

6. Chrome背景脚本是ES模块，但manifest原先缺type=module；现已补齐，并在已有Chrome构建入口校验身份、配套版本和module声明，避免仅拷贝成功冒充可加载声明正确。依据：[Chrome service worker基础文档](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics)。

## 接缝审核

- 01/02：App 级唯一生命周期与同值设置；有界状态事件的消费者不能只依赖主窗口存在；摘要取消传播。
- 02/03：所有传输回调显式 generation；异步准备、合并、摘要和最终提交在取消/删除/重下后不复活旧状态；暂存文件按代次隔离。
- 02/04/05：逐条持久化结果、0基原请求索引、真实任务 ID、相同请求重放；部分失败不能整体伪报成功。
- 01/05：共享 IntegrationServer 的可观察状态、幂等 restart、旧监听器回调过滤。

- 补充审核：详细导入的同ID并发请求先等待当前进程的inFlight结果，再查持久化幂等记录；避免第一请求只写占位时，回退请求拿到“不确定未接收”的中间结果。旧状态重启后的不完整记录仍明确标记未确认，不假接受。

- 超时与取消：Coordinator审批continuation可按reviewID取消，API超时/重启会取消本次import work；循环保留已持久化项，未开始项记录取消；同ID重放仍有真实逐项结果。并发导入最多32项，活动幂等记录不因TTL清理；旧部分记录缺原位置时不推测索引来授权取消Chrome。

## 必要构建

- 干净构建路径：/Users/zjx/Developer/scratch/codex/zjx-download-repair-20261018.2/DerivedData。
- Xcode：`xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' -derivedDataPath <以上路径> CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64' build`；最终exit0 / BUILD SUCCEEDED。只剩AppIntents元数据跳过提示，本产品未使用该框架。
- SwiftPM：`swift build -c release --product zjx-download-cli --arch arm64 --scratch-path <scratch>/cli-arm64`及x86_64，各exit0，lipo合并并签名。
- Chrome：`npm --prefix browser-extension run build:chrome` exit0；6个源JS和build脚本node --check exit0；zsh -n、git diff --check通过。
- 编译迭代如实保留：attempt1进度Task推断Void?；attempt2有效端口switch缺return；attempt3后台清理捕获非Sendable Transfer；attempt4 HLS参数顺序和URL可选值；attempt5构建成功，随后移除无效@preconcurrency/未用返回值警告后final再次成功。没有同一错误连续3次失败。
- 签名首次因Helpers中的shell脚本未签而拒绝；为两个脚本分别签名后重新签App，严格deep校验成功；未安装失败候选。
- 构建日志：发布目录build-logs/，scratch保留完整中间输出。构建成功不等于功能通过。
- 安装2.0.1/build20261018.2，主可执行SHA-256 `7a530c63978f456775831d2acc476a412421e5fca3559392c60ca807df8a402c`；Team ZNSTKHPLY3；icns SHA-256 `6c3c9a8bc60b45d62a640ca15a79bc4d75ea91b0d990f88bed1906216c93d122`。
- 安装前未发现App/Host进程；旧App原包移入archive/20261018-pre-repair-20261018.2/。新包复制到Applications暂存并验签后更名安装，保留回退。没有启动App。
- 现用两份状态文件哈希与源图标8文件前后一致；既有Chrome host注册只读核对，无迁移/全局依赖/PATH/服务变更。

## 知识收尾

| 主题 | 权威来源 | 当前源码 | 运行态 | 文档/规则 | 处理 |
| --- | --- | --- | --- | --- | --- |
| 卡死与下载正确性 | 本次代码/用户反馈/历史日志 | 已修复并编译 | 待用户验收 | 计划和发现已同步 | 5 Luna 已交付，主代理已审核 |
| 发布安装身份 | 新构建产物和安装包 | 已构建签名 | 已安装build20261018.2，未启动 | 已同步交付 | 保留旧包后安装，不启动验收 |
| 用户验收 | manual-test-checklist / test-result-template | 适用 | 全待用户测试 | 已增加 A-054…A-067 | 不冒称通过 |
| 原规格/反向证据 | docs/clean-room-rebuild 与 reverse-analysis-evidence | 只读保留 | 不适用 | 不修改 | 沿用用户任务书 |
| 记忆 | Codex 生成记忆 | 不适用 | 只作历史线索 | generated-read-only | 未获显式记忆写入授权，未改 |
| 工作区证据 | baseline / worker 记录 / 构建日志 | 保留 | 不适用 | 不清场 | 未删除继承文件或诊断现场 |

## 主代理集成补充

- HLS调用位置已与03的generation参数契约对齐；后台清理只捕获Sendable路径和代次，进度Task明确Void返回。所有源变化均纳入最后一次App和CLI构建。
- App、Native Host和Framework只使用系统/相对@rpath依赖，无ABDownloadManagerCore残留；四个Mach-O产物均核对x86_64+arm64。
- 功能未实现项（本次修复任务）：未发现遗留；运行验证项仍全部待用户测试，包括Chrome关联歧义采取保留/恢复浏览器下载、跨进程超时的不确定交接提示、关闭主窗口后系统呈现。

## 2026-10-19 Git与治理更新

- 用户新授权提交并推送origin任务分支；此前文档中的“未提交/不push”为当时状态，不再约束此次同步。
- 项目规则入口AGENTS.md指向唯一机器政策，保留数据、用户手测与身份边界；不复制或改写全局政策。
- 全局托管技能/入口只读核对：0文件需同步，ALL MANAGED SKILL CHECKS PASSED。
- 不提交构建缓存、发布包、.agent-work或日用数据；发布与旧App/source归档保留。未执行清场、功能测试或全局环境变更。

- 暂存全量差异检查提示原规格/反向证据中既有Markdown行尾空格及末尾空行（原字节与归档核对一致）；遵循不可改原文要求保留。新增实现与本轮说明单独差异检查通过，未把原文警告称作全量无警告。
