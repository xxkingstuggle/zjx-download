# zjx-download 2.0.1 / build20261018.2

交付日期：2026-10-18。Mac原生App与Chrome配套扩展2.0.1。**功能/性能验收：全部待用户测试。**

## 本次修复

- 同值设置不再触发重复持久化、DNS/网络/限速重配置；App级服务与事件处理独立于主窗口生命周期。
- 网络进度有界合并，Range/HLS准备、合并和最终文件复制离开主线程；任务代次隔离取消、重下和迟到回调。
- 文件提交保留替换备份，核验长度/摘要、目标保留标识和文件身份后保存完成状态；失败和取消保留可恢复线索。
- Chrome/HTTP/Native/CLI共享真实逐项接收回执、requestId去重、审批取消和期限；只有明确接收才取消对应Chrome下载。
- 只读状态恢复、跨来源凭据、HTTP边界、cURL解析、数值溢出、主窗口关闭后入口及更新器校验补齐。
- 发现与源码证据：repair-findings-20261018.md；主代理审核：repair-review-20261018.md。不能由代码审查推断已证明用户卡死的唯一触发链。

## 实际交付核对

| 项目 | 实际结果 |
| --- | --- |
| Xcode Release Universal | exit0，BUILD SUCCEEDED；App+Native Host+ZJXDownloadCore均x86_64/arm64 |
| SwiftPM CLI | arm64 exit0 / x86_64 exit0，lipo合并Universal并签名 |
| Chrome build | npm run build:chrome exit0；manifest 2.0.1 / background.type=module |
| 签名 | Apple Development，Team ZNSTKHPLY3；codesign --verify --deep --strict exit0；未公证 |
| 安装 | /Applications/zjx-download.app，2.0.1/build20261018.2，未启动 |
| 名称/身份 | zjx-download / com.zjx.download |
| 图标 | Mac icns及Chrome源图标字节与安装前一致 |
| 日用数据 | state-v2与legacy state安装前后SHA-256一致；未迁移、清空或修改凭据/下载文件 |
| Native Messaging | 既有专属注册只读核对，固定扩展ID ikfafcgjoghicpkoolbofdaoonendhak，路径仍为安装App内Helper |
| 功能测试 | 未运行；A-001…A-067全部待用户测试 |

构建命令和失败迭代记录在repair-review-20261018.md；全部日志在发布目录build-logs/。最终Xcode提示未依赖AppIntents而跳过元数据提取，不影响构建成功。

## 路径与恢复

- 正式源码：/Users/zjx/Developer/repos/zjx-download；独立仓库https://github.com/xxkingstuggle/zjx-download，正式默认分支main；构建前基线0f1245261f429bd6378b43603b2a6f45eb263ef3；完整源码提交177bdd9a69005eba9fbbcc800969e719750ca666先推送工作分支，后按2026-10-19用户澄清接入main，最新交付记录见Git与PROGRESS.md。
- 发布目录：/Users/zjx/Developer/releases/zjx-download/2.0.1-repair-20261018/。
- 新App：该目录zjx-download.app及zjx-download-macos-2.0.1.zip；CLI在bin/zjx-download-cli，未改全局PATH。
- Chrome：browser-extension/dist/chrome/及zjx-download-chrome-2.0.1.zip。用户在chrome://extensions重新加载此目录；两端均应显示2.0.1，App build20261018.2。
- 旧App：/Users/zjx/Developer/releases/zjx-download/archive/20261018-pre-repair-20261018.2/zjx-download.app；附RECOVERY.md，旧版本2.0.0/build20261018.1。
- 旧源码及规格归档：/Users/zjx/Developer/releases/zjx-download/archive/20261018-040041-pre-clean-room/，保留Git bundle、原测试、未跟踪规格/审计材料及恢复说明。
- 本次修复源码差异：旧App归档同级repair-source.patch，仅含相对本轮起点的源码改动，不能代替完整Git历史。
- 构建与诊断scratch：/Users/zjx/Developer/scratch/codex/zjx-download-repair-20261018.2/，保留排错，不自动清理。仓库.agent-work中保留源码基线/哈希，无日用数据副本。

回退时先正常退出App和Native Host，保留当前App后将归档旧包整体恢复到/Applications/zjx-download.app；不要将两个包合并复制。现用状态仍为schema2，新增回执字段为可选；本次未执行数据格式迁移。回退前保留用户数据快照，不删除状态或下载文件。

## 用户测试

1. 先填测试环境，执行A-053/A-054：冷启动、空任务、同值设置、关闭主窗口、菜单栏和服务生命周期。
2. 执行A-002/A-005/A-006：普通下载、暂停/退出恢复、文件长度与独立SHA-256。
3. 更新Chrome2.0.1，执行A-032…A-043及A-055/A-060/A-061/A-066：真实接收、拒绝、失败回退、重复请求和审批超时。
4. 其余用例按manual-test-checklist.md逐项填写；旧数据迁移只在用户测试配置操作。

结果表：test-result-template.md。Bug报告包含测试编号、App与扩展版本、复现步骤、实际现象、预期结果，可附截图/脱敏日志；不要提供真实Cookie、API key或密码。无现场堆栈时不把卡死原因写成唯一确定结论。

## 当前阻塞

无（源码实施、必要构建、签名和安装）；功能与性能仍待用户测试。没有启动App、操作日用Chrome、跑自动化测试/真实下载回归、故障注入或性能压测。

## 2026-10-19 交付补充

App ZIP已实际解压并核对严格签名、安装与ZIP内可执行哈希一致；Chrome ZIP已核对manifest版本和模块声明。SHA256SUMS覆盖发布文件；此项是产物核对，没有启动App或运行功能测试。
