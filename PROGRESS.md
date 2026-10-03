# Current delivery

Updated 2026-10-04. Current local candidate: RC3.

- Native macOS 26 SwiftUI/AppKit application and branded Chrome companion.
- Native task table, queues/categories, settings consumers, Keychain credentials, REST confirmation, secure update checks and Chrome interface implemented.
- 100 Swift tests passed; Chrome tests and build passed.
- Real Chrome context-menu download completed with matching file hash. A 256 MiB task resumed after app restart; cancellation status regression fixed.
- Universal app, isolated verifier and Chrome package validated locally. Not installed, notarized or published.
- See [current feature matrix](docs/native-completeness-audit/feature-matrix.md) and [remaining verification](BLOCKED.md). Raw acceptance records stay local and are excluded from Git.
