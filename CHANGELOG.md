# Changelog

All notable changes to Meterline will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- App icon.
- Simplified Chinese and English interface. The app follows the macOS language setting by default, falls back to English, and has a Language menu to choose one.
- Release workflow that builds a draft GitHub Release with a DMG and checksum, with signing and notarization when Apple credentials are configured.

- Local macOS notifications when consecutive usage snapshots detect a primary quota reset.
- Source registry and per-account credentials, capabilities, snapshots, refresh scheduling, and revision-scoped cache isolation.
- Connection management, up to three selected notch readings, dynamic account details, web cookie login, and Copilot device authorization.
- Built-in subscription, Coding Plan, balance, organization usage, and existing-tool read paths, with explicit authentication and verification limits in `docs/providers.md`.
- Declarative HTTP/JSON custom queries, editable New API/Sub2API templates, credential-free template export, and connection previews.
- Opt-in incremental usage scanning, versioned SQLite history, time/group filters, token/cost charts, and optional pricing catalog import.
- Core regression test sources for mappings, quota semantics, deduplication, account separation, and pricing boundaries.

### Fixed

- Background credential reads no longer show Keychain password prompts. They now read this app's items directly with interaction off, and ask you to reauthorize when that isn't possible.

### Changed

- Renamed the project from Codex Meter to Meterline. The first launch copies existing data and preferences and leaves the originals in place, and credentials move to `Meterline …` Keychain items as they are first read. See `docs/migration.md`.
- Values saved to disk are now in English. The history database moves to version 3, rewriting billing event IDs so the next refresh does not count a bill twice.
- The application uses a source/account collection instead of three dedicated AppDelegate client states.
- Claude uses the non-inference usage path first; billed probes require an explicit per-connection opt-in.
- Local logs, external exports and organization daily bills are separate statistics datasets; billing uses UTC days and current credential scopes, while currencies and pricing origins remain distinct.
- Legacy connection migration and expanded privacy/contribution documentation are included. Provider account verification remains pending.

## [0.2.0] - 2026-07-22

### Added

- Universal 2 build support with an explicit macOS 14 deployment target.
- Typed Codex rate-limit decoding and bounded JSON-RPC transport.
- Unit tests for parsing, time formatting, percentage clamping, and path trimming.
- Launch-at-login control using `SMAppService`.
- Chinese and English documentation, privacy policy, security policy, and contribution guide.

### Changed

- Split the original single source file into domain, transport, UI, and application layers.
- Calculate edge progress by the real outline length instead of the horizontal coordinate.
- Keep the last successful snapshot in memory when refreshing fails.
- Remove persistent usage-snapshot caching.

### Fixed

- Prevent stderr pipe backpressure from blocking the Codex child process.
- Stop rendering data-read failures as a red 0% quota.
- Use the actual display safe-area height instead of a fixed 32-point notch height.

[Unreleased]: https://github.com/ifryan/meterline/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ifryan/meterline/releases/tag/v0.2.0
