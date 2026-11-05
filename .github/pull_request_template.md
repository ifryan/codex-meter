## What changed

<!-- Describe the resulting behavior, affected source IDs/regions, and any authentication requirements. -->

## Why

<!-- Explain the user problem or root cause. -->

## Validation

<!-- Check only commands actually run. Record reasons for skipped checks; sample parsing, live accounts and native UI acceptance are separate. -->

- [ ] `git diff --check`
- [ ] `sh -n build-app.sh`
- [ ] `swift test`
- [ ] `./build-app.sh`

Provider/sample checks:

- Source IDs, regions and authentication scopes:
- Synthetic or redacted samples exercised:
- Live account verification (or not performed):
- Native UI acceptance (or not performed):

## Privacy and compatibility

- [ ] No credentials or real account data were added.
- [ ] Provider matrix and protocol compatibility changes are documented.
- [ ] Unknown values, currencies, reporting periods and estimates remain distinct.
- [ ] Account changes, cancellation, migration and history deduplication were considered.
- [ ] Third-party code and assets include their license information.
