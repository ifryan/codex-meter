# Meterline

[中文](README.md) · [Provider matrix](docs/providers.md) · [Migration](docs/migration.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

[![CI](https://github.com/ifryan/meterline/actions/workflows/ci.yml/badge.svg)](https://github.com/ifryan/meterline/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)

A native macOS monitor for AI usage. Subscription quotas, reset times, API balances, tokens, and costs appear around the MacBook notch, or in a centered capsule on screens without one.

It tracks multiple accounts across many services, in English or Simplified Chinese depending on your macOS language. Only local Codex mode needs the Codex CLI.

The project was previously called Codex Meter. Upgrading migrates your data automatically. See the [migration guide](docs/migration.md) (in Chinese).

This is an unofficial community project, not affiliated with or endorsed by any provider. Product names and trademarks belong to their owners.

## Features

- **Always visible**: pin up to 3 connections and choose a main metric for each. Hover to see every enabled connection; drag headings to reorder.
- **Multiple accounts**: add several named accounts per source, each with its own credentials, region, refresh interval, and error state.
- **Several sign-in methods**: local sessions, separate OAuth files, API keys, web login cookies, and Copilot device authorization, depending on the source.
- **Custom sources**: connect unlisted services with a form-based HTTP query and JSON field mapping. No arbitrary scripts.
- **Usage statistics**: a separate window shows today, 7-day, and 30-day trends, grouped by tool, account, or model. Local log scanning is off by default.
- **Reset notifications**: a local macOS notification when a quota reset is detected.

The display rules are deliberately conservative:

- Progress appears only when a metric has a known total.
- Failed queries keep the last value with its timestamp, rather than showing 0.
- Unknown prices stay unknown instead of counting as free.
- Currencies are never added together. Local logs, tool exports, and provider bills are separate datasets, so the same usage isn't counted twice.

## Supported sources

The registry has 41 entries, including regional variants and templates. That isn't 41 services, and not all of them have been verified against real accounts. The [provider matrix](docs/providers.md) lists the read path, sign-in requirements, and limits for each one.

| Category | Sources |
| --- | --- |
| Subscriptions | Codex / ChatGPT, Claude, GitHub Copilot, Gemini CLI, Antigravity, Cursor, Windsurf, Kiro, Factory / Droid, Warp |
| Coding plans | GLM (China, team), Z.ai, Kimi Code, MiniMax, OpenCode Go, Command Code, Alibaba Coding Plan, Volcengine Ark, Tencent Cloud Token Plan (enterprise), ZenMux |
| API balances | DeepSeek, Moonshot, OpenRouter, StepFun, Novita AI, AiHubMix, SiliconFlow (legacy balance API retired; a balance is not guaranteed) |
| Organization usage | OpenAI API, Anthropic API (both need an admin key) |
| Existing tools | Magpie (local HTTP API), CC Switch (read-only usage export file) |
| Custom | Custom HTTP / JSON, plus New API / One API and Sub2API templates |

Local log scanning covers Codex, Claude, Gemini CLI, OpenCode, and Pi. Kimi and MiniMax are supported only for JSONL with a compatible structure.

## Project status

The project is pre-1.0, so configuration and UI may still change.

- **Releases**: multi-source monitoring is only on `main` and hasn't been released. The latest release, [v0.2.0](https://github.com/ifryan/meterline/releases/tag/v0.2.0), predates it and has no installer attached. From the next version on, [Releases](https://github.com/ifryan/meterline/releases) will include a `.dmg`.
- **Automated checks**: CI runs `swift test` and a Universal 2 build on every push.
- **Not done yet**: source-by-source verification with real accounts, and full acceptance testing of the new UI. Most of these APIs aren't stable public contracts, so parsing can break when a response changes. If that happens, please [open an issue](https://github.com/ifryan/meterline/issues).

Screenshots of the new UI will be added after acceptance testing.

## Install

You need macOS 14 or later (Apple Silicon or Intel).

### Download

Download the `.dmg` from [Releases](https://github.com/ifryan/meterline/releases) and drag Meterline to Applications.

If a version isn't notarized by Apple (its release notes say so), macOS blocks the first launch. Open it once, then go to System Settings → Privacy & Security and click **Open Anyway**. If macOS says the app is damaged, run:

```sh
xattr -dr com.apple.quarantine /Applications/Meterline.app
```

### Build from source

You need Apple Command Line Tools.

```sh
git clone https://github.com/ifryan/meterline.git
cd meterline
./build-app.sh
open "dist/Meterline.app"
```

Once it works, drag the app to `/Applications` and turn on **Launch at login** in the notch menu.

The default build is ad-hoc signed and meant for local use. A rebuild may change the app's identity. If the Keychain then refuses saved credentials, reauthorize them in the connection editor.

Build options:

```sh
# Apple Silicon only, which is faster
ARCHS=arm64 ./build-app.sh

# Sign with a Developer ID
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
```

To try it first, use demo mode. It creates synthetic accounts in memory, doesn't read the Keychain or history, sends no quota requests, and saves no configuration:

```sh
METERLINE_DEMO=1 "dist/Meterline.app/Contents/MacOS/Meterline"
```

## Getting started

A new install starts with an empty connection list.

1. Click the notch or capsule and choose **Connections…**.
2. Under **Add connection**, pick a source and configure a local account, separate credentials, or a web login.
3. Optionally run **Preview connection** to check the query result, then save and enable. Previewing doesn't save anything.
4. Turn on **Pin to notch** for connections you want always visible, and choose a main metric.
5. For history, open **Usage statistics… → Collection and pricing**, enable log scanning, and set directories and prices.

A few sources behave differently:

- **Codex**: local mode reads through `codex app-server --stdio`, with no token to paste. Additional accounts use their own OAuth file or token.
- **Claude**: reads the usage endpoint first, which uses no inference quota. It sends a minimal inference request to read response headers only if you enable the paid probe on that connection.
- **GLM**: legacy keys keep working, or you can copy them to a new entry with **Migrate legacy GLM credentials**. The old entry isn't deleted.

Upgrading from an older version? See the [migration guide](docs/migration.md).

If Codex is in a non-standard location, choose the executable in the connection, or set the path and restart the app:

```sh
defaults write io.github.ifryan.meterline codexExecutablePath /absolute/path/to/codex
```

## Custom sources

Any service with an HTTP endpoint that returns JSON can usually be connected:

- Requests can use GET or POST. Plain HTTP needs explicit enablement, and redirects are rejected.
- Authentication headers use the `${token}`, `${cookie}`, and `${userID}` placeholders. The real values go in the credential fields and live in the Keychain. Keep secrets out of URLs, literal headers, and request bodies, because those are included in exported templates.
- Field paths look like `data.balance` or `items[0].remaining`. Arrays, value scaling, remaining or used direction, and reset times are supported.

New API / One API and Sub2API have starter templates. Templates carry no credentials and stay disabled after import until you configure authentication.

## Data and privacy

There is no account system, analytics, or backend that uploads your history. Network requests go only to the sources you configure. models.dev is contacted only when you click **Fill in prices from models.dev**, and that request carries no credentials or session content.

Local files live in `~/Library/Application Support/Meterline/`:

| Location | Contents |
| --- | --- |
| `connections.json` | Non-secret connection settings, ordering, log directories, account bindings, and prices |
| `usage.sqlite` | Normalized usage events, quota snapshots, and import positions. Kept for 90 days by default, configurable from 30 to 730. Not encrypted; protected by file permissions |
| Keychain `Meterline Connections` | Per-connection keys, tokens, and cookies |

History stores usage fields only, not prompts, replies, code, or complete sessions. Kiro's CLI query may create an empty session, and other local tools follow their own networking and logging rules. See the [privacy notes](PRIVACY.md) for the full boundaries.

Costs estimated from API prices are not what a subscription actually charges you.

## Contributing

The most useful things right now:

1. Verify a source with your own account, and report the result (without account details) in an issue or in the [provider matrix](docs/providers.md).
2. Add an adapter for a new source, following the [provider guide](docs/provider-development.md).
3. Test the UI on different displays and languages, and contribute screenshots. Demo mode keeps real accounts out of them.
4. Proofread translations, or add a new language.

Read [CONTRIBUTING.md](CONTRIBUTING.md) first (currently in Chinese). The usual checks:

```sh
git diff --check
sh -n build-app.sh
swift test
./build-app.sh
```

`./build-app.sh` needs only Command Line Tools. `swift test` depends on XCTest, which needs full Xcode. Without it, let CI run the tests.

To change interface text or add a language, see [CONTRIBUTING.md](CONTRIBUTING.md).

To release, push a `vX.Y.Z` tag. CI builds a draft Release with the `.dmg`, which you then publish by hand.

Never attach tokens, cookies, complete responses, or session files to issues and PRs. Report security problems privately as described in [SECURITY.md](SECURITY.md).

## License and credits

Released under [GPL-3.0-only](LICENSE).

The notch design draws on Atoll and boring.notch. The source architecture and interfaces draw on CodexBar, Magpie, CC Switch, and providers' public protocols. Full attribution and the Ubuntu Mono font license are in [NOTICE.md](NOTICE.md).
