# zjx-download macOS native rewrite matrix

This matrix is the audit record for the Swift 6/macOS 26 rewrite. The source
paths in the evidence column refer to the upstream tree at
`afc57634b3c121c6415213242b2b600cccc6fd6e`; they are retained as evidence,
not as runtime code. Verification is local and does not use a public server.

| Original capability | Source evidence | Native replacement | Test/verification | Status |
|---|---|---|---|---|
| HTTP task model and lifecycle | `downloader/core/.../downloaditem/http/HttpDownloadItem.kt`, `HttpDownloadJob.kt` | `DownloadTask`, `DownloadEngine` actor | `IntegrationTests.testHTTPProbeAndRangeDownload` | Implemented |
| HEAD/range probing, redirects | `downloader/core/.../connection/HttpDownloaderClient.kt`, `part/HttpPartDownloader.kt` | `HTTPClient.probe`, URLSession default redirect handling | local fixture range and redirect tests | Implemented |
| Multi-connection ranges and merge | `downloader/core/.../part/RangedPart.kt`, `Parts.kt`, `TransactionalFileSaver.kt` | persisted `DownloadPart` ranges, concurrent task group, atomic merge | local loopback range assembly test | Implemented |
| Dynamic part sizing | `DefaultAppSettings.dynamicPartCreation`, `PartSplitSupport.kt` | deterministic range splitting from configured connection count | range test asserts part state | Implemented |
| No-Range fallback | `PartSplitSupport.kt`, `HttpDownloader.kt` | single URLSession response written to `.abpart` | local `/norange` test | Implemented |
| Pause/resume/cancel/retry | `Downloader.kt`, `PartDownloadStatus.kt`, exception/retry classes | actor control state, retry backoff, durable part offsets | engine state transitions; cancellation API | Partial (deterministic interruption matrix remains) |
| ETag/Last-Modified and If-Range | `FileChangedException.kt`, `HttpResponseInfo.kt` | `ResourceValidator`, If-Range, resource-change rejection | validator model tests and range requests | Implemented |
| Crash/restart recovery | `DownloadListFileStorage.kt`, `PartListFileStorage.kt` | atomic JSON `AppStateStore`, active states reopened as paused | `testPersistenceRecoversActiveTasks` | Implemented |
| HLS VOD/master playlists | `downloaditem/hls/HLSDownloader.kt`, `HLSPartDownloader.kt` | `HLSDownloader`: master selection, media segments, AES-128 CBC, sidecar resume; plain segments use URLSession byte streaming and AES-128 remains bounded to one encrypted segment | local two-segment HLS fixture | Partial (pause/cancel stream test remains) |
| HLS live stream boundary | HLS job has no finite completion for live playlists | reject live playlists instead of creating a never-ending file task | explicit `unsupportedHLS` error | Deliberate boundary |
| SHA-1/SHA-256/SHA-512/MD5 checksums | `shared/.../FileChecksum`, `HashUtil` references and downloader checksum config | `ChecksumCalculator` streaming CryptoKit/RFC1321 MD5 | checksum regression test | Implemented |
| Queues CRUD/order/start-stop | `downloader/core/.../queue/QueueManager.kt`, desktop queue pages | `AppStateStore` queue CRUD and SwiftUI QueueList | queue model and persistence tests | Implemented |
| Queue concurrency/global concurrency | `DownloadQueue.kt`, `QueueManager.kt`, settings defaults | `QueueScheduler` actor plus engine limits | scheduler code path; local queue integration available | Partial (combined multi-task fixture remains) |
| Recurring and cross-midnight schedules | `queue/ScheduleTimes.kt`, queue UI | `QueueSchedule.isOpen`, weekday and overnight handling | schedule boundary XCTest | Implemented |
| History | DB/storage and home/history UI sources | `DownloadRecord` and durable history list | completion/failure append path | Implemented |
| Categories and automatic classification | `shared/.../util/category/Category.kt`, `CategoryManager.kt`, desktop category pages | Codable extension/host rules, default folder, AppStateStore CRUD, CategoriesView, automatic classification and manual category picker | `ModelTests.testCategoryRulesAndLegacyStateCompatibility`; manual UI checklist | Partial (edit UI and full automatic-rule matrix remain) |
| Per-host defaults | `shared/.../perhostsettings/PerHostSettingsItem.kt`, `PerHostSettingsManager.kt`, desktop per-host pages | `HostOverride`, persisted CRUD, matching host application, Settings host editor | `ModelTests.testHostOverrideMatchesCaseInsensitively`; manual UI checklist | Partial (full task execution matrix remains) |
| Task editing and file actions | desktop download detail/actions and `FileNameUtil.kt` | EditTaskSheet, safe FileUtilities rename/move, Open and Reveal actions | manual UI checklist | Partial (manual UI verification remains) |
| Batch URL wildcard generation | `shared/.../batchdownload/BaseBatchDownloadComponent.kt`, desktop `BatchDownnload.kt` | `BatchURLPattern` plus pattern fields/preview in NewDownloadSheet | `testBatchURLPatternExpansionAndLimit`; manual UI checklist | Partial (advanced batch options/manual flow remain) |
| Checksum utility UI | desktop `pages/checksum/DesktopFileChecksumComponent.kt`, `FileChecksumPage.kt` | asynchronous `ChecksumToolView` with algorithm selection, progress and copy | checksum engine tests; manual UI checklist | Partial (manual UI verification remains) |
| Queue schedule editor and completion actions | desktop queue pages and `getOnQueueEventActions.kt` | QueueEditSheet with weekdays/time/overnight schedule and confirmed QueueCompletionAction model | `testQueueScheduleRoundTripIncludingOvernightWindow`; manual confirmation checklist | Partial (power action execution intentionally not implemented) |
| Filename/path safety and conflicts | `destination/IncompleteFileUtil.kt`, `FileNameUtil.kt` | `FileUtilities` sanitization, containment, rename/overwrite/skip | path/conflict unit coverage | Implemented |
| Security-scoped folder authorization | desktop path/storage and platform file utilities | `FolderBookmarkStore` bookmark persistence and scoped access | bookmark API isolated for macOS UI | Partial (full relaunch scope test remains) |
| Proxy and cookies | `ProxyDatastoreStorage.kt`, downloader host config | URLSession proxy dictionary, shared cookie storage, custom headers | local headers/cookie test | Implemented |
| Basic auth | HTTP credentials and integration source model | caller-supplied Authorization headers preserved | local auth fixture test | Implemented |
| TLS policy | `ignoreSSLCertificates` setting | default URLSession trust; explicit opt-in trust delegate | safe default is code-level invariant | Implemented |
| REST `/add` | `integration/server/.../Endpoints.kt`, `AddDownloadsFromIntegration.kt` | loopback `RESTService`, array and envelope decoding | `testRESTCompatibility` | Implemented |
| REST `/queues` | `Endpoints.kt`, `ApiQueueModel.kt` | JSON queue projection | REST test | Implemented |
| REST `/start-headless-download` | `Endpoints.kt`, `NewDownloadTask.kt` | nested source/folder/name/queue/category payload | REST test | Implemented |
| REST `/ping`, API key, CORS | `Endpoints.kt`, `IntegrationSettings.kt`, translated setting text | 127.0.0.1 listener, X-Api-Key, OPTIONS/CORS headers | REST test | Implemented |
| Clipboard import | `shared/.../ClipboardUtil.*` | AppKit pasteboard monitor, URL filtering, batch add | app lifecycle code; manual UI boundary | Implemented |
| Notifications | `NotificationSender.kt`, notification settings | UserNotifications completion/failure requests | app notification service path | Implemented |
| Menu bar/tray | `desktop/app/.../Tray.kt` | SwiftUI `MenuBarExtra` | app target build | Implemented |
| Login item | `shared/.../AutoStartManager.kt` | `SMAppService.mainApp` on saved setting | app target build; requires bundled app entitlement at install | Implemented |
| Settings migration/persistence | `DefaultAppSettings.kt`, desktop settings storage | Codable `AppSettings`, legacy UserDefaults import, atomic state | persistence test | Implemented |
| Secure updates | `shared/updater/...` GitHub updater sources | opt-in HTTPS manifest/digest policy; disabled by default for fork; no unsigned install | `SecureUpdatePolicy` unit surface | Implemented safely |
| Localized strings | `shared/resources/.../locales/*.properties` (27 locales) | generated Apple `.lproj/Localizable.strings` resources | SPM resource compilation | Partial (critical English/Chinese keys wired; full UI review remains) |
| Liquid Glass/accessibility | Compose theme and desktop settings UI | macOS 26 `.glassEffect`, centralized fallback, reduce transparency/motion, labels, keyboard commands, dynamic system fonts | app target build and source audit | Partial (manual VoiceOver/UI automation remains) |
| App packaging | Gradle desktop packaging workflows | Native `zjx-download.xcodeproj` application target, shared scheme, Info.plist, bundle identifier, asset catalog, and SwiftPM core | `xcodebuild ... build CODE_SIGNING_ALLOWED=NO`; inspect `.app` bundle; `xcodebuild ... test` | Implemented |
| Multi-selection and select-all-visible | desktop download list multi-select/`BaseHomeComponent` selection list | SwiftUI `List(selection: Set<Int64>)`, `TaskSelection` pure model, select-all/clear against the current visible list, pruning on refresh | `SelectionTests` (toggle, select-all, prune, snapshot, ordering) | Implemented |
| Batch actions and confirmed delete | desktop home batch action menus and confirm-delete flows | `AppModel` batch start/pause/retry/cancel with per-status filtering, `DeleteSelectionSummary` classification, confirmed multi-delete sheet with "also delete files" | `SelectionTests` batch-guard and delete-classification cases; selection and delete lifecycle wired in app | Partial (manual multi-select/right-click rendering, Command+range, on-disk deletion still unverified) |
| Keyboard shortcuts and context menu | desktop key shortcuts and download row context menu | `AppCommands` Command+A / Command+Delete / batch shortcuts gated to Downloads; `contextMenu(forSelectionType:)` selection menu | app target build; manual UI checklist | Partial (manual keyboard/context-menu verification remains) |

