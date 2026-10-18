# zjx-download

`zjx-download` is a native macOS download manager with a companion Chrome MV3 extension. The current rebuild targets macOS 26 and Chrome. The app, CLI, and Native Messaging host share one task model and local API.

## Current delivery

- App: **2.0.1**, build **20261018.2**, installed at `/Applications/zjx-download.app`; bundle ID `com.zjx.download`, Universal x86_64/arm64. Apple Development signed; not notarized.
- Chrome extension: **2.0.1**, ID `ikfafcgjoghicpkoolbofdaoonendhak`. Reload the updated unpacked extension using [the Chrome guide](docs/native-rebuild/chrome-install.md).
- Downloads: `/Users/zjx/Developer/releases/zjx-download/2.0.1-repair-20261018/`, including App, CLI, Chrome ZIP and unpacked extension.
- This update addresses repeated settings writes, transfer progress overhead, file commit/cancellation safety and Chrome handoff receipt handling. See [repair notes](docs/native-rebuild/repair-release-20261018.md).
- App, CLI and Chrome builds succeeded. Runtime behavior and performance remain **待用户测试**; the executor has not launched the new App or run functional tests. Start with A-053/A-054 and A-002 in [the manual checklist](docs/native-rebuild/manual-test-checklist.md); return results using [the result template](docs/native-rebuild/test-result-template.md). All A-001…A-067 remain pending.
- Data remains under `~/Library/Application Support/zjx-download/`. Legacy `ABDownloadManager/state.json` is available for preview and explicit import, preserving the source. No data migration was performed during this update.
- Current boundaries and acceptance status: [BLOCKED.md](BLOCKED.md).

Source repository: [xxkingstuggle/zjx-download](https://github.com/xxkingstuggle/zjx-download), an independent private repository with the current implementation on its default branch `main`. Project workflow and data boundaries: [AGENTS.md](AGENTS.md).

## Build

Requires Xcode with the macOS 26 SDK, Swift 6.2+, Node.js, and npm.

```sh
xcodebuild -project zjx-download.xcodeproj \
  -scheme zjx-download \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

swift build -c release
npm --prefix browser-extension run build:chrome
```

The Chrome builder uses Node.js built-ins and writes an unpacked extension to `browser-extension/dist/chrome/`.

## Install the Chrome extension

Install `/Applications/zjx-download.app`, then follow [`docs/native-rebuild/chrome-install.md`](docs/native-rebuild/chrome-install.md). That guide covers unpacked loading, project-specific Native Messaging registration, and version identification. Grant site and request-header permissions only for features you enable.

## Report a problem

Use [`docs/native-rebuild/test-result-template.md`](docs/native-rebuild/test-result-template.md) and include the test ID, app and extension versions, reproduction steps, actual behavior, expected behavior, and optional redacted logs or screenshots.

## License and attribution

The project remains Apache-2.0. See [`LICENSE`](LICENSE) and [`browser-extension/LICENSE`](browser-extension/LICENSE). The upstream browser integration attribution is preserved in the browser extension README.
