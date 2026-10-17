# Authority fixture history teardown

## Scope and architecture assessment

Improvement 035 begins at published `1db02e1d` in its own
`verify/035-authority-fixture-history` worktree. The scope is the committed
PostgreSQL teardown of three distributed authority fixtures: Enrico catalog
history, SSH credential registration versus retirement, and Teams retirement
overlap. Each fixture deleted its raw Oban rows but left the retained job
snapshot and transition events behind.

No production architecture impact. ADR-0059's allowlisted job snapshots and
transition events persist transactionally with Oban changes and survive raw
deletion; ADR-0119 supersedes its read restriction and carries the retention
requirements forward. Production lifecycle, retention, authorization and the
`marshall_admin_job_capture` trigger are unchanged. Test teardown is allowed to
remove disposable fixture history after its callers have stopped; campaign 029
established that pattern and contract for the shared cleanup library this
improvement reuses. No ADR decision, status or supersession changes. No new
native boundary is changed or claimed, so no machine test is added or run.
New Inception testing and validation remain excluded.

## Baseline finding

The investigation established the intended database behavior first: deleting an
Oban job runs the real DELETE trigger, which retains the redacted audit
snapshot and transition events and marks the raw row absent. The omission is in
test fixture teardown, not in production deletion.

`/tmp/verify035-baseline.exs` reproduced the defect on the unchanged fixtures
in partition `marshall_testverify035`. Each of the three fixtures left exactly
two retained rows after its own cleanup returned:

- Enrico history: raw job 1 (`Marshall.Enrico.Worker`, repository
  `ff418112-2180-44a0-964d-feaef1fb3e90`) left event hash
  `9e883ba07a8c5c1a6e0f403b2c272fee` and snapshot hash
  `de1f3780f1b11e5b5ca7685e81d3d122`.
- Teams retirement: raw job 2 (`Marshall.Accounts.Workers.DeleteUserMachines`,
  deletion `9b225072-efc9-4e6b-994d-49a568e2979d`) left event hash
  `e382d3738d4995724a3d148a44f2c5cb` and snapshot hash
  `a94d73ece5bdeabba167a5cc18b53f07`.
- SSH credential retirement: raw job 3
  (`Marshall.Accounts.Workers.DeleteUserMachines`, deletion
  `5a7186fe-fca4-4db7-900d-7b906fb2b99b`) left event hash
  `54c8e6fc82dc4e7f5a39653bb15668f4` and snapshot hash
  `409507753431a991b467ea1c09e4ba30`.

The complete-public-table inventory delta of each cleanup touched only
`admin_job_events` and `admin_job_snapshots` with added rows; nothing was
removed and no earlier row changed. Exact fixture and job IDs are in
`/tmp/verify035-baseline-{enrico,team,credential}-ids.log`; the full
before/during/after row inventories are
`/tmp/verify035-baseline-{enrico,team,credential}-{before,during,after}.log`.
All six baseline rows remain preserved in the partition as evidence; no broad
deletion or reset substitutes for the scoped repair. The `1ebd576e`-prefixed
administrator, gateway, account, owner and team IDs in those logs are
disposable fixture identities only.

## Repair and contract review

The coordinator approved a scoped repair: teardown removes exactly the retained
rows belonging to the fixture's own jobs, using the exact job IDs returned by
deletion, with controls proving unrelated job history survives.

Each fixture's raw `DELETE FROM oban_jobs` now routes through the shared
[committed fixture cleanup](../../../marshall/test/support/committed_fixture_cleanup.ex)
`jobs!/2`, which deletes matching raw jobs with `RETURNING id` inside one
transaction and then removes only those IDs' `admin_job_events` and
`admin_job_snapshots` after the real trigger has run
(contract `committed-fixture-job-trigger-order`). The predicates are the
fixture-local selectors established by the baseline reproduction:
`args->>'id'` bound to the Enrico repository ID, and
`args->'primary_key'->>'id'` bound to each owned deletion receipt for the two
retirement fixtures. Fixture users, repositories and deletion receipts are read
before disposal, so the job sets are exactly the fixture-owned rows.

Each of the three distributed test modules gains a setup-level complete
public-table snapshot and an `on_exit` `assert_restored!`
(contract `committed-fixture-inventory-oracle`), and every fixture body now
runs under `Cleanup.protect peers do ... after ... end`
(contract `committed-fixture-primary-failure`): a failed body stops and
monitors the supplied independent peers before any row deletion, a teardown
failure is reported as a second ExUnit error, and the original assertion
remains primary. Existing operation ordering and gate/drain logic are
unchanged; inner gate release was already idempotent (`guarded` unlocks in its
own `after`, and the protected teardown repeats it harmlessly). New fixture
ownership contracts (`enrico-fixture-history-ownership`,
`credential-retirement-fixture-history-ownership`,
`team-retirement-fixture-history-ownership`) require callers to finish or stop
all remote operations before disposal and permit deletion only of exact
returned job histories; unrelated history must survive. Root, Marshall test and
callee contracts were reviewed; no application contract changes.

