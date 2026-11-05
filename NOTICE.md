# Notices and acknowledgements

## Meterline

Copyright © 2026 Ryan.

Licensed under GPL-3.0-only. See [LICENSE](LICENSE).

## Ubuntu Mono

The bundled Ubuntu Mono font files are distributed under the Ubuntu Font Licence 1.0. The complete license is included at [Resources/Fonts/LICENCE.txt](Resources/Fonts/LICENCE.txt).

## Design references

The notch presentation was informed by the public designs of:

- [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll), GPLv3
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), GPLv3

## Trademarks

Product and company names, including Codex, OpenAI, Claude, and Anthropic, are trademarks of their respective owners. This project is unofficial and is not affiliated with or endorsed by any of them.

## Provider architecture and protocol references

The multi-source Swift implementation uses the following public architecture and interface references. Their source trees are not bundled with this project:

- [steipete/CodexBar](https://github.com/steipete/CodexBar/tree/5f93dc3068b3bee3f8753f3772614cc2949c335d), MIT, Copyright (c) 2026 Peter Steinberger: provider descriptors, capability boundaries, authentication and quota response shapes. [License](docs/licenses/CodexBar-MIT.txt).
- [yetone/magpie](https://github.com/yetone/magpie/tree/5a32923542988ada1508af3a4cd9d22d1123d709), MIT, Copyright (c) 2026 yetone: separate subscription/plan/balance queries, regional endpoints, and integration data contracts. [License](docs/licenses/Magpie-MIT.txt).
- [farion1231/cc-switch](https://github.com/farion1231/cc-switch/tree/3fc8794cf21b44344becf844029fe1308d56bbf0), MIT, Copyright (c) 2025 Jason Young: Coding Plan registry, account-level signing contracts, and usage-query configuration references. [License](docs/licenses/CC-Switch-MIT.txt).
- [anomalyco/models.dev](https://github.com/anomalyco/models.dev/tree/018efeee8549161fa2dbed51850c21b18a43eb54), MIT, Copyright (c) 2025 models.dev: optional model pricing catalog requested by the user. [License](docs/licenses/models.dev-MIT.txt). Downloaded catalog versions are timestamped at runtime.
- [Novita API documentation](https://docs.novita.ai/api-reference/basic-get-user-balance) and [ZenMux documentation](https://zenmux.ai/docs/guide/quickstart): official balance units and management query contracts.

The implementation retains separate provider-reported, imported, and estimated values. Upstream support lists are not represented as this project's verified compatibility claims.

Reference revisions were recorded on 2026-10-27. Representative protocol files were compared with those revisions: CodexBar `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanUsageFetcher.swift`, Magpie `internal/provider/balance.go` and `planquota.go`, and CC Switch `src-tauri/src/services/coding_plan.rs`. These source comparisons are not live provider verification. No upstream source tree is bundled; the MIT notices are retained for interface implementation references and adaptations.
