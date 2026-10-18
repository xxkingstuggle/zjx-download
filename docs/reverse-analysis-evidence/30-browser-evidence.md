# 浏览器集成反向拆解证据

> 2026-10-18授权更新：用户允许查看旧项目及本审计材料；此前严格隔离的访问限制已取消。事实记录保留，新业务实现须独立设计编写。

## 固定对象与方法

- 官方扩展仓库：[amir1376/ab-download-manager-browser-integration](https://github.com/amir1376/ab-download-manager-browser-integration)。当前源码固定为 master 提交 [`658a0c70188d78033f478ba51c102a273322166f`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/658a0c70188d78033f478ba51c102a273322166f)，提交日期 2026-10-13。
- 最新稳定版为 [`v1.5.0`](https://github.com/amir1376/ab-download-manager-browser-integration/releases/tag/v1.5.0)，发布日期 2026-07-27；标签直接指向提交 [`fe1c01928e8702282ef36f2726bc793423f5dc77`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/fe1c01928e8702282ef36f2726bc793423f5dc77)。固定 master 相对稳定版比较为 [v1.5.0...658a0c7](https://github.com/amir1376/ab-download-manager-browser-integration/compare/v1.5.0...658a0c70188d78033f478ba51c102a273322166f)：ahead 5、behind 0。
- 桌面端协议交叉核对固定官方提交 [`e329495b6630b18e4b41d7682da33318b0f9ea18`](https://github.com/amir1376/ab-download-manager/commit/e329495b6630b18e4b41d7682da33318b0f9ea18)。未把本项目中的浏览器扩展 fork 作为原版证据。
- 所有源码引用均为固定提交的 GitHub permalink 和行号。`[S]` 只表示静态源码或仓库元数据确认，不代表原版已在浏览器实测；`[U]` 表示本轮没有黑盒证据。具体功能约定见 [浏览器集成净室功能规格](../clean-room-rebuild/30-browser-integration-spec.md)。

## 证据索引

### BS-001 固定版本、稳定版与版本差异

扩展发布页记录 v1.5.0 日期和发布说明；Git 标签解析到上述固定 SHA；compare 显示五个后续提交。[v1.5.0 发布页](https://github.com/amir1376/ab-download-manager-browser-integration/releases/tag/v1.5.0)、[稳定版标签提交](https://github.com/amir1376/ab-download-manager-browser-integration/commit/fe1c01928e8702282ef36f2726bc793423f5dc77)、[稳定版至固定 master 比较](https://github.com/amir1376/ab-download-manager-browser-integration/compare/v1.5.0...658a0c70188d78033f478ba51c102a273322166f)。

### BS-002 浏览器权限与平台清单

共同 manifest 配置全站 HTTP/HTTPS 内容脚本和 host 权限，并声明 `contextMenus`、`webRequest`、`cookies`、`storage`、`tabs`、`downloads`、`notifications`、`nativeMessaging`。Chrome 清单为 MV3；Firefox 为 MV2，并额外声明 `webRequestBlocking`。[共同 manifest 权限](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/manifest/shared.ts#L20-L59)、[Chrome manifest](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/manifest/manifest.chrome.ts#L11-L22)、[Firefox manifest](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/manifest/manifest.firefox.ts#L10-L29)。

### BS-003 扩展后台启动与监听

后台启动时探测后端、创建菜单、注册下载拦截和扩展消息处理；MV3 启动保持事件监听辅助逻辑。[后台启动顺序](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/background/background.ts#L42-L59)、[MV3 监听维持逻辑](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/utils/extension-api.ts#L1-L12)。

### BS-004 设置默认值和持久化

配置写入浏览器本地扩展存储，存储变化后重新读取并广播；固定提交中的缺省开关、端口、扩展名、大小、绕过键、忽略 URL、API Key 等值列于配置 schema。[配置写入与变化](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/configs/Config.ts#L19-L35)、[默认值和校验](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/configs/Config.ts#L44-L104)、[默认端口和 API Key 头名](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/utils/Constants.ts#L1-L9)。

### BS-005 右键菜单

菜单上下文是 `selection` 以及 `link`、`audio`、`video`、`image`；普通下载取 `linkUrl` 或 `srcUrl`，选区入口以右键标签页 ID 发消息，并在缺少该 ID 时查询当前窗口活动页。[菜单创建和处理](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contextmenus/ContextMenus.ts#L12-L75)。英文界面的菜单和选区按钮文案分别由以下本地化条目提供：[英文菜单文案](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/public/_locales/en/messages.json#L1-L17)。

### BS-006 选区抽链与快捷条

选区检测、弹窗开关、延迟和按键动作由内容脚本执行；抽取实现遍历各 Range，要求公共祖先为元素节点，只查询其后代锚点并检查选区包含关系；选区按钮负责下载和关闭。[内容脚本选区检测](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contentscripts/ContentScript.ts#L20-L38)、[延迟弹窗和快捷键状态](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contentscripts/ContentScript.ts#L64-L108)、[选区链接抽取](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/utils/LinkExtractor.ts#L3-L31)、[选区按钮及关闭逻辑](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/popup/selection/SelectionPopup.ts#L9-L36)。

### BS-007 自动接管、过滤、下载事件与回退

直接响应路径过滤请求类型、GET、自动接管开关、状态码、文本响应、URL 规则、大小和绕过键；文件名取响应头或 URL，扩展名命中设置列表。未知 `Content-Length` 被接受；已知大小严格小于配置阈值时排除。[过滤规则](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L69-L214)。

扩展监听请求头、响应头、媒体响应和下载创建；成功后取消浏览器重复下载，并可关闭新标签。下载事件路径还会过滤扩展发起、旧/已结束、无对应观察请求、忽略 URL、大小、快捷键等情况；原始观察到的请求头直接用于提交，缺少时另查 Cookie。取消路径包括 cancel、erase、removeFile。[请求响应监听](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L299-L401)、[下载事件和取消](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L403-L525)、[新标签关闭条件](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L261-L275)。

Chrome MV3 的响应 pass/cancel 实现为空；Firefox MV2 可返回 cancel 标志。应用添加失败时的恢复逻辑会重置已处理标记；MV3 分支明确为 no-op，恢复创建浏览器下载的逻辑未完成。[MV3 拦截能力](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/Manifest3DownloadLinkInterceptor.ts#L3-L16)、[MV2 拦截能力](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/Manifest2DownloadLinkInterceptor.ts#L5-L20)、[失败后恢复分支](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L542-L565)。这证明实现分支存在，不证明各浏览器安装环境下实际回退效果。[U, BS-024]

### BS-008 绕过自动接管快捷键

默认快捷键按平台选取；匹配支持修饰键组合、顺序规范化和旧 macOS `Delete` 的 `Backspace` 兼容。设置页录制组合并提示 macOS `Control+click` 不可用。[默认值](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/configs/Config.ts#L76-L82)、[组合匹配](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/utils/Shortcut.ts#L1-L62)、[按键录制和提示](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L550-L653)。

### BS-009 下载请求字段、Cookie 与静默选项

下载项公开字段为 `link`、`downloadPage`、`headers`、`description`、`suggestedName`、`type`；请求选项为 `silentAdd`、`silentStart`。手动添加按 Cookie 开关获取/清空 headers；后台动作只在静默添加开启时设置两个静默选项，且成功静默单项时创建通知。[下载项类型](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/interfaces/DownloadRequestItem.ts#L1-L10)、[请求选项默认值](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/interfaces/DownloadRequestOptions.ts#L3-L15)、[选区/媒体 headers 开关](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contentscripts/AddDownloads.ts#L6-L25)、[静默选项及单项通知](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/background/actions.ts#L10-L37)、[Cookie、Host 和 User-Agent](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/background/actions.ts#L39-L63)。

### BS-010 HTTP API 和通道选择

扩展 HTTP API 使用 `http://localhost:<port>/add` 与 `/ping`、POST JSON、非空时带 `X-Api-Key`，HTTP 等待 500 ms；HTTP 失败可按组合 API 顺序继续 native。探测 native 和单次请求通道是不同状态。[HTTP API 实现](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/HttpApi.ts#L10-L67)、[后端选择与添加请求封装](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/Backend.ts#L36-L105)、[按顺序尝试 API](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/CompositeAppApi.ts#L19-L44)。

### BS-011 HTTP 媒体与 HLS

媒体发现监听 `media` 响应，以及 URL 匹配 `.m3u8` 的 XHR；资源和页面 URL 都遵守忽略/固定媒体规则与大小阈值。固定排除域为 YouTube 及 youtu.be。[媒体事件注册](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L319-L354)、[媒体过滤及事件分类](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/linkgrabber/DownloadLinkInterceptor.ts#L609-L676)、[固定媒体域](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/MediaBlackList.tsx#L1-L5)。

HTTP 媒体从响应头、URL 或 MIME 取得扩展名；HLS 主清单展开变体，媒体清单累计时长并要求首段扩展名 `ts`。候选生成拒绝无类型、无扩展名和检测为加密的项目；支持两种 HLS MIME 前缀，对其他 MIME 仅接收已知且小于 2 MiB 的长度。[媒体和 HLS 解析](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/MediaOnTab.ts#L90-L215)、[候选字段和加密过滤](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/MediaOnTab.ts#L280-L377)、[清单读取限制](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/MediaOnTab.ts#L399-L443)、[加密方法、MIME 与 2 MiB 常量](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/HLSUtils.ts#L10-L29)、[按标签页重置候选](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/media/MediaRegistry.ts#L32-L66)。

### BS-012 网页媒体候选条

候选条初始折叠、显示数量；支持展开、关闭、逐条点击，展示名称及 duration、size、resolution、bandwidth、extension。关闭后本页脚本将候选条标为 dismissed；添加点击后折叠列表。[浮层创建、关闭和 dismissed 状态](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/popup/media/MediaSelectionPopup.ts#L4-L7)、[关闭及初始状态](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/popup/media/MediaSelectionPopup.ts#L145-L162)、[候选显示、点击和折叠](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/popup/media/MediaSelectionPopup.ts#L185-L258)、[点击媒体条目交给添加流程](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contentscripts/ContentScript.ts#L49-L62)。

### BS-013 Native Messaging 与桌面端处理

扩展 native envelope 使用 `{id, content:{action,isError,payload}}`，payload 是 JSON 字符串；浏览器 ID 以 `B_` 开头。普通未连接请求使用一次性 `sendNativeMessage`，请求连接/等待和断开处理也存在；固定源码未发现业务启动调用长连接连接方法。长连接等待有 10 秒扩展侧计时器，一次性发送没有扩展侧计时器。[浏览器 envelope](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/nativemessaging/NativeMessagingProtocol.ts#L18-L33)、[native port 建立与状态](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/nativemessaging/NativeMessagingTransport.ts#L19-L68)、[长连接请求计时器](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/nativemessaging/NativeMessagingTransport.ts#L129-L173)、[one-shot host 请求](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/nativemessaging/NativeMessagingTransport.ts#L175-L201)、[Native API 动作名](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/NativeMessagingApi.ts#L49-L65)。

桌面端固定提交存在 API key 保护的 `/add`、`/queues`、`/start-headless-download`、`/ping`；默认 API 启用、关闭认证、端口 15151、监听 `127.0.0.1`。`/add` DTO 接受 `items` 和 `options`，包含 HTTP/HLS 字段，并兼容旧 HTTP credential 数组。[REST 路由与认证](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/integration/server/src/main/kotlin/com/abdownloadmanager/integration/Endpoints.kt#L21-L76)、[监听地址和端口设置](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/integration/server/src/main/kotlin/com/abdownloadmanager/integration/Integration.kt#L34-L91)、[默认 API 设置](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/storage/appsettings/DefaultAppSettings.kt#L38-L44)、[下载请求 wire DTO](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/integration/server/src/main/kotlin/com/abdownloadmanager/integration/model/DownloadCredentialsFromIntegration.kt#L8-L59)、[新下载任务映射](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/integration/server/src/main/kotlin/com/abdownloadmanager/integration/model/NewDownloadTask.kt#L5-L14)。项目锁定 Ktor 3.6.0 且未设置自定义 API-key header 名；官方 Ktor 文档给出的默认头为 `X-API-Key`，缺失或错误时返回 401，因此与浏览器发出的 `X-Api-Key`（HTTP header 名不区分大小写）一致。[依赖版本](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/gradle/libs.versions.toml#L43-L46)、[Ktor API-key 认证默认行为](https://ktor.io/docs/server-api-key-auth.html?topic=.2.0)。浏览器 `items`/`options` payload 与该 DTO 兼容；未采用仓库 OpenAPI 文件取代运行时路由事实。[S]

桌面 Native host 使用相同 envelope 和 `add`/`ping` 动作，回复 echo 请求 ID；add 和 ping 成功都回 `true`。[Native 请求 envelope](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/nativemessaging/host/BrowserMessageRequest.kt#L7-L47)、[Native add/ping handler](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/nativemessaging/host/DefinedHandlers.kt#L8-L49)、[路由和错误回复](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/nativemessaging/host/NativeMessagingRouter.kt#L23-L43)。host 的注册和原生消息协议 framing 证据：[Native host 注册代码](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/nativemessaging/NativeMessaging.kt#L73-L99)、[stdio framing](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/nativemessaging/host/stdio/StdioProtocol.kt#L9-L24)。

桌面端把 browser import options 转为 GUI 添加选项；单项 silent 行为和多项默认显示窗口不同。已有编辑窗分支仅处理第一项。[桌面入口转发](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/integration/IntegrationHandlerImp.kt#L29-L45)、[GUI 入口和已有编辑窗分支](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/AppComponent.kt#L808-L855)、[单项静默等待与失败转表单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/single/BaseAddSingleDownloadComponent.kt#L81-L82)、[单项静默流程](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/single/BaseAddSingleDownloadComponent.kt#L408-L499)、[多项窗口行为](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/multiple/BaseAddMultiDownloadComponent.kt#L55-L80)。

### BS-014 工具栏弹窗与连接状态

弹窗打开时查询应用可达性，显示 checking/connected/not connected；提供自动接管、网页弹窗、静默添加开关和更多设置入口。[弹窗打开时状态检查](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/browseractionpopup/BrowserAction.tsx#L30-L44)、[状态文案和开关](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/browseractionpopup/BrowserAction.tsx#L89-L135)。

### BS-015 完整设置页

完整设置页展示自动接管、扩展名、忽略 URL、最小大小、绕过快捷键、弹窗、静默添加/开始、Native 状态、HTTP 端口/API Key 和发送 Cookie。设置页没有 `allowPassDownloadIfAppNotRespond`、`closeNewTabIfItWasCaptured` 的 setter。[设置页状态和 setter](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L39-L179)、[设置页字段布局](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L250-L299)、[静默选项](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L335-L404)、[后缀、忽略 URL、大小与快捷键](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L406-L548)、[端口、API Key、Native 状态、Cookie](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/optionsui/OptionUi.tsx#L655-L781)。

### BS-016 队列接口和浏览器端缺口

对固定 master 的完整 Git 树及浏览器源码检索 `queues`、`queueId`、`getQueues`，未发现浏览器侧队列 API 或队列选择入口；浏览器 HTTP 类只公开 add/ping，后端封装也只提供 add/ping。[浏览器 HTTP add/ping](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/HttpApi.ts#L58-L67)、[浏览器后端公开操作](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/backend/Backend.ts#L87-L129)。桌面 REST 确实注册 `GET /queues`，但该浏览器扩展不调用。[桌面 REST 路由](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/integration/server/src/main/kotlin/com/abdownloadmanager/integration/Endpoints.kt#L21-L76)。

### BS-017 通知与错误提示

静默添加成功仅对单项创建系统通知；应用 API 错误和网络失败会通过当前标签页 alert 提示，通知 API 异常只记日志。[成功通知](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/background/actions.ts#L19-L36)、[错误处理](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/background/actions.ts#L65-L82)、[内容脚本 alert 接收](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contentscripts/ContentScript.ts#L111-L122)。

### BS-024 未做原版黑盒验收

本轮使用固定提交静态源码、仓库历史和官方桌面端源码进行反向拆解；未启动原版浏览器扩展或桌面应用，也未操作或更改 Chrome。Chrome MV3 离线回退、浏览器时序、权限撤销、站点匹配边界、HLS 页面表现和 UI 提示仍需在隔离环境实测。此条是审计范围说明，不构成原版行为证据。

## 稳定版至固定 master 的提交变化

v1.5.0 发布说明列出的稳定版基线变化包括 Native Messaging、API Key 认证、应用不能接受下载时避免浏览器下载丢失的修复，以及选项页文件类型偶发清空修复。[v1.5.0 发布说明](https://github.com/amir1376/ab-download-manager-browser-integration/releases/tag/v1.5.0)

固定 master 比该标签多 5 个提交，均列于 [GitHub compare](https://github.com/amir1376/ab-download-manager-browser-integration/compare/v1.5.0...658a0c70188d78033f478ba51c102a273322166f)：

1. [`2adb8d5`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/2adb8d5eb16eb84261ca3f8225b1b89e10a9b58c)（2026-07-30）：README 增加 Chrome/Firefox 商店徽章，无确认的运行时变化。
2. [`4e37488`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/4e3748898f9e60198b293b7fcfc834c61e1de5e1)（2026-08-17）：macOS 默认绕过键改为 Backspace，并允许用户设置绕过键；这是可见设置和默认行为变化。[当前默认值](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/configs/Config.ts#L76-L82)
3. [`d15970d`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/d15970d452ae981dd0b6ef008cfe52817144be5d)（2026-08-17）：扩展入口结构重构并增加平台信息传递；未确认新增独立用户功能。
4. [`1871203`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/1871203ce9665ea6802e8d1328f8b70c7dc9d948)（2026-09-29）：绕过键支持修饰键组合，规范化顺序，并提示 macOS `Control+click` 不可用；这是可见行为变化。[当前组合逻辑](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/utils/Shortcut.ts#L1-L62)
5. [`658a0c7`](https://github.com/amir1376/ab-download-manager-browser-integration/commit/658a0c70188d78033f478ba51c102a273322166f)（2026-10-13）：修复“Download selected links”无效果问题，按右键事件关联的标签页发内容脚本消息，必要时退到当前窗口活动标签页。[当前处理逻辑](https://github.com/amir1376/ab-download-manager-browser-integration/blob/658a0c70188d78033f478ba51c102a273322166f/src/contextmenus/ContextMenus.ts#L56-L72)
