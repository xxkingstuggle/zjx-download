# Upstream / Rewrite Cross-Audit Notes

> 历史记录：本文属于 2026-10-18 替换前的实现/审计阶段，保留用于追溯。文中的“当前”、测试结果和执行任务不适用于现役实现；现役入口见 [文档索引](README.md)，执行边界以根目录 AGENTS.md 为准。

Audit date: 2026-09-14. Upstream = `amir1376/ab-download-manager`, default branch `master`.
All upstream file paths below were fetched and read (via `gh api` / raw content). Swift references are to this repo unless prefixed with `upstream:`.

---

## 1. Upstream capability inventory

Legend: **Rewrite?** = does the Swift rewrite have an equivalent (grep-confirmed where noted).

### 1.1 Download list / home page
- **Original behavior** (`desktop/.../pages/home/HomePage.kt`, `HomeComponent.kt`, `sections/DownloadList.kt`): table with Check/Name/Size/Status/Speed/TimeLeft/DateAdded columns, sortable, lazy list, virtualised; search box, filters, drag-and-drop for URLs/files onto the window, categories + queues side panel, footer, notification area, delete/category/confirm prompts.
- **Rewrite?** Yes, but simplified: a single SwiftUI `List` (`ABDownloadManagerApp.swift:750`) with rows that show icon, name, progress, status, speed; no per-column sortable table, no search box, no categories/queue side panel on the downloads page (they are separate sidebar sections), no drag-and-drop import.
- Filters: upstream has `FilterState` (text search, category, queue, status = All/Finished/Unfinished) — `shared/.../pages/home/FilterState.kt`, `category/DefinedStatusCategories.kt`. **Rewrite?** No — no in-list filter/search; status-based visibility is implicit (cancelled hidden via `visibleTasks`, `ABDownloadManagerApp.swift:173-175`).

### 1.2 Add-download dialog
- **Original behavior** (`desktop/.../pages/addDownload/single/AddDownloadPage.kt` + `.../multiple/AddMultiItemPage.kt`, `shared/.../pages/adddownload/*`): single AND multi-download dialogs, per-item URL/name/folder/credentials (headers, auth, cookies), import options (silent add/start), add-to-queue + add-to-category, per-host settings preview, icon preview, add to existing via edit.
- **Rewrite?** Partial. `NewDownloadSheet` (`ABDownloadManagerApp.swift:915`) supports multi-line links, headers, checksum, speed limit, queue, category, conflict policy, start-immediately, and batch. No per-link individual credentialed entries, no silent-start option in the UI sheet (silent flags exist only in REST), no "add to existing".

### 1.3 Download actions (per-item and batch)
- **Original behavior** (`shared/.../pages/home/AbstractDownloadActions.kt`, `desktop/.../pages/home/DesktopDownloadActions.kt`): open file, open folder, resume, pause, delete, re-download, move-to-queue, move-to-category, copy link, copy as cURL, copy as JSON, edit, file checksum, show properties. Move-to-queue and move-to-category build dynamic submenus.
- **Rewrite?** Partial. Start/resume/pause/retry/cancel/delete exist (`ABDownloadManagerApp.swift:388-400`). **Missing**: open *folder* (only open file / reveal in Finder at `:892`), move-to-queue, move-to-category, re-download/restart, copy link, copy as cURL/JSON, per-item file-checksum-from-selection (checksum tool exists but is file-picker based).
- Delete semantics: upstream delete prompt splits finished/unfinished and offers "also delete file from disk" (`HomePage.kt` `ShowDeletePrompts`, `BaseHomeComponent.confirmDelete`). **Rewrite?** Yes — `DeleteSelectionSummary`, `requestDeleteConfirmation`, `DeleteSelectionSheet` (`ABDownloadManagerApp.swift:408-449, 828-856`).

### 1.4 Queues
- **Original behavior** (`shared/.../pages/home/queue/QueueActions.kt`, `desktop/.../pages/queue/*.kt`): per-queue concurrency, start/stop queue group, schedule window (overnight crossing allowed), per-queue settings (extra queue settings persist per queue), reorder, delete with confirm (`downloadSystem.deleteQueue`).
- **Rewrite?** Yes and more/less. `DownloadQueue`, `QueueSchedule.isOpen` handle overnight (crossover) windows (`Queue.swift:64-92`), scheduler (`QueueScheduler.swift:27-49`) honors `isRunning`, schedule window, concurrency, global limit, and `completionAction`. **Gap**: `completionAction` (quit/sleep/shutdown) is *persisted and UI-editable* (`QueueEditSheet`, `ABDownloadManagerApp.swift:1076`) but **never executed** by any code path — no quartz/power-action runner exists (upstream `onqueuecompletion` + `poweractionalert`). Upstream queue ordering + delete-the-only-queue guard is present (`AppStateStore.swift:184-189` prevents deleting the last queue; upstream `dialogData` guard is equivalent-ish, unverified).

