# Git attribution and guest identity review

## Scope and architecture impact

ADR-0199 introduces account-owned Git preferences, immutable machine snapshots,
validated execution metadata and guest Git defaults. Existing Accounts, Compute
and Agents domains retain authority. No deployment service or listener is added.
ADR-0178/0179 stable configuration ownership and existing placement/boot fences
remain applicable. Attribution is trusted model instruction, not enforcement.

## Findings and evidence

Merged-source review found the Git-only SettingsLive had displaced ADR-0196's
combined account page. The repaired `/settings` route uses AccountLive and keeps
Git preferences in its fourth anchored section. Existing profile, passkey and SSH
controls, strict fresh-login mount and single Account navigation entry remain.
The old settings URLs still answer 404. This reconciles two accepted decisions
without adding authority or a service. Focused execution of the combined page is
recorded separately from guest Git configuration and native image acceptance.

Implementation and verification are in progress. Native cross-OS and production
rollout acceptance must remain distinct from codec, property and component tests.
