# 2026-09-27: Host enrollment and replacement authority verification

Scope: verification campaign improvement 112 (`verify/112-host-replacement`,
discovery 049). Verification of host enrollment/credential/drain/retire
authority and the native two-stage replacement journey. ADRs unchanged:
0025 (protected enrollment files), 0026 (maintenance drain/retirement),
0043 (host provisioning), 0045 (declarative Lilly enrollment), 0063 (private
services/Ziggy), 0064 (customer isolation), 0105 (Audi wildcard custody),
0111 (private-service TLS names). No production runtime, schema or protocol
change except the documented runtime configuration indirection for Ziggy and
Galileo (defaults preserve deployed behavior exactly).

## Generated histories with an independent oracle

`marshall/test/marshall/compute/enrollment_history_test.exs` implements two
StreamData properties against a pure host model:

- "generated histories converge with the oracle and end retired":
  19 generated operator operations (prepare, prepare retry, prepared rotation,
  rotation retry, manual rotation, revocation, credential verification of newest
  and oldest retained files, session open/replay/stale, report ingestion, enable
  and disable through both entry points, drain, drain retry, advance, resume,
  retire), always closed out by rotate/open/report/drain/advance/retire.
  The model tracks: registration, retirement, maintenance mode, enabled flag,
  active credential with file bytes, per-operation issuance records, connection
  epoch, current/stale sessions, report sequence, readiness, current and
  previously closed drain rows (the latter added in the integration addendum).
  Per step, the database is compared against the model on host fields
  (enabled/mode/epoch/session/sequence), the at-most-one-active credential
  identity, session rows, enrollment operation rows (action-bound credential
  ids), drain status and closure, and the critical enablement boundary:
  enabling requires normal maintenance plus a fresh v3 execution-ready report,
  and the step asserts a fresh report row at enable-commit time for both entry
  points (`Enrollment.set_enabled` and `AdminHostConfiguration.run`) under a
  shared oracle computed from the same database row and database clock.
  Refused operations are wrapped in a complete-table inventory equality check
  across hosts, pools, credentials (+versions), sessions, enrollment
  operations, drains (+versions), admin events, telemetry, VMs, reservations,
  addresses and operations. Each history's terminal sweep proves every issued
  token is permanently unauthorized and its file verifies inactive, retired
  issuance/session/report/refusal classes hold, and revocation after retirement
  is a no-op.
- "credential histories preserve live guest reservations byte for byte":
  same operations on a host holding a real provisioned guest reservation;
  the reservation row digests (md5 over full-row JSON, ordered) are byte-stable
  across every generated rotation/revocation/admission/maintenance step, and
  retirement is refused while the reservation is retained. Reservation hashes
  arrive from SQL digests and are independent of the runtime's persistence code.

Both suites also pin: rotation is not idempotent by file retry (a second manual
rotate rotates again; a prepared operation retry never rotates again — the
lost-response guarantee), the one_active_per_host database identity, and the
post-retirement refusal of every issuance surface.

Checks: see focused suite results in Evidence below.

## Distributed schedules on three independent BEAMs

`marshall/test/marshall/compute/distributed_enrollment_test.exs` starts three
real peers with independent Repo pools over one committed PostgreSQL
(`gateway`-gated simultaneous release), with the complete committed-table
inventory asserted after each test:

1. identical same-name preparations from all three nodes converge on one
   host row, one active credential, three operation rows, byte-equal files;
   the same three conflicting registrations then all refuse with
   `registration_conflict`.
2. conflicting same-name machines produce exactly one winner and two
   `registration_conflict` refusals, one durable row matching the winner's
   machine, and the winner's file verifies for the enrolled host.
3. three concurrent manual rotations all issue (serialized by the host lock),
   exactly one stays active (envelope file verification distinguishes the
   survivor), and a shared prepared rotation raced from all three nodes issues
   exactly once with byte-equal outputs and one operation row.
4. retirement racing direct rotations ends with the host permanently retired,
   zero active credentials, every issued token unauthorized, a late direct
   rotation hitting `host_retired`, and the retained drain/host rows.

## Suspected-defect verdicts

