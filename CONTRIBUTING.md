# Contributing to zjx-download

This repository is the independent macOS 26+ app and Chrome MV3 companion. Read [AGENTS.md](AGENTS.md) for the active workflow, data protection boundaries and build commands. The source belongs in this repository; do not send project changes to the upstream AB Download Manager repository.

## Bug reports

Use [the test result template](docs/native-rebuild/test-result-template.md). Include the test ID when available, App version/build, Chrome extension version/ID, macOS/Chrome versions, reproduction steps, expected and actual behavior, and the effect on existing tasks or files. Redact credentials and private URLs from logs.

## Changes and verification

Preserve existing uncommitted work. Use `zjx/` branches when a separate branch is needed. Build using the commands in [README.md](README.md); functional, UI, download and performance checks are reserved for user testing under the current project rules. Do not run `swift test` or `npm test`, launch the App for acceptance, or operate daily Chrome for verification.

Describe the change, actual build results and remaining user checks. A successful build is not functional acceptance. Follow the project's current authorization before pushing, installing or publishing; do not create a Release as part of documentation maintenance.

## Attribution and history

Preserve Apache-2.0, the original icon bytes and upstream author attribution. [CHANGELOG.md](CHANGELOG.md) records the inherited upstream history; current local delivery records are in [PROGRESS.md](PROGRESS.md) and [INSTALL_LEDGER.md](INSTALL_LEDGER.md). The current UI uses Simplified Chinese; upstream Crowdin instructions do not define this project's translation workflow.
