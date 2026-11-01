# 文档入口与事实边界

现役实现为 2026-10-18 替换后的 Swift/macOS 26+ App、CLI/Native Host 和 Chrome MV3 扩展。当前交付、Git 同步与复验结果以根目录 [PROGRESS.md](../PROGRESS.md) 的最新记录为准；产品阻塞以 [BLOCKED.md](../BLOCKED.md) 为准。

## 现役说明

- [README](../README.md)：安装版本、构建和使用入口。
- [设计与功能落点](native-rebuild/design-and-coverage.md)：当前模块、数据边界和功能入口；界面后续修订见 PROGRESS。
- [Chrome 安装](native-rebuild/chrome-install.md)：扩展与专属 Native Messaging 注册。
- [手测清单](native-rebuild/manual-test-checklist.md)和[回填表](native-rebuild/test-result-template.md)：A-001…A-070；当前版本全部待用户测试。
- [安装记录](../INSTALL_LEDGER.md)：替换和恢复凭证。未发生安装时不追加安装事件。
- [项目规则](../AGENTS.md)：执行限制；机器政策通过唯一源路径读取。

## API 合同边界

根目录 [REST-API.yml](../REST-API.yml) 是继承的上游 1.0 规格，保留作兼容参考，不是当前完整合同。现役路由、授权、错误和回执以 [IntegrationServer.swift](../Sources/ZJXDownloadCore/IntegrationServer.swift) 为准；配套消费者为 [Chrome app-api.js](../browser-extension/src/app-api.js)、[Native Host](../Sources/ZJXDownloadNativeHost/NativeHost.swift) 和 [CLI](../Sources/ZJXDownloadCLI/main.swift)。

当前源码含 `POST /ping`、`POST /add`、`POST /start-headless-download`、`GET /queues`、`POST /queues/{id}/start`、`GET /tasks`、任务操作、扩展设置读取/更新和退出请求。添加接口返回含 `requestId`、`accepted`、`acceptedCount`、`acceptedTaskIDs`、逐项结果的 JSON；接收不等于下载完成。默认 loopback 端口 15151；可选密钥通过 `X-API-Key` 传递，Origin/Host 和请求长度/期限另有校验。这里仅说明源码合同，未通过运行请求验收；NWError 22 与 Chrome 交接仍 pending。

## 历史资料

- `native-rebuild/` 的日期版发布、故障、修复与 worker 文档：2026-10-18 交付过程，不能替代最新 PROGRESS 和当前手测表。
- `native-completeness-audit/`、`macos-native-rewrite-plan.md`、`feature-matrix-round2.md`、`audit-upstream-notes.md`：替换前实现的审计、任务书和证据；其中测试数、类型名和验收结论不适用于现役代码。历史证据路径可能已归档，不作为待执行命令或当前通过证据。
- `clean-room-rebuild/`、`reverse-analysis-evidence/`：保留原始规格和证据，不改写。旧阶段执行限制由现役项目规则及后续用户授权覆盖。
- 根目录 `CHANGELOG.md`：上游版本历史；`DONATE.md` / `.github/FUNDING.yml` 的链接支持上游作者。

## 构建自动化边界

本地入口见 README。现存 `.github/workflows/release.yml` 使用 `macos-14`、`latest-stable` Xcode 和 ad-hoc 签名，只打 App 包，并可在 `v*` tag 上创建 Release。该流程尚未按当前 macOS 26 SDK/Swift 6.2、双架构 CLI、Chrome 和签名交付要求验证；不能当作当前发布保障。本次文档维护不触发 workflow、tag 或 Release，后续发布前需单独修订并验证。
