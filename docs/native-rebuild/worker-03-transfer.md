# Luna-03 传输模块修复记录

## 开工回执

- 日期：2026-10-18；任务：启动/下载正确性修复中的传输模块。
- 仓库：`/Users/zjx/Developer/repos/zjx-download`；分支 `zjx/clean-room-native-rebuild`；HEAD `0f1245261f429bd6378b43603b2a6f45eb263ef3`。
- 继承工作树已有约200条未提交改动；单 worktree、stash为空；不重置、不提交、不改分支。
- 已读 `PROGRESS.md`、修复计划/发现、机器开发技能及唯一机器政策和 `MACHINE_STATE.md`。
- 独占修改 `DownloadEngine.swift`、`SegmentedDownloadService.swift`、`HLSService.swift`、`NetworkConfiguration.swift`。
- 原实现快照：`.agent-work/performance-repair-20261018/baseline.json`；仅用于本任务差异核对。
- 当前证据：单下载 delegate 标注为主线程隔离却使用自建队列；进度逐回调创建主线程任务并等待限速；Range 合并/预分配同步执行。
- 当前证据：Range 检查 Content-Range、长度和 validator，但缺少跨 scheme/host/port 的完整来源比较；HLS 与重定向同样只比较 host。
- 不启动 App、不触碰日用数据、不下载、不运行测试或构建；由主代理统一构建并审核接缝。
- 下一步：为回调贯穿任务 generation，修复有界回调、文件保留/取消时序、Range 异步合并与来源凭据隔离，再做静态核对。

## 发现与实施

- `DownloadEngine` delegate 继续用单独的串行 `OperationQueue`，URLSession 回调保持 `nonisolated`；delegate 共享的会话认证策略由锁保护。`didFinishDownloadingTo` 先在回调返回前将 URLSession 临时文件移动到私有 staging，再回 MainActor 检查代次和来源，避免系统临时文件先被清理。
- 单流进度由线程安全 mailbox 合并字节增量并保留最新快照；每代最多一个 MainActor drain，UI 进度最多每 100ms 发一次，完成进度可立即发出。暂停和 session 收尾取消该代 drain；限速等待用可取消的 `Task.sleep`，避免暂停后留下长睡眠任务。
- HTTP HEAD 返回 405/501 时只返回未知长度、无 validator、`supportsRanges=false`，文件名只从原始 URL 推断，`finalURL` 保持原 URL；错误响应的 Content-Length、ETag、Last-Modified、Content-Disposition 和 Content-Type 不作为资源事实。Coordinator 创建任务时保留原始 `sourceURL`，之后走普通单流 GET，不启 Range。
- 单流启动保存本代的恢复标记、预期长度及强 ETag/Last-Modified。普通请求的 HTTP 206 一律拒绝；恢复请求的 206 要求 Content-Range 格式有效、末端到达全文件末尾、已知总长完全匹配、可见的原始 Range 起点匹配、Content-Length（若有）等于区间长度，且 URLSession 暂存文件长度等于 Content-Range 总长。200 响应同样核对 validator 和实际暂存长度；`expectedLength == 0` 也执行精确比较。
- Range preparation 和合并运行在可取消的 utility detached task；分段目录有代次标记和目录锁。新一代 start 等旧清理完成，删除仅按旧代 marker 清理。URLSession 分段临时文件在 delegate 回调内移到 app-support `staging/` 下唯一 transient path（目录 0700、文件 0600），只有仍是当前代才安装成 segment；回调返回后清理 transient。预分配/零填充不占主线程，填充和合并按块检查取消。
- Range 继续要求每个响应为匹配请求的 206 与完整 Content-Range；比较可用的 Content-Length、实际分段长度及强 ETag 或 Last-Modified，并发送 If-Range。服务器返回 200 时走单流 fallback。
- HLS 入口接受 `generation` 并将代次传入恢复 journal；分段临时文件带随机名并在写完后原子 rename。连接池取消可退出等待 continuation，限速睡眠响应 Task cancellation，进度聚合按 100ms 节流。manifest/header 与分段凭据按 scheme、host、有效 port 来源隔离；跨来源重定向剥离 Authorization、Cookie、Proxy-Authorization、Set-Cookie，并拒绝 HTTPS 降级。
- `NetworkConfiguration.hasSameOrigin` 与移除凭据辅助函数统一处理 scheme、host、默认/显式 port；`DownloadEngine` 和 `SegmentedDownloadService` 重定向处理接入同一来源规则。

## 静态核对与剩余风险

- 已静态检查四个负责源码文件的 start/pause/cancel 和 HLS 调用签名、`TaskCoordinator.swift` 的 generation 调用点、delegate 回调/文件 staging 顺序、Content-Range/长度/validator 分支、重定向来源比较及清理任务。未修改 Coordinator；跨模块签名与 Luna-02 对齐：
  - `DownloadEngine.start(task:generation:headers:settings:resumeData:speedLimitBytesPerSecond:proxyPassword:)`；`pause(taskID:generation:)`、`cancel(taskID:generation:)` 均支持可选代次；所有进度、暂停、完成和失败回调携带 generation。
  - `SegmentedDownloadService.start(task:generation:headers:settings:speedLimit:proxyPassword:) async throws`；`pause(taskID:generation:)`、`cancel(taskID:generation:deletePartial:)`；进度、暂停、完成、失败和 Range fallback 回调携带 generation。
  - `HLSService.download(... runtimePolicy:generation:progress:)`，默认 generation 为 0 以兼容旧调用，Coordinator 显式传入当前代。
- 本轮没有运行测试、构建、App、Chrome 或真实下载；行为未验证，仍待主代理统一构建和用户手测。
- 主代理接缝待集成：Coordinator 对已有续传任务重验时，当前会把 probe 返回的 nil ETag/Last-Modified 当作来源变化。HEAD 405/501 已返回未知元数据并关闭 Range，但如果旧任务带 validator 和已下载字节，Coordinator 仍可能失败而不是清除续传状态后从原 URL 普通 GET；Luna-02 已确认负责该分支，本代理按文件边界未改 Coordinator。
- 已知残余：macOS `F_PREALLOCATE` 本身是单次同步系统调用，虽已移到 detached utility worker，调用中途不可协作取消；不再占 MainActor。Range Content-Range 使用严格规范化格式比较，格式异常的服务器响应会失败而不会拼接。HLS checkpoint 在格式损坏或超过 64 MiB 时会重新建立私有缓存；最终下载文件不受该清理影响。
- 下载行为、恢复、错误页 HEAD 回退、206 恢复、限速暂停、跨来源凭据隔离和 HLS 取消状态仍全部待用户测试，不标记通过。

## 主代理暂停留痕（2026-10-18T12:57:43+08:00）

用户因额度不足要求暂停，本代理已被 interrupt。当前在途修改已保留，未完成交付，未构建/测试；后续先读 PROGRESS.md 暂停交接并核对实际源码。

## 恢复交付记录（2026-10-18）

- 按暂停交接先复读 `PROGRESS.md` 和本记录，核对四个负责文件的现状后续改，未覆盖他人接线。
- 已补齐 progress drain 生命周期、单流 206 全资源长度/validator 校验、HEAD 405/501 元数据回退，以及 Range 私有 staging 文件权限；其余接口/取消/后台 I/O/跨来源处理做了静态复核。
- 本子任务源码和静态记录已交付给主代理；Coordinator 的 HEAD 不支持续传接缝需由主代理或02处理。没有运行测试、构建或 App。
