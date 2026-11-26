# zjx-download 2.0.0 hotfix

App build `20261018.1` adds a guard for the reported startup crash, which occurs when SwiftUI creates the App before AppKit has initialized `NSApp`. The existing Chrome extension and CLI remain version 2.0.0 and are unchanged. User launch acceptance is pending.

## Files

- `zjx-download.app` and `zjx-download-macos-universal-2.0.0-build-20261018.1.zip`: signed Universal macOS App.
- `zjx-download-chrome-2.0.0.zip`: unchanged Chrome companion.
- `bin/zjx-download-cli`: unchanged CLI.
- `docs/native-rebuild/manual-test-checklist.md`: user test cases A-001 through A-053; all remain **待用户测试**.
- `docs/native-rebuild/test-result-template.md`: result and bug report template.
- `SHA256SUMS.txt`: artifact checksums.

The App is installed at `/Applications/zjx-download.app`. The previous installed bundle is recoverable at `~/Developer/releases/zjx-download/archive/20261018-pre-hotfix-20261018.1/zjx-download.app`.

The executor built and signed the package but did not launch the App, exercise downloads, run functional tests, migrate user data, or operate Chrome. Please test A-053 and report results with the included template.
