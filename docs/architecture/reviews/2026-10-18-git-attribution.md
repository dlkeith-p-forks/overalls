# Git attribution and guest identity review

## Scope and architecture impact

ADR-0198 introduces account-owned Git preferences, immutable machine snapshots,
validated execution metadata and guest Git defaults. Existing Accounts, Compute
and Agents domains retain authority. No deployment service or listener is added.
ADR-0178/0179 stable configuration ownership and existing placement/boot fences
remain applicable. Attribution is trusted model instruction, not enforcement.

## Findings and evidence

Implementation and verification are in progress. Native cross-OS and production
rollout acceptance must remain distinct from codec, property and component tests.
