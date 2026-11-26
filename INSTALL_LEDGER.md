# 安装记录

## 2026-11-17 本机接口启动修复

- `/Applications/zjx-download.app` 从 2.0.3/build20261117.1 更新为 2.0.4/build20261117.2（独立 DerivedData 的 Universal Release 签名构建）。
- 确认 App、Native Host 与 CLI 均退出后，归档原包并装入新包。新版尚未启动。
- App、解包 ZIP、安装包通过严格签名校验，签名团队、产品标识及原图标一致。

## 2026-11-17 主窗口外观更新

- `/Applications/zjx-download.app` 从 2.0.2/build20261023.1 更新为 2.0.3/build20261117.1（Universal Release 构建来自独立 DerivedData）。
- 通过应用退出确认正常退出旧版。确认 App、Native Host 与 CLI 均已退出后，先归档旧包，再装入已验签的新包。新版尚未启动。
- App、解包 ZIP 和安装包均通过 `codesign --verify --deep --strict`。签名团队为 Apple Development Team，原图标字节一致。App、Host、Core 和 CLI 均为 arm64/x86_64。

## 2026-10-23 界面与系统外观修复

- 目标：`/Applications/zjx-download.app`，2.0.1/build20261018.2 → 2.0.2/build20261023.1。
- 来源：独立 DerivedData Universal Release 构建。
- 替换前未发现 App、Native Host 或 CLI 运行进程。先暂存并验证新包，再将旧包完整移至回退目录，最后将新包移入目标路径；未启动 App。
- 核对：App/Host/Core/CLI 均 arm64+x86_64，包内仅 ZJXDownloadCore.framework；签名 Developer Team，`codesign --verify --deep --strict` 通过；产品标识 com.zjx.download，原图标字节保持。
- 不涉及任务数据库、下载、设置、目录授权、凭据、Native Messaging 注册或全局环境变更；UI/系统外观切换待用户手测。
