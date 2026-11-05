# Security Policy

## Supported versions

Until tagged releases are available, only the latest revision on the default branch receives security fixes. After releases begin, the latest minor release will be supported.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public Issue. Use [GitHub private vulnerability reporting](https://github.com/ifryan/codex-meter/security/advisories/new) and include:

- affected commit or version;
- macOS and Codex versions;
- minimal reproduction steps;
- expected and actual behavior;
- impact assessment.

Never attach access tokens, cookies, credentials, or a complete private Codex configuration.

## Trust boundary

Codex Meter is not sandboxed because it needs to launch the local Codex executable. The selected executable runs with the current user's privileges. Install Codex only from a trusted source and use `CODEX_METER_CODEX_PATH` only with an executable you trust.

Multi-source connections can also read explicitly selected CLI/app sessions, OAuth files, local usage logs, and read-only application databases. App-owned secrets are scoped to a connection UUID in the Keychain. Saves authorize only this app and the system credential reader for those dedicated entries, never all applications or other tools' entries. Background access must remain noninteractive.

Custom HTTP queries are declarative, not executable plugins. They use explicit URLs, methods, headers, and bounded JSON mappings; credentials belong in Keychain placeholders, not exported constants. Imported templates are disabled until reviewed and configured. HTTP requires explicit enablement, redirects are rejected, and built-in API requests use fixed provider endpoints.

Local history may contain account labels, provider identities, model names, quota values, tokens, and costs. It does not contain full conversations. The SQLite database is protected by filesystem permissions, not claimed to be encrypted. See [PRIVACY.md](PRIVACY.md) for storage and deletion behavior.
