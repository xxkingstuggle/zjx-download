# zjx-download for Chrome

This is the Chrome companion for the `zjx-download` macOS app. It sends links and browser download requests to the app's loopback integration API.

## Features

- Send a link or selected links from Chrome's context menu.
- Capture supported downloads and selected page links.
- Forward request headers and cookies when enabled.
- Detect media streams, including HLS playlists.
- Choose whether captured downloads are added or started silently.
- Keep Chrome's original download when the app cannot accept a request.
- Configure the loopback port and API key in the extension settings.
- Use a compact quick-settings popup, grouped options, selection action, and media picker styled for macOS.
- Follow Chrome's system light or dark appearance, with English and Simplified Chinese interface text.

The default API port is `15151`. Turn on **Browser Integration** in the macOS app and use the same port and API key in the extension. The app listens on loopback; the extension does not send download requests to a remote service. Third-party dependency license texts are included in the build as `THIRD_PARTY_NOTICES.txt`.

## Build and load locally

From this directory, run:

```sh
npm ci
npm test
npm run check:manifest
npm run licenses
npm run build
npm run pack
```

`npm run build` creates the unpacked Chrome extension at `dist/chrome`; `npm run pack` creates the versioned archive `dist/zjx-download-chrome-<version>.zip`. In Chrome, open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select `dist/chrome`. Open **Details → Extension options** to configure it. These steps do not install the macOS app; obtain a local app build from the [zjx-download releases page](https://github.com/xxkingstuggle/zjx-download/releases).

The quick-settings popup exposes automatic capture, page popups, and silent adding. The options page keeps connection, download handoff, website rules, and advanced request-header controls visible. Its colors follow the browser's system appearance; the extension text follows Chrome's language, with English as the fallback.

## Project links

- [Project home and source](https://github.com/xxkingstuggle/zjx-download)
- [Report an issue or request a feature](https://github.com/xxkingstuggle/zjx-download/issues/new/choose)
- [Releases](https://github.com/xxkingstuggle/zjx-download/releases)

## Upstream attribution

The browser integration is based on `amir1376/ab-download-manager-browser-integration` at commit `1871203ce9665ea6802e8d1328f8b70c7dc9d948`, originally authored by AmirHossein Abdolmotallebi. The upstream Apache-2.0 license and attribution are retained in [LICENSE](LICENSE). `zjx-download` is an independent downstream project and is not an upstream website or store listing.
