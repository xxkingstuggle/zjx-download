# 开工回执 · 2026-10-18
1. 目标：保留 `zjx-download` 名称、Bundle ID `com.zjx.download` 和图标，独立重写 macOS 26＋Chrome，实现规格覆盖并安装到 `/Applications/zjx-download.app`。
2. 顺序：归档旧提交/测试/未跟踪规格 → 建立功能落点 → 重写共享任务与持久化/网络 → 原生界面和系统集成 → Chrome/CLI → 构建、打包、安装 → 交付用户手测表。
3. 基线：`feat/macos-native-liquid-glass`，HEAD `0f1245261f429bd6378b43603b2a6f45eb263ef3`；无 tracked diff、worktree、stash。
4. 实施分支：`zjx/clean-room-native-rebuild`；旧分支保留。
5. 归档：`~/Developer/releases/zjx-download/archive/20261018-040041-pre-clean-room/`；Git bundle 已验证，旧 `Tests/` 与两份未跟踪文档树已收录并计算 SHA-256。
6. 身份：scheme/可执行文件/产品名 `zjx-download`，Bundle ID `com.zjx.download`，目标平台 macOS 26。
7. 图标 SHA-256：Mac `f9d1cda5b7af1a121d69275d7277236652f2e946f901269590e38073c7998564`；Chrome 16 `6064b8c3d9bc8181cf8b37656ac6b559b6c3387314effeaec01b1544c186d9fa`、32 `8ccea0c567e9a2012ecb4a0fe64da2a6462d7bb0963e02263ad5c809446955ab`、48 `74f9596022ea06636b9e9830112501dfb4923e6949e4391603e015f4de9b873d`、96 `8d853c467b8749069af5818e637ce47593dacf24d5770b486665a45ac8221093`、128 `6e8a25f8ebbabc6b22477c5a2842c43758c3370d7442f65091825f18dea5b5d1`.
8. 构建入口：`xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`；Chrome：`cd browser-extension && npm run build:chrome`。
9. 最大风险：旧数据/授权/凭据兼容和断点下载文件正确性；不操作现用数据，不运行功能测试，用户测试状态全部保持“待用户测试”。
