# Cross-replica revocation propagation for non-login read surfaces

## Scope and architecture impact

Campaign improvement 068 verifies that browser session revocation and session
invalidation committed on one Marshall serving replica take effect on the other
replicas' protected non-login read surfaces: mounted Control room reads
(ADR-0119/0123 inherited ADR-0065 hooks), handbook and machine pages, the
mounted usage export and the Control room account projection read action. Login
itself is 007's scope (`2026-09-25-mfa-login-verification.md`); this improvement
does not duplicate it. No production schema, interface, domain ownership,
protocol, deployment or runtime change is anticipated: this is verification and
documentation work under the accepted ADR-0065 → ADR-0119 → ADR-0123 chain.
Production deployment is not part of this work.

## Pre-implementation record

- **User operation.** An administrator selects **Sign out everywhere** for an
  account on one serving replica, or a stored login is otherwise invalidated
  (direct token revocation, database-time expiry), while the affected user holds
  mounted or fresh reads of the Control room, handbook and machine pages
  through other replicas.
- **Allowed result.** Before invalidation commits, an ordinary signed-in user's
  read checks succeed on every replica (positive control), because every replica
  reads the same committed authority state.
- **Refusal.** After invalidation commits on any replica, each surface's next
  admission check on every replica refuses, with the documented closed set:
  LiveView required-login checks halt to `/sign-in` (handbook/machines);
  Control room checks halt to `/machines`; the export controller fails its
  login verification; the account projection action returns forbidden. At the
  distributed assertion level these are exactly `:error` from
  `Marshall.Accounts.Login` checks, `false` from `Marshall.Authorization.Cedar`
  and `{:error, Ash.Error.Forbidden}` from the read action.
- **Failure and recovery cases.** A replica partitioned from its database
  during revocation cannot produce an authorization at all: per ADR-0119/0123
  no replica caches positive authority, so its read checks raise instead of
  serving protected stale reads (fail closed); after rejoin, its next checks
  refuse the revoked login. Replicas never partitioned refuse from commit
  onward. The documented staleness bound is transaction commit: a read racing
  an in-flight but uncommitted revocation may still allow (READ COMMITTED);
  no check may allow after commit.
- **Independent property oracle.** The test model tracks the causal chain
  revoke-event → durable session state → per-replica read outcome. Durable
  state is observed by raw `tokens`-table SQL executed on each replica
  (purpose/expiry/presence of the login JTI), never by an SUT predicate or
  cache signal. Expected read outcomes derive only from the observed durable
  state and the phase (before, in-flight, committed).
- **Native boundary.** Documentation-only; see decision below.
- **Dependencies.** 001/003/007 fixture patterns: three independent peer BEAMs
  sharing committed PostgreSQL (`Marshall.CommittedFixtureCleanup`,
  `Marshall.CommittedFixtureInventory` complete-row oracle,
  `Marshall.PasskeyFixture`, `Marshall.RememberedLoginFixture` pause gates).
- **Required checks.** Focused suite with `--include distributed`, full
  `mix precommit` in marshall/, `prek run --all-files`, ADR/HLDD structure and
  generated reference/coverage/views gates, Nix `hldd` check; mutation run and
  restoration recorded below.

## Evidence anchors

- `Marshall.Accounts.Login.token_present/2`
  ([login.ex](../../../marshall/lib/marshall/accounts/login.ex)) re-reads the
  current user-purpose token on every call; the `login-no-revocation-cache`
  contract forbids previously accepted tokens remaining authorized.
- `Marshall.Authorization.Cedar`
  ([cedar.ex](../../../marshall/lib/marshall/authorization/cedar.ex)) re-reads
  the persisted principal and its live login on every decision; only static
  policy text and schema are compiled into `:persistent_term` at startup. No
  session or authorization cache exists to invalidate.
- `MarshallWeb.LiveUserAuth.fresh_login/1` and
  `MarshallWeb.LiveAdminAuth.check/1` re-verify stored login and read
  authority on every mounted event, message and navigation per ADR-0119.
- `Marshall.Accounts.AdminUsers.revoke_sessions/2` commits the
  `user`/`remember_me` purpose invalidation under the account row lock
  (ADR-0123), followed by the outcome event.

## Verified boundary

