# Luna-04 Chrome 修复记录

## 开工回执（2026-10-18）

- 目标：修复扩展错误接收确认、Chrome 自动接管误取消、请求关联错配和权限撤销后仍捕获。
- 范围：仅 `browser-extension/src/` 与 `browser-extension/scripts/`；图标、公钥、manifest身份不变。
- 基线：`zjx/clean-room-native-rebuild`，HEAD `0f1245261f429bd6378b43603b2a6f45eb263ef3`；保留继承的未提交改动。
- 当前实现版本预置为2.0.1；实际构建和语法检查由主代理统一执行。
- 风险优先级：只有与请求逐项匹配的持久接收结果才能取消对应Chrome下载；模糊/超时状态不推断成功。
- 跨模块依赖：02的 `importRequestDetailed` 逐项结果和05的 HTTP/Native JSON 响应须按同一 `requestId` 契约对齐。
- 本任务不启动App/Chrome，不操作现用数据，不做功能、下载或性能测试。
- 开工下一步：实现严格接收解码、部分接受映射、捕获事件精确关联、有界状态和权限撤销清理。

## 发现与实现

- `app-api.js` 的 HTTP 接收响应现在必须是有效且自洽的逐项回执：匹配 `requestId`、完整唯一的 0 基 `items[].index`、正安全整数 `taskID`、非空失败原因，并且 `acceptedTaskIDs`、`acceptedCount`、`accepted` 与逐项结果一致。缺字段、重复索引／任务ID、错序ID或不一致都视为未知，不默认接受。
- Native ping 检查外层 ID、`content.isError === false` 和 `pong`；Native add 先检查同样的外层ID及错误标志，再解码 `content.payload`。HTTP 与 Native fallback 共用同一 `requestId`。HTTP业务JSON不带传输字段；Native payload 的 `options.apiPort/apiKey` 供 Host 使用，符合 Luna-05 契约。请求设置读取、HTTP和Native等待均受总时限约束；Native调用超时仅停止等待，可能仍在 App 内完成，自动接管对此按不确定状态恢复Chrome并提示。
- `background.js` 只在 webRequest 收到响应时登记下载候选；等真实 `downloads.onCreated` 到达，再按 URL、referrer、请求时间和唯一候选筛选具体 DownloadItem.id。相同URL/referrer的多候选或多下载、缺少可用时间戳、并行同源下载和状态查询异常均失败开放并保留Chrome项。暂停前重新核对目标ID和未暂停状态；只有App对单项返回可验证 taskID 并将 `accepted` 标记写入 session 后，才取消该ID。
- 对暂停、提交、接受和恢复持久化最小 session 标记（downloadId、requestId、状态、时间）。未知接收状态只尝试恢复Chrome并提示用户，不自动取消；`pauseRequested` 不能证明暂停由扩展执行时不自动恢复。暂停API拒绝与用户手动暂停存在竞态时保留手动处理标记，不猜测暂停所有者。无URL、认证头、Cookie等敏感内容写入session。
- 自动捕获候选、下载事件、请求头、HLS请求、待交接及候选面板均有容量／时限界限。HLS及常规媒体候选按原始请求tab/frame送达；下载块不作为媒体候选；面板更新合并到250ms窗口。网站权限或webRequest权限撤销会停止捕获监听；Cookies权限撤销会清除凭据缓存、剥除页面候选中的Cookie并取消待处理HLS读取，非Cookie媒体/下载发现仍按其单独授权继续。请求头开关关闭会清除所有缓存认证头，网站授权撤销会清除候选。
- MV3 的 webRequest 和 downloads 轻量监听器在 service worker 顶层同步注册；回调先等待设置与交接恢复结果，再按最新权限和配置执行。解决了仅在异步恢复完成后才注册监听器、可能错过唤醒首个事件的问题。
- 手动发送认证仅在同一tab、frame、完整规范化URL、GET及30秒窗口中唯一匹配缓存时使用；歧义时明确提示用户到App补充请求头或选择对应资源。Cookies仅在请求头开关及Cookies权限有效时发送；授权丢失会从页面缓存媒体候选中移除Cookie。
- 清理了 `zjx-selection` runtime message 发送后不回包导致消息通道悬挂的问题；配置消息只回传授权状态，不携带未请求的响应正文。

## 静态审核与交接

- 触发链：service worker 求值时同步注册；`onBeforeSendHeaders` 有界缓存候选认证头；`onHeadersReceived` 过滤并登记文件／媒体候选；`downloads.onCreated` 记录实际下载ID；匹配唯一候选后复查并暂停该ID，执行有同一requestId的 HTTP→Native 接收；严格回执后写 `accepted` 状态并取消对应Chrome项。错误、拒绝、超时、权限变更和worker恢复分支均保留或恢复Chrome并提示。
- 静态检查结论：逐项接受解析会拒绝未知回执；部分接受以服务端原始输入index和真实taskID映射；仅显式单项持久接收可进入自动取消路径。捕获候选按tab/frame作为来源并向对应frame送媒体数据；无法从Chrome DownloadItem取回webRequest requestId/tab/frame，因此URL/referrer/时间关联若有任何可见歧义即不接管。
- 并发风险修复：旧候选到达时会对最近最多300条下载事件逐个调用 `downloads.search`；现先在内存中筛出唯一时序候选，仅查询一个精确ID。接受中的Chrome取消也计入并发上限，避免接受回执后Chrome查询挂起时无限积累任务。
- 启动性能修复：之前每个唤醒期间的webRequest/download事件都会调用刷新函数并递增配置generation；首轮刷新慢时，事件洪峰会让刷新重复执行、重复广播和注入页面。现在事件共享同一个刷新Promise，等待者最多300个，超额事件安全跳过。
- 配置写入收敛：`getEffectiveConfig()` 在异步持久化前保留并返回本次计算的局部配置对象，避免 `storage.onChanged` 并发清空全局缓存后返回 `null`。`saveConfig()` 只写值有变化的键，减少无变化配置写入引发的事件和覆盖无关设置的窗口。
- 接缝：HTTP/Native 接收回执与 Luna-02/Luna-05 已约定结构对齐；Native Host 使用 `content.payload.options.apiPort/apiKey`，HTTP只发 `X-API-Key`。JS将服务端Int64任务ID要求为安全整数；更大ID会拒绝并保留Chrome项。`content.isError` 缺失或为true不会被视为接受。
- 剩余限制：Chrome DownloadItem没有来源的webRequest requestId、tabId或frameId；极窄的同URL、同referrer、同时间窗口请求竞态不能做到协议级精确绑定，代码采用多候选/并行检测并失败开放。`chrome.storage.session`保证service worker生命周期内恢复标记；完整浏览器退出可能清空session。暂停API拒绝与用户同时手动暂停无法可靠辨别时，扩展保留暂停并提示人工处理，避免误恢复。
- 未运行App、Chrome、真实下载、功能测试、构建、Node语法检查或故障注入；这些由主代理统一验证。不能据此宣称扩展功能通过。主代理下一步：审核差异并运行统一构建／语法检查；将上述竞态、重启恢复、接受／拒绝／超时、权限撤销、手动认证与部分接受写入用户手测表。
