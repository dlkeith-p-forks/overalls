# Roster identity verification

## Scope and checkpoint

Campaign improvement 064 starts from published `c14ae27d`. It verifies the
host-facing guest roster path that ADR-0110 introduced, ADR-0115 re-scoped for
boot authority, ADR-0117 carried into personal workspaces, and ADR-0125 extended
with permanent fresh identities and the bounded batch allocator. No production
source changes; this improvement adds generated properties, fixed boundary
tests and three-BEAM contention schedules against the existing roster and
allocator, plus one detected-and-restored mutant.

### Pre-implementation record

- **User operation.** Ownership, grants and team membership determine the guest
  roster a host fetches during and after boot (`Marshall.SSH.GuestAccess.roster/2`,
  dispatched as `ssh_roster` by the internal inference API after Audi/Lilly
  physical binding checks).
- **Allowed result.** The roster contains exactly the current writers: the VM
  owner, unarchived grant holders and current team members, deduped, each with a
  fresh Cedar `write` decision and a durable allocated identity covering the
  exact persisted username/UID pair. `version` strictly increases per fetch so
  the guest helper never sees a stale or replayed roster. Stable re-fetch
  preserves the existing allocation (same names/UIDs, no retirement or
  renumbering).
- **Refusal.** A retired account is excluded from the roster but its identity
  rows remain reserved. More than 512 deduped candidates is denied atomically:
  no allocation, no version consumption, unchanged durable state; 512 exactly is
  admitted. A roster fetch contested by a concurrently retiring candidate must
  recheck the locked User row and refuse atomically rather than allocate a fresh
  identity for the retired account; this recheck was admitted by the
  improvement-018 design but historically uncovered by an executed schedule.
- **Failure/recovery.** A roster fetch whose allocation batch refuses (the
  64-collision budget) rolls back completely: no partial identity allocation for
  other writers, unchanged prior identities, and a subsequent clean fetch
  succeeds with the surviving writer set. Opposite-owner rosters retain
  canonical User-lock order; improvement 018's sort-mutant evidence must stay
  green. The roster path must use the batch allocator; an `ensure!/1` loop
  regression is guarded by asserting the batch's documented sorted-ID result
  order on the returned accounts and by the canonical-order contention schedule.
- **Independent property oracle.** The expected roster is derived inside the
  test from raw grant and membership reads plus an independently filtered User
  set, with per-candidate fresh Cedar re-checks through the public
  `Marshall.Access.Authorization.allowed?/3` gate, and the returned accounts are
  compared against the durable `GuestAccount` table for exact username/UID
  pairs. The oracle never calls the roster implementation's own derivation; it
  re-enumerates candidates and re-decides authority itself.
- **Native boundary.** None. Roster composition, name/UID binding, the 512
  candidate bound and allocation contention are Marshall database/BEAM behavior.
  Guest-side reconciliation against retained pre-Cedar images is a separate
  capability tracked as pending campaign improvement 048 (native retained-image
  roster migration), which owns the native fleet files such as
  `nix/tests/machines/fleet/ssh-bootstrap-guest.exs`; this improvement does not
  touch them. Improvement 018 retains the fourth native NixOS journey evidence
  for fresh NixOS disks; this change does not claim any native run.
- **Dependencies.** None.
- **Required checks.** Focused new suites including the explicitly selected
  `:distributed` schedules; full `mix precommit` in `marshall/`; all-file
  `prek run --all-files`; `scripts/check_adrs.exs`; `scripts/check_hldd.exs`;
  `scripts/hldd_options.exs --check`; `scripts/hldd_coverage.exs --check`;
  `scripts/hldd_views.exs --check`; and `nix build .#checks.x86_64-linux.hldd`.

## Baseline evidence and gap analysis

Existing coverage reused, not re-run here except where stated:

- `guest_identity_history_test.exs` covers same-email generations, the shared
  survivor roster and the team rejoin roster, with the surviving roster
  surviving a same-email re-share (improvement 018, recorded).
- `guest_identity_bounds_test.exs` covers the allocator-side 64-collision
  budget, batch rollback and UID exhaustion through `ensure!/1`/`ensure_all!/1`
  directly, not through the roster fetch path.
- `guest_identity_distributed_test.exs` covers three-BEAM allocation/retirement
  schedules and the opposite-owner canonical lock order with its sort mutant.
  That evidence must stay green on this tree and is re-run explicitly.
- `guest_access_test.exs` covers physical binding refusals, bootstrap operation
  fences and one grant/revoke roster refresh.

Uncovered before this improvement:

1. No generated composition property bound the served roster against an
   independently derived writer set over owner, grant, revoked-grant, viewer,
   team-member and retired-user combinations.
2. Version strict increase and stable re-fetch identity preservation were only
   observed incidentally (the guest helper enforces monotonicity via
   `ssh.roster_stale`; the server side had no property).
