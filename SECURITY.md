# Security Policy

## Supported versions

Security fixes go to the default branch and the latest release. Older releases aren't patched, so please update.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public Issue. Use [GitHub private vulnerability reporting](https://github.com/ifryan/meterline/security/advisories/new) and include:

- affected commit or version;
- macOS version, and the version of any related tool or provider;
- minimal reproduction steps;
- expected and actual behavior;
- impact assessment.

Never attach access tokens, cookies, credentials, or a complete private tool configuration.

## Trust boundary

Meterline is not sandboxed because it launches local command-line tools such as Codex, Claude Code, and Kiro, and reads files you select. A selected executable runs with the current user's privileges. Install these tools only from a trusted source, and only point a connection or `METERLINE_CODEX_PATH` at an executable you trust.

Multi-source connections can also read explicitly selected CLI/app sessions, OAuth files, local usage logs, and read-only application databases. App-owned secrets are scoped to a connection UUID in the Keychain. Saves authorize only this app for those dedicated entries, never all applications or other tools' entries. Background reads turn Keychain interaction off, so they fail with a prompt to reauthorize instead of showing a password dialog.

Custom HTTP queries are declarative, not executable plugins. They use explicit URLs, methods, headers, and bounded JSON mappings; credentials belong in Keychain placeholders, not exported constants. Imported templates are disabled until reviewed and configured. HTTP requires explicit enablement, redirects are rejected, and built-in API requests use fixed provider endpoints.

Local history may contain account labels, provider identities, model names, quota values, tokens, and costs. It does not contain full conversations. The SQLite database is protected by filesystem permissions, not claimed to be encrypted. See [PRIVACY.md](PRIVACY.md) for storage and deletion behavior.