## Verification commands

```sh
swift build
swift test
swift run zjx-download
```

`swift build`, `swift test`, the shared Xcode scheme build/test, and a bounded standalone `.app` launch are the repeatable checks. `swift run` requires
a GUI-capable logged-in macOS session. The loopback XCTest fixture is the only
network server used by tests.

## Explicit non-goals / boundaries

* Live HLS has no finite file boundary and is rejected with a user-visible
  error; VOD and master playlists are supported.
* A Swift Package executable produces a native macOS executable. Creating a
  signed `.app`, login-item registration, notarization, and VoiceOver UI
  automation require Xcode signing/bundle context and are not claimed by the
  package-only checks.

## Latest verification record (2026-09-13)

- `swift build` — passed.
- `swift test` — passed, 16 tests / 0 failures (including large deterministic
  loopback range assembly, REST auth/options/queues/preflight, scheduler intent,
  path safety, checksum, shared limiter, part reconciliation, cancellation cleanup,
  bookmark reload, and batch pattern expansion).
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — passed; output is a real universal `zjx-download.app`.
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` — passed, 16 tests / 0 failures.
- Bundle inspection confirmed `CFBundleIdentifier=com.zjx.download`,
  `CFBundleDisplayName=zjx-download`, `CFBundleIconName=AppIcon`, and
  `LSMinimumSystemVersion=26.0`.
- Placeholder scan in native sources/tests/docs returned no matches.
- Kotlin/Java/Gradle/Linux/Windows/Android residue scan returned no matches;
  the former Linux install/uninstall scripts are removed.

- A bounded launch of the built bundle remained alive for 2 seconds with its embedded Core framework; the process was then terminated by the test harness.

## Remaining implementation gaps

The matrix intentionally does not overstate completion. Category management,
host override editing, safe stopped/completed task editing, batch wildcard
creation, checksum utility, and queue schedule editing now have native UI
paths, but remain manually unverified. The engine still lacks a deterministic
forced-disconnect/retry fixture and a full HLS pause/resume end-to-end test.
AES-encrypted HLS segments use bounded one-segment buffering by design; plain
segments use URLSession byte streaming. A combined two-task end-to-end limiter
fixture remains. Signed/notarized distribution and manual VoiceOver verification
are outside the unsigned local build. These are tracked as partial rather than
complete.

## Job-007 verification record (2026-09-13)

Focused checks run after the management UI changes:

- `swift test --filter ModelTests` — passed, 9 tests / 0 failures.
- `swift test --filter IntegrationTests.testHTTPProbeAndRangeDownload` — passed, 1 / 0.
- `swift test --filter IntegrationTests.testRESTCompatibility` — passed, 1 / 0.
- `swift build` — passed.
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — passed; new `Classification.swift` and `ChecksumToolView.swift` are included in the Xcode source phases.
- No complete Xcode test run was repeated in this job, per the minimal-test constraint. The prior complete Xcode run remains recorded above as 16 tests / 0 failures.

The app target still produces the unsigned universal bundle at
`~/Library/Developer/Xcode/DerivedData/zjx-download-*/Build/Products/Debug/zjx-download.app`.

## Manual acceptance checklist (not run by automation)

- Add one URL and a multiline batch; verify destination, headers, checksum,
  queue/category and conflict policy controls.
- Create/edit/delete/reorder categories; verify extension and host rules,
  category default folder, automatic classification, and manual override.
- Create a per-host override; add a matching URL and verify headers,
  connections/speed/defaults are applied.
- Pause/resume/cancel a slow download; verify partial files and restart behavior.
- Edit a stopped task; verify safe rename, URL, directory, queue/category and
  request settings. Open and reveal a completed file.
- Use the checksum sheet with each algorithm and copy its output.
- Edit queue weekdays and HH:mm bounds, including an overnight window; confirm
  any non-`none` completion action twice before enabling it.
- Exercise HLS VOD, AES-128, and HLS sidecar recovery with a local fixture.
- Select a sandbox-protected folder and relaunch the app to verify bookmark
  authorization is retained; no signed/notarized build was used here.
- Check VoiceOver labels, keyboard navigation, Light/Dark appearance, and
  Reduce Transparency/Reduce Motion manually. No VoiceOver/XCUITest claim is
  made by this record.

## Job-008 verification record (2026-09-13)

- `swift test --filter ModelTests` — passed, 10 tests / 0 failures. This includes category rules, legacy state decoding, host override Codable/application, bookmark reload, batch expansion, queue schedule round-trip, proxy credentials, path conflict, and shared limiter checks.
- `swift test --filter IntegrationTests.testHLSAssembly` — passed, 1 test / 0 failures; this exercises the unencrypted HLS streaming path against the loopback fixture.
- `swift build` — passed.
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — passed after all Job-008 source changes.
- Bundle metadata and a bounded 2-second standalone launch smoke were checked:
  `com.zjx.download`, macOS 26.0, AppIcon, and an alive process.
  The app and embedded Core framework remain universal arm64/x86_64 binaries.

No full Swift test suite, full Xcode test suite, UI automation, VoiceOver,
public-network download, signing, notarization, or release operation was run
in this job.

## Job-010 verification record (2026-09-13)

Focused localization and layout closeout. Commands actually run:

- `swift build` — passed.
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — passed with no warnings or errors.

Bundle inspection of the resulting Release build:

- `Contents/Resources` contains only `en.lproj`, `zh-Hans.lproj`, and
  `Metadata.appintents`; there is no nested `Contents/Resources/Resources`.
- `plutil -lint` reports OK for both `Localizable.strings` files.
- `CFBundleDevelopmentRegion` is `zh-Hans`, so the bundle's own default is
  Simplified Chinese rather than English.
- Sidebar keys resolve to 下载 / 队列 / 分类 / 历史记录 / 设置 in `zh-Hans` and to
  Downloads / Queues / Categories / History / Settings in `en`.
- All 173 localization keys referenced from Swift sources resolve in both
  bundles; neither file contains duplicate definitions.

Not verified here (left to manual testing): actual on-screen rendering, colour
scheme and Reduce Motion/Transparency appearance, VoiceOver, and window resizing.
No signing, notarization, launch, test suite, or network activity was performed.

## Job-011 verification record (2026-09-13)

Closeout: signed Release bundle delivered to `outputs/`.

Commands actually run and their results:

- `swift build` — passed.
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — exit 0, BUILD SUCCEEDED, no warnings or errors.
- `codesign --force --timestamp=none --options runtime --sign <Apple Development identity>` applied to the embedded framework binary, the framework bundle, and the app bundle, inner-to-outer.
- `codesign --verify --deep --strict --verbose=2` — "valid on disk" and "satisfies its Designated Requirement".
- `spctl -a -vv` — accepted, origin `Apple Development: guozhongeba@gmail.com (PS6ALT4AA5)`, TeamIdentifier `ZNSTKHPLY3`.
- The app was launched from `outputs/` and the process stayed alive; a window capture was taken with `screencapture -l<windowID>`.

Shipped bundle inspection (`/Applications/zjx-download.app`):

- `Contents/Resources` contains exactly `en.lproj`, `zh-Hans.lproj`, `Metadata.appintents`; no nested `Contents/Resources/Resources`.
- `CFBundleDevelopmentRegion` is `zh-Hans`.
- Sidebar and empty-state keys resolve in Chinese: 下载 / 队列 / 分类 / 历史记录 / 设置 and 暂无下载.
- All 173 localization keys referenced from Swift sources resolve in both shipped bundles (zh-Hans 752 entries, en 194 entries).
- Executable and embedded framework are universal arm64 + x86_64.

Screenshot: `outputs/ABDM-final.png` shows the shipped build running in
Simplified Chinese — sidebar 资料库/应用 sections with 下载/队列/分类/历史记录/设置,
window title 下载, and the 暂无下载 empty state. No raw `*.title` keys are shown
and no empty detail pane appears on the Downloads page.

Not verified (left to manual testing): adding and downloading a real file, queue
scheduling, category and host-override editing, switching the language picker
between 简体中文 and English at runtime, VoiceOver, and light/dark plus
Reduce Motion/Transparency appearance. No notarization was performed and no
test suite or network download was run.

## Job-012 verification record (2026-09-14)

Multi-selection, select-all-visible, batch actions, and the confirmed delete
flow. Commands actually run:

- `git diff --check` — clean, exit 0.
- `swift build --scratch-path .build/job-012-scratch` — passed, no warnings.
- `swift test --scratch-path .build/job-012-scratch` — passed, 38 tests /
  0 failures (17 new `SelectionTests` + 1 new `IntegrationTests.testAbortCleansPartFilesWithoutHistory`
  + the existing 20). The new coverage exercises selection add/remove/toggle,
  select-all-visible + clear, prune after refresh/filter (never selects hidden
  tasks, keeps primary when still present), snapshot ordering, batch state
  filtering (start/pause/retry/cancel guards per status), delete-confirmation
  finished/unfinished/mixed classification, and the engine's `abort()` delete
  path (partial files cleaned, no cancellation History record).
- `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/zjx-job12-dd4 build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
  — exit 0, BUILD SUCCEEDED, no warnings or errors.
