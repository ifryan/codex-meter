# Codex Meter

[中文](README.md) · [Provider matrix](docs/providers.md) · [Migration](docs/migration.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md)

A native macOS monitor for AI subscription quotas, reset windows, API balances, tokens, and costs, displayed around the MacBook notch or in a centered capsule.

- Independent named accounts, credentials, regions, refreshes, and error states.
- Pin up to three connections and choose their main metric. Hover for all enabled accounts; drag headings to reorder.
- Built-in read paths for Codex, Claude, GLM/Z.ai, Kimi, MiniMax, Copilot, Gemini, Cursor, and more. Consult the [matrix](docs/providers.md): registry entries include regional variants, templates, and retired APIs, and are not a count of verified services.
- Custom HTTP request forms and JSON field mapping, including arrays, scaling, reset times, and template import/export. No arbitrary script execution.
- Existing CLI/app sessions, independent OAuth files, API keys, web cookies, and Copilot device authorization.
- A separate statistics window with today/7-day/30-day filters, trends, and grouping by tool, account, or model.
- Opt-in local log scanning with incremental cursors, stable event IDs, and explicit unknown-account/unknown-price states.
- Provider-reported values, estimates, currencies, local logs, and external imports remain separate.
- Keychain credentials, timestamped stale data, bounded concurrency, and backoff. Paid inference probes are off by default.

On 2026-10-27, this revision passed its Universal 2 build, local signature verification and installed-binary comparison, and replaced the local installed app. Unit tests, provider-by-provider account verification and native UI acceptance have not been performed. Updated screenshots are pending native acceptance.

This is an unofficial community project, not affiliated with or endorsed by any provider. Product names and trademarks belong to their owners.

## Getting started

1. Click the notch/capsule and open **连接设置…** (Connections).
2. Add a source and configure a local session, independent account file, API key, or web login.
3. Optionally preview the connection, then save and enable it.
4. Pin up to three accounts and select their main metric.
5. Open **用量统计…** (Usage) to enable local scanning and configure paths and prices.

The local Codex mode still delegates authentication to `codex app-server --stdio`. Independent accounts can use their own OAuth files. Claude tries the non-inference usage endpoint first; billed probes run only when explicitly enabled.

Legacy GLM credentials can be reused or explicitly copied into a new account-specific Keychain item without deleting the old item. See [migration](docs/migration.md) and the [historical authentication reference](docs/legacy-authentication.md).

## Custom and external sources

Configure URL, GET/POST, headers, and JSON paths such as `data.balance` or `items[0].remaining`. Authentication headers reference `${token}`, `${cookie}`, or `${userID}`, resolved from the Keychain. Keep secrets out of URLs, literal headers, and bodies.

New API/One API and Sub2API provide editable starting templates. Imported templates are disabled until configured. Magpie reads its quotas/usage API; CC Switch imports a user-selected CSV/JSON usage export without accessing its credential database. External exports and local logs are separate statistics datasets.

## Requirements and source build

- macOS 14+, Apple Silicon or Intel.
- Apple Command Line Tools for source builds.
- Source-specific login or credentials; Codex CLI is required only for local Codex mode.

```sh
git clone https://github.com/ifryan/codex-meter.git
cd codex-meter
./build-app.sh
open "dist/Codex Meter.app"
```

The default output is a Universal 2 app. Development builds use ad-hoc signing; public binaries require appropriate signing and notarization.

```sh
ARCHS=arm64 ./build-app.sh
```

Custom Codex executables may be chosen per connection, or through the existing `codexExecutablePath` setting and `CODEX_METER_CODEX_PATH` environment override.

## Local data and pricing

`~/Library/Application Support/CodexMeter/connections.json` stores non-secret connection settings and prices. `usage.sqlite` stores normalized usage events, quota snapshots, and import positions, with a default 90-day retention. Secrets are stored per connection UUID in the `CodexMeter Connections` Keychain service.

Logs are opt-in. Only usage fields are persisted, not prompts, replies, code, or complete sessions. Local and imported records use the local timezone; organization billing uses UTC daily buckets and a separate dataset. Billing records are scoped to the current credentials. Prices match exact model IDs and can be entered manually or supplemented from models.dev on request. Unknown pricing remains unknown; API-price estimates are not subscription payments. See [privacy](PRIVACY.md).

## Development

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [provider guide](docs/provider-development.md). Suggested validation commands:

```sh
swift test
./build-app.sh
```

Record automated, account, and native UI checks separately. Never attach credentials or complete sessions to issues.

## License

[GPL-3.0-only](LICENSE). Design and interface references, plus bundled font attribution, are listed in [NOTICE.md](NOTICE.md).
