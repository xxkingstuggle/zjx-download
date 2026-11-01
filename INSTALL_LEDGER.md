# 安装记录

## 2026-10-23 界面与系统外观修复

- 目标：`/Applications/zjx-download.app`，2.0.1/build20261018.2 → 2.0.2/build20261023.1。
- 来源：`/Users/zjx/Developer/releases/zjx-download/2.0.2-ui-20261023/zjx-download.app`，独立 DerivedData Universal Release 构建。
- 替换前未发现 App、Native Host 或 CLI 运行进程。先暂存并验证新包，再将旧包完整移至回退目录，最后将新包移入目标路径；未启动 App。
- 回退包：`/Users/zjx/Developer/releases/zjx-download/archive/20261023-pre-ui-20261023.1/zjx-download.app`，同目录 `RECOVERY.md` 说明恢复步骤；旧主程序 SHA-256 与替换前一致。
- 核对：App/Host/Core/CLI 均 arm64+x86_64，包内仅 ZJXDownloadCore.framework；签名 Team ZNSTKHPLY3，`codesign --verify --deep --strict` 通过；产品标识 com.zjx.download，原图标字节保持。
- 不涉及任务数据库、下载、设置、目录授权、凭据、Native Messaging 注册或全局环境变更；UI/系统外观切换待用户手测。
