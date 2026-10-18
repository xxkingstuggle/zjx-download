# Chrome 配套扩展

App 版本：2.0.1 / build20261018.2；扩展版本：2.0.1 / MV3。扩展目录：`browser-extension/dist/chrome/`；打包文件：随发布包提供的 `zjx-download-chrome-2.0.1.zip`。扩展 ID：`ikfafcgjoghicpkoolbofdaoonendhak`。Manifest 中的固定公钥用于保持解压扩展 ID 与本机 host 注册一致。

## 安装

1. 安装 `/Applications/zjx-download.app`。安装步骤会配置本项目专属 Native Messaging host；Chrome 必须重启后才会重新读取该注册。首次打开 App 后，在“设置 → 集成”确认 API 已启用且端口与扩展设置一致。
2. Chrome 打开 `chrome://extensions`，启用“开发者模式”。
3. 选择“加载已解压的扩展程序”，指向 `/Users/zjx/Developer/releases/zjx-download/2.0.1-repair-20261018/browser-extension/dist/chrome`。已有扩展则更新目录后点“重新加载”，不要同时装两份。
4. 打开扩展“选项”，检查 App 连接状态。扩展不会静态注入网站脚本；自动接管、选区和媒体候选仅在用户打开相应选项并授权网站访问后启用。请求头/Cookie 另需用户授权。
5. 安装后检查 `/Applications/zjx-download.app/Contents/Helpers/manage-native-host` 和 Chrome 用户目录下的 `NativeMessagingHosts/com.zjx.download.json`。注册只允许固定扩展 ID `ikfafcgjoghicpkoolbofdaoonendhak`；若同名注册原先指向别处，安装脚本会先保存副本。

## 配套版本识别

- App：Finder 选择 `zjx-download.app` →“显示简介”；或检查 `Contents/Info.plist` 的 `CFBundleShortVersionString`、`CFBundleVersion` 与 `CFBundleIdentifier`。
- Chrome：`chrome://extensions` 卡片显示版本；“详情 → 检查视图”可查看扩展 ID。应为 `ikfafcgjoghicpkoolbofdaoonendhak`，manifest version 应为 `2.0.1`。
- 两端版本应与发布目录同名版本一致。更新解压扩展后在 `chrome://extensions` 点重新加载；Native Messaging 注册使用同一固定扩展 ID，不改其他 Chrome host。
- 卸载本项目 host 时使用 `.../manage-native-host uninstall`。脚本会将本项目注册文件改名保留，不清除浏览器资料。

## 权限范围

扩展使用右键菜单、存储、标签、下载、通知、Native Messaging 与本机 HTTP API。站点访问、webRequest 和 cookies 权限按用户启用的功能申请；不启用自动接管时，Chrome 原生下载保持可用。撤销权限后需要在扩展详情重新授权，并按 Chrome 提示刷新测试标签页。
