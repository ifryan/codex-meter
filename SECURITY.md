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