3. The roster-level 512-candidate bound and its atomic refusal had no direct
   test; only the allocator's own 512-input guard was exercised.
4. The concurrently-retired-candidate recheck inside a roster fetch (candidate
   passes the pre-filter, is retired before the batch allocator locks and
   rechecks its User row) had no executed schedule.
5. Roster-fetch allocation rollback consistency (no partial identities, clean
   retry) was only covered at the allocator level.

## Verification plan

1. `marshall/test/marshall/ssh/guest_roster_history_test.exs` (sandboxed):
   - Generated composition histories: 1–4 extra users across unused, operator,
     viewer, revoked, retired-operator and (for team VMs) member/admin
     assignments; owner always active. Fetch twice; compare the complete
     returned account set, exact username/UID pairs, sorted-user order, UID
     range and 32-byte name bound against the independent oracle; assert strict
     version increase and unchanged identity projection between fetches.
   - Fixed boundary test: 513 seeded candidates deny atomically with no
     allocation; archiving one grant admits exactly 512 and preserves sorted
     order and unique names/UIDs.
   - Fixed recovery test: a grantee blocked by 64 seeded suffix collisions makes
     the roster fetch fail with an empty resulting allocation delta; revoking
     the blocked grantee then succeeds and a re-fetch preserves the owner's
     identity.
2. `marshall/test/marshall/ssh/guest_roster_distributed_test.exs` (three
   independent BEAMs, committed fixtures, complete public-table row-hash
   preservation per `Marshall.CommittedFixtureInventory`):
   - Contested retirement: grantee retirement holds the User row behind a real
     production SQL gate while the in-flight roster blocks on the same row; on
     release the roster must refuse atomically, the third BEAM observes no
     allocation for the retired account, and a subsequent fetch serves the
     preserved owner identity alone.
   - Duplicate concurrent roster fetches across two BEAMs serialize through the
     namespace and agree on one durable identity set with fresh versions.
3. Mutant: remove the retired-candidate recheck in
   `GuestAccounts.lock_user!/1`; the contested-retirement schedule must fail;
   restore and re-run green; record both.
4. Re-run improvement 018's distributed identity suite (sort-mutant canonical
   order schedule included) on this tree; confirm it stays green.
5. Full Marshall precommit, all-file prek, ADR/HLDD/generated checks and the
   Nix HLDD build.

## Execution

### Focused fixture corrections (test-side only)

Three harness defects were corrected during bring-up; none is a production
change:

1. Repeating `terminal_fixture/1` across generated runs inside one sandbox
   transaction places a later VM on an earlier run's host, failing
   `connect/2` with `:machine_identity_mismatch`. The suite's `vm_fixture/1`
   helper now disables previously created hosts before each new terminal
   fixture, mirroring the proven `GuestIdentityFixture.roster_fixtures!/0`
   capture pattern.
2. Reading the owner User row through the plain read action is forbidden for
   the internal actor; the test uses the reviewed `internal_lookup` query.
3. The initial refusal test claimed refusal was idempotent on immediate retry.
   It is not: the bounded refusal consumes UID sequence values, so a retry
   under an unchanged occupied window begins past the moved window. Threshold
   probes (62/63 admitted, 64/65 refused through the roster path) confirmed the
   budget boundary; the refusal consumed exactly UIDs 700000–700063. The test
   now asserts complete rollback and re-tests refusal while holding the occupied
   window over the sequence position via the sandbox-transactional sequence
   rewind documented in the existing bounds suite.

### Focused sandboxed execution

The new sandboxed roster history selection reported
**3 checks (1 property, 2 tests)** ("3 passed"), seeds `640001`–`640003`, about
7 seconds each (`/tmp/kittens-verify064/history-run1.log` and seed reruns):

- The generated property composes 1–4 extra users over unused/operator/viewer/
  revoked grants, team member/admin membership on generated team VMs, and
  retirement. It serves the roster three times per run (before and after the
  exclusion transitions, then a stable re-fetch): versions strictly increase,
  the independent oracle (raw grant/membership reads plus fresh per-candidate
  Cedar write re-checks, never the roster code path) matches the complete
  returned account set exactly, every returned account equals its durable
  `GuestAccount` username/UID row, account order follows the batch allocator's
  sorted unique user IDs (an `ensure!/1` loop regression oracle), UIDs stay in
  200000–999999, names stay within 32 bytes and safe-name admission, and no
  durable identity row changes across the transitions or re-fetches.
- The boundary test seeds 512 grants: 513 deduped candidates deny atomically
  twice with zero identity allocation; revoking one grant admits exactly 512
  unique durable identities with a stable re-fetch.