[Distributed schedules](../../../marshall/test/marshall_web/cross_replica_revocation_test.exs)
run on three independent peer BEAMs, each with its own `DBConnection` pool,
sharing one committed PostgreSQL database; the coordinating test node is not a
peer. The [fixture](../../../marshall/test/support/read_revocation_fixture.ex)
mirrors the exact production admission checks per surface — required-login
browser reads (handbook and machines via `LiveUserAuth.fresh_login/1`),
Control room reads (`LiveAdminAuth.check/1`), the mounted usage export
(`InferenceExportController`'s `Login.verify/2`), and the account projection
read action (`list_admin_users` through `Checks.ControlRoomRead`) — and reports
exactly `:allow` or `:refuse`. Raised reads are never a refusal evidence: any
unexpected raise fails the schedule directly. The independent oracle observes
the raw `tokens` row (purpose, presence, database-time expiry) via SQL executed
on each replica, tracks revoke-event → durable session state → second-replica
read outcome, and never consults an SUT predicate or cache signal.

Fixed schedules cover administrator **Sign out everywhere** revocation, single
stored-login revocation and database-time expiry, each initiated on a distinct
replica; generated schedules vary kind, revoking replica and per-replica check
order. The commit-boundary schedule pauses the real account-locked revocation
mid-update through a target-specific PostgreSQL trigger (007's fixture): while
uncommitted, concurrent replica reads observe the pre-commit row and may allow;
after commit, every replica refuses with the closed set above. The partition
schedule stops one replica's `Marshall.Repo` supervision child, commits
revocation on another, and asserts the partitioned replica cannot complete any
read decision at all (raised checks = fail closed; no cached positive
authority), that non-partitioned replicas refuse from commit onward, and that
the rejoined replica enforces the committed revocation on its first completed
recheck with no explicit invalidation message. Complete public-table row-hash
inventories are asserted restored after every schedule.

## Native boundary decision

Documentation-only. The ADR wording promises only checks against shared
committed authority: ADR-0119 requires rechecking stored login and read
authority during navigation, events, refreshes and asynchronous completion;
ADR-0123 requires mounted and fresh access to recheck shared authority across
serving replicas; inherited ADR-0065 requires checks at admission and during
ongoing privileged access. None requires a native multi-replica browser run
for non-login read surfaces. The propagation bound is a distributed-systems
property of the BEAM/shared-PostgreSQL shape — one durable store read by every
replica on every admission check, with no positive session or authorization
cache (`login-no-revocation-cache`, `cedar-current-administrator`). The
three-BEAM schedule exercises exactly that boundary with real cross-node
commit visibility. The per-replica browser/transport boundary for these very
surfaces is already native-recorded (003 `control-room-browser`,
005 `hldd-browser`), and the cross-replica browser cookie/backend-observation
boundary by 007 (`mfa-login-browser`, three colocated packaged services). A new
native run would re-observe the same committed-store read behind a second
replica's socket with no new kernel, TLS, cookie or WebSocket primitive; it is
not required by the ADR text and adds no evidence class.

## Validation

Focused distributed validation below ran against this change on
`MIX_TEST_PARTITION=verify068` with the shared local PostgreSQL:

- `mix test test/marshall_web/cross_replica_revocation_test.exs
  --include distributed --seed 68001`: **5 passed (1 property, 4 tests)** in
  6.9 seconds. Seed `68002`: 5 passed (1 property, 4 tests) in 7.8 seconds.
  After a no-behavior normalization edit, seed `68004`: 5 passed (1 property, 4
  tests) in 8.3 seconds.
- Mutation probe: a temporary production mutation in `Login.token_present/2`
  memoized positive presence in per-node `:persistent_term`, skipping
  cross-replica invalidation. With seed `68003` the suite reported **0/5
  passed**; the commit-boundary schedule failed at the intended oracle
  (`assert ^expected = :peer.call(peer, Reads, :browser_read, [reader])` with
  pinned `:refuse`, observed `:allow` on the non-revoking replica after
  commit), and remaining schedules cascaded through the shared-peer stop
  contract. Exact production bytes were restored via `git checkout`
  (verified clean diff), and the restored suite passed again with the same
  seed `68003` (**5 passed** in 6.2 seconds).
- Fixture audit after all runs: `users`, `tokens`, `account_admin_events`,
  `account_verifications`, `account_passkeys` and
  `account_passkey_challenges` each report zero retained rows in the isolated
  partition database, consistent with the per-test complete public-table
  row-hash restoration assertion.

- Full standalone suite: `mix test --include distributed` reported
  **1,192 passed (139 properties, 1,053 tests), 2 excluded**, seed `43021`, in
  743.4 seconds — the published 046 scope plus this improvement's five checks.
  The first complete run of the same source reported the identical
  **1,192 passed (139 properties, 1,053 tests), 2 excluded** in 681.4 seconds
  (its seed was not captured before output truncation and is not claimed).
- The enclosing `mix precommit` on the committed tree passed: toolchain
  (Elixir 1.20.4, OTP 29.0.6), ADR (124 decisions), HLDD receipts current,
  contracts (102 CONTRACTS files), compile `--warnings-as-errors`, format, the
  full suite **1,192 passed (139 properties, 1,053 tests), 2 excluded**, seed
  `230692`, browser-state checks, and forced Dialyzer with **0 errors, 0
  skipped, 0 unnecessary skips** in 1m11.85s (log
  `/tmp/kittens-verify068/precommit2.log`, overall "done (passed
  successfully)").
- Structural gates: `elixir scripts/check_adrs.exs` passed (124 decisions);
  generated HLDD coverage/options/views checks passed;
  `nix build .#checks.x86_64-linux.hldd` succeeded; all-file `prek` passed
  (per-application logging checks, hldd-review, ruff format/check and ty).

## Contract review

Inspected ancestor and local contracts: root `AGENTS.md` verification rules,
`marshall/CONTRACTS` (durable authority, test isolation, real distribution,
gate preservation), `marshall/test/CONTRACTS` (sandbox isolation, at-least-three
BEAM distribution, fixture TLS), the account-side declarations on `Login`,
`Security`, `Cedar` and the two LiveView hook modules, and the
`RememberedLoginFixture`/`CommittedFixture*` contracts. New source ships with
typed specs and per-obligation `@cc` contracts on the fixture module and the
test module. No production interface changed; no contract was weakened or
deleted. Every cross-replica read decision in the schedules goes through shared
committed PostgreSQL, and fixture teardown deletes only its own rows under the
complete public-table row-hash assertion. No contract violation found in the
inspected scope.