### 1.5 Categories
- **Original behavior** (`shared/.../util/category/*`): category = name + file-type list + URL pattern list + icon + folder; auto-categorize by file name; default categories seeded (Compressed, Programs, Videos, Music, Pictures, Documents, ...) with default sub-folders; reset-to-default; reorder; category delete prompt.
- **Rewrite?** Partial. `DownloadCategory` with `acceptedFileTypes`/`acceptedURLPatterns`/folder, auto-assign on add (`AppStateStore.swift:120-123`), CRUD + reorder (`CategoriesView`, `AppStateStore.swift:101-104`). **Missing**: no default-category seeding (starts with empty categories — upstream seeds 7+), no icons, no auto-categorize-existing, no reset-to-default. `useCategoryByDefault` setting is persisted but unused (see dead fields).

### 1.6 History
- **Original behavior** (`desktop/.../pages/home/Actions.kt` / HomeComponent menu): history of finished downloads with reveal, clear history.
- **Rewrite?** Yes — `HistoryList` (`ABDownloadManagerApp.swift:1103`), `appendHistory`/`clearHistory` (`AppStateStore.swift:198-215`). Plus a History sidebar section.

### 1.7 Settings pages
- **Original behavior** (`desktop/.../pages/settings/*`, `shared/.../settings/CommonSettings.kt`, `BaseSettingsComponent.kt`): grouped settings (appearance, download, notifications, proxy, per-host) with a sidebar; `DesktopSettings.kt` defines the groups.
- **Rewrite?** Yes — single `SettingsView` Form (`ABDownloadManagerApp.swift:1105-1149`) with appearance/download/storage/units/system/proxy-TLS/integration/categories/host-overrides/notifications. **Missing config groups**: DNS settings (`IDNSSettingsStorage`), download-folder registry, "use relative date/time", size/speed unit pickers, UI scale, show icon labels (upstream settings `useRelativeDateTime`, `uiScale`, `showIconLabels`, `sizeUnit`, `speedUnit` have no Swift UI or consumer).

### 1.8 Appearance / theme
- **Original behavior** (`shared/AppSettingsStorage` theme + theme provider + `PlatformThemeDetector`): `dark`/`light`/`system` themes; theme switchable; system theme follows platform.
- **Rewrite?** Yes — `ThemeMode` (system/light/dark), `AppearanceOverride`, `.preferredColorScheme` at `ABDownloadManagerApp.swift:24,32,38`. Theme default `dark` matches upstream. **Gap**: upstream `defaultDarkTheme`/`defaultLightTheme` selectable per platform — not modeled in Swift.

### 1.9 Tray / menu bar
- **Original behavior**: desktop uses Compose multi-window (tray-less by default on desktop; menu bar via `MenuBar`), `HomeComponent` builds File/Tasks/Tools/Help menus.
- **Rewrite?** Partial — a macOS menu-bar extra (`MenuBarView`, `ABDownloadManagerApp.swift:1151`) with active count, New Download, Open, Quit. No tray icon (`Catalog`), no create-desktop-entry (Linux-only upstream, N/A on macOS).

### 1.10 Notifications
- **Original behavior** (`shared/.../pagemanager/NotificationSender.kt`, `notification/BaseNotificationSound.kt`): completion notifications with custom sounds (general/success/error sound files), completion dialogs, progress dialogs.
- **Rewrite?** Partial — `notifyForFinishedTasks` (`ABDownloadManagerApp.swift:257-268`) uses macOS `UNUserNotificationCenter`, honors `showCompletionDialog` and `soundEnabled`. **Dead**: `generalSound`/`successSound`/`errorSound` persisted but never read (see dead fields). `showDownloadProgressDialog` persisted but never read — there is genuinely no progress dialog.