- The recovery test forces the 64-collision budget during a roster fetch: the
  fetch refuses, owner identity and every other row are unchanged (complete
  rollback), a windowed retry refuses again, and after the blocked writer is
  revoked the next fetch serves exactly the preserved owner identity with an
  increased version.

### Three-BEAM distributed execution

The new distributed schedule file passed **2 passed**, seed `961117`, 10.5
seconds (`/tmp/kittens-verify064/distributed-run2.log`), and reseeded runs
`64021`–`64023` also passed:

1. Contested retirement: the retirement gate holds the grantee's User row
   behind a real production UPDATE trigger; the in-flight roster is observed
   blocked on that row; on release the roster refuses atomically with
   `{:error, :unauthorized}` and allocates nothing for the retired candidate;
   the third BEAM observes two preserved identities and the retirement
   tombstone; the next fetch serves exactly the surviving owner identity with a
   fresh increased version.
2. Duplicate concurrent fetches of one VM serialize on the locked VM row; both
   commit the identical durable identity set with distinct increasing versions;
   the third BEAM observes no uncommitted allocation mid-flight.

Both schedules assert complete public-table row-hash preservation through
`Marshall.CommittedFixtureInventory` snapshot/restore. The existing
three-BEAM identity suite — including the opposite-owner canonical lock order
schedule whose sort-mutant evidence must stay green — passed inside the
combined selection below on this tree.

### Combined roster/identity selection

The combined selection of both new suites plus
`guest_identity_history_test.exs`, `guest_identity_bounds_test.exs`,
`guest_identity_distributed_test.exs` and `guest_access_test.exs` reported
**25 passed (4 properties, 21 tests)**, seed `828216`, 26.4 seconds with
`--include distributed` (`/tmp/kittens-verify064/combined-run1.log`).

### Mutation evidence

Bounded mutant: remove the retired-candidate recheck
`if user.deleted_at, do: Ledger.rollback(:unauthorized)` from
`GuestAccounts.lock_user!/1`.

- The new contested-retirement roster schedule detected it: **0/1 passed**,
  seed `252318` (`/tmp/kittens-verify064/mutant-run.log`). With the recheck
  removed, the in-flight roster failed with `{:error, :invalid_guest_username}`
  — the retirement's email tombstone trips the incarnation re-parse — instead
  of the required atomic `{:error, :unauthorized}` refusal at the canonical
  User-lock point. The honest reading: the recheck pins the refusal shape and
  the exact fence point before any identity work; the roster-serving path had
  no executed schedule for this race before this improvement.
- The existing allocator-level three-BEAM schedules also detect the same mutant
  at the direct `ensure!/1` refusal shape: **16/20 passed**, seed `199184`
  (`/tmp/kittens-verify064/mutant-existing.log`).
- Source restored with `git checkout`; the focused rerun reported **5 passed
  (1 property, 4 tests)**, seed `64010`
  (`/tmp/kittens-verify064/restored-run.log`).

### Full suite and gates

The standalone full suite — the exact test command `mix precommit` runs —
reported **1192 passed (139 properties, 1053 tests), 2 excluded**, seed
`204573`, 14m15.7s wall time (`/tmp/kittens-verify064/full-suite.log`). This
includes the five new checks.

The full `mix precommit` in `marshall/` (toolchain, architecture, HLDD,
contracts, logging, compiler with warnings as errors, unused-dependency,
format, tests with distributed included and warnings as errors, terminal,
dashboard, workspace, forced Dialyzer), all-file `prek run --all-files`,
`scripts/check_adrs.exs`, `scripts/check_hldd.exs` with recorded receipts,
`scripts/hldd_options.exs --check`, `scripts/hldd_coverage.exs --check`,
`scripts/hldd_views.exs --check` and `nix build .#checks.x86_64-linux.hldd` all
passed on the committed tree; per-gate commands and outputs are in the
improvement's final report and are not re-executed by future readers.

## Remaining gaps

- **Native boundary: none, and justified.** This improvement exercises
  database/BEAM behavior only: roster composition, durable name/UID binding,
  candidate bounds, rollback and multi-node lock contention. The guest-side
  reconciler against retained pre-Cedar images is a separate capability
  scheduled as pending campaign improvement 048 (native retained-image roster
  migration), which owns the native fleet files under
  `nix/tests/machines/fleet/`; this change touches none of them. The Rust
  helper's stale-roster/version enforcement (`ssh.roster_stale`) is
  Marshall-version-agnostic and covered by its existing Hegel/unit tests.
- Improvement 018's retained scopes stand: native Ubuntu fresh identity,
  populated production migration, mixed-release operation, retained guest
  disks, physical independent hosts and rollout acceptance remain outside this
  run.
- The five-second Audi lease, login audit and physical binding fences are
  covered by improvements 002/011/018 evidence; not re-run here.
- No production source, protocol, schema or decision changed; the ADR-0125
  implementation-evidence list gains pointers to these tests.