- Bundle inspection of the Release build: `CFBundleIdentifier=com.zjx.download`,
  `CFBundleDisplayName=zjx-download`, executable and embedded Core framework are
  universal `arm64+x86_64`; `Contents/Resources` contains `en.lproj`, `zh-Hans.lproj`,
  `AppIcon.icns`, `Assets.car`, `Metadata.appintents`. The new `selection.*`,
  `commands.*`, `error.batchFailure` and `error.fileMissing` keys resolve in both
  bundles; `TaskSelection` symbols are present in the Core framework.
- A bounded launch of the built bundle stayed alive for 3 seconds and was then
  terminated by the harness.

Fidelity notes (remaining differences):

- SwiftUI `List(selection:)` multi-select + `contextMenu(forSelectionType:)` are
  used; Command-multi-select and Shift-range selection follow the native macOS
  behavior. Right-click on an unselected row and the exact native
  re-selection timing were not verified headlessly; the context-menu actions read
  the model selection, which the list binding keeps in sync.
- "Select all / clear" applies to the currently visible Downloads list (cancelled
  tasks are treated as dismissed and excluded; completed tasks remain visible so
  they can be opened, revealed or deleted). Sidebar/status/category/search/sort
  filters do not yet exist in the Downloads page beyond the terminal-state split,
  so selection always resolves against the one visible list.
