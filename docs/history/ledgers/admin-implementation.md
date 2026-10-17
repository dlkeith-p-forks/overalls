# Admin implementation and acceptance ledger

> **Historical record:** This ledger preserves revision-specific implementation or verification evidence. It is not a current operational runbook, and its claims retain the original scope and execution gaps.

This tracks the accepted September 18 admin plan. An unchecked item remains part
of the goal; partial application checks do not establish fleet acceptance.

## Workspace and delivery

- [x] Separate `feat/marshall-admin` worktree at `/home/antithesishq/overalls-admin`.
- [x] Forward migrations, Ash snapshots, ADRs and final architecture review.
- [x] Required project precommit gates, protocol consumer gates and pinned Nix evaluation checks (native relocation acceptance remains environment-blocked).
- [x] Existing account promotion: the operator’s verified organizational mailbox, performed
  once through the authorized sudo exception; no standing bypass command exists.

## Authorization

- [x] Persisted administrator membership, explicit Cedar policies, bounded admin queries.
- [x] First successful registration bootstraps exactly once; concurrent signup tests.
- [x] Administrators change others' membership, never their own; always one admin.
- [x] Fresh login and role checks on mount/events/navigation/refresh and domain actions.
- [x] Fleet VM operations, sharing, terminal/application/SSH access and live revocation.
- [x] Bounded administrator workload inventory with lifecycle, relocation and resize entry points reusing current safety checks.
- [x] Audited actions and access, without secrets or terminal contents.
- [x] Browser-session, VM-grant, SSH-key, SSH-session and evacuation decisions write redacted administrator audit events; `/admin/audit` provides a bounded view, while terminal contents and credentials remain excluded.
- [x] Administrator lifecycle and relocation requests write redacted audit events inside their durable coordinators; idempotent retries do not duplicate rows.

## Monitor

- [x] All physical platform hosts deduplicated, role/VM/service attribution.
- [x] Independent authenticated versioned NixOS collector; five-second samples.
- [x] Bounded non-authoritative live caches, coalesced replica notifications.
- [x] Minute persistence batches, no detailed telemetry inside compute transactions.
- [x] Host/device history: minute/24-hour and 15-minute/30-day.
- [x] VM/service history: minute/24-hour and hourly/30-day.
- [x] Existing scheduling cadence and 10-second/5-minute history unchanged; `Marshall.Telemetry.Recorder` still writes both resolutions and Lilly control ticks remain one second.
- [x] Bounded 30-minute retry buffer, deduplication, visible overflow/gaps.
- [x] CPU/core breakdown, load/pressure/throttling, RAM/cache/swap/OOM.
- [x] Physical/logical ZFS use, snapshots, compression, quotas and device I/O.
- [x] External-interface network counters and VM owned-interface traffic.
- [x] Fleet-level external network and physical disk rate summaries with bounded observed resource counts; VM traffic remains separately attributed.
- [x] Weighted totals, reporting coverage, source/context/reset correctness.
- [x] Fleet matrix, ranked workloads, node drill-down, historical charts and annotations; totals and rankings cover all enrolled hosts while the visible inventory remains keyset-bounded.
- [x] Capacity explanations using actual overhead/startup/relocation hold arithmetic.
- [x] Database/HTTP/BEAM/job health with non-destructive metric snapshots.
- [x] Intended/observed configuration, deployed revision and updater state.
- [x] Intended versus observed host roles, collector identity, boot identity, sample sequence, and validated updater revision/phase/failure status are visible; revision drift is shown from the updater's candidate/healthy state.
- [ ] Storage/ingestion/UI benchmark: 100 hosts × 100 workloads, WAL and retention.
- [x] Disposable PostgreSQL history benchmark exercises 100 hosts × 100 workloads: 400 retained buckets, 100 receipts, 3,074,464 WAL bytes and 1,596 ms on the disposable fixture; production-sized WAL/retention and browser latency remain open.

## Administration

