# 启动卡死与下载正确性修复任务书

执行者为 5 个 Luna，主代理负责集成审核。本书及用户已确认任务约束为实施依据。中断先读 PROGRESS.md 和各自 worker 记录；只修改分配文件，不覆盖其他人的改动。

这次要使空任务启动没有重复配置回写，任务开始/暂停/取消与文件结果一致，Chrome/CLI 只对真实持久化接收给出成功。优先级：用户数据与文件正确性 > 功能 > 响应与原生体验 > 简洁。

## 事实、假设与边界

2026-10-18：分支 zjx/clean-room-native-rebuild，HEAD 0f124526；约200条继承的未提交改动，单 worktree、无 stash。当前安装为2.0.0/build20261018.1；此前干净 Release 构建成功，功能未验收。用户报告空列表启动卡死；此前只读统计为0任务、5.6KB状态，历史日志同进程每2–4ms重复DNS配置。

已确认代码缺陷及来源见 repair-findings-20261018.md。菜单栏绑定是循环入口的候选，尚无卡死堆栈；不能把候选当实测根因。只补 NSApp 空指针不能消除状态回写和I/O耦合。

沿用用户决定：macOS26+Chrome；名字、com.zjx.download和图标不变；不删任务、设置、凭据、下载文件；不执行现用数据迁移。只做静态审查、必要构建和语法检查；不启动App、操作日用Chrome、跑功能/下载/故障注入/性能测试，不新增自动化测试。功能验收由用户填写。不push、不装全局工具。

## 任务0与协作

先读机器政策、MACHINE_STATE、PROGRESS；核对分配文件当前内容，写≤10行开工回执到自己的worker记录。原实现快照仅供diff，在.agent-work/performance-repair-20261018/baseline.json。旧规格和反向证据只读。

主代理独占README、PROGRESS、BLOCKED、Xcode/Package配置、手测表和发布安装。5个子代理分两批，文件边界如下；新增跨模块API先通知主代理，不自行改邻居文件。不得运行App或改真实数据；不得提交、切分支、撤销继承改动。

## 实施顺序与落点

1. Luna-01：Sources/ZJXDownloadApp/*.swift（不含Info/图标）。让菜单栏绑定幂等且避免渲染期间重配置；服务与监视器由应用生命周期持有、启动/停止一次；减小列表和状态事件的刷新范围。审核其他原生入口的重复副作用。记录worker-01-app.md。
2. Luna-02：TaskCoordinator.swift、StateStore.swift、Models.swift、ProcessDNSResolver.swift。先在副本归一化设置，没变化不发布/写盘，按字段差异应用网络配置；修复立即开始被canResume拒绝；节流进度、保护取消/删除后的迟到完成与重试；只读恢复不try!崩溃、不写临时共用状态；持久化失败不假接收；最终落盘重I/O移出主线程并保持覆盖回退。记录worker-02-state.md。
3. Luna-03：DownloadEngine.swift、SegmentedDownloadService.swift、HLSService.swift、NetworkConfiguration.swift。审核delegate执行线程、回调世代、Range长度与版本校验；把合并/预分配移出主线程、可取消；限速与进度任务有界；跨来源不泄露认证，暂停/取消无迟到完成复活。记录worker-03-transfer.md。
4. Luna-04：browser-extension/src与scripts。接收解码失败必须失败；Native ping核对isError；只有明确接收后才取消Chrome下载，部分接受按实际数量；请求ID在回退中保持一致；缓存/监听器有界，权限失效及时停止捕获。图标、公钥、manifest身份不变。记录worker-04-chrome.md。
5. Luna-05：IntegrationServer.swift、NativeHostProtocol.swift、ZJXDownloadNativeHost/NativeHost.swift、ZJXDownloadCLI/main.swift。严格请求大小/长度/超时和来源校验；监听器无自持有、旧回调不污染新状态；/add回复包含真实任务ID和数量，保留必要OK兼容；CLI不猜最大ID，不把拒绝或尚未就绪当成功；消息帧遵循Chrome限制。记录worker-05-bridge.md。

## 规矩与验收

每个缺陷记录触发路径→代码证据→修改→剩余风险；不为凑数声称找全。不能靠删除功能、吞错误、假进度、放宽协议校验或篡改旧测试通过。重复构建错误3次换方案，单项3方案后记阻塞继续其他项。

主代理审查每个交付diff和接缝；在所有修改稳定后统一执行已存在的xcodebuild Release入口、SwiftPM CLI构建、npm run build:chrome、node --check和git diff --check。构建输出必须真实保留；构建不代表功能通过。按已授权安装边界处理签名/产物，运行中App不强杀；写入受沙箱阻止时如实记阻塞。

## 完成条件

1. 本轮确认缺陷都有实现或明确阻塞，5份记录齐全；主流程状态、接收ID、取消与文件落盘接缝经过主代理代码审核；用户手测保持待测。
2. 必要构建成功且名字身份图标不变，旧应用可恢复、用户数据未变；PROGRESS/BLOCKED、版本、详细手测步骤和结果模板与实际交付一致。若构建/安装未完成必须明确报告，不能以任务派发或计划完成代替实现交付。