Controls. Every one of the 14 tests in the three suites now proves its teardown
restores the complete public-table inventory, so any unrelated job, snapshot,
or other row deletion fails the test. Before/after run audits preserve the six
retained baseline rows and all earlier rows byte-identically, and the expected
four production triggers remain. The unrelated-job preservation semantics of
`jobs!/2` itself keep their dedicated 029 regression: a completed same-worker
control inserted through real Oban keeps identical raw-row, snapshot and event
hashes through target cleanup; that generator reruns unmodified in the full
gate below.

The handbook reference records these developer-verification boundaries. User
scenario coverage and existing native records retain their scopes: disposing of
test rows adds no runtime product acceptance. `19-coverage.md` and
`scenarios.json` were inspected and intentionally not changed: no user-facing
scenario, authority boundary or refusal changed, and committed-fixture hygiene
is developer documentation under chapter 17, which gains one paragraph
recording the extended disposal and this review. All cleanup consumers were
inspected: the three scoped suites, and
`admin_account_distributed_test.exs`, which calls the team retirement cleanup
with an empty user list and is therefore behavior-neutral under the repair; its
own retained-row attribution, if any, remains separate campaign work, as with
the unattributed rows recorded in the 029 and 031 reviews.

## Execution record

### Focused repaired suites and controls

On the Verify035 partition, a pre-run audit recorded 3 `admin_job_events`,
3 `admin_job_snapshots`, zero `oban_jobs`, the six exact retained baseline rows
(job/snapshot pairs 1, 2 and 3 above) and the four expected production
triggers; the complete inventory snapshot is
`/tmp/verify035-before-repaired-rows.log`, SHA-256
`e195ce5ba43291b05980cee47871fa34ca9c7ce45e8e766264a3fd5f448fdd80`.

The focused run
`mix test --include distributed --seed 35001 test/marshall/enrico/history_distributed_test.exs test/marshall/ssh/credential_retirement_distributed_test.exs test/marshall/teams_retirement_distributed_test.exs`
passed all 14 tests (0 properties; these suites are fixed schedules), in 16.3
seconds (all synchronous), two stock exclusions (`:host`, `:capacity`).
Every test's complete-inventory `on_exit` assertion passed.
`/tmp/verify035-repaired-focused1.log` retains the run.

The post-run audit is byte-identical to the pre-run inventory (same SHA-256
`e195ce5b…`): zero net rows across every public table, the six baseline rows
preserved with `raw_present=false`, and the same four triggers.
`/tmp/verify035-after-repaired-rows.log` retains the manifest.

A direct per-fixture probe (`/tmp/verify035-repaired.exs`, the baseline script
replayed against the repaired teardown) shows each fixture's real job present
during the fixture — job 17 `Marshall.Enrico.Worker`, jobs 18 and 19
`Marshall.Accounts.Workers.DeleteUserMachines` — and an empty inventory delta
with zero retained snapshots and zero retained events after cleanup. The probe
itself leaves no residue. `/tmp/verify035-repaired-fixtures.log` and
`/tmp/verify035-repaired-{enrico,team,credential}-{before,during,after,ids}.log`
retain this evidence. Replayed under the original teardown, the identical
script is exactly the baseline that left the six rows above; under the repair
it leaves none, with unrelated rows untouched.

### Final gates

Full Marshall `mix precommit` on the final code tree: **1,174 passed
(133 properties, 1,041 tests), two exclusions, seed `515085`**; compiler,
ADR/contract/logging and browser checks passed; forced Dialyzer reported zero
errors, skips and unnecessary skips (log: `/tmp/verify035-final-precommit.log`).
The coordinator rerun of the focused distributed trio reproduced **14 passed**
at the recorded seed `35001`. All-file `prek` (ruff format/check, ty, logging,
hldd-review), `check_adrs.exs` (124 decisions), `check_hldd.exs`,
`hldd_options --check`, `hldd_coverage --check` and `hldd_views --check` all
pass. This documentation finalization and the ledger row are text-only
post-gate additions; governance receipts were re-recorded after them and the
Nix HLDD gate builds the committed tree.

## Remaining scope

The six baseline reproduction rows remain preserved in
`marshall_testverify035` as evidence, matching the campaign's
retained-and-attributed rule; no broad deletion or reset removes them. Rows
retained by other partitions and other fixtures remain separate 029/031/033
scope. This improvement is test-fixture hygiene over shared library code: no
production decision, native boundary or user scenario changes, and no new
Inception validation.
