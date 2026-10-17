# Persisted sharing and machine pages review

## Scope and evidence

Implement the authorized sharing and signed-in machine workflow. ADR-0018 adds the
Access domain, durable grant/request resources, fresh Cedar entity construction,
VM-lock serialization, bounded views and authenticated LiveViews. It refines
ADRs 0002, 0003, 0008, 0009, 0010 and 0016 without replacing their requirements.

## Findings and resolution

- **High, corrected implementation gap:** roles previously existed only in Cedar
  test entities. Persisted grants now drive every user VM read and lifecycle
  authorization. Internal resources remain unavailable to ordinary users.
- **High, corrected race:** an authorized manager could otherwise lose access while
  waiting for lifecycle locks. Sharing serializes on the VM row; lifecycle rechecks
  membership after locking. A real second BEAM waits on the database VM lock while
  revocation commits, then receives denial with no generation/operation change.
- **High, corrected replay risk:** a delayed share request could undo revocation.
  Immutable request results and the VM lock provide replay identity independently
  of the current grant. Nine requests across three BEAMs create one result/grant;
  replay after revocation does not restore access.
- **Medium, corrected disclosure gap:** generic user reads could expose internal
  host/account data. Explicit user views return selected fields and use bounded
  cursors; account resolution is a private action invoked after management checks.
- **High, corrected UI trust gap:** hiding lifecycle/sharing controls alone does not
  protect them. Forged viewer events and events from an already connected revoked
  manager go through current Ash/Cedar checks and leave intent unchanged.
- **Open platform requirements:** remote terminal transport/writer/session authority,
  retained telemetry, production email/deployment, multi-host and load acceptance.
  No terminal-access or complete-platform claim follows from these machine pages.

## Verification

- Nine sharing tests/property cases passed, including the persisted role matrix,
  archival/audit, full-email lookup, owner protection, replay, private reads,
  cursor pagination and aggregate capacity without double counting host CPU/RAM.
- Five LiveView tests passed: sign-in requirement, provisioning/lifecycle, sharing,
  forged viewer events, connected manager revocation and capacity exhaustion.
- Nine three-node cases passed, including two new sharing/revocation cases.
- Marshall precommit passed: 107 cases (7 properties, 100 tests), compiler,
  formatter, toolchain, ADR checks and Dialyzer with its existing single upstream
  typespec exclusion. No new exclusion was added.
- Asset compilation passed. Chromium verified magic-link sign-in, new-user
  registration, provisioning, viewer sharing/restrictions and live revocation in
  two separate browser contexts. Desktop and mobile screenshots were inspected;
  there was no horizontal overflow or JavaScript error. The browser used locally
  minted test links; actual external email delivery remains unverified.
- The temporary browser server exited successfully, and its host/VM/access,
  account/token and operation/job fixtures were removed.
- All four opt-in host runtime integration cases passed after this change.

## Limits and follow-up

The browser fixture uses synthetic host capacity to verify UI/authentication; it
cannot prove physical execution. ADR-0017 separately records real Firecracker
lifecycle and isolation evidence. This change adds no privileged host operation.
The complete platform remains partial, with ADR-0008 terminal and writer work next.
