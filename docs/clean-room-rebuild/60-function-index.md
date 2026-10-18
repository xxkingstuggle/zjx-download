# 功能编号索引

方向版本0.2 · 2026-10-18。保留80组功能与通用规则、50条跨模块验收场景和15条历史候选/差异记录作为覆盖索引。

用户目标与基础正确性优先；S为原版事实，R为作者候选，U为未核实事实。具体默认、架构和增强功能按[当前方向](01-native-rebuild-direction.md)选择，不视为用户已批准。实现与运行状态仍为未开始。

| 领域 | 组数 |
|---|---|
| 通用要求 | 17 |
| 桌面操作与设置 | 26 |
| 下载与网络 | 11 |
| 队列与计划 | 4 |
| 公开接口与CLI | 3 |
| 浏览器扩展 | 19 |

| 编号 | 功能/要求 | 规格位置 | 证据编号 |
|---|---|---|---|
| G-001 | [R] 功能入口必须形成完整闭环 | [正文](00-scope-and-rules.md#g-001) | 作者约定/基础正确性 |
| G-002 | [R] 任务记录与文件分别处理 | [正文](00-scope-and-rules.md#g-002) | 作者约定/基础正确性 |
| G-003 | [R] 执行状态与磁盘事实一致 | [正文](00-scope-and-rules.md#g-003) | 作者约定/基础正确性 |
| G-004 | [R] 所有设置都有实际作用和生效范围 | [正文](00-scope-and-rules.md#g-004) | 作者约定/基础正确性 |
| G-005 | [R] 表单取消与失败可恢复 | [正文](00-scope-and-rules.md#g-005) | 作者约定/基础正确性 |
| G-006 | [R] 重启有明确结果 | [正文](00-scope-and-rules.md#g-006) | 作者约定/基础正确性 |
| G-007 | [R] 批量命令遵守可见范围和选择范围 | [正文](00-scope-and-rules.md#g-007) | 作者约定/基础正确性 |
| G-008 | [R] 浏览器接管有可验证的交接结果 | [正文](00-scope-and-rules.md#g-008) | 作者约定/基础正确性 |
| G-009 | [R] 请求凭据限定在下载用途 | [正文](00-scope-and-rules.md#g-009) | 作者约定/基础正确性 |
| G-010 | [R] 平台操作采用 macOS 可用行为 | [正文](00-scope-and-rules.md#g-010) | 作者约定/基础正确性 |
| G-011 | [R] 先证实协议范围 | [正文](00-scope-and-rules.md#g-011) | 作者约定/基础正确性 |
| G-012 | [R] 错误必须指向下一步操作 | [正文](00-scope-and-rules.md#g-012) | 作者约定/基础正确性 |
| G-013 | [R] 易用性按真实任务验证 | [正文](00-scope-and-rules.md#g-013) | 作者约定/基础正确性 |
| G-014 | [R] 本轮完成文档，不启动开发 | [正文](00-scope-and-rules.md#g-014) | 作者约定/基础正确性 |
| G-015 | [S/R] 同一份用户数据只由一个应用实例管理 | [正文](00-scope-and-rules.md#g-015) | GS-001 |
| G-016 | [S/R] 普通启动、后台启动和重新显示主窗分别定义 | [正文](00-scope-and-rules.md#g-016) | GS-002 |
| G-017 | [S/R] 应用异常有独立于下载错误的反馈 | [正文](00-scope-and-rules.md#g-017) | GS-003 |
| D-001 | 主页面、入口和筛选 | [正文](10-desktop-functional-spec.md#d-001) | DS-001、DS-002、DS-003 |
| D-002 | 下载列表、列、排序和选择 | [正文](10-desktop-functional-spec.md#d-002) | DS-002、DS-003 |
| D-003 | 菜单命令、快捷键与删除范围 | [正文](10-desktop-functional-spec.md#d-003) | DS-001、DS-003、DS-004、DS-005 |
| D-004 | 新建网址与凭据导入 | [正文](10-desktop-functional-spec.md#d-004) | DS-006、DS-007 |
| D-005 | 批量网址生成 | [正文](10-desktop-functional-spec.md#d-005) | DS-008 |
| D-006 | 单条添加下载 | [正文](10-desktop-functional-spec.md#d-006) | DS-007、DS-009、DS-010 |
| D-007 | 重复下载冲突 | [正文](10-desktop-functional-spec.md#d-007) | DS-008、DS-009 |
| D-008 | 编辑现有下载 | [正文](10-desktop-functional-spec.md#d-008) | DS-005、DS-011 |
| D-009 | 多条链接添加 | [正文](10-desktop-functional-spec.md#d-009) | DS-006、DS-012 |
| D-010 | 分类管理 | [正文](10-desktop-functional-spec.md#d-010) | DS-013、DS-014、DS-037 |
| D-011 | 队列界面入口 | [正文](10-desktop-functional-spec.md#d-011) | DS-015、DS-016 |
| D-012 | 下载进度、完成窗口和单项设置 | [正文](10-desktop-functional-spec.md#d-012) | DS-017、DS-018 |
| D-013 | 设置页面结构和外观 | [正文](10-desktop-functional-spec.md#d-013) | DS-019、DS-020 |
| D-014 | 通知、登录启动和系统托盘 | [正文](10-desktop-functional-spec.md#d-014) | DS-019、DS-020、DS-021 |
| D-015 | 默认下载目录和路径选择器 | [正文](10-desktop-functional-spec.md#d-015) | DS-007、DS-009、DS-019、DS-021 |
| D-016 | 下载引擎设置入口 | [正文](10-desktop-functional-spec.md#d-016) | DS-019、DS-022 |
| D-017 | 浏览器集成设置入口 | [正文](10-desktop-functional-spec.md#d-017) | DS-019、DS-022 |
| D-018 | 逐主机设置窗口 | [正文](10-desktop-functional-spec.md#d-018) | DS-019、DS-023 |
| D-019 | 文件校验工具 | [正文](10-desktop-functional-spec.md#d-019) | DS-024、DS-025、DS-035 |
| D-020 | 下载错误对话框 | [正文](10-desktop-functional-spec.md#d-020) | DS-026 |
| D-021 | 更新检查与版本提示 | [正文](10-desktop-functional-spec.md#d-021) | DS-027、DS-034 |
| D-022 | 关于、致谢、翻译和开源许可 | [正文](10-desktop-functional-spec.md#d-022) | DS-028、DS-029 |
| D-023 | 退出确认 | [正文](10-desktop-functional-spec.md#d-023) | DS-001、DS-030 |
| D-024 | 下载完成后的系统电源动作 | [正文](10-desktop-functional-spec.md#d-024) | DS-018、DS-031、DS-032 |
| D-025 | 平台专有桌面入口 | [正文](10-desktop-functional-spec.md#d-025) | DS-001、DS-033 |
| D-026 | JSON/cURL 交换格式与任务数据边界 | [正文](10-desktop-functional-spec.md#d-026) | DS-006、DS-036 |
| N-001 | HTTP/HTTPS 下载创建、请求字段和命名 | [正文](20-download-queue-network-spec.md#n-001) | NS-01、NS-02、NS-03、NS-04、NS-05、QS-01 |
| N-002 | Range、并发分片、断点恢复与重试 | [正文](20-download-queue-network-spec.md#n-002) | NS-02、NS-05、NS-06、NS-07、NS-08、NS-09、NS-10、NS-11、NS-12 |
| N-003 | 输出文件、剩余空间、时间戳和部分文件 | [正文](20-download-queue-network-spec.md#n-003) | NS-05、NS-06、NS-08、NS-09、NS-11、NS-12、NS-13、NS-14 |
| N-004 | HLS 下载范围和限制 | [正文](20-download-queue-network-spec.md#n-004) | NS-04、NS-15、NS-16、NS-17、NS-18 |
| N-005 | 全局与单任务速度、连接和重试设置 | [正文](20-download-queue-network-spec.md#n-005) | NS-06、NS-19、NS-20、QS-02 |
| N-006 | 代理、DNS、TLS、User-Agent 与 HTTP 协议 | [正文](20-download-queue-network-spec.md#n-006) | NS-02、NS-10、NS-21、NS-22、NS-23、NS-24 |
| N-007 | 逐主机下载覆盖 | [正文](20-download-queue-network-spec.md#n-007) | NS-02、NS-25、NS-26 |
| N-008 | 下载期间防止系统睡眠 | [正文](20-download-queue-network-spec.md#n-008) | NS-27、NS-28 |
| N-009 | 文件校验工具 | [正文](20-download-queue-network-spec.md#n-009) | NS-29 |
| Q-001 | 队列模型、默认队列和删除 | [正文](20-download-queue-network-spec.md#q-001) | QS-01、QS-02、QS-03 |
| Q-002 | 顺序、并发和任务状态流转 | [正文](20-download-queue-network-spec.md#q-002) | NS-05、QS-01、QS-02、QS-03、QS-04 |
| Q-003 | 周期计划和空队列策略 | [正文](20-download-queue-network-spec.md#q-003) | QS-02、QS-05、QS-06 |
| Q-004 | 下载完成动作 | [正文](20-download-queue-network-spec.md#q-004) | QS-05、QS-06、QS-07、QS-08 |
| I-001 | 本地 REST 服务线协议 | [正文](20-download-queue-network-spec.md#i-001) | IS-01、IS-02、IS-03、IS-04、IS-05、IS-06、IS-07 |
| I-002 | 桌面 CLI 命令与能力范围 | [正文](20-download-queue-network-spec.md#i-002) | IS-05、IS-08、IS-09、IS-10、IS-11、NS-08、NS-12 |
| I-003 | 原生消息通信与启动交接 | [正文](20-download-queue-network-spec.md#i-003) | IS-12 |
| N-010 | 磁盘文件删除跟踪与缺失项清理 | [正文](20-download-queue-network-spec.md#n-010) | NS-30 |
| N-011 | 新产品的状态与恢复约定 | [正文](20-download-queue-network-spec.md#n-011) | 作者约定/基础正确性 |
| B-001 | 浏览器安装、权限与入口 | [正文](30-browser-integration-spec.md#b-001) | BS-001、BS-002、BS-003、BS-004、BS-005、BS-006、BS-013、BS-014、BS-024 |
| B-002 | 配置保存与即时生效 | [正文](30-browser-integration-spec.md#b-002) | BS-004、BS-014、BS-015、BS-024 |
| B-003 | 工具栏弹窗与连接状态 | [正文](30-browser-integration-spec.md#b-003) | BS-002、BS-010、BS-014 |
| B-004 | 右键菜单单项下载 | [正文](30-browser-integration-spec.md#b-004) | BS-002、BS-005、BS-007、BS-009、BS-017 |
| B-005 | 右键下载选区内链接 | [正文](30-browser-integration-spec.md#b-005) | BS-002、BS-005、BS-006、BS-009、BS-024 |
| B-006 | 拖选文字后的“下载选中链接”快捷条 | [正文](30-browser-integration-spec.md#b-006) | BS-002、BS-006 |
| B-007 | 自动接管浏览器下载 | [正文](30-browser-integration-spec.md#b-007) | BS-002、BS-003、BS-004、BS-007、BS-024 |
| B-008 | 新标签页自动关闭 | [正文](30-browser-integration-spec.md#b-008) | BS-002、BS-004、BS-007、BS-015、BS-024 |
| B-009 | 绕过自动接管快捷键 | [正文](30-browser-integration-spec.md#b-009) | BS-004、BS-007、BS-008 |
| B-010 | 站点忽略规则、后缀与大小门槛 | [正文](30-browser-integration-spec.md#b-010) | BS-002、BS-004、BS-007、BS-011、BS-015、BS-024 |
| B-011 | Cookie、请求头与认证信息 | [正文](30-browser-integration-spec.md#b-011) | BS-002、BS-004、BS-005、BS-007、BS-009、BS-010、BS-012 |
| B-012 | 静默添加与静默开始 | [正文](30-browser-integration-spec.md#b-012) | BS-004、BS-006、BS-009、BS-010、BS-013、BS-014、BS-015、BS-017 |
| B-013 | HTTP 音视频发现 | [正文](30-browser-integration-spec.md#b-013) | BS-002、BS-006、BS-007、BS-011、BS-012 |
| B-014 | HLS 清单、质量、音轨与 DRM | [正文](30-browser-integration-spec.md#b-014) | BS-007、BS-011、BS-012、BS-024 |
| B-015 | 网页媒体候选条 | [正文](30-browser-integration-spec.md#b-015) | BS-002、BS-006、BS-011、BS-012 |
| B-016 | 应用 API 与队列 | [正文](30-browser-integration-spec.md#b-016) | BS-004、BS-009、BS-010、BS-013、BS-016、BS-017 |
| B-017 | Native Messaging 通道 | [正文](30-browser-integration-spec.md#b-017) | BS-002、BS-009、BS-010、BS-013、BS-024 |
| B-018 | 设置页字段、默认值与生效点 | [正文](30-browser-integration-spec.md#b-018) | BS-004、BS-015、BS-024 |
| B-019 | 通知与错误提示 | [正文](30-browser-integration-spec.md#b-019) | BS-002、BS-009、BS-012、BS-017 |