- Double-click on a completed file opens it; otherwise it anchors the inspector.
  A multi-selection double-click never opens an arbitrary row.
- Command+Delete walks the same confirmed-delete sheet; start/pause/retry
  shortcuts are gated to the Downloads section.

Not verified (left to manual testing): actual rendering of the selection bar and
toolbar menu, right-click re-selection specifics, keyboard Command+range
interaction, and real file deletion from disk. No signing, notarization,
commit, or push was performed.

## Job-014 verification record (2026-09-14)

Addresses the six independent-review defects from Job-013: primary maintenance,
visible-list pruning, right-click selection snapshot, invalid-state batch skips,
delete-sheet state reset, and reverse-check against upstream Kotlin.

Commands actually run:

- `git diff --check` — clean, exit 0.
- `swift build --scratch-path .build/job-014-scratch` — passed, no warnings.
- `swift test --scratch-path .build/job-014-scratch` — passed, 46 tests /
  0 failures (the 25 `SelectionTests`, 20 existing unit tests, 1 abort-cleanup
  integration test). New coverage: `AppModel.replaceSelection` primary
  stabilization, prune drops cancelled/hidden ids from the *visible* list,
  `isAllVisibleSelected` subset semantics (all visible ⊆ selected, empty => false),
  batch snapshot excludes hidden ids, `runBatch` skips unresumable tasks without
  aggregating them as failures while genuine engine errors still aggregate and
  do not abort subsequent legal items.
