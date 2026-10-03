# zjx-download for macOS

zjx-download is a native Swift 6 download manager for macOS 26. This
branch is intentionally macOS-only: the application uses SwiftUI/AppKit,
URLSession, Network.framework, UserNotifications, ServiceManagement, and
security-scoped bookmarks instead of the former Kotlin/Compose/Gradle stack.

## Features

- HTTP(S) downloads with redirects, headers, cookies, Basic auth, proxy
  configuration, safe TLS defaults, ETag/Last-Modified resume semantics,
  retry, pause, cancel, checksums, and atomic assembly.
- Concurrent HTTP Range parts with a no-Range fallback and crash/restart
  recovery.
- Finite HLS VOD/master playlists, including AES-128 segments and resumable
  segment sidecars.
- Queues with CRUD, ordering, priority, concurrency limits, weekday schedules
  (including overnight windows), history, and global/task speed limits.
- SwiftUI `NavigationSplitView` app shell with a virtualized AppKit
  `NSTableView`, inspector, batch-add sheet, settings, keyboard commands, menu
  bar extra, clipboard monitoring, notifications, and macOS 26 styling.
- Loopback REST compatibility at `127.0.0.1:15151`: `POST /add`, `GET
  /queues`, `POST /start-headless-download`, and `POST /ping`. Send `X-Api-Key`
  when API authentication is enabled. The service accepts both the legacy
  array body and the newer object/envelope form.

## Chrome companion

The branded Chrome extension source and its local build instructions are in
[`browser-extension/README.md`](browser-extension/README.md). To validate or
build the Chrome package:

```sh
cd browser-extension
npm ci
npm test
npm run build:chrome
```

The unpacked extension is written to `browser-extension/dist/chrome`. The
extension uses the app's loopback REST API; Chrome is not installed or changed
by the app build.

## Build and test

Requires macOS 26 and Swift 6.2 or newer:

```sh
swift build
swift test
swift run zjx-download
```

`swift run` starts the native executable in a GUI session. A Release app can be
built from the Xcode project with:

```sh
xcodebuild -project zjx-download.xcodeproj \
  -scheme zjx-download \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The repository's [release workflow](.github/workflows/release.yml) builds an
Universal (`arm64` + `x86_64`) Release app on a GitHub macOS runner, signs it
ad-hoc, verifies the signature, and packages `zjx-download-macOS.zip`.
It runs manually with
`workflow_dispatch` and automatically for tags matching `v*`.

### 安装

当前项目没有 Apple Developer ID，也没有 Apple notarization。GitHub 下载
版本第一次启动时，macOS 可能会阻止运行。第一次尝试打开后，进入：

系统设置 → 隐私与安全性 → 仍要打开

之后即可正常双击启动。不要关闭 Gatekeeper，也不要使用
`sudo spctl --master-disable`。

## Data and safety

State is stored atomically under
`~/Library/Application Support/ABDownloadManager/state.json`; folder
permissions are represented by security-scoped bookmarks. The default update
channel is disabled and the update policy requires HTTPS and a verified SHA-256
before a host application may offer an artifact. Partial files remain until a
successful atomic merge unless the cancellation setting requests deletion.

The current implementation status and remaining verification are in the
[feature matrix](docs/native-completeness-audit/feature-matrix.md). The earlier
rewrite plan remains available at
[`docs/macos-native-rewrite-plan.md`](docs/macos-native-rewrite-plan.md).

## License

zjx-download remains Apache-2.0. See [`LICENSE`](LICENSE) for copyright
and attribution. The translated resource strings retain their original
localization attribution.
