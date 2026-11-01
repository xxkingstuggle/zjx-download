# zjx-download

`zjx-download` is a native macOS download manager with a companion Chrome MV3 extension. The current rebuild targets macOS 26 and Chrome. The app, CLI, and Native Messaging host share one task model and local API.

## Current delivery

- App: **2.0.2**, build **20261023.1**, installed at `/Applications/zjx-download.app`; bundle ID `com.zjx.download`, Universal x86_64/arm64. Apple Development signed; not notarized.
- Chrome extension remains **2.0.1**, ID `ikfafcgjoghicpkoolbofdaoonendhak`; no extension source changes in this update. See [the Chrome guide](docs/native-rebuild/chrome-install.md).
- Downloads: `/Users/zjx/Developer/releases/zjx-download/2.0.2-ui-20261023/`, including App, CLI, Chrome ZIP and unpacked extension.
- This update lets system appearance control light/dark mode, separates accent colors from appearance, replaces the crowded settings sheet with a resizable settings window with sidebar navigation and grouped scrolling forms, and adds clear empty-list/search states. Earlier transfer and handoff repairs remain documented in [the repair notes](docs/native-rebuild/repair-release-20261018.md).
- Universal App, both CLI architectures and Chrome builds succeeded. Strict signature, identity, icon and architecture checks passed. The executor has not launched the new App or run functional/UI tests. Recheck A-047 and A-068…A-070 in [the manual checklist](docs/native-rebuild/manual-test-checklist.md); all A-001…A-070 remain **待用户测试** on this build. The `Network.NWError 22` visible in the user's screenshot remains unresolved.
- The old 2.0.1 App is preserved at `/Users/zjx/Developer/releases/zjx-download/archive/20261023-pre-ui-20261023.1/`. Installation is recorded in [INSTALL_LEDGER.md](INSTALL_LEDGER.md). Source commit `fbc86589` is pushed to `origin/main` (checked 2026-11-01); no 2.0.2 tag or Release was created. The App is installed locally, but runtime behavior and user acceptance remain pending.
- Data remains under `~/Library/Application Support/zjx-download/`. Legacy `ABDownloadManager/state.json` is available for preview and explicit import, preserving the source. No data migration was performed during this update.
- Current boundaries and acceptance status: [BLOCKED.md](BLOCKED.md).

Source repository: [xxkingstuggle/zjx-download](https://github.com/xxkingstuggle/zjx-download), an independent private repository whose default branch is `main`. Remote `main` contains the 2.0.2 implementation at `fbc86589` (checked 2026-11-01). The latest GitHub Release is still `v0.2.2`; there is no 2.x Release. Project workflow and data boundaries: [AGENTS.md](AGENTS.md).

Documentation map, historical evidence and API contract boundaries: [docs/README.md](docs/README.md). The latest delivery audit is recorded in [PROGRESS.md](PROGRESS.md).

## Build

Requires Xcode with the macOS 26 SDK, Swift 6.2+, Node.js, and npm.

```sh
xcodebuild -project zjx-download.xcodeproj \
  -scheme zjx-download \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

swift build -c release --product zjx-download-cli
npm --prefix browser-extension run build:chrome
```

The Chrome builder uses Node.js built-ins and writes an unpacked extension to `browser-extension/dist/chrome/`.

## Install the Chrome extension

Install `/Applications/zjx-download.app`, then follow [`docs/native-rebuild/chrome-install.md`](docs/native-rebuild/chrome-install.md). That guide covers unpacked loading, project-specific Native Messaging registration, and version identification. Grant site and request-header permissions only for features you enable.

## Report a problem

Use [`docs/native-rebuild/test-result-template.md`](docs/native-rebuild/test-result-template.md) and include the test ID, app and extension versions, reproduction steps, actual behavior, expected behavior, and optional redacted logs or screenshots.

## License and attribution

The project remains Apache-2.0. See [`LICENSE`](LICENSE) and [`browser-extension/LICENSE`](browser-extension/LICENSE). The upstream browser integration attribution is preserved in the browser extension README.