### 1.11 Clipboard monitoring
- **Original behavior** (`shared/.../util/ClipboardUtil.kt`, `HomeComponent` newDownloadFromClipboardAction): Ctrl/Cmd+V to grab download links from clipboard.
- **Rewrite?** Yes — explicit `ClipboardMonitor` (1s poll of `NSPasteboard.general`, `ClipboardMonitor.swift:5-24`), gated by `clipboardMonitoring` setting. Note: rewrite **auto-starts** downloads from clipboard (start=false is overridden? — `start: false` at `ABDownloadManagerApp.swift:116`), which matches upstream "add to queue" behavior only partially (upstream adds without forcing start by default). **Not verified** whether behavior differs.

### 1.12 Browser integration
- **Original behavior** (`shared/.../util/BrowserIntegrationModel.kt`, `desktop/.../integration/IntegrationHandlerImp.kt`): Firefox/Chrome/Opera/Edge extension, native messaging, `addDownloadByGui`, `listQueues`, silent import options.
- **Rewrite?** No browser-extension integration; the closest is the loopback REST server (Section 1.17).

### 1.13 Checksum verification
- **Original behavior** (`desktop/.../pages/checksum/FileChecksumWindow.kt`, `FileChecksumPage.kt`, `DesktopFileChecksumComponent.kt`): per-download verify from the downloaded file; verify a file against an expected hash.
- **Rewrite?** Both. (a) In-download expected-checksum verified post-merge (`DownloadEngine.swift:185-190`); (b) standalone `ChecksumToolView` (`ChecksumToolView.swift:5-34`) with file picker + algorithm + progress + copy. **Gap**: no batch "verify checksum" for selected downloads (upstream exposes the checksum dialog over the selection).

### 1.14 REST API / integration server
- **Original behavior**: `IntegrationHandler` API with add by GUI, add headless, list queues; browser extension talks to it.
- **Rewrite?** Yes — `RESTService` (`RESTService.swift:34-155`) implements `POST /add` (envelope + bare array), `POST /start-headless-download`, `GET /queues`, `POST /ping`, CORS, optional `x-api-key` auth, loopback-only bind. Port default 15151 matches upstream `apiPort`.

### 1.15 Proxy / TLS
- **Original behavior** (`shared/.../util/proxy/*`): proxy modes Direct/System/PAC/Manual with rules + PAC support.
- **Rewrite?** Partial — `ProxySettings` with none/system/manual, scheme http/https/socks5, bypass list, credentials (`AppSettings.swift:66-118`); wired in `HTTPClient.swift:23-38`; TLS `allowInsecureCertificates` wired at `HTTPClient.swift:125-137`. **Missing**: PAC mode (rewrite has none/system/manual only).

### 1.16 Update check / updater
- **Original behavior** (`desktop/.../pages/updater/*`, `shared/updater/*`, `shared/.../updater/UpdateDownloaderViaDownloadSystem.kt`): update check, downloader-based update download, "app updated to version N" notification, post-update cleanup of downloaded update files.
- **Rewrite?** Partial / mostly stubbed. `SecureUpdatePolicy` (`SecureUpdatePolicy.swift:16-28`) provides manifest fetch + SHA-256 verify + `UpdateChannel`, but **nothing in the app calls it** (only a Settings picker writes `updateChannel`). Default `updateChannel = .disabled` (by design per comments: "safe on a fork"). No `UpdateManager`, no update-download, no "app updated" notification. `lastUpdateCheck` persisted, never read (dead).

### 1.17 Speed limit
- **Original behavior**: global speed limit + per-download speed limit; `useAverageSpeed` toggling average display.
- **Rewrite?** Global `speedLimit` (`DownloadEngine.swift:336-338`) + per-task `speedLimit` (`:339-342`) both enforced. **Dead**: `useAverageSpeed` persisted, never read.

### 1.18 Host overrides (per-host settings)
- **Original behavior** (`shared/.../util/perhostsettings/PerHostSettingsItem.kt`, `.../pages/perhostsettings/*`): per-host username/password/userAgent/threadCount/speedLimit, plus per-host download settings; GUI page.
- **Rewrite?** Yes — `HostOverride` (`Classification.swift`) with headers/threads/speed/folder/category, applied at add time (`AppStateStore.swift:112-117,137`), UI in `HostOverridesView`/`HostOverrideEditorSheet`. Upstream `username`/`password`/`userAgent` per-host fields are folded into headers in the rewrite (no dedicated auth fields).

### 1.19 Batch download
- **Original behavior** (`desktop/.../pages/batchdownload/BatchDownloadPage.kt`, `shared/.../pages/batchdownload/BaseBatchDownloadComponent.kt`): pattern expansion with `*` wildcard, number range, zero-padding to equal width.
- **Rewrite?** Yes — `BatchURLPattern` (`BatchURLPattern.swift:15-38`) with `*`, start/end, `wildcardLength` padding; UI in `NewDownloadSheet` batch disclosure.