- [ ] Users/roles/sharing, session and SSH-key revocation.
- [x] Bounded administrator inventory and revocation for VM grants, SSH keys and live SSH sessions; browser-session and full VM access control remain broader follow-up work.
- [x] Administrators can revoke all stored browser login sessions for another account; the action is serialized, audited and immediately observed by the fresh-login hook.
- [x] Fleet machine lifecycle/resize/move/terminal/application access entry points are available under `/admin/workloads`, with mutations delegated to the existing per-VM coordinators.
- [x] Node admission and CPU/RAM admission-overhead controls use a current-admin serialized host action; physical limits stay deployment-managed.
- [x] Maintenance capacity view exposes configured CPU/RAM admission overhead and clearly separates it from deployment-managed physical limits.
- [x] Image catalog, Audi routes/issuance/publication and Porsche gateway status.
- [x] Read-only image catalog, Audi route/issuance/publication and Porsche gateway status at `/admin/operations`; configuration mutation and secret custody remain deployment-managed.
- [x] Credential expiry and revocation metadata only at `/admin/operations`; enrollment/installation/secrets stay deployment-managed.
- [x] Production `/admin/*` routes use the authenticated LiveView session; development AshAdmin remains isolated at `/dev/resources` and is compile-gated.

## Evacuation and jobs

- [x] Separate admission exclusion from continued ingress/SSH serving.
- [x] Durable evacuation campaign distinct from existing stop-in-place drain.
- [x] Preview ordering/destinations/capacity/blockers; transactional admission recheck.
- [ ] Running/stopped guests preserve identity/data/state/sharing/address.
- [x] Explicit prolonged-downtime approval; pause/resume scheduling.
- [x] Evacuation-owned moves/restoration permitted without general admission.
- [x] Transfer slots/rate/bytes/phases/observed downtime; no fabricated ETA/percent.
- [x] Physical source reclamation and fresh quiescence before maintenance-ready.
- [x] Resume admission without moving back; empty-host retirement.
- [x] Timeline correlates campaign, VM, jobs, commands, readiness and cleanup.
- [x] Bounded campaign/workload milestone timeline is visible in the Lilly maintenance console, including historical campaign milestones, retained redacted relocation job states, and redacted relocation commit/cleanup milestones; raw command payloads and terminal contents remain excluded.
- [x] Jobs states/filters/attempts/timing, safe failure details and audited retries.
- [x] Transactional redacted 30-day job history independent of raw pruning.
- [ ] Native two-Lilly movement, ingress continuity, restoration and cleanup acceptance.

## Verification boundaries

Tests must cover role/bootstrap races and active-session revocation; measurement
resets/reuse, double counting, missing reports, retention and overload; all job
states and retry races; evacuation failures, conflicting work and source recovery.
No guest-process collection or live-memory migration is planned. Times use UTC.

## Current verification checkpoint

The initial users/roles page is at `/admin/users`. Focused account/browser tests
pass; the full Marshall test phase passes 547 tests including three-peer role
races. The dedicated fresh-database bootstrap probe passes. Full precommit is
complete, including Dialyzer. The subsequent Jobs changes have separate focused
tests and still require the full gate. See the
[foundation review](../../architecture/reviews/2026-09-18-admin-foundation.md) for limits.
The fixture PostgreSQL instance is on port 55439; run tests with
`MARSHALL_TEST_PORT=55439 MIX_TEST_PARTITION=adminjobs1` inside `devenv shell`.
Use four schedulers for the main test runner to avoid oversubscribing fixture
connections. Overalls deployment and the one-time production account promotion
were separately verified through the host's declarative auto-update path.

The Jobs domain and screens pass 14 focused tests and a three-peer retry race.
The subsequent full Marshall gate passed 561 checks and Dialyzer; later collector
changes have a separate consumer gate in progress. The independent fleet
collector has ten passing isolated tests and passing pinned Nix configuration
checks. Lilly's full gate passed 273 checks and Dialyzer. Ingestion, monitoring
credentials, history and dashboards were pending at that collector checkpoint; see the
[collector review](../../architecture/reviews/2026-09-18-fleet-collector.md).

Scoped monitor credentials, strict HTTP ingestion, a bounded observational cache,
minute history/receipt commits and administrative history reads now exist. The
focused ingestion suite passes 22 tests; the latest full Marshall test phase
passed 581 checks before three final focused additions, and its Dialyzer phase
passed. Deployment wiring and replica/native/scale acceptance remain open, as recorded in the
[ingestion review](../../architecture/reviews/2026-09-18-fleet-ingestion.md).

