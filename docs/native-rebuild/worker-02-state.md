# Luna-02 状态与持久化修复记录

## 开工回执（2026-10-18）

- 目标：修正状态更新、请求接收、凭据来源隔离和最终文件提交路径。
- 顺序：确认调用链与跨模块接口；实现状态/持久化修复；做静态差异核对并记录风险。
- 范围：仅 TaskCoordinator.swift、StateStore.swift、Models.swift、ProcessDNSResolver.swift 与本记录。
- 基线：分支 `zjx/clean-room-native-rebuild`，HEAD `0f1245261f429bd6378b43603b2a6f45eb263ef3`。
- 工作树已有约200项继承改动；只改分配文件，不重置、暂存或提交。
- 同仓库 Luna-01/03 并行工作；已开始协商 coordinator 生命周期与 transfer generation 接缝。
- 发现：立即开始写 `.preparing` 后被 `canResume` 拒绝；同值设置会重写状态并重配网络。
- 发现：持久化错误后新增任务留在内存；恢复错误分支用 `try!` 打开固定临时状态目录。
- 发现：重定向后持久化最终 URL，却保留原来源认证头；完成校验/文件移动最终回到主线程。
- 限制：不启动 App、不碰日用数据、不运行测试或构建；主代理统一构建与审核。

## 主代理暂停留痕（2026-10-18T12:57:43+08:00）

用户因额度不足要求暂停，本代理已被 interrupt。当前在途修改已保留，未完成交付，未构建/测试；后续先读 PROGRESS.md 暂停交接并核对实际源码。

## 续跑与交付留痕（2026-10-18）

- 恢复前已重新阅读 `PROGRESS.md`、修复计划、发现表和本记录；核对工作树有多人并行的在途改动，未重置、暂存、提交或覆盖其他代理文件。
- 修复设置更新：先复制并规范化 `AppSettings`/分类；相等时直接返回；成功持久化后才按 DNS、代理/连接、全局限速、睡眠策略、全局限速模式、集成服务配置变化触发各自回调。新增 `onIntegrationSettingsChanged: ((AppSettings) -> Void)?`，仅 API 开关/端口/密钥要求/密钥账户改变后触发。
- 修复启动状态：任务先持久化为 `.queued`，再进入 `.preparing`；每次异步恢复信息读取或远端探测后按任务 ID 重新找索引并核对 generation，避免等待期间其他任务删除导致数组索引错位。
- generation 接缝：下载引擎、Range、HLS 回调/启动/暂停/取消显式传 generation；取消、重下、删除、编辑及暂停会失效旧代，迟到事件按 ID+代过滤。取消操作忽略已完成/已取消任务，避免在最终提交收尾窗口把已完成状态改回取消。
- 进度常态按每任务 200ms 节流，达到已知总量时允许立即发布最终进度；全局状态写盘最多每秒一次。进度不发状态事件。新增公开 `TaskStatusEvent`/`TaskStatusEventBatch` 和 `taskStatusEvents(after:)`，保留最近 256 个只含状态转移的事件、sequence 和 gap 标识。
- 添加 `ImportRequestItemResult`/`ImportRequestResult` 与 `importRequestDetailed(_:requestID:digest:)`。每条结果使用原请求 0 基 index；只有任务状态与逐项结果共同落盘后才返回 taskID/accepted；失败项有错误；同 ID+digest 重放读取持久结果；旧 `importRequest` 继续返回 `[Int64]` 以兼容原调用。错误信息替换已知来源 URL 的凭据、查询与片段，避免把来源令牌写进批量结果或任务错误。
- 只读恢复改为打开既有支持目录的只读状态对象，不创建目录、临时状态或进程锁；移除了共享固定临时路径和 `try!` 路径，恢复失败后阻止写状态/启动队列。状态写入改为同目录临时文件、写完设为 0600 后 POSIX 原子 rename；提交前拒绝把状态路径当作符号链接或特殊文件，避免 chmod/rename 前错误已覆盖新数据却被误报为未保存。
- 完成校验、可选摘要和提交复制均在 utility task / `FileCommitter` actor 进行；摘要任务通过取消处理器传播取消。校验包含已知零字节长度。替换保留备份到完成状态成功落盘；事务保留 reservation id、固定目标 reservation path、安装文件 device/inode；目标路径以“解析父目录、保留叶子”方式规范化。rename 避开保留目标；replace/cancel 遇活动 reservation 报冲突；回滚核对安装文件身份，外部替换时不删目标并在错误中留恢复路径。安装失败但内容已校验时保留暂存文件并写出路径；文件状态保存失败回滚后重新核对 generation/任务 ID。
- `ProcessDNSResolver.swift` 已审查，无需修改：DoH 地址仅允许 HTTPS、无用户凭据/fragment，错误路径回退系统 DNS；协调器只在 DNS 设置实际变化后应用。
- 传输接缝已核对 Luna-03 当前 API：`DownloadEngine.start(task:generation:headers:...)`、`pause/cancel(taskID:generation:)`；`SegmentedDownloadService.start(task:generation:...) async throws`，其暂停/取消及回调携带 generation；HLS 调用传 `generation:`。
- 静态核对：`rg` 确认详细导入 API、状态事件/集成配置回调、固定 reservation path、零字节长度检查及 generation 清理点；未找到 `try!`。未运行测试、构建、App、Chrome 或真实下载，未触碰日用数据；这些均留给主代理统一构建及用户手测。
- 最终静态复核：核对暂停/取消/重试的代际失效、启动异步等待后的任务 ID 重查、文件提交 reservation 固定路径及回滚 inode/device 校验、持久化失败后的代际重查、摘要任务取消传播；未发现需要扩张本次边界的额外改动。相关源码仍需主代理做统一编译与跨模块集成核验。
- 接缝修复：针对 Luna-03 将 HEAD 405/501 表示为全未知 metadata（nil 长度/validators、不可用 Range、原始 URL）的事实，Coordinator 现在仅在远端明确返回不同长度或 validator 时报告来源改变；validator 缺失时按无法验证清空续传与 Range checkpoint、更新探测字段并从原 URL 普通 GET。Luna-03 已确认该语义兼容。
- 未解决风险：Swift 编译与跨模块集成尚未由主代理验证；Range 检查点、真实文件替换/回滚、旧数据读取及取消边界均需用户手测。若用户在网络完成、最终校验/提交期间暂停任务，Coordinator 会取消当前文件提交代并保留暂停状态；具体恢复检查点及是否需要重新传输须由手测确认。当前没有需用户处理的代码阻塞，也不声明功能或性能通过。