### 1.20 Conflict policy (on duplicate)
- **Original behavior**: `OnDuplicateStrategy` (rename/overwrite/etc.) in `ir.amirab.downloader.utils`.
- **Rewrite?** Yes — `FileConflictPolicy` rename/overwrite/skip (`Policies.swift:3-8`), `FileUtilities.resolveConflict` (`FileUtilities.swift:21-39`), applied during merge (`DownloadEngine.swift:181`). Rename scheme `name (n).ext` matches standard behavior (upstream exact scheme not read into this audit).

### 1.21 Open file / open folder
- **Original behavior**: `DownloadItemOpener.openDownloadItem` / `openDownloadItemFolder`, `openFileAction`, `openFolderAction`; "openFileOrShowProperties" double-click (finished → open; unfinished → properties).
- **Rewrite?** Open file + reveal in Finder yes (`ABDownloadManagerApp.swift:892, 1106`); double-click opens finished, otherwise focuses inspector (`openTask`, `:324-329`). **Missing**: an explicit "open containing folder" menu action for the download list (upstream `openFolderAction`).

### 1.22 Delete semantics
- **Original behavior** (`BaseHomeComponent.requestDelete/confirmDelete`, `HomePage` prompts): confirm prompt distinguishing finished/unfinished, "also delete file from disk" flag, per-item delete from multi-selection, delete-missing-files / delete-all-finished / delete-all-unfinished / delete-entire-list batch deletes.
- **Rewrite?** Confirm sheet with also-delete-files yes. **Missing**: delete-missing-files, delete-all-finished, delete-all-unfinished, delete-entire-list batch menu items (upstream `HomeComponent.kt` Tasks submenu). Rewrite's `appliesTo` batch actions only cover start/pause/resume/retry/cancel.

### 1.23 Download engine (parts/retry/range)
- **Original behavior**: downloader library manages parts, ranges, retry, dynamic part creation, sparse file allocation, server last-modified, average speed, incomplete-file extension suffix, partial deletion on cancel.
- **Rewrite?** Engine (`DownloadEngine.swift`): range parts (`makeParts`, `downloadPart`), retry with backoff + `maxDownloadRetryCount`, single-stream fallback, resume via sidecar `.abpart` files, checksum verify, atomic merge. **Dead settings** (see section 3): `dynamicPartCreation`, `useServerLastModifiedTime`, `appendExtensionToIncompleteDownloads` (only referenced in a doc comment `DownloadTask.swift:122`), `useSparseFileAllocation` (not modeled), `useAverageSpeed`.

### 1.24 Auto-start on boot / login
- **Original behavior**: `AutoStartManager` + setting.
- **Rewrite?** Yes — `SMAppService.mainApp.register()/unregister()` on `saveSettings` (`ABDownloadManagerApp.swift:350-354`), setting `autoStartOnBoot`.

### 1.25 Enter-URL dialog / confirmation
- **Original behavior** (`desktop/.../pages/enterurl/EnterNewUrlPage.kt`, `shared/.../pages/enterurl/*`): dedicated "enter new URL" flow with downloader selection.
- **Rewrite?** The URL entry is folded into `NewDownloadSheet` — no separate enter-url page, no downloader-type selection (rewrite auto-detects HLS via `.m3u8`).

---

## 2. Rewrite gap scan

