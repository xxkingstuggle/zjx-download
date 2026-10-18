# zjx-download for Chrome

The Chrome extension sends HTTP(S) download requests to the `zjx-download` macOS app over its loopback API. It supports a toolbar popup, context-menu links, selected-page links, download handoff, optional request headers, and media candidates. App acceptance and file completion are separate states; check the app for transfer status.

## Build

Run from the repository root:

```sh
npm --prefix browser-extension run build:chrome
```

The unpacked extension is written to `browser-extension/dist/chrome/`. The build script uses Node.js built-ins; it does not install packages.

## Load in Chrome

1. Install `/Applications/zjx-download.app`.
2. Open `chrome://extensions`, enable **Developer mode**, and choose **Load unpacked**.
3. Select `browser-extension/dist/chrome/` from the matching release.
4. To allow Native Messaging to launch the app, run `/Applications/zjx-download.app/Contents/Helpers/manage-native-host install`. The registration is limited to extension ID `ikfafcgjoghicpkoolbofdaoonendhak` and is saved under Chrome's NativeMessagingHosts directory.

See [`../docs/native-rebuild/chrome-install.md`](../docs/native-rebuild/chrome-install.md) for version checks, permissions, and removing the project registration.

## Acceptance and feedback

All browser checks are listed in [`../docs/native-rebuild/manual-test-checklist.md`](../docs/native-rebuild/manual-test-checklist.md) and begin as **待用户测试**. Report issues with the listed test ID, both versions, reproduction steps, actual and expected behavior, and optional redacted logs or screenshots.

## License and attribution

This project is distributed under Apache-2.0. The earlier browser integration project and its original author are credited in [`LICENSE`](LICENSE) and this README. The current extension implementation is a clean-room rewrite.

The earlier browser integration was authored by AmirHossein Abdolmotallebi and is available at [amir1376/ab-download-manager-browser-integration](https://github.com/amir1376/ab-download-manager-browser-integration), commit `1871203ce9665ea6802e8d1328f8b70c7dc9d948`.