- Release xcodebuild
  `xcodebuild -project zjx-download.xcodeproj -scheme zjx-download -configuration Release -derivedDataPath .build/job-014-xcbuild ARCHS='arm64 x86_64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
  — exit 0, BUILD SUCCEEDED, no warnings/errors.
- Bundle checks on `.build/job-014-xcbuild/Build/Products/Release/zjx-download.app`:
  `lipo -info` shows `x86_64 arm64` universal; `plutil` confirms
  `CFBundleIdentifier=com.zjx.download`, `CFBundleDisplayName=zjx-download`,
  `CFBundleShortVersionString=1.0.0`; `Contents/Resources` contains `en.lproj`,
  `zh-Hans.lproj`, `AppIcon.icns`, `Assets.car`, `Metadata.appintents`.
- Launch smoke test: `open` of the Release bundle stayed alive (process present)
  and was terminated by the harness.

Fix details per defect:

1. **Primary maintenance** — added `AppModel.replaceSelection(_:preferredPrimary:)`,
   the single path the list binding and the right-click menu use. A non-empty
   selection keeps the previous primary when still visible, otherwise picks the
   first selected id in `visibleTasks` order (never an arbitrary Set member);
   empty selection clears primary. The selection setter now calls it.
2. **Visible-list pruning** — `pruneSelection()` now prunes against
   `visibleTasks.map(\.id)` instead of `tasks.map(\.id)`, so cancelled/hidden ids
   cannot survive into selection, batch snapshots, or a later Command+A.
3. **Right-click snapshot** — `TaskSelectionMenu` now receives the `Set<Int64>`
   SwiftUI passes in and every action (start/pause/retry/cancel/delete) resolves
   against that snapshot through new `*Selected`-adjacent `start(ids:)`/`pause(ids:)`
   etc. APIs. `apply()` mirrors upstream `onRequestOpenDownloadItemOption`:
   right-clicking an unselected row replaces the model selection; the batch uses
   the snapshot either way.
4. **Invalid-state skip** — `BatchAction` + `runBatch` isolate the state guard
   from the engine call; a task whose state cannot take the action is skipped
   (not a failure); only genuine thrown errors aggregate into `lastError` and one
   error never aborts the remaining legal items.
5. **Delete-sheet reset** — `DeleteSelectionSheet` resets `alsoDeleteFiles = false`
   via `.onAppear` and `.onChange(of: model.deleteConfirmation?.ids)`, so every new
   confirmation starts unchecked; cancel never mutates tasks/files.
6. **Reverse-check** — read upstream `DownloadList.kt` (desktop, sections),
   `HomeComponent.kt`, `BaseHomeComponent.kt`, `AbstractDownloadActions.kt`,
   `DesktopDownloadActions.kt`. Confirmed: selection is pruned against the live
   download list (`selectionListItems`), plain click replaces the selection
   (`changeAllSelection(false)` + single select), right-click on an unselected
   row re-selects to that row before showing options, `isALlSelected` is
   `list.map { it.id }.all { it in selectionList }` (false for empty), and the
   option menu actions operate on the current `selections`. The Swift
   implementation mirrors these; the one deliberate difference is that the Swift
   context-menu actions use the snapshot passed into the menu rather than the
   model's synced selection, because iOS/macOS list right-click timing can lag
   the model.

Not verified headlessly (left to manual acceptance): the actual right-click
re-selection visual timing, native Command/Shift range rendering, and real
file deletion from disk. No signing, notarization, commit, or push was
performed.