1. `enroll_file/2` lacked the per-name advisory lock and a host_retired guard
   (manual path relied on unique identities only). Reproduced: with the manual
   re-enrollment of an existing name classified as the generic
   `issuance_failed_verify_output` rather than a deterministic conflict, and no
   shared serialization with `prepare_file/4`. Repaired minimally:
   `enroll_file/2` now takes the same `enrollment:<name>` advisory transaction
   lock inside `issue_file/2` and refuses precisely (`:host_retired` for a
   retired name, `:registration_conflict` for any other existing registration),
   and `issue_file/2` surfaces exactly those two pre-issuance refusals instead
   of collapsing them into the uncertain-outcome class. Retirement of the
   writer path additionally gains the same fence on `rotate_file/3` before it
   delegates to the inner `Credentials.rotate/2` retired fence.
   Regression coverage: `enrollment_test.exs`
   ("manual enrollment shares the per-name lock fence and the retired fence",
   "conflicting same-name registration refuses precisely in both entry orders")
   plus the race schedules.
2. `prepare_file/4` error taxonomy across its file boundary: verified correct
   by pins, not repaired (`output_exists` and `unsafe_output_path` are preserved
   distinctly; unreadable/malformed requests report the fixed
   `invalid_enrollment_request` class; no authority row is created on any
   pre-transaction failure). Contractually the closed-class is intentional:
   the caller retries with the same operation ID, and preparation must fail
   closed. Pin: "preparation failure taxonomy is preserved across its file
   boundary".
3. `Credentials.rotate/2` non-idempotency: pinned by generated histories and
   the distributed rotation race (manual rotate always issues; a prepared
   operation retry never does).
4. Post-retirement name non-recycling: pinned in the fixed test, the history
   terminal sweep and the native journey; documented in HLDD chapters 13 and 14.

## Seeded mutants (injected, fired, reverted)

| Mutant | Intended detection | Observed |
| --- | --- | --- |
| Omit `pg_advisory_xact_lock("enrollment:" <> name)` in `EnrollmentPreparation` | `distributed_enrollment_test.exs` tests 1–2 | Both schedules failed (same-name convergence and one-winner conflict), then reverted and re-passed with the rest of the suite |
| Omit the `:host_retired` fence in `Credentials.rotate/2` | `distributed_enrollment_test.exs` test 4 and `DrainsTest` retired-authority pin | Both failed on the fence assertions, then reverted and re-passed |

## Evidence

Focused suites under `MIX_TEST_PARTITION=verify112` (shared local PostgreSQL
socket, `ERL_FLAGS="+S 6:6"`):

- property histories and rotation-reservation suites pass with recorded seeds:
  `enrollment_history_test.exs`: 2 properties pass (12 runs each), ~11 s.
- `enrollment_test.exs`: 20 fixed tests pass (17 pre-existing plus 3 new pins).
- four distributed schedules pass with complete-table restoration:
  `distributed_enrollment_test.exs`: 4 committed schedules pass; combined with
  `drains_test.exs` 33 pass. Evidence scope note: reservation digests stable across every generated history.
- **native host-replacement journey passes**: derivation `/nix/store/v6ajjygfcc3gybam4wzzznh4rm9aihqc-vm-test-run-kittens-host-replacement.drv`, total native build+VM run wall time 9m58s (five subtests: bootstrap/enrollment 83 s, baseline guest private-service reachability 34 s, retirement 13 s, stale-credential refusal 10 s, replacement prepare/enroll/rotate/enable 75 s; QMUs cleaned in 2.87 s; owned process identity count zero at end). All six scenario stages passed.
- Marshall `mix precommit`: counts recorded in the campaign report; forced
  Dialyzer clean.
- Native: `vm-test-run-kittens-host-replacement` (see below for the executed
  derivation/output paths and durations).

## Native journey (HEAVY lock)

`nix build .#checks.x86_64-linux.host-replacement` runs the fleet fixture with
`hostReplacement = true`: m1–m3 Marshall replicas, two Lilly provisioners, one
PostgreSQL node, HAProxy front, one customer-american client VM. Topology
deviations for this variant: the replacement provisioner boots unenrolled on
its own physical storage fixture (independently built disk images, distinct
zpool/dataset GUIDs), and lilly/ziggy/galileo/audi-private on the replacement
are never boot-started — the scenario delivers credentials and starts them.