Patterns searched in `Sources/`:
- `TODO`, `FIXME`, `stub`, `placeholder`, `mock`, `fatalError`, `preconditionFailure`: **0 matches**.
- `Color.black`, `Color.white`, `NSColor.black`, `NSColor.white`, `Color(red:`, fixed RGB: **0 matches**.
- Hardcoded semantic colors (flagged as potential deviation only where literal preferences are implied):
  - `ABDownloadManagerApp.swift:869` — `var color: Color { task.status == .failed ? .red : task.status == .completed ? .green : .accentColor }` (status row color; the `.red`/`.green` are SwiftUI semantic system colors, not hardcoded RGB, but they bypass the app's theming layer).
  - `ABDownloadManagerApp.swift:889` — `Text(error).foregroundStyle(.red)` (error text color).
- Empty action closures default Initializers:
  - `ABDownloadManagerApp.swift:596` — `Button(LocalizedStringKey("common.ok")) {}` — error alert OK (intentional no-op dismiss; SwiftUI alerts auto-dismiss. Not a stub, but it *looks* like an empty action).
  - `ABDownloadManagerApp.swift:1066` — `Button(LocalizedStringKey("newDownload.cancel"), role: .cancel) {}` — power-action confirm dialog cancel (also auto-dismiss; intentional).
  These are the only `{}` action closures found; neither actually does work, they rely on SwiftUI dismissal behavior.
- Hardcoded state / configuration:
  - `ABDownloadManagerApp.swift:23,30,36,1112,127` — language always falls back to `"zh-Hans"` hardcoded when unset (upstream default `language = null` → system). `AppLocalization.defaultLanguageCode = "zh-Hans"` hardcoded (`:470`, `:132`).
  - `ABDownloadManagerApp.swift:22-23,`, `:30-31`, `:36-37` — locale forced per scene to `model.settings.language ?? "zh-Hans"`.
  - `AppStateStore.swift:19` — default seed queue named `"Default"`.
- Hardcoded `"ABDownloadManager/1.0 (macOS)"` default UA (`HTTPClient.swift:39`).

### Capabilities present upstream with no Swift counterpart (from section 1)
- Move to queue / move to category submenus.
- Copy link / copy as cURL / copy as JSON.
- Open download folder (list-level).
- Re-download / restart download action.
- Verify-checksum over the selection (batch checksum).
- Delete-missing / delete-all-finished / delete-all-unfinished / delete-entire-list batch deletes.
- Search box + in-page filters (status/category/queue/text).
- Default category seeding + reset-to-default + auto-categorize existing.
- Browser-extension integration (Firefox/Chrome/Edge/Opera) and native messaging.
- PAC proxy mode.
- Queue completion power actions (quit/sleep/shutdown) — UI + persisted but never run.
- Update check / auto-update / "app updated" notification / post-update cleanup.
- Per-download progress dialog (`showDownloadProgressDialog`).
- Downloader (protocol) selection in add-download flow.
- Multi-download (tabular) add page.
- DNS settings (upstream `IDNSSettingsStorage`).
- Folder/down-load-location registry (`DownloadFoldersRegistry`, `SystemDownloadLocationProvider`).
- Tools menu: open-source libraries page, translators page, donate action, per-host page, support action group.
- About page / confirm-exit / credits pages (dedicated windows).

---

## 3. Dead settings fields

Method: for each persisted field in `AppSettings.swift`, `grep -rn "\.<field>\b" Sources/ABDownloadManagerCore Sources/ABDownloadManagerApp | grep -v AppSettings.swift` and inspect every hit; a field is dead when its only non-decode hits are Settings-UI writes (Picker/Toggle) or persisted-name references, and no engine/UI read path consumes it. Fields persisted, editable, but with **no business effect**:

| Field | Where written/store | Evidence of no real consumer |
|---|---|---|
| `uiScale` | `AppSettings.swift:202,245,321,341` | 0 reads outside AppSettings.swift |
| `showIconLabels` | `AppSettings.swift:203,246,342` | 0 reads outside AppSettings.swift |
| `useRelativeDateTime` | `AppSettings.swift:204,247,343` | 0 reads |
| `dynamicPartCreation` | `AppSettings.swift:211,252,348` | 0 reads outside AppSettings.swift |
| `useServerLastModifiedTime` | `AppSettings.swift:212,253,349` | 0 reads |
| `appendExtensionToIncompleteDownloads` | `AppSettings.swift:213,254,350` | only a doc-comment mention `DownloadTask.swift:122` |
| `useAverageSpeed` | `AppSettings.swift:214,255,351` | 0 reads (speed display always computes instantaneous rate, `DownloadEngine.swift:327-333`) |
| `useCategoryByDefault` | `AppSettings.swift:216,257,353` | 0 reads (category assignment has its own always-on logic in `AppStateStore.swift:120-123`) |
| `trackDeletedFilesOnDisk` | `AppSettings.swift:221,260,356` | 0 reads |
| `sizeUnit` | `AppSettings.swift:225,262,358` | 0 reads (display always uses `.binaryBytes` labels via `formatBytes`/`ByteCountFormatter`) |
| `speedUnit` | `AppSettings.swift:226,263,358` | 0 reads |
| `notifications.generalSound` | `AppSettings.swift:135,143` | 0 reads (only encode/decode) |
| `notifications.successSound` | `AppSettings.swift:136,144` | 0 reads |
| `notifications.errorSound` | `AppSettings.swift:137,145` | 0 reads |
| `notifications.showDownloadProgressDialog` | `AppSettings.swift:138,146` | 0 reads (no progress dialog exists) |
| `updateChannel` | `AppSettings.swift:236,269,363` | read only by Settings Picker (`ABDownloadManagerApp.swift:1143`); `SecureUpdatePolicy` never invoked from app code |
| `lastUpdateCheck` | `AppSettings.swift:237,270,363` | 0 reads |
| `settingsVersion` | `AppSettings.swift:240,271,364` | written by migration (`SecureUpdatePolicy.swift:33`) but never read to drive migration behavior |
| `proxy.bypassList` | `AppSettings.swift:88,97,106` | persisted; `HTTPClient.swift` uses host/port/scheme/creds only (no bypass implementation) |

Also dead-end (model-level, not AppSettings): `DownloadQueue.completionAction` (`Queue.swift:15,24,172-178`) is UI-editable and persisted but never executed by `QueueScheduler.swift` or anywhere else (no power-action runner). `DownloadTask.priority` is persisted and scheduled (FIFO priority ordering in `QueueScheduler.swift:35-38`) — that one is live.

Grep command used for all of the above:

```bash
for f in uiScale showIconLabels useRelativeDateTime dynamicPartCreation useServerLastModifiedTime appendExtensionToIncompleteDownloads useAverageSpeed useCategoryByDefault trackDeletedFilesOnDisk sizeUnit speedUnit updateChannel lastUpdateCheck settingsVersion; do
  echo "== $f =="; grep -rn "\.$f\b" Sources/ | grep -v AppSettings.swift
done
# plus targeted: grep -rn "generalSound\|successSound\|errorSound\|showDownloadProgressDialog" Sources/ | grep -v AppSettings.swift
```

Caveat: `appendExtensionToIncompleteDownloads` — `.abpart` naming is actually used by the engine (`DownloadEngine.swift:155,216,356,368-370`, `DownloadTask.swift:125-127`), but the suffix is a fixed constant (`PartFileNaming.incompleteSuffix`, not the setting), so the setting itself is dead even though the feature works hardcoded.

---

## 4. Could not verify

- `desktop/.../pages/DeepDownloadPage/...` (path guess wrong) — 404; single-download-page internals read only via `shared/.../singledownloadpage/BaseSingleDownloadComponent.kt` (listed, not read in depth).
- The `ir.amirab.downloader` library internals (downloader engine behavior, `OnDuplicateStrategy` exact semantics, `DownloaderInUi` steps) are **external dependencies**, not in this repo — engine-level parity (retry math, part boundary behavior, average speed wheel) can only be verified against that library's sources, which I did not fetch.
- Upstream queue/notification *default sounds* (`generalNotificationSound` etc. default `""`) confirmed from `DefaultAppSettings.kt` (read), but the notification *sound-playing* implementation (looping/custom files) lives in desktop platform code I did not fully read.
- Exact `HomeComponent` short-cut set beyond what's in the file read (`HomeComponent.kt:250-285`) — keyboard shortcut parity for `Backspace/DELETE`, `Cmd+N`, `Cmd+V`, `Cmd+C`, `Cmd+Alt+S`, `Cmd+Q`, `Cmd+O`, `Cmd+F`, `Cmd+E`, `Cmd+P`, `Cmd+R`, `Cmd+I`: rewrite implements Cmd+`, Cmd+N, Cmd+A, Cmd+Delete, Cmd+Return, Cmd+P (commands menu, `ABDownloadManagerApp.swift:1152-1197`) — no Cmd+O/E/F/R/I/Q equivalents; **the upstream file paths for the shortcut manager's target actions were read, but a complete per-key mapping check was not done**. 
- `about`, `credits`, `extenallibs`, `confirmexit`, `downloaderror`, `poweractionalert` pages — directory listings obtained, individual files not read in full (only that they exist as dedicated page/window components).
- Default download folder resolution — upstream `PlatformDownloadLocationProvider.getDownloadLocation().resolve("ABDM")`: the rewrite mirrors `~/Downloads/ABDM` (`AppSettings.swift:308-312`) but the upstream Android/other-platform provider code was not read; macOS-path parity is asserted, not verified against a Windows/Android path.
- `DesktopSettings.kt` full configurable-group list (DNS, folder-registry, relative-time UI) read only as file presence; the individual configurable groups' exact UI defaults not fully inventoried.
- Git history / branch drift: upstream `master` may differ from the version the rewrite targeted (no tag or pin found in repo).