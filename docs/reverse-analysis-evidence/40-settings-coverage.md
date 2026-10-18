# 设置字段覆盖核对

> 2026-10-18授权更新：用户允许查看旧项目及本审计材料；此前严格隔离的访问限制已取消。事实记录保留，新业务实现须独立设计编写。

本表是审计索引，可用于理解旧设置和功能映射。38个公共App字段与3个桌面字段均有功能落点；映射只证明规格覆盖，不证明开关已在运行中生效。

固定源码：[公共设置接口](https://github.com/amir1376/ab-download-manager/blob/e329495b6630b18e4b41d7682da33318b0f9ea18/shared/app/src/commonMain/kotlin/com/abdownloadmanager/shared/storage/appsettings/IAppSettingsModel.kt#L12-L50)。默认值、范围、目标差异见对应规格。

| 原字段 | 功能编号 |
|---|---|
| `theme` | D-013 |
| `defaultDarkTheme` | D-013 |
| `defaultLightTheme` | D-013 |
| `language` | D-013 |
| `font` | D-013 |
| `uiScale` | D-013 |
| `showIconLabels` | D-013 |
| `useRelativeDateTime` | D-013 |
| `threadCount` | N-002/N-005 |
| `maxConcurrentDownloads` | N-005/Q-002 |
| `maxDownloadRetryCount` | N-002/N-011 |
| `dynamicPartCreation` | N-002 |
| `useServerLastModifiedTime` | N-003 |
| `appendExtensionToIncompleteDownloads` | N-003 |
| `useSparseFileAllocation` | N-003 |
| `useAverageSpeed` | D-013 |
| `showDownloadProgressDialog` | D-012/D-014 |
| `showDownloadCompletionDialog` | D-012/D-014 |
| `useSpeedLimit` | N-005 |
| `speedLimit` | N-005 |
| `minPartSize` | N-002 |
| `autoStartOnBoot` | D-014 |
| `notificationSound` | D-014 |
| `generalNotificationSound` | D-014 |
| `errorNotificationSound` | D-014 |
| `successNotificationSound` | D-014 |
| `defaultDownloadFolder` | D-015/N-001 |
| `apiEnabled` | D-017/I-001 |
| `apiPort` | D-017/I-001 |
| `apiAuthKey` | D-017/I-001 |
| `apiAuthEnabled` | D-017/I-001 |
| `trackDeletedFilesOnDisk` | N-010 |
| `deletePartialFileOnDownloadCancellation` | N-003 |
| `sizeUnit` | D-013 |
| `speedUnit` | D-013 |
| `ignoreSSLCertificates` | N-006 |
| `useCategoryByDefault` | D-010 |
| `userAgent` | N-001/N-006 |
| `mergeTopBarWithTitleBar` | D-013 |
| `useNativeMenuBar` | D-013 |
| `useSystemTray` | D-014 |

独立存储/系统配置另核：代理和PAC=N-006；DNS=N-006；逐主机=N-007/D-018；队列/计划/完成动作=Q-001至Q-004；分类=D-010；目录历史=D-015；原生host=I-003；更新=D-021；列表列配置=D-002；渲染API兼容设置=D-013及平台差异。不能把41字段总数等同于所有用户设置。
