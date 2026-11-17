# zjx-download

`zjx-download` is a native macOS download manager with a companion Chrome MV3 extension. The current rebuild targets macOS 26 and Chrome. The app, CLI, and Native Messaging host share one task model and local API.

## Current delivery

- **2.0.4**, build **20261117.2**, is installed at `/Applications/zjx-download.app`. The Universal arm64/x86_64 bundle uses `com.zjx.download` and Apple Development signing.
- The local API supplies the loopback address and port once when starting its listener. This addresses the `NWError 22` startup error caused by passing the same port twice.
- The main window uses macOS behind-window translucency with a native glass search and action bar. The task table retains its system background for contrast. The window uses a solid background when Reduce Transparency is enabled.
- The App, App ZIP, Universal CLI and Chrome 2.0.1 package are under `/Users/zjx/Developer/releases/zjx-download/2.0.4/`. The unpacked extension uses ID `ikfafcgjoghicpkoolbofdaoonendhak`. See [the Chrome guide](docs/native-rebuild/chrome-install.md).
- Build, signature, identity, icon and architecture checks passed. Local API startup and Chrome/CLI handoff await user verification under A-041 and A-042. Appearance remains covered by A-071. See [the manual checklist](docs/native-rebuild/manual-test-checklist.md).
- The previous 2.0.3 App is preserved at `/Users/zjx/Developer/releases/zjx-download/archive/20261117-pre-listener-20261117.2/`. See [the installation record](INSTALL_LEDGER.md).
- Data remains under `~/Library/Application Support/zjx-download/`. Legacy `ABDownloadManager/state.json` is available for preview and explicit import, preserving the source. No data migration was performed during this update.
- Current boundaries and acceptance status: [BLOCKED.md](BLOCKED.md).

The independent private source repository uses `main` as its default branch. [xxkingstuggle/zjx-download](https://github.com/xxkingstuggle/zjx-download) · [Project instructions](AGENTS.md)

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