The fleet matrix now retains offline enrolled hosts and exposes weighted totals
and coverage. Node drill-down shows bounded resource pages and on-demand history
charts. Twenty-five focused Fleet/domain/UI tests pass; the full Marshall test
phase passed 590 checks and its Dialyzer phase passed. Both pinned collector
Nix checks and the ADR checker passed. Workload ranking now exists, and history
pagination now reaches the complete retained 30-day summary window. Capacity explanations, control-plane health and advisory
preview now exist. See the
[dashboard review](../../architecture/reviews/2026-09-18-fleet-dashboards.md).

Evacuation now has separate enabled/admission-excluded mode, fixed campaign/cohort,
per-workload stopped-copy approval, pause/continue and one-at-a-time relocation
scheduling with durable authority after requester demotion. Empty-host physical
readiness, admission resume and retirement coordinators exist. Five new tests and
eighteen existing relocation-capacity tests pass. The full Marshall test phase
passed 595 checks and Dialyzer passed. At that checkpoint preview/console,
changed/cancelled-workload re-planning and native acceptance remain open; see the
[evacuation review](../../architecture/reviews/2026-09-18-evacuation-foundation.md).

The maintenance console now provides bounded node/workload pages, on-demand
advisory preview, campaign controls, per-revision downtime approval and explicit
re-planning. Re-planning rotates the move key and clears old approval; unfinished
moves/resizes remain excluded. Linked relocation progress uses actual attempt
bytes and observed downtime. The access authority console also exposes bounded,
redacted VM grants, SSH fingerprints and active SSH sessions with administrator
revocation. Focused sharing/key/access tests pass and Ash snapshot consistency
passed. The latest Marshall gate passed 664 tests (60 properties) and Dialyzer
completed successfully. The isolated native
`relocation-fleet` check remains blocked by the environment's missing
`nested-kvm` system feature; no native acceptance result is claimed. Full
campaign timeline, detailed concurrent/native acceptance and production account
promotion remain open; see the [console review](../../architecture/reviews/2026-09-18-maintenance-console.md).

## Interactive dashboard redesign

The approved follow-up redesign uses built-in fleet, host and VM/service dashboards,
shared time controls and existing 30-day retention. The user waived the proposed
100-host × 100-workload benchmark for this follow-up. Existing broader monitoring
acceptance obligations above are not retroactively claimed complete. See
[ADR-0062](../../architecture/decisions/0062-interactive-monitoring-dashboards.md) and the
[review](../../architecture/reviews/2026-09-18-interactive-dashboards.md).

## Passkey administration and account retirement

The approved follow-up adds passkey MFA, five-minute elevation for administrative
changes, invitations and cascading account deletion. See [ADR-0065](../../architecture/decisions/0065-passkey-administration.md),
[ADR-0066](../../architecture/decisions/0066-account-retirement.md), and the
[validation review](../../architecture/reviews/2026-09-18-passkey-administration.md).

### Passkey browser reproduction

Use a fresh dedicated `MIX_TEST_PARTITION` with `MIX_ENV=test` and the disposable
PostgreSQL fixture; run `mix ash.setup` first. The browser probe uses real
WebAuthn with Chromium's CTAP2 virtual authenticator, with no physical key needed.
Build assets with the pinned Nix Marshall package (or the configured native
Tailwind/esbuild tools). In `marshall/`, run:

```sh
PASSKEY_BROWSER_PORT=4419 PASSKEY_BROWSER_CONTEXT=/tmp/passkey-browser.json \
  mix run --no-start scripts/passkey_browser_fixture.exs
```

In another terminal with Python Playwright available, run:

```sh
CHROMIUM_EXECUTABLE=/path/to/chromium \
  python scripts/passkey_browser_probe.py /tmp/passkey-browser.json
```

Stop the fixture afterward and remove its private context file if it remains.
The fixture requires test mode and a nonempty database partition; it never sends
email or touches production. Native physical deletion acceptance is tracked in
the [MFA review](../../architecture/reviews/2026-09-18-passkey-administration.md).

The passkey/account-retirement implementation passes the complete Marshall gate:
717 checks (64 properties, 653 tests), including three-replica ceremony and
retirement races, with zero Dialyzer findings/exclusions. Chromium CTAP2 browser
acceptance passes. ADRs 0065/0066 preserve ADR-0064's Customer restrictions; see the
[review](../../architecture/reviews/2026-09-18-passkey-administration.md) for scope and
physical deletion acceptance limits.
