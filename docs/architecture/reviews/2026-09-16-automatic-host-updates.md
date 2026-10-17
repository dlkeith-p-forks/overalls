# Automatic host updates

## Scope and evidence

Review the optional [updater module](../../../nix/domains/system/auto-update/default.nix),
[phase runner](../../../nix/domains/system/auto-update/runtime.py), shared secret resolver,
Marshall migration entrypoint and Lilly readiness protocol. This changes recovery
and deployment authorization boundaries under ADR-0036, retaining ADR-0030 except
its operator-only migration requirement. ADR-0032 governs unchanged identity and
secret custody; ADR-0017 governs guest and owner lifetime; ADR-0033 governs evidence.

## Findings

- Resolved implementation defect: `nixos-rebuild --store-path` still attempted to
  rebuild its own executable from the ambient channel. Actual machine activation
  exposed this; `--no-reexec` now keeps the invocation on the pinned executable
  and the already-built system closure.
- Resolved implementation defect: a previous attempt's handoff could outlive its
  staging directory. Staging now removes the old handoff before replacing files;
  activation publishes a new descriptor-bound handoff only after preflight and
  migration. Resolver cleanup is confined to the private candidate destination.
- Resolved implementation defect: dropping the encrypted source's filename
  extension prevented SOPS from selecting its decoder. An isolated real SOPS
  probe reproduced the failure and confirmed resolution with the preserved
  extension; candidate snapshots now retain it.
- Resolved implementation defect: requiring the Git secret preparation unit could
  stop the updater during its own secret publication. It now orders and wants
  preparation, checks it before fetch, and excludes itself from stopped consumers.
- Resolved recovery defect: an independently supervised migrator can outlive a
  killed updater. Its transient unit now has a fixed host-local name, preventing
  a retry from starting another migrator and exceeding the two-connection budget.
  The bounded original operation may finish; schema rollback remains forbidden.
- Resolved locking defect: Ecto's default table-lock transaction can hit the
  existing fifteen-second idle-transaction deadline while a second connection
  runs a longer migration. Shared Repo configuration now selects PostgreSQL
  advisory locking without weakening serving deadlines. The concurrent fixture
  runs longer than that deadline and observes the actual granted advisory lock.
- Resolved compatibility defect: an EnvironmentFile can be replaced while its
  old values are still serving. Comparison now uses each live Marshall process's
  authority fields privately, falling back to the retained file only when no
  local Marshall process is running.
- Consumer recovery follows transitive service dependencies, restores active
  consumers and application roles, and leaves inactive timer-driven oneshots
  alone. This avoids forcing unrelated certificate renewal during publication.
- The complete fleet check passed: both distinct Lilly release switches and an
  encrypted credential-only update reached verified health; all six guest VMMs,
  retained writes, network policy and authenticated browser terminal recovery
  survived. All sixteen checks in the isolated updater snapshot passed.

## Decisions and open questions

Independent hosts may restart simultaneously; this implementation provides no
fleet availability guarantee. Compatible migrations remain the release author's
responsibility. Automatic secret changes cannot promote encryption keys or change
shared database/cookie/token authority. Candidate migration uses two connections
per declared replica in addition to serving and operator budgets. No automatic
schema rollback, reboot, storage formatting, enrollment or authority issuance is
introduced. Production configuration and activation remain separate deployment
work, not an open implementation choice.

## Verification performed

Final verification completed on 2026-09-17.

Lilly and Marshall `mix precommit` passed, including contracts, tests and forced
Dialyzer: 97 Lilly and 231 Marshall tests/properties. Focused Python compatibility
tests passed (three cases). Module evaluation and both source-release checks
passed. The actual-switch suite passed under KVM, covering phase failures,
concurrency, correction, health-only retry, inactive consumers and private
identity cleanup. The credential-rotation machine check passed with three
concurrent candidate migrators, a twenty-second migration, observed advisory
locking, staged-source consistency, failed migration isolation, coordinated-secret
rejection, compatible key addition and updater journal leakage checks. The fleet
check passed in full under KVM (1,714 seconds), including distinct Lilly releases,
secret-only replacement credentials, retained guest writes and networking,
authenticated browser terminal failover, database/daemon recovery, storage
lifecycle and provisioner revocation.

All sixteen exported checks in the isolated snapshot passed sequentially:

- `module-configuration`, `storage-configuration`, `marshall-release`, `lilly-release`.
- `auto-update`, `fleet`, `service-roles`, `secret-custody`, `credential-rotation`, `acme-route53`.
- `native-zfs`, `zfs-lifecycle`, `zfs-guest`, `zfs-io`.
- `mirrored-installation`, `bootstrap-images`.

A final evaluation reproduced every recorded derivation exactly, and every result
matched its successful output path. ADR structure/links, native contract syntax
and discovery, and whitespace checks passed. The temporary host KVM device ACL
used by the Nix builders was restored after machine verification.

## Contract audit

Reviewed updater candidate/staging/guest-preservation contracts, shared resolver
publication and cleanup, Lilly readiness and private socket boundaries, and the
shared migration entrypoint and its operational callers. Candidate and ordinary
secret preparation use the same resolver; the local socket exposes only its
whitelist; actor observations are accepted only from the current actor pid. No
remaining contract violation was found in this scope. Native-note discovery and
repository structural checks passed; these do not substitute for machine checks.

Concurrent workload-placement, protocol-v3 and newly added guest-readiness edits
are outside this review. The sixteen-check count refers to the updater snapshot,
not the evolving shared-workspace export list. Nix verification uses an isolated
snapshot based on `8be693e` plus the updater changes, with exact
derivation comparison against earlier passes. The fleet uses the original recorded
application packages. Fixture fixes wait for the generated
SSH public key instead of an exited key-generation oneshot and require reports
under three seconds old before releasing an admission race. A merely fresh
4.64-second report could legitimately expire during the race against the unchanged
five-second deadline; the admission assertions remain unchanged. Moving browser
acceptance after the update scenarios exceeded the normal ten-minute login-token
lifetime, so it now requests fresh normal tokens for the same existing fixture
users immediately before browser login, retaining production expiration rules.
Initial cadence probes also observed 5.06- and 5.12-second samples during early
reporting. The steady-state probe now waits for at least three reports from each
host and a fresh starting sample before retaining the same six observations and
five-second assertion. Startup freshness and steady-state cadence remain distinct
checks; the production deadline is unchanged.

## Follow-up work

No updater implementation work remains from the approved plan. Production host
configuration and activation remain separate deployment work. ADR-0036 retains
ADR-0030's reference-host adapter, physical failure-domain and production acceptance
gaps; nested fixtures do not establish those properties or 100-instance throughput.
Concurrent placement/protocol integration requires its own validation.
