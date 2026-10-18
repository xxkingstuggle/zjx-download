# Luna-01 App 修复记录

## 开工回执（2026-10-18）

- 目标：降低启动/菜单栏重复设置副作用，并收敛 App 生命周期中的服务与监视器。
- 范围：仅 `Sources/ZJXDownloadApp/*.swift`（不含 Info.plist、资源和图标）。
- 基线：`zjx/clean-room-native-rebuild`；继承工作树有大量未提交替换改动，保留不重置。
- 约束：不启动 App、不操作 Chrome/现用数据、不运行测试或构建；由主代理统一构建。
- 已读：`PROGRESS.md`、修复计划/发现、机器开发技能、唯一机器政策和 MACHINE_STATE。
- 重点检查：MenuBarExtra setter、服务所有权、监视器取消、任务列表排序及状态观察。
- 初始待确认：App/窗口/协调器间是否存在重复创建或副作用；结论以源码为准。

## 发现与修复

- `MenuBarExtra(isInserted:)` 原 setter 在 SwiftUI 求值期间直接改设置，可能造成重复持久化/刷新；现在 getter 只读，setter 先比较当前值，再投递到 MainActor 并复查后写入。设置页同类绑定也采用幂等延后写入。[AppMain.swift:79](../../Sources/ZJXDownloadApp/AppMain.swift#L79) [SystemIntegration.swift:34](../../Sources/ZJXDownloadApp/SystemIntegration.swift#L34)
- App 原先由 MainWindow 的 `onChange(data.tasks)` 做全数组比较，并在每次进度更新中扫描、排序任务；去掉数组状态事件消费，改用 Luna-02 新增的有界 `taskStatusRevision`/`taskStatusEvents(after:)`。状态通知/声音由应用级 relay 唯一消费，UI 窗口只注册详情窗打开动作；最多暂存 64 个不同的待展示任务，超限写日志。状态历史出现缺口时消费仍保留的事件并写日志。[AppMain.swift:143](../../Sources/ZJXDownloadApp/AppMain.swift#L143) [MainWindow.swift:139](../../Sources/ZJXDownloadApp/MainWindow.swift#L139)
- `tasks` 过滤/排序结果在一次 MainWindow body 求值中只计算一次并复用；分类计数改为单次 reduce 后复用，避免分类列表逐行重复扫描任务数组。[MainWindow.swift:27](../../Sources/ZJXDownloadApp/MainWindow.swift#L27) [MainWindow.swift:34](../../Sources/ZJXDownloadApp/MainWindow.swift#L34) [MainWindow.swift:73](../../Sources/ZJXDownloadApp/MainWindow.swift#L73)
- 速度 Double 转 Int64 前处理非有限值、负数及溢出；进度百分比夹到 0–100；剩余时间拒绝不合理或溢出的估值。[MainWindow.swift:219](../../Sources/ZJXDownloadApp/MainWindow.swift#L219) [TaskDetailViews.swift:219](../../Sources/ZJXDownloadApp/TaskDetailViews.swift#L219)
- 校验任务关闭时原外层任务被取消，但 `Task.detached` 哈希仍运行。现用 `withTaskCancellationHandler` 将取消传给计算任务，并保留 generation 检查，避免旧结果覆盖新窗口状态。[TaskDetailViews.swift:391](../../Sources/ZJXDownloadApp/TaskDetailViews.swift#L391) [TaskDetailViews.swift:411](../../Sources/ZJXDownloadApp/TaskDetailViews.swift#L411)
- 监视器、集成服务器和事件 relay 由 App 创建一次、交由 AppDelegate 在正常启动/退出时 start/stop；窗口关闭不会停止服务。全局限速监视器只在 `backgroundInteraction` 模式安装两秒计时器和 App 活跃状态观察者，切换模式或退出时失效 timer 并移除 token。[AppMain.swift:14](../../Sources/ZJXDownloadApp/AppMain.swift#L14) [SystemIntegration.swift:96](../../Sources/ZJXDownloadApp/SystemIntegration.swift#L96) [SystemIntegration.swift:346](../../Sources/ZJXDownloadApp/SystemIntegration.swift#L346)
- Luna-02 已提供状态事件与限速模式变化接口；根代理确认 Luna-05 需要给 `IntegrationServer` 增加 `@Observable`，并实现 `restart` 幂等/generation 防旧回调。当前 `MainWindow` 已依赖 `@Bindable IntegrationServer`，等该接缝后主代理统一构建；本代理未改 Core 文件。

## 静态核对与剩余风险

- 根据 `.agent-work/performance-repair-20261018/baseline.json` 做了四个自有 Swift 文件的内容哈希与变更行数核对；修改文件仅为 `AppMain.swift`、`MainWindow.swift`、`SystemIntegration.swift`、`TaskDetailViews.swift`，其他任务文件保留。
- 静态检索确认 App 侧已不存在 `onChange(of: coordinator.data.tasks)`、窗口侧 `handleTaskStatusEvents`、旧 `drain` 消费器及第二个 relay 定义；唯一状态消费者常驻于 App 生命周期，状态事件来源为 Luna-02 的 bounded API。
- 本代理未启动 App/Chrome、未碰现用数据、未运行测试或构建；按分工由主代理统一构建。功能与运行性能仍需用户手测/运行观察。
- 剩余风险：事件生产 API 仅保留 256 个状态转移；主线程极端长时间被阻塞可能出现缺口，relay 会记录并消费保留事件，但已丢弃的历史转移无法重放。详情窗口暂存最多 64 个任务，超限保留最新请求并写日志。系统是否允许已关闭主窗口的 SwiftUI `OpenWindowAction` 再开详情窗，需主代理/用户手测确认。
- 构建接缝：Core `IntegrationServer` 尚待 Luna-05 改成 `@Observable`、幂等 restart 并过滤旧监听回调；当前为明确待接缝，不宣称编译通过。