Stages:

1. Baseline: l1 enrolled at bootstrap; a real nested `standard` guest on l1
   reaches `https://llm.internal/health/ready` 200 and a forged binding gets
   403 through netns-confined Audi private DNS/TLS and the real Ziggy proxy.
2. Retirement: guest deleted by the owner's public lifecycle action, the
   reservation fully released, the real drain chain confirms quiescence and
   retires the host; one in-flight exchange is raced against the retirement
   (either order admitted: the exchange completes on old authority or is
   refused once); the host row persists with `maintenance_mode=retired`,
   `enabled=false`, and the drain row retained.
3. Stale authority over real TLS: the old compute credential's session replay
   and fresh open both return the unauthorized class via the packaged Lilly
   control client against the fleet listener; the report sequence freezes
   permanently; the old Ziggy token gets HTTP 403 from `/api/ziggy/v1/identity`
   and `/renew`.
4. Replacement: `zpool reguid`/`zfs` create supplies brand-new pool and dataset
   GUIDs on l2's own disks (asserted different from the old host's);
   `kittens-marshall-enrollment` over pinned operator SSH prepares the
   replacement (server-generated host id binding the fresh identity figures);
   the same operation ID retry returns byte-identical results;
   name recycling of the retired host is refused (bridge rejection plus the
   retired row persisting alone); `enable-once` returns `host_not_ready`
   before any authority observation; the envelope is delivered only through
   the sealed SOPS bundle; the runtime configuration binds the issued host id
   into Lilly's runtime config and the Ziggy/Galileo indirection files;
   the replacement reports fresh execution readiness.
5. Rotation and gated enable: a `rotate-credential` through the bridge issues a
   new credential (retry equal); readiness-gated enable commits; SQL confirms
   `enabled`.
6. A new guest on the replacement reaches llm.internal again; the retired
   host's credential remains underground (session open refused, Ziggy 403).

Explicitly not claimed: physical providers (bare-metal or cloud), production
DNS/CA/load, multi-region, rebooted-host replacement, Inception nesting,
database-loss rebind (historical-authority territory, improvement 117).

## Ziggy HTTP refusal taxonomy at the fleet boundary

The retired-host inference credential is refused exactly with
`{"error":"unauthorized"}` HTTP 403 by the Inference API in the sandbox test
(`credentials_test.exs` covers both plug-direct and real Bandit/HTTPS
transport). Over the full fleet listener chain the same token gets the API's
boundary-class 400 `invalid_request` — both refuse every authority transition;
this review keeps the precise 403 pin local and uses the closed refusal class
in the native check. The marshal-side verifier rejects the same token by its
own domain path regardless.

## Remaining gaps / follow-ups

### Integration addendum: repeated drain history (2026-09-29)

The fastpath primary branch's full Marshall gate passed 1,344 of 1,345 checks
but failed the enrollment history property at seed `374271`. The shrunk
`[:drain, :prepare, :open_new, :report, :prepare, :resume]` history exposed a
model-only omission: a resumed drain remains a durable closed row, and a later
successful request creates another row. Production retained both; the old oracle
matched `[row]` and could not represent that history. The revised model carries
all prior closed drains and compares every persisted row's identity, status and
closure after each step. A fixed drain → advance → resume → new drain test pins
that SQL-backed behavior. The focused enrollment file passed **3 checks**
(2 properties, 1 test) at seed `374271` on unchanged Marshall production code
(`/tmp/opencode/fastpath-enrollment-oracle-focused2.log`). Full merged-project
precommit and native guest acceptance remain separate; this is not a
production-authority change.

- The mid-flight exchange race is a injected-or-transport race rather than a
  precise lock-wait schedule; both orders are admitted and the permanent fence
  is asserted after the retirement commit. A deterministically queued host-row
  lock schedule would sharpen the overlap claim.
- Marshall-side ziggy/galileo runtime configuration indirection
  (`configurationFile`) is additive and dormant unless used by the fixture;
  deployed behavior is unchanged (default null keeps the store-deployed
  configuration).
