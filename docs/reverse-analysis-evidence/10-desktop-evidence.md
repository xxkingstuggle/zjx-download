# 桌面功能反向拆解证据

> 2026-10-18授权更新：用户允许查看旧项目及本审计材料；此前严格隔离的访问限制已取消。事实记录保留，新业务实现须独立设计编写。

审计基线：`e329495b6630b18e4b41d7682da33318b0f9ea18`（2026-10-15 master）。以下链接均固定到该 commit。此文件是审计材料，执行者可以查阅理解原功能。功能映射指向 `docs/clean-room-rebuild/10-desktop-functional-spec.md` 中的 `D-*`。

## DS-001 主窗口菜单、任务命令入口和快捷键

**映射**：D-001、D-003、D-011、D-021～D-023、D-025。  
**证据**：[HomeComponent 菜单/任务命令](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt#L165-L224)、[表格快捷键/主动作栏](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt#L397-L432)。

**推导**：菜单分为 File、Tasks、Tools、Help；Tasks 暴露队列动作和按缺失/已完成/未完成/全部清除任务；Tools 含浏览器集成、Linux 创建桌面入口、逐主机设置、设置；Help 含支持、许可、翻译者、捐赠、检查更新、关于。桌面修饰键按 macOS Meta、其他系统 Ctrl 选择。Home 顶部工具栏含恢复/暂停/队列/停止全部/删除/设置。  
**限制**：快捷键在不同窗口焦点与原生菜单模式下的触发优先级未运行确认。菜单字符串资源的本地化版本需随目标 locale 验收。

## DS-002 主页面、筛选、拖放和删除确认

**映射**：D-001、D-003、D-010。  
**证据**：[HomePage 拖放和布局](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomePage.kt#L228-L398)、[删除下载确认](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomePage.kt#L414-L530)、[删除分类确认](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomePage.kt#L591-L664)、[底部汇总/搜索](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomePage.kt#L822-L923)。

**推导**：下载确认按完成/未完成计数显示说明；磁盘删除复选框只在选择含完成项时显示。删除分类提示下载不会删除。底部显示选中计数/大小与活动数/速率；搜索栏过滤名称。桌面拖放接受字符串和文件，提示可接收状态；文件只处理首个且受大小限制。  
**限制**：该 UI 文件未显示复选框初值；另一个状态对象/共享组件的初值需结合证据核对。拖放 Mac 平台事件重读逻辑是实现细节，不作用户规格要求。原版权限、外部拖放兼容性未运行确认。

## DS-003 下载表格列、排序、选择和持久化

**映射**：D-001～D-003。  
**证据**：[下载表列/渲染](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/sections/DownloadList.kt#L284-L473)、[选择与鼠标行为](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/sections/DownloadList.kt#L93-L281)、[表头排序与列菜单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/desktopMain/kotlin/com/abdownloadmanager/shared/ui/widget/table/customtable/Table.kt#L54-L155)、[列显隐/顺序/排序控制](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/desktopMain/kotlin/com/abdownloadmanager/shared/ui/widget/table/customtable/Table.kt#L237-L379)、[表格布局状态](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/desktopMain/kotlin/com/abdownloadmanager/shared/ui/widget/table/customtable/TableUtils.kt#L209-L345)、[主页面初始排序和保存](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt#L253-L269)。

**推导**：表格列为选择标记、名称、状态、大小、速度、剩余时间、添加日期、开始日期、完成日期、Location。名称锁定可见；默认隐藏开始/完成日期和 Location；初始按添加日期降序。用户可通过表头菜单控制列显隐、顺序、排序，调整列宽；表状态保存。鼠标单选、多选修饰键、Shift 范围选择、Cmd/Ctrl+A、Escape、点击空白清除选择均有实现。  
**版本限定**：Location 列属于审计 master 的新增功能；基线差异记录见总审计 VS-001。  
**限制**：表格排序相同键的稳定顺序、跨筛选保留选择方式及大列表实际渲染性能未运行确认。主规格把这些未确定用户结果明确标成 `[R]` 或 `[U]`。

## DS-004 下载条目菜单及可用条件

**映射**：D-003、D-012、D-019。  
**证据**：[桌面单项菜单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/DesktopDownloadActions.kt#L50-L84)、[通用操作和状态门槛](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/AbstractDownloadActions.kt#L80-L185)、[复制/属性/校验/移动](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/AbstractDownloadActions.kt#L188-L259)。

**推导**：单项菜单包含 Open、Open With、Open Folder、Resume/Pause、Delete、Restart、Move to Queue/Category、复制链接/JSON/cURL、Edit、File Checksum、Properties。Open/With 需要完成；暂停/恢复按所选中有资格的条目；编辑使用默认项，活动但不可暂停的任务才允许；校验需要选择中含完成项；JSON/cURL 生成只取 HTTP 凭据。  
**限制**：复制菜单在混合协议选择中的空结果表现未确认。文件打开方式的应用选择器是操作系统行为。移分类/队列为任务归属变化；不能从动作名推断物理文件移动。

## DS-005 主数据视图的分类与队列动作

**映射**：D-001、D-003、D-010、D-011。  
**证据**：[分类过滤/自动分类/移动队列/分类](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/BaseHomeComponent.kt#L103-L163)、[列表视图筛选/选择汇总](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/BaseHomeComponent.kt#L248-L311)、[状态/打开逻辑](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/BaseHomeComponent.kt#L313-L429)、[分类上下文操作](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/CategoryActions.kt#L42-L120)、[队列上下文操作](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/queue/QueueActions.kt#L44-L130)。

**推导**：可按分类/队列/状态/名字过滤；自动分类处理未分类活动和已完成记录；分类和队列动作提供新增、编辑或移动入口。删除分类只删除分类设置项；默认队列不可删除。  
**限制**：队列执行、计划和完成动作由 Q 规格负责。分类 reset 对原有手工映射的详细副作用需在 CategoryManager 范围进一步说明，不把“恢复默认”推断成删文件。

## DS-006 新建 URL 与导入格式

**映射**：D-004、D-009、D-021。  
**证据**：[通用动作入口](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/action/CommonActionFactories.kt#L37-L82)、[导入/导出格式选择](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/extractors/linkextractor/DefaultDownloadCredentialsExtractor.kt#L6-L22)、[JSON 凭据导入/导出](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/extractors/linkextractor/DownloadCredentialsFromJson.kt#L10-L29)、[cURL 解析](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/extractors/linkextractor/DownloadCredentialsFromCurl.kt#L5-L46)、[单 URL 页面](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/enterurl/EnterNewURLPage.kt#L55-L266)、[首次剪贴板填充/自动下载器](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/enterurl/BaseEnterNewURLComponent.kt#L20-L112)。

**推导**：导入识别顺序 JSON → cURL → 普通网址，按链接去重；新 URL 有粘贴入口与 Auto 处理器，并允许手动选处理器；单 URL 页面仅在剪贴板解析出一条网址时自动填充。JSON 输出单条 HTTP 凭据时为对象，多条为数组。  
**限制**：导入入口实际消费系统剪贴板/拖入文本；本 UI 没有另存 JSON 文件对话框。具体 cURL 参数支持范围以解析器为准，不能宣传为完整 curl 兼容。

## DS-007 添加下载表单、分类与路径历史

**映射**：D-006、D-010、D-015。  
**证据**：[单条添加表单字段/重复 UI](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/single/AddDownloadPage.kt#L53-L207)、[新建输入与分类默认](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/single/BaseAddSingleDownloadComponent.kt#L81-L190)、[分类自动匹配与目录记忆](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/single/BaseAddSingleDownloadComponent.kt#L196-L325)、[提交并入队/直接下载](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/single/BaseAddSingleDownloadComponent.kt#L328-L354)、[目录文本框/历史目录行为](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/shared/LocationTextField.kt#L45-L250)。

**推导**：提供 URL、分类、路径、文件名、响应检查、重试及更多设置。默认分类项可能选中但开关默认关；分类打开后路径跟分类，没有分类路径时回退全局默认。提交可以经队列选择或立即下载。记住默认路径与仅加入最近目录历史是两种动作。  
**限制**：路径权限检查在静态源码确认了写入能力门槛，但当前系统 ACL/卷权限的真实错误文本需运行测试。

## DS-008 重复项、批量网址展开与队列选择初值

**映射**：D-005、D-007、D-009、D-011。  
**证据**：[重复解决选项/按钮](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/single/AddDownloadPage.kt#L210-L320)、[重复解决和提交有效性](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/single/AddDownloadPage.kt#L444-L507)、[批量模板/范围输入与首尾预览](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/batchdownload/BatchDownnload.kt#L30-L190)、[通配符选项和手动长度初值/范围](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/batchdownload/BatchDownnload.kt#L205-L267)、[批量序列初值/校验/展开](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/batchdownload/BaseBatchDownloadComponent.kt#L19-L190)、[多项导入列表去重边界](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/multiple/BaseAddMultiDownloadComponent.kt#L157-L175)、[队列选择器](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/shared/SelectQueue.kt#L39-L226)、[记忆最近队列及快速确认](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/addToQueue/SelectQueueComponent.kt#L16-L87)。

**推导**：重复选项包含编号文件、覆盖、更新既有下载链接、显示/打开已下载文件；默认冲突未处理前不能 Add/Download。批量起止初值为空、通配符初值 Auto；手动长度控件初值 2，范围 1–10；有效 URL 剪贴板可填入模板。首尾预览显示当前范围结果，展开上限为 1000；静态校验没有要求模板必须包含 `*`，首条生成 URL 有效即可。多项导入只过滤此前已在列表中的凭据，不在同次输入数组内部去重；因此无 `*` 模板会在列表中生成多行相同 URL。添加窗口 Add 的普通点击打开队列选择器，长按快速使用记住的队列选项；记住队列是明确勾选。  
**限制**：源码确认输入状态与静态校验；生成 URL 后经多项导入去重的完整组合效果需运行验证。重复识别到磁盘/数据库冲突的竞态也需运行验证。

## DS-009 高级下载参数界面入口

**映射**：D-006、D-008、D-009。  
**证据**：[HTTP 请求高级设置](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/downloaderinui/http/add/HttpNewDownloadInputs.kt#L95-L195)、[HLS 请求高级设置](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/downloaderinui/hls/add/HLSNewDownloadInputs.kt#L101-L201)、[桌面高级选项弹层](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/shared/ExtraConfig.kt#L33-L119)。

**推导**：每个下载器可呈现速度上限、校验摘要、线程数、用户名、密码、User-Agent、下载页等选项；不同下载器选项集合不必相同。执行行为归 N 规格。  
**限制**：这里不把所有设置强行塞入所有下载器；凭据/表单显示和服务实际消费的差异由 N 规格核对。

## DS-010 编辑下载

**映射**：D-003、D-008。  
**证据**：[编辑入口状态限制](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/AbstractDownloadActions.kt#L168-L185)、[编辑页面字段/来源页更新](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/editdownload/EditDownload.kt#L98-L175)、[编辑确认/警告](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/editdownload/EditDownload.kt#L341-L449)、[加载与保存任务更新](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/editdownload/BaseEditDownloadComponent.kt#L31-L103)。

**推导**：编辑字段至少包含当前链接和名称；从下载页更新请求信息；刷新/高级设置/错误详情；点击 Change 保存已有项。编辑活动任务受暂停状态约束；可能要求重启下载的更改先警告。  
**限制**：对于已完成/暂停任务哪些协议字段可编辑、警告条件的完整矩阵由具体下载器确定；不应在桌面 UI 层统一抹平。

## DS-011 批量添加列表和选择

**映射**：D-009。  
**证据**：[批量表格/列](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/multiple/AddMultiItemTable.kt#L37-L187)、[列表列/错误显示](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/multiple/AddMultiItemTable.kt#L213-L268)、[批量表单字段](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/multiple/AddMultiItemPage.kt#L32-L171)、[分类/目录模式](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/addDownload/multiple/AddMultiItemPage.kt#L174-L348)、[多项输入和批量提交](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/multiple/BaseAddMultiDownloadComponent.kt#L79-L118)。

**推导**：批量表格按选择/名称/链接/大小或错误显示；初始未选中；只提交选中有效项。可全部保存到指定分类，或逐项自动分类。搜索按文件名匹配。  
**限制**：单行检查请求并发程度、部分失败界面表现未进行运行核实。

## DS-012 批量添加的状态和动作实现

**映射**：D-009。  
**证据**：[筛选选择/有效提交与统计](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/multiple/BaseAddMultiDownloadComponent.kt#L157-L265)、[批量加入队列/自动分类](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/adddownload/multiple/BaseAddMultiDownloadComponent.kt#L311-L423)。

**推导**：批量链接逐个检查；选择为空时不能提交；筛选全选针对筛选列表；重复策略为创建编号文件；“全部同一位置”与每项类别目录选择互斥。  
**限制**：缺少对批量提交部分写入失败的运行证据，D-009 以 `[R]` 要求逐项显示结果。

## DS-013 分类定义和预置规则

**映射**：D-010、D-015。  
**证据**：[分类表单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/category/NewCategoryPage.kt#L25-L95)、[分类字段状态/验证](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/category/CategoryComponent.kt#L20-L149)、[扩展名/URL 匹配规则](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/Category.kt#L21-L84)、[六个预置分类](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/DefaultCategories.kt#L17-L152)、[类别创建/更新/删除/重排](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/CategoryManager.kt#L28-L53)。

**推导**：输入图标、名称、可选扩展名/URL 规则和可选分类目录；保存必须有图标/名称；自动匹配按 URL 规则优先于扩展名。预置分类名和扩展名列表载入规格。分类是一种整理元数据，不代表下载文件本身搬家。  
**限制**：恢复默认时旧类别成员映射的最终结果、同优先级并列规则在 UI 的用户可见顺序未由片段证实。

## DS-014 分类和状态侧栏

**映射**：D-001、D-010。  
**证据**：[状态组/分类拖放与排序](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/sections/category/Categories.kt#L58-L306)、[分类删除确认文本](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomePage.kt#L591-L664)。

**推导**：状态/分类组可收起；类别可筛选任务、重排、拖入任务，并通过右击动作菜单管理。删除类别确认不删除下载。  
**限制**：拖放鼠标/触控板交互的可访问性没有运行核验。

## DS-015 队列面板桌面交互

**映射**：D-001、D-011。  
**证据**：[队列面板、展开、选择、拖入](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/sections/queue/Queues.kt#L73-L190)、[队列动作状态和默认队列限制](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/home/queue/QueueActions.kt#L44-L130)、[新建队列窗口/字段](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/newQueue/NewQueueDialog.kt#L20-L55)、[新建队列表单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/newQueue/NewQueuePage.kt#L14-L63)。

**推导**：队列标题/队列行右击打开操作菜单；点队列筛选；拖任务到队列修改归属；菜单支持 start/stop/edit/delete/clear/add，默认队列不可删。新建窗口只有队列名、Add、Cancel，空值需由产品规则确定。  
**限制**：队列的时间表、并发和完成动作由 Q 规格独立覆盖。

## DS-016 设置页布局和字段清单

**映射**：D-013～D-018。  
**证据**：[三个设置页与所有字段组](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/settings/DesktopSettingsComponent.kt#L31-L181)、[侧栏与滚动布局](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/settings/SettingsPage.kt#L38-L223)、[设置窗口大小持久化](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/settings/DesktopSettingsComponent.kt#L190-L232)。

**推导**：外观组包含主题/深浅方案、语言、字体、界面比例、原生菜单、紧凑顶部栏、图标标签、相对日期、登录启动、系统托盘、单位/平均速度、声音及三个声音文件、进度/完成窗口、Render API。下载引擎组覆盖默认路径/默认分类、全局下载参数、逐主机、代理/DNS/UA/TLS/Last-Modified、磁盘参数。浏览器集成组覆盖 API 启用/端口/认证/Key。设置窗口侧栏 150–300 dp 可调，初始 250 dp，窗口大小保存；默认外观页。

**限制**：该页面提供入口，不等于每个设置真实系统效果验证。消费者和默认值分别见 DS-019～DS-023。DS 编号为审计追溯，不向净室实现者提供此表。

## DS-017 进度窗口和完成窗口

**映射**：D-012、D-014。  
**证据**：[窗口按任务状态切换](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/singleDownloadPage/ShowDownloadDialogs.kt#L51-L189)、[进行中页签/信息/动作区](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/singleDownloadPage/ProgressDownloadPage.kt#L54-L185)、[完成窗口动作](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/singleDownloadPage/CompletedDownloadPage.kt#L37-L150)、[进度信息内容](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/singledownloadpage/BaseSingleDownloadComponent.kt#L282-L384)。

**推导**：进度窗口有 Info/Speed/On Completion 页签、进度条、错误入口和可伸缩分片信息；结束时能变成完成窗口。完成窗口显示文件名/类型/大小，并可打开、打开方式、打开文件夹、拖拽文件到其他应用、关闭。  
**限制**：自动打开门槛、完成窗口关闭时序见 DS-021；系统打开操作需要真实平台测试。

## DS-018 单项速度、线程及完成动作

**映射**：D-012、D-024、N-002、N-005、Q-005。  
**证据**：[单项设置与单位/继承值](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/singledownloadpage/BaseSingleDownloadComponent.kt#L231-L279)、[单项连接/限速设置与完成设置](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/singleDownloadPage/DesktopSingleDownloadPageComponent.kt#L70-L117)、[完成状态更新/单项完成窗口覆盖](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/singledownloadpage/BaseSingleDownloadComponent.kt#L103-L134)。

**推导**：线程数 0 使用全局，正数有最大范围；速度限制 0 表示无限制。单项完成窗口覆盖全局默认。桌面另提供下载完成后关机选项。  
**限制**：单项设置改动需等待 debounce 后写入任务；这只是源码事实，不指定新实现的内部延迟。睡眠/休眠静态实现未完成，D-024 记录平台边界。

## DS-019 外观/系统/API 设置控件定义

**映射**：D-013～D-017。  
**证据**：[通用设置控件定义与范围](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/settings/CommonSettings.kt#L269-L456)、[主题/语言/字体比例](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/settings/CommonSettings.kt#L457-L604)、[主题清单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/ui/theme/DefaultThemes.kt#L6-L190)、[系统主题选项与深浅分组](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/ui/theme/ThemeManager.kt#L24-L67)、[开机启动/通知声音/弹窗/API 字段](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/settings/CommonSettings.kt#L605-L746)、[桌面独有设置与 Render API 提醒](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/settings/DesktopSettings.kt#L16-L99)。

**推导**：大小单位二选一、速度单位四选一；UI 比例固定为八档；主题只有 System 时显示默认深浅主题；语言 System/可用语言；声音字段有路径、浏览 WAV、试听、清除。API 端口范围 0–65000，key 字符串控件展示有效/无效概况。Render API 的描述明确需要重启。

**限制**：`StringConfigurable` 的 API Key 文本显示遮掩方式及键盘粘贴行为需运行确认；此 UI 源码不足以证明 API Server 改值后何时重启。语言/字体可选项由运行环境提供，不以静态资源目录推定当前可用项。

## DS-020 设置默认值和数据存储边界

**映射**：D-013～D-017。  
**证据**：[共享默认值](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/storage/appsettings/DefaultAppSettings.kt#L11-L52)、[桌面特有默认值](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/desktopMain/kotlin/com/abdownloadmanager/shared/storage/appsettings/DefaultAppSettings.desktop.kt#L3-L9)、[设置模型字段验证](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/storage/appsettings/sharedAppSettingsDefination.kt#L21-L86)、[设置模型字段投影](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/storage/AppSettingsStorage.kt#L43-L90)。

**推导**：共享默认主题 dark，深色 dark、浅色 light；语言/font/UI 比例为系统/应用默认值；图标标签、相对日期、平均速度、进度/完成窗、登录启动、声音、默认分类、API 默认启用；API 默认端口 15151，认证关闭，Key 随首次配置生成；全局速度模式关闭但预设 256 KiB/s；线程 8、并发 3、重试 3、动态分片开、Last-Modified/后缀/取消删除关、最小部分 512 KiB、UA 空、TLS 忽略关、大小/速度为二进制单位。默认下载位置为系统 Downloads/ABDM；桌面稀疏分配/紧凑顶部栏/托盘默认开，mac 原生菜单默认关。

**限制**：这只确认缺少持久化值或坏值恢复时的应用默认，不说明用户安装升级后的实际已存储偏好。声音默认路径为空表示平台默认，是否真能播放由 OS 测试决定。

## DS-021 通知、自动弹窗、托盘和登录启动消费者

**映射**：D-014、D-015、D-023。  
**证据**：[完成/开始事件弹窗与错误通知分支](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/AppComponent.kt#L626-L677)、[托盘菜单](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/ui/Ui.kt#L203-L230)、[登录启动设置消费者](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/repository/BaseAppRepository.kt#L118-L140)、[通知声音映射](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/notification/BaseNotificationSound.kt#L23-L55)。

**推导**：下载完成发成功通知；开始事件可开进度窗口；完成事件可开完成窗口。错误时，如果没有进度窗且全局完成窗设为开，则弹错误详情，否则发送错误通知。托盘菜单提供列表、剪贴板添加、全局限速、设置、退出。登录启动变化传给平台注册器。声音按错误/成功/常规信息类别选择。  
**限制**：操作系统通知权限、不同 Linux 托盘协议、macOS Dock 显隐行为需真实 OS 测试。规则反映默认事件分支，单项覆盖另见 DS-018。

## DS-022 下载引擎设置入口和默认路径消费者

**映射**：D-015～D-017；下载语义指向 N-001/N-002/N-005/N-006。  
**证据**：[下载引擎页字段组](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/settings/DesktopSettingsComponent.kt#L141-L181)、[默认目录写入时更新分类目录引用](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/repository/BaseAppRepository.kt#L118-L127)。

**推导**：字段包括默认目录、默认分类、速度模式/值、线程、并发、重试、动态分片、最小分片、逐主机、代理、DNS、User-Agent、TLS、Last-Modified、追踪磁盘删除、未完成后缀、取消时删临时文件、稀疏分配。默认路径变化会更新跟随该默认路径的分类目录值。  
**限制**：实际下游消费者和字段应用对象由 N 领域说明，不以设置控件存在代替验证。

## DS-023 逐主机设置编辑器

**映射**：D-016、D-018、N-007。  
**证据**：[逐主机列表、搜索、增删](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/perhostsettings/PerHostSettingsPage.kt#L42-L135)、[搜索和工具栏](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/perhostsettings/PerHostSettingsPage.kt#L159-L254)、[编辑字段/草稿/保存与删除](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/perhostsettings/PerHostSettingsComponent.kt#L49-L92)、[Host/限速/线程/凭据/UA](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/perhostsettings/PerHostSettingsComponent.kt#L134-L253)、[新增删除未提交草稿](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/perhostsettings/PerHostSettingsComponent.kt#L256-L300)。

**推导**：主机列表可搜索，新增空 host 配置、删除选中项；右侧编辑 host、速度限制、线程数、用户名、密码、User-Agent。页面草稿与已保存值分开；Update 有差异才启用，保存后关闭；Cancel 丢弃编辑。  
**限制**：密码字段是否默认隐藏、重复 Host 保存规则、Host 匹配范围见运行验证和 N-007。

## DS-024 文件校验窗口与表格

**映射**：D-003、D-019。  
**证据**：[校验表列和摘要编辑动作](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/checksum/FileChecksumPage.kt#L54-L172)、[摘要复制/编辑控件](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/checksum/FileChecksumPage.kt#L236-L370)、[窗口大小/关闭](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/checksum/FileChecksumWindow.kt#L21-L64)。

**推导**：按任务显示名称、校验状态、算法、计算摘要、保存摘要；页底可选默认算法、Start、Close。计算值右击复制；保存值右击复制/编辑。关闭只关闭窗口。  
**限制**：源码确认算法名称与默认值见 DS-035；真实大文件计算结果、编辑值的系统剪贴板交互仍需运行核验。

## DS-025 文件校验计算与状态

**映射**：D-019。  
**证据**：[加载项目和自动校验条件](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/checksum/BaseFileChecksumComponent.kt#L39-L101)、[保存摘要更新和比较](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/checksum/BaseFileChecksumComponent.kt#L109-L169)、[开始计算/错误/结果](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/pages/checksum/BaseFileChecksumComponent.kt#L171-L269)。

**推导**：只对已完成且存在的本地文件计算摘要；有保存摘要的任务可以自动开始；没有摘要时仅计算并显示 Done，不称为匹配；结果分匹配、不匹配、计算完成、文件缺失、未完成、异常。  
**限制**：真实大文件取消响应、内存/CPU使用未测；关闭窗口时后台计算是否中断应按 D-019 重建约定验收。

## DS-026 下载错误对话框和剪贴板

**映射**：D-020、D-006、D-008、D-014。  
**证据**：[错误对话框展示/按钮](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/downloaderror/DownloadErrorPage.kt#L41-L165)、[复制错误 URL 与原因](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/downloaderror/DownloadErrorComponent.kt#L13-L44)。

**推导**：展示下载链接、错误标题/描述/建议；Copy 将 URL 与原因 JSON 复制；OK/关闭关闭错误窗。  
**限制**：剪贴板内容包含的错误原因字段可能含环境信息；脱敏策略需安全审阅，运行版是否可访问剪贴板未验证。

## DS-027 更新提示

**映射**：D-021。  
**证据**：[更新检查支持门槛](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/action/CommonActionFactories.kt#L184-L196)、[更新提示窗口和按钮](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/updater/UpdaterDialog.kt#L19-L54)、[版本号/日志/更新与取消](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/updater/NewUpdatePage.kt#L38-L104)、[按钮触发](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/updater/NewUpdatePage.kt#L139-L201)。

**推导**：Help 菜单检查更新仅当 updater 支持时启用；源码确认的入口是手动触发。有新版时显示新版本号和可滚动 Markdown changelog；Update 启动更新并关闭窗口，Cancel/窗口关闭只关闭对话框。检查中显示 loading 通知；无更新显示约三秒的信息通知，检查错误显示约三秒错误通知；发现新版本时打开更新窗口。
**限制**：静态搜索未找到启动时自动检查调用；未运行真实网络检查或更新安装。自动触发和系统通知呈现需运行确认。更新下载安装链路见 DS-034；固定源码未发现签名校验。

## DS-028 关于页

**映射**：D-022。  
**证据**：[关于对话框规格](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/about/AboutDialog.kt#L23-L71)、[应用名称/版本和网站区](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/about/AboutPage.kt#L54-L179)、[社区/网页链接](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/about/AboutPage.kt#L181-L229)、[翻译与开源入口](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/about/AboutPage.kt#L231-L327)。

**推导**：不可调整大小的关于窗口，显示产品身份、版本、项目网站、捐赠、源码、频道、群组、翻译贡献。子页通向翻译者名单和第三方许可证。  
**限制**：外部 URI 最终处理取决于系统浏览器。

## DS-029 第三方库许可列表和详情

**映射**：D-022。  
**证据**：[库列表与行点击](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/extenallibs/ExternalLibsPage.kt#L23-L153)、[库详情和许可链接](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/extenallibs/LibraryDialog.kt#L36-L160)。

**推导**：列表显示名称、版本、artifact ID、作者、许可证；点行打开详情，展示可用描述、开发者、组织、链接和许可。  
**限制**：清单随构建库数据而变，不把某次构建中的完整库名单硬编码为产品功能。

## DS-030 退出确认

**映射**：D-023。  
**证据**：[退出确认对话框](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/confirmexit/ConfirmExit.kt#L12-L23)。

**推导**：确认退出 UI 为警告型对话框，Cancel 关闭，Confirm 调用异步退出。  
**限制**：触发条件及活动下载在退出时如何保存/提示需应用生命周期调用链或原版运行进一步确定。D-023 对新实现明确了用户可见处理。

## DS-031 电源动作倒计时提醒

**映射**：D-024。  
**证据**：[提醒窗口/倒计时文案/原因](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/poweractionalert/PowerActionAlertWindow.kt#L44-L199)、[立即执行/取消按钮](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/poweractionalert/PowerActionAlertWindow.kt#L202-L239)、[倒计时和动作结果](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/poweractionalert/PowerActionComponent.kt#L22-L108)。

**推导**：默认 30 秒，倒计时到期或立即执行会先处理回调再尝试动作；取消关闭提醒。失败显示错误状态/原因。触发原因包括队列完成、队列结束时间、下载完成和未知。

## DS-032 桌面电源动作平台边界

**映射**：D-012、D-024。  
**证据**：[可选动作枚举](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/shared/src/main/kotlin/ir/amirab/util/desktop/poweraction/PowerActionConfig.kt#L3-L16)、[macOS 操作分派](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/shared/src/main/kotlin/ir/amirab/util/desktop/poweraction/PowerActionMac.kt#L5-L20)、[Linux 操作分派](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/shared/src/main/kotlin/ir/amirab/util/desktop/poweraction/PowerActionLinux.kt#L5-L32)、[Windows 操作分派](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/shared/src/main/kotlin/ir/amirab/util/desktop/poweraction/PowerActionWindows.kt#L5-L17)。

**推导**：动作枚举含 Shutdown、Hibernate、Sleep，但各 OS 适配器中的 Hibernate/Sleep 当前静态实现为未完成功能。macOS Shutdown 有 AppleScript 调用；Linux 有两种关机命令回退；Windows 执行关机命令。  
**限制**：没有运行或真实执行任何电源操作。源码返回布尔值不证明 OS 接受、授权或完成操作。

## DS-033 Linux 创建桌面入口

**映射**：D-001、D-025。  
**证据**：[菜单入口限制](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/pages/home/HomeComponent.kt#L165-L224)。

**推导**：工具菜单“创建桌面入口”在 Linux 分支存在；Windows/macOS 不显示。  
**限制**：本证据只证明 UI 入口，不证明创建 desktop entry 成功或文件内容正确；重建验收必须检查系统桌面真实启动行为。

## DS-034 更新发现、下载与安装流程

**映射**：D-021。  
**证据**：[检查状态和更新动作](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/commonMain/kotlin/com/abdownloadmanager/UpdateManager.kt#L28-L64)、[按当前版本筛选新版](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/commonMain/kotlin/com/abdownloadmanager/updatechecker/UpdateChecker.kt#L6-L16)、[GitHub 最新发布、平台/架构资产和摘要字段](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/commonMain/kotlin/com/abdownloadmanager/updatechecker/GithubUpdateChecker.kt#L17-L55)、[应用内更新下载与复用记录](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/updater/UpdateDownloaderViaDownloadSystem.kt#L19-L60)、[更新文件准备与安装器启动](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/commonMain/kotlin/com/abdownloadmanager/updateapplier/BaseUpdateApplier.kt#L10-L49)、[桌面支持条件和资产选择](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/desktopMain/kotlin/com/abdownloadmanager/updateapplier/DesktopDirectLinkUpdateApplier.kt#L19-L75)、[平台压缩包更新器](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/desktopMain/kotlin/com/abdownloadmanager/updateapplier/UpdateInstallerFromArchiveFile.kt#L83-L129)、[Windows 安装程序启动](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/updater/src/desktopMain/kotlin/com/abdownloadmanager/updateapplier/UpdateInstallerByWindowsExecutable.kt#L5-L14)。

**推导**：检查读取 GitHub 最新发布，选择当前平台和兼容架构的资产，并与当前语义版本比较。`.md5` 文件资产被跳过，普通更新资产的摘要字段为 null；未发现更新器执行签名或摘要比较。无兼容更新资产会触发检查错误。桌面更新只在安装目录可写时支持；Windows 检测到 NSIS 安装且有 `.exe` 资产时选择安装程序，否则选择支持的 zip/tar.gz 压缩包。压缩包、Windows 安装程序通过外部更新器启动，意图停止旧进程、替换安装文件并重新打开应用。更新准备使用应用下载系统，记录放在专用更新目录，可复用同名下载，文件缺失时重置；不会放入用户队列或分类。

**限制**：静态代码只能证明启动外部更新器，未证明实际下载、替换、重启成功；下载器等待完成或取消后仅检查目标文件存在。不能把文件存在等同于文件完整，也不能报告签名已验证。平台脚本的真实权限、安装目录和杀毒软件行为未执行。

## DS-035 内置主题与文件摘要算法

**映射**：D-013、D-019。  
**证据**：[七个内置主题及默认深浅主题](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/ui/theme/DefaultThemes.kt#L6-L190)、[系统主题可选条件和浅深主题分组](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/ui/theme/ThemeManager.kt#L24-L67)、[校验算法列表、默认值和摘要格式](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/HashUtil.kt#L8-L46)。

**推导**：内置主题名称为 Dark、Light、Obsidian、Deep Ocean、Twilight、Black、Light Gray。仅系统主题探测器支持时添加 System 选项；默认深色 Dark、默认浅色 Light。校验算法固定为 MD5、SHA-1、SHA-256、SHA-512，默认 SHA-256；可序列化摘要格式为 `算法名:摘要值`。

**限制**：列表与默认值静态确认；没有运行原版主题切换、实际文件摘要或跨平台系统主题探测。

## 覆盖与未确定

- 桌面规格共 25 个功能编号 `D-001` 至 `D-025`，另含快捷键与平台差异汇总。
- 本证据文件共 35 条，覆盖主窗、列表、添加/编辑、分类/队列、设置、校验、错误、更新、关于、退出和电源动作。父规格另行整合 N/Q/I/B 领域。
- 版本特别补入：JSON 对象/数组剪贴板导入/导出、记住最近队列与长按 Add、选中数量/大小、开始/完成时间列、Open With。Location 列仅属于当前审计 master 的新增内容。
- 没有运行或安装原版，也没有实际执行通知/登录启动/更新/关机。证据只支持静态行为推导；D 规格对用户可验收行为给出明确规则，并在原版运行效果未知时保留 `[U]` 或标明 `[R]`。

## DS-036 HTTP凭据交换字段补证

映射D-026。根审在固定提交核对 [HttpDownloadCredentials.kt](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/downloader/core/src/commonMain/kotlin/ir/amirab/downloader/downloaditem/http/HttpDownloadCredentials.kt#L10-L22)、[JSON导入导出](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/extractors/linkextractor/DownloadCredentialsFromJson.kt#L10-L29)、[cURL解析和生成](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/extractors/linkextractor/DownloadCredentialsFromCurl.kt#L5-L48)。HTTP可交换link/headers/username/password/downloadPage/userAgent，非任务数据库。cURL只做字符串识别，不执行命令，原正则不覆盖完整shell引号语法；新实现自己的输出能往返是R。

## DS-037 分类组合匹配、优先级与恢复默认补证

映射D-010。根审核对 [CategoryManager.kt L41-L109](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/CategoryManager.kt#L41-L109) 与 [Category.kt L50-L95](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/util/category/Category.kt#L50-L95)。类别同时有扩展名和URL条件时AND；URL条件/模式数量/文件类型条件/类型数量决定优先级。reset先替换默认类别并对全部现有项重新匹配，不能描述成保留所有手工分类。确认保护是R，非原版已证明行为。

## DS-038 渲染兼容选项与平台默认

映射D-013。根审核对 [RenderApi.kt L24-L99](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/desktop/app/src/main/kotlin/com/abdownloadmanager/desktop/utils/renderapi/RenderApi.kt#L24-L99)：Mac不指定自有后端默认（Default），有效显式选项Metal/OpenGL/Software；Linux自有默认Software；Windows按架构选择OpenGL/ANGLE。环境显式指定可覆盖保存选择。这些是原产品兼容选项，不是要求新实现复刻内部框架。
