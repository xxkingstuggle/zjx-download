# 修复发现与证据

日期：2026-10-18。证据为当前源码和此前用户报告/只读历史日志。这里不声明功能或性能测试通过。

| ID | 优先级 | 当前证据 | 责任 | 验收关注 |
| --- | --- | --- | --- | --- |
| R-01 | P0 | AppMain菜单栏绑定→TaskCoordinator.updateSettings无新旧值判断，先改可观察data、同步写JSON并重设DNS/限速/网络；历史日志重配置每2–4ms；循环具体入口尚待确认 | 01/02 | 空任务启动，菜单栏切换、同值保存不反复写盘 |
| R-02 | P0 | add(startImmediately)存preparing，紧接startTask仅允许canResume(queued/paused/failed)，立即开始被拒绝 | 02 | 手工、Chrome静默、队列立即开始 |
| R-03 | P0 | TaskCoordinator读取失败时try!建立固定临时目录StateStore；锁冲突/不可写可再次崩溃 | 02 | 数据损坏、另一实例时只读恢复、不覆盖原数据 |
| R-04 | P0 | completeTransfer异步校验后commitFile仅按id找任务；缺取消/重下世代校验，迟到回调可覆盖新状态 | 02/03 | 校验/合并中暂停、取消、删除、重新下载 |
| R-05 | P1 | 每个网络didWriteData建主线程Task，updateProgress多次改整份data.tasks，界面全量filter/sort/onChange比较 | 01/02/03 | 快速多任务传输下列表响应、状态事件只发一次 |
| R-06 | P1 | @MainActor Range.merge循环读写MB块；非稀疏预分配写零、commitFile搬移/替换也在主线程 | 02/03 | 大文件合并、外置盘落盘及取消响应 |
| R-07 | P0 | add把remote.finalURL保存为source，却保存原请求credentialHeaders；后续可直接向重定向目的来源发原凭据 | 02/03 | 跨host/端口/scheme重定向凭据隔离 |
| R-08 | P0风险 | DownloadEngine为@MainActor，URLSessionDownloadDelegate以@preconcurrency适配，但使用自定义非主delegateQueue；需审查隔离/共享字典 | 03 | 所有回调线程、临时文件在delegate返回前保留 |
| R-09 | P0 | app-api.decodeAcceptance无法识别回复时return accepted:true；native ping未检查content.isError | 04 | 畸形/错误/空回复不得接管或显示已连接 |
| R-10 | P1 | Chrome.submit用items.length显示接收数量，REST/add只回OK，无法表明部分失败 | 02/04/05 | 部分接受的ID/数量、取消Chrome仅对应成功单项 |
| R-11 | P1 | CLI通用请求4s，但/add可等用户确认；收到拒绝JSON未视为失败，随后GET/tasks猜全局最大ID | 05 | 并发添加/拒绝/长确认无错ID假成功 |
| R-12 | P1 | IntegrationServer.listener状态闭包捕获server自身；Content-Length被min截断，累计body有界性/超时不完整，未校验浏览器Origin | 05 | 启停无泄漏、畸形/超大/跨站请求拒绝 |
| R-13 | P1 | ExchangeCodec 导出反斜线换行的 cURL，InputImport 逐行只读取 curl 开头行，后续 -H 和认证丢失；正则也不能还原 shell 单引号转义 | 主代理 | 多行/引号/认证/名称往返，不执行 shell |
| R-14 | P1 | 批量范围 end-start+1 可 Int 溢出，补零宽度无上限 | 主代理 | Int.max 范围/极大补零不崩溃、不分配巨量字符串 |
| R-15 | P0 | 更新器只把候选团队与远端清单比较，未绑定当前 App；rollback 使用 zsh 只读 status 变量，错误分支会再次失败 | 主代理 | 团队/图标不符拒绝，替换失败保留旧 App |

| R-16 | P1 | 主窗口关闭后菜单栏只寻找旧NSWindow、新建/导入和quit只发窗口通知；设置页改API配置也仅由主窗口onChange重启 | 主代理/02 | 显式命名窗口入口、App级API配置与退出处理、Chrome确认可重开主窗 |

| R-17 | P0 | background.js使用顶层ES import，构建只拷贝文件，而manifest未声明background.type=module，Chrome按classic worker解析将无法启动 | 主代理 | MV3模块类型与源文件一致，加载扩展后无service worker模块解析错误 |

每个worker完成后在各自记录补充新发现、修复和未关闭项；主代理统一更新本表。功能与性能的最终结果由用户手测填写。
