# macOS 原生交互规格

这是后续实现的验收规格，不是当前界面截图或实现已通过的声明。上游的操作和设置基准见 [功能矩阵](feature-matrix.md)。

## 窗口和导航

```text
┌──────────────────────────────────────────────────────────────────────┐
│ macOS title bar | back/forward | New ▾ | search | inspector | refresh │
├──────────────────┬───────────────────────────────────────────────────┤
│ Library          │ Download table                                    │
│  Downloads       │ Name | Size | Status | Speed | Time | Added ...   │
│  Queues          │                                                   │
│  Categories      │ selected row(s) → native context/actions           │
│  History         │                                                   │
│                  ├───────────────────────────────────────────────────┤
│                  │ selection count • active downloads • total speed   │
│                  │                                                   │
│                  │ Settings opens the standard macOS Settings window  │
└──────────────────┴───────────────────────────────────────────────────┘
```

- 主窗使用 `NavigationSplitView` 的 sidebar/detail；侧栏分类支持折叠与可见计数，Downloads 页顶部提供搜索/筛选。主窗遵循系统窗口控制、title bar、toolbar、sidebar row 和 semantic color；不把桌面端 Compose 菜单/卡片原样搬过来。
- Downloads 使用 macOS `Table` 或等价的原生虚拟化列表：Name、Size、Status、Speed、Time Left、Date Added 默认显示；Date Started/Date Finished 可从列配置加入；用户列顺序、宽度、显隐与排序写入本地窗口状态，默认 Date Added 降序。滚动必须虚拟化，状态更新只重绘受影响行。
- Sidebar 可在窄窗口折叠；Inspector 有可见切换。空间不足时转换为原生 Inspector sheet/popover，不把列表压到不可操作。沿用现有 544×420 代码值只能作为起点，最终最小尺寸通过所有可见控件、不裁切和键盘焦点实测确定。
- 空下载页给出简短说明与“新建下载”主操作；空筛选结果提供清除筛选；没有任务与没有匹配项不能共用含糊状态。
- Settings 从系统 Settings command / `⌘,` 打开独立标准设置窗口，按 Appearance、Downloads、Notifications、Network、Integration、Advanced 组织。默认保存编辑即时生效并可撤销；若保留 Save 按钮，必须显示未保存状态和取消行为。

## 下载列表与多选

- 使用原生列标题排序、列尺寸调整、列显隐菜单、搜索字段、状态/类别/队列筛选器；筛选状态显示成可清除的 token，结果数随筛选更新。
- 点击选择一行；`⌘`-click 多选，Shift 范围选择，`⌘A` 选择当前可见结果，Escape 清除。选择变化不允许让过滤隐藏的任务进入后续操作；筛选前选中的不可见项在筛选变化时清理或在 UI 明确保留隐藏数量，不能静默对隐藏任务执行动作。
- 右键未选中的行仅操作该行并让它成为当前选择；右键当前多选项保留并操作整个选择。上下文菜单项按任务状态禁用，并用原生分隔符分组。
- 选择栏只在有选择时出现：开始/暂停/重试/取消/删除、移动队列、移动类别、复制链接格式、checksum。动作运行后回报成功和失败数量，单项失败不阻断其余合法任务。
- 删除确认明确显示任务数量和完成/未完成数；只有已完成文件才显示“同时删除磁盘文件”。范围清理命令先预览受影响条目数量，再确认。

## 新增、编辑和批量

- `⌘N` 打开 New Download sheet，`⌘V` 显式解析剪贴板 URL；关闭剪贴板自动监控仍可手动粘贴。Sheet 使用原生 `Form`、NSOpenPanel、默认/取消按钮和键盘焦点，不显示伪 web 输入框。
- 单项表单字段：URL、自动建议文件名、目录、认证/headers/cookie、checksum、限速、队列、类别、冲突动作、立即开始。保存前校验 scheme、URL、目录、checksum 和正整数；错误就地显示，保留用户输入，不静默关闭。
- 多项表格为每个 URL 显示解析结果、文件名、认证信息、目标位置及错误；可批量选择、删除、编辑共享值，重复 URL 去重规则须可解释。批量模式按上游 `*` 数字区间与零填充预览，只有 pattern 也必须启用 Add。提交时保留同一轮填写的所有 headers/checksum/speed/queue/category/conflict/start 值。
- 编辑下载：未完成任务允许编辑上游支持的远程设置；已完成任务允许重命名或移动本地文件，URL/请求凭据类字段禁用并说明原因。移动使用文件安全范围检查，冲突继续走可选策略，失败时保留原任务并展示具体错误。
- 添加流程可由扩展/API 请求 silentAdd 与 silentStart；交互添加时先显示预览页，silentAdd 跳过页面但不等于强制开始。

## 队列、类别、历史

