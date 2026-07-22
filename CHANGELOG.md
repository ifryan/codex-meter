# Changelog

All notable changes to Codex Meter will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ifryan/codex-meter/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ifryan/codex-meter/releases/tag/v0.2.0
