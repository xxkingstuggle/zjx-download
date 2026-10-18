# Luna-05 桥接与 CLI 修复记录

## 开工回执（2026-10-18）

- 目标：修正 HTTP/Native/CLI 的请求边界、幂等接收结果和就绪语义。
- 顺序：核对 02/04 契约；加固单一集成服务；对齐 Native Host 与 CLI；静态核对风险。
- 范围：仅 IntegrationServer.swift、NativeHostProtocol.swift、NativeHost.swift、CLI main.swift 与本记录。
- 基线：分支 `zjx/clean-room-native-rebuild`；继承改动很多，本轮只改分配文件，不暂存/提交。
- 已确认：服务未标记 `@Observable`，监听状态闭包自持有旧 listener；HTTP 长度被截断接受。
- 已确认：`/add` 只回 OK，Native Host 把无效 JSON 降级为空对象且错误一律当 App 不可用。
- 已确认：CLI 4 秒超时、忽略拒绝并用全局最大任务 ID 猜本请求结果。
- 接缝：02 提供 `importRequestDetailed` 与同步 `cancelImportRequest(requestID:)`；04 已确认结构化回执、Native 传输字段与 HTTP header 契约。
- 限制：不启动 App/Chrome、不访问日用数据、不跑测试或构建；主代理统一审核构建。

## 实施记录

- `IntegrationServer` 已使用 Observation，并保持配置相同的 `restart` 幂等；监听回调按 generation 过滤旧 listener，停止、重启、连接超时和客户端断开都会关闭自有连接、计时器并取消对应导入请求。
- HTTP 只绑定 `127.0.0.1`，校验 Host 端口和受信任扩展 Origin；允许无 Origin 本机客户端。请求解析设定头部、请求体、总连接数、请求超时和导入超时上限，拒绝重复头、错误/重复/负数/超限 Content-Length、截断请求、额外请求字节及 Transfer-Encoding。
- `/add` 使用 `requestId` 回执和逐项结果。body/header ID 同时存在时必须一致；旧客户端缺少 ID 时生成 UUID 并回传，空白或非法的显式 ID 返回错误。摘要使用排序 JSON，并忽略 `options.apiKey` 与 `options.apiPort`；转入 Coordinator 的业务 payload 不含这两个传输字段。
- 导入等待超时后先取消 route Task，再同步调用 `cancelImportRequest(requestID:)`，由 Coordinator 保留真实已持久化项目结果并停止未接收项目。拒绝和 API 错误保留 requestId 与错误类别。
- Native Host 对请求帧（本项目输入上限 4 MiB；不是 Chrome 的入站平台上限）、JSON、动作、request ID 与端口进行验证；发往 Chrome 的回复上限 1 MiB。Native 认证读取 `content.payload.options.apiPort/apiKey`，向 App 只发送 `X-API-Key` header，并从业务 body 移除 apiKey/apiPort。认证/API 拒绝不会触发“App 未运行”重启路径；Native 成功需核验外层 ID 和结构化逐项回执。
- 单次 `/add` 上限对齐 1,000 项。按 160 UTF-8 字节截短每项错误信息，使结构化回执保持有界。
- CLI 导入等待上限为 130 秒，校验 requestId、acceptedCount、逐项 ID 后打印本请求任务 ID；拒绝或错误会以非零状态失败，不再推测全局最大 ID。`--start` 通过单项 `startDownload` 传给 Coordinator。`gui start-if-not-started` 仅在 POST `/ping` 实际返回 `pong` 后报告 ready；认证失败不会再次打开 App。
- 已在统一 `X-Request-Deadline-Ms` / `options.requestDeadlineMs` 契约中闭合 `/add` 的期限：HTTP 可从 body 或 header 读取，二者同时给出必须相同；拒绝无效、非整数或过期值。仅 `/add` 将绝对毫秒期限传给 Coordinator，路由计时器取 125 秒与剩余期限的较小值。`requestDeadlineMs`、apiKey、apiPort 在转入任务业务和 canonical digest 前移除；Native 回退通过相同期限 header 发送，并将每次探活/HTTP超时限制在剩余预算内。
- Native Host 在过期请求时不唤起或转发 App；探活后、唤起后、等待就绪时和最终转发前均重查期限。无期限的旧 CLI/Native 请求继续使用现有服务端 125 秒默认导入上限。`/start-headless-download` 不支持该 body deadline 字段。
- 新增连接响应启动标志，防止服务端超时响应与被取消的 route Task 后续响应在同一 socket 上重复写入；正在发送响应的连接由其 send completion 关闭。
- 修复静态核对发现的请求解析编译问题：先构造完整 body，再提取 requestId 与检查 Host/Origin。

## 静态交接

- 已核对 04 的确认契约：HTTP body 为 `{requestId,items,options:{silentAdd,silentStart}}`，API key 只在 `X-API-Key`；Native `content.payload` 包含同一业务字段及连接用 `options.apiPort/apiKey`，外层 `id` 等于 requestId。Native Host 转 HTTP 时去掉传输字段；04 的 Native ping 也使用一致的 requestId。
- deadline 接缝：04 在 body `options.requestDeadlineMs` 携带同一绝对毫秒值；Native Host 删除该 transport option 后以 `X-Request-Deadline-Ms` 转给 HTTP。服务端摘要忽略期限字段，HTTP 与 Native 回退同 requestId 的下载业务不会因 transport 形态冲突。
- 兼容边界：没有 requestId 的旧 HTTP `/add` 请求仍接受并收到服务器生成的回执 ID；这种旧请求无法在调用方跨重试保证幂等。需要可靠回退/去重的客户端必须复用自己的 requestId。
- 本代理未运行测试、构建、App 或 Chrome，也未触碰现用数据。由主代理统一做静态审核与构建；功能行为仍待用户手测。尚待主代理确认源码语法、项目集成和产物体积等构建期事项。
- 本次续跑同样未运行测试、构建、App 或 Chrome，未操作现用数据；源码编译、跨模块集成与功能行为均待主代理静态审核/构建及用户手测。

## 额度恢复续跑回执（2026-10-18）

- 目标：闭合 Chrome 总 deadline 与服务端导入审批之间的期限接缝。
- 顺序：HTTP 解析/幂等摘要；Native Host 预检、启动等待与转发预算；静态核对。
- 范围仍限 IntegrationServer、NativeHostProtocol、NativeHost、CLI 与本记录。
- 已核对主代理 `/add` deadline 字段契约：绝对毫秒、body/header 一致，服务端把 Date 传入 Coordinator。
- 继承源码发现一个编译问题：请求体变量在首次引用后才声明；一并修复。
- 并行状态：沿用 zjx/clean-room-native-rebuild 共享工作树；只修改本代理文件，不覆盖邻居改动。
- 限制：不运行测试/构建，不启动 App/Chrome，不触碰现用数据；主代理统一验证。