- Queues 使用原生可拖动列表/表格，行内启动/停止状态、并发上限；添加/编辑为 sheet；排程选择星期和时间，跨午夜校验。删除必须确认任务迁移到哪个有效队列。完成动作（无、退出、睡眠、关机）在保存时提示权限/后果，在本轮任务全部完成后只触发一次，并有可测试的 action adapter。
- Categories 展示名称、图标、匹配扩展名/URL host/pattern 和默认目录；默认分类集可恢复，匹配规则优先级明确；新增任务自动分类受 `useCategoryByDefault` 控制；为已有任务提供明确批量应用入口。列表顺序持久化。将任务拖到类别变更其分类，将已完成本地文件拖入类别不隐式移动文件。
- History 继续展示本地已有记录、完成时间和 Finder reveal/清空历史。搜索、筛选、复制 URL、单条移除是可选 macOS 体验建议，不计作已确认的上游 parity 要求；删除本地文件须与删除记录分开并明确提示磁盘操作。

## 菜单、键盘和拖放

- App 菜单由 SwiftUI `Commands` / AppKit 原生命令组成：File（新建、剪贴板、批量、退出）；Tasks（队列组、停止全部、任务范围清理）；Tools（浏览器集成、host overrides、Settings）；Help（支持、开源库、翻译、捐赠、更新、关于）。Commands 根据窗口/选择/任务状态正确启用，菜单和工具栏走同一 action model。
- 保持上游 macOS 常用键位：`⌘N` 新建、`⌘V` 粘贴/识别剪贴板、`⌘C` 复制 URL、`⌘⌥S` Settings、`⌘O` 打开已完成文件、`⌘F` Finder reveal、`⌘E` 编辑、`⌘P` 暂停、`⌘R` 恢复、`⌘I` 详情、Backspace 删除；增加 `⌘A` 可见列表全选和 Escape 清除。标准 `⌘Q` 使用 macOS quit command。若与 VoiceOver、系统菜单或文本编辑快捷键冲突，优先保留 macOS 系统约定并在菜单显示实际键位。
- 任务列表接受拖入 URL 字符串、网页链接和文件；多个 URL 先预览后添加。拖到 Queue/Category 是明确的归属动作；拖出已完成任务给 Finder/桌面提供文件 URL，不移动或删除源文件。拖放进度和拒绝原因可感知，离开区域后状态清理。
- MenuBarExtra 显示应用图标和活动数，菜单有新建、显示主窗口、队列组控制、暂停全部/恢复、最近错误和退出。图标、计数、菜单快捷键在真实 macOS 菜单栏验收；不将“SwiftUI 有 MenuBarExtra 代码”视作界面已显示。

## 设置和外部集成

- 每个控件有范围、默认值、重置策略和数据迁移。系统外观、字体大小、单位、相对日期、通知声音、进度提示、目录注册、DNS、PAC 与代理绕过都必须可见且消费者读取的是保存后的值。
- 密码和 API key 存 Keychain；状态文件保存引用/标识，不明文放在 JSON。打开鉴权但密钥为空时阻止保存；API 监听明确显示 loopback 地址，不开外网监听。
- Settings 中 REST 集成提供连接/鉴权状态和 Copy API key；“浏览器扩展”项提供安装状态/端口/API 连通诊断，不伪称扩展已安装。请求来源、错误时是否保留浏览器自身下载、Cookie/header 采集在扩展中显式告知。
- 完成、失败、权限受限、服务未启动、端口冲突、主机无响应等显示在对应任务或集成页；系统通知只是补充，不能替代 app 内状态。启动项、通知、Finder 权限按系统实际结果显示。

## 错误和可访问性

- 单任务错误在 Status 列和详情中说明 HTTP 状态、TLS、存储或校验类别，提供可用的 Retry/Open Logs/Reveal Partial File 操作；删除/无效设置等错误靠近发起位置，不汇总成无上下文的单个全局 alert。
- 存储空间不足、目录权限、文件消失、重复文件、坏 URL、checksum 不符、代理/证书失败、REST 鉴权失败、端口冲突都要可恢复；部分批量失败显示总数和逐条错误并允许复制。
- 所有图标按钮有 VoiceOver label、任务行暴露文件名/状态/速度/选中状态，排序列声明排序方向；VoiceOver rotor 能按任务行与列移动。全程键盘可到达，不用颜色单独表示状态，遵从 Reduce Motion/Transparency、系统对比度和字号。
- 验收需要 VoiceOver、Full Keyboard Access、浅色/深色/跟随系统、窗口最小尺寸、缩放、1000/10000 行和错误/空状态矩阵。仅静态 `accessibilityLabel` 检索不能代表辅助功能通过。

## UI 验收路径

1. 启动空应用；键盘从 sidebar 到列表到 Settings；浅色/深色/系统切换并重启后检查保留。
2. 从单项、粘贴、多 URL、pattern-only batch 分别添加；无效 URL、无权限目录、重复文件必须留在可解释状态。
3. 创建队列和类别、设置 schedule、拖放重排；把任务分到不同队列/类别；检验并发、计划开始和类别自动匹配。
4. 对活动、暂停、失败、完成任务分别单选、多选、范围选；右键未选行和已选多选；执行所有菜单动作并检查受影响 ID。
5. 用浏览器扩展执行上下文菜单、选区链接、自动捕获、Cookie 受限站点、多媒体和 HLS，确认 API 断开时浏览器回退策略。
6. 打开每个 Settings 控件改变值，重启/重新建任务/发 REST 请求，再检查行为改变；死设置列表每项必须有独立行为测试。
7. 用 VoiceOver 与全键盘完成上述流程；用错误夹具注入网络失败、404/500、磁盘满模拟与 checksum 错误。
