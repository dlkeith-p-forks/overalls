# Committed test fixture history

## Scope and architecture assessment

Improvement 029 begins at published `c12a73e6` in its own
`verify/029-fixture-history-cleanup` worktree. Published `8af8164f` is integrated
before the first full gate; `4bd7d237` is integrated before final verification.
The intervening 028/032 changes do not alter these fixture or application
operation paths. The scope is committed PostgreSQL fixtures for public
admission, Galileo peer tokens and guest account rosters.

No production architecture impact: ADR-0100 carries forward ADR-0099's retained
agent history after VM deletion; ADR-0042 carries forward ADR-0009's durable audit
requirements. The detached agent-history migration and production lifecycle,
authorization, storage and retention behavior are unchanged. Test teardown is
allowed to remove disposable fixture history after its callers have stopped.
No new native boundary is changed or claimed, so no machine test is added or run.
New Inception testing and validation remain excluded.

## Baseline finding

On unchanged `c12a73e6`, the existing three-peer admission test for one idempotent
request passed at seed `29001` but left nine fixture rows: one each in five agent
history tables, one job event and snapshot, and two lifecycle events. The actual
`GalileoPeerFixture.create/cleanup` public-operation fixture added the same nine
rows. `GuestIdentityFixture.roster_fixtures!/cleanup_rosters` added 22: two each
in the five agent and two job tables, plus eight lifecycle events.

Full public-table row digests before, during and after each fixture and its exact
VM/owner/host IDs establish these specific causes. No earlier rows changed or
disappeared. Automatic agent registration is part of public provisioning. Its
roots intentionally lack a VM foreign key. The real Oban DELETE trigger retains
job snapshots and marks the raw row absent; deleting the job alone leaves the
redacted history. Lifecycle events likewise deliberately survive their resource.

These are test fixture omissions, not production deletion defects. Earlier full
suite counts from other campaign partitions are leads only; they do not prove
which fixture wrote every retained row. All older campaign databases and all 40
new baseline rows in `marshall_testverify029` remain untouched. No database reset
or broad history deletion substitutes for verification.

Baseline logs and exact inventories are `/tmp/verify029-baseline-admission.log`,
`/tmp/verify029-baseline-fixtures2.log` and
`/tmp/verify029-{before-galileo,created-galileo,after-galileo,created-rosters,after-rosters}-rows.log`.
An earlier disposable baseline script had a delimiter syntax error before any fixture SQL
ran; `/tmp/verify029-baseline-fixtures.log` retains that setup failure separately.

## Repair and contract review

The shared [committed fixture cleanup](../../../marshall/test/support/committed_fixture_cleanup.ex)
replaces duplicated compute teardown. Exact fixture placements supply VM IDs;
only their roots, threads, audit rows and versions are removed in foreign-key
order. Richer referenced agent work aborts the history cleanup transaction.
Lifecycle deletion uses exact VM or dedicated fixture-host IDs. Raw Oban deletion
captures returned job IDs, runs the real DELETE trigger, and then removes only
those job events and snapshots. Shared image ownership is captured before public creation. Only new fixture
image IDs may be disposed; pre-existing unreferenced images and their versions
remain intact, as do images with any remaining VM reference.

A protected teardown keeps the original assertion and stack trace. If cleanup
also fails, ExUnit reports both errors with the original first. A failed body
stops and monitors its supplied independent peers before deleting rows; failure
to observe peer termination prevents cleanup. Existing successful distributed
operation ordering is unchanged. Root, Marshall, test and callee contracts were
reviewed; new contracts describe fixture ownership, failure ordering and exact
history bounds without changing application contracts.

The [generated regression](../../../marshall/test/marshall/committed_fixture_cleanup_test.exs)
executes shuffled histories containing both success and intentional assertion
failure for each of the three public-operation fixtures. It compares every public
table's complete row digest inventory after each cleanup, including an unrelated
fixture's automatic agent, job and lifecycle histories. That control host is
disabled before the protected snapshot solely to keep new admission on its own
fixture hosts. A second control owns an unreferenced image. Every generated history runs both
control cases; no control row is deleted or altered during either history. Separate
checks preserve simultaneous errors and observe an outstanding independent peer
call stopped before teardown.

The handbook reference records these developer-verification boundaries. User
scenario coverage and existing native records retain their scopes: disposing of
test rows adds no runtime product acceptance.

## Execution record

Final full, type, static and documentation verification passes as recorded below.
Initial focused execution exposed assertion-message
formatting in the new test (ExUnit adds newlines); this fixture-only issue is
corrected using matching assertion text. The corrected initial three checks
(one property, two tests) pass at seed `29002` in 5.4 seconds. The final generator
additionally requires both outcome types for every fixture in each history.

The first affected run passes 49 checks (one property, 48 tests), seed `29003`,
in 67.7 seconds. Its complete-table audit preserves all prior hashes and adds no
agent or job rows, but retains 57 relocation lifecycle rows. These are
`SourcePermitRequest` and `CleanupRequest` events without VM/host fields. The
actual resource/workflow identity mappings establish their fixture ownership;
cleanup now captures the exact relocation IDs before deleting those resources.
All 57 first-candidate rows remain as additional preservation controls.

The corrected affected run includes an independent complete-public-table
before/on-exit inventory check for every test in all three distributed suites.
It passes all 49 checks, seed `29004`, in 82.2 seconds. Every row digest is restored,
including the 97 retained baseline/candidate data rows, bootstrap and migrations.
Both `/tmp/verify029-before-affected2-rows.log` and
`/tmp/verify029-after-affected2-rows.log` have SHA-256
`020ee2de76bf55b8f6e2e836a000f25ed0175fceb28ae874112d41e970564176`.
Logs `/tmp/verify029-affected1.log` and `/tmp/verify029-affected2.log` retain both
passing test runs and their different audit outcomes; both sessions drained.


### First full gate and ownership correction

The first full Marshall gate at seed `842287` reports 1,172/1,173 passing
(133/133 properties, 1,039/1,040 tests), two excluded, in 807.0 seconds. The
three-peer token race body succeeds but its new complete-inventory `on_exit`
assertion fails. The original output truncates both maps before their changed
entry: its precise historical cause is not established. Browser checks and
forced Dialyzer complete successfully with zero errors/skips; the gate exits 2.
`/tmp/verify029-precommit1.log` preserves the failure. The gate formatter changes
one inventory query's wrapping; stripped Elixir AST comparison confirms identical
semantics. Captured trees are `98849b02594ad85def5eaffd1a5beb5c9dd155f9`
(preformat) and `306559546c4b0c5cc8154647d14eeb9d24eb4bff` (formatted).

After the gate drains, every one of the 236 prior rows is preserved and 26 rows
are added (13 job snapshots and 13 events). Those rows remain retained and their
owning fixtures are not yet attributed. There are no other database connections,
advisory locks or remaining fixture BEAM processes. The expected four production
triggers remain. The complete final manifest has SHA-256
`54bff1a94ee40dc239703cf12d652841250dea6118d301b9541477b5da502ae9`.
The older `verify025` partition's 630 recorded agent rows remain byte-identical
under its existing digest oracle, SHA-256
`380277480a2944fdd3c2e1782147f3c0b60248bab7f02e118364f6163978f7bd`.
The audit is `/tmp/verify029-audit-full1.log`.

The same peer suite passes both tests against the retained database at seed
`842287`. A separate owned control then reproduces a relevant fixture bug:
`GalileoPeerFixture.create/cleanup` removes a pre-existing unreferenced image and
its version. Its independent delta contains only `compute_images` hash
`e9ca493fff9ccf3a65ec39fcf6e3e9d1` and `compute_images_versions` hash
`14b9310b552604ef1a59a8df0f4d6b85`, both removed. The probe disposes only its own
control and restores the exact original inventory; its log is
`/tmp/verify029-image-control.log`. This causal probe supports the ownership fix;
it does not prove the original truncated full-gate mismatch had the same cause.
The strict oracle now reports every changed table and added/removed hash, retains
multiplicity and detects added/removed empty tables without exposing row payloads.

The retention-continuation test also replaces its pre-existing worker-wide job
predicate with exact newly captured job IDs within its serial/manual-Oban interval.
A completed same-worker control, inserted through real Oban and its history trigger,
keeps identical raw-row, snapshot and event hashes through target cleanup. Its
completion state is excluded by the pinned Oban drainer and AshOban's incomplete
uniqueness set. Control disposal uses only its captured ID and preserves original
body errors if teardown fails.

A diagnostic full-run attempt was stopped on request during architecture tests
before committed distributed fixtures ran. Its shutdown returns zero but is
explicitly cancelled, not passing evidence. Before/after complete inventories are
identical at the `54bff1a9` digest above; its log is
`/tmp/verify029-diagnostic-full.log`. The corrected final execution is recorded below.


The corrected affected suites pass 50 checks (one property, 49 tests), seed
`29005`, in 96.3 seconds. This includes both image-control cases, all six generated
success/failure fixture steps, exact completed-job preservation and per-test full
inventories. The run drains and leaves all 262 rows byte-identical at SHA-256
`54bff1a94ee40dc239703cf12d652841250dea6118d301b9541477b5da502ae9`.
Its log and manifests are `/tmp/verify029-affected3.log` and
`/tmp/verify029-{before,after}-affected3-rows.log`. Formatting reaches a checked
fixed point before the final source capture; contract format/discovery passes.


### Final execution and remaining scope

The corrected full Marshall `precommit` gate passes at seed `842287`: 1,174
checks (133 properties, 1,041 tests), two existing exclusions, in 838.5 seconds
(37.3 async, 801.1 sync). The pinned-runtime, compiler, ADR/HLDD/contracts/logging,
browser-state and TypeScript gates pass. Forced Dialyzer reports zero errors,
zero skips and zero unnecessary skips in 1 minute 7.3 seconds. The complete
session drains with exit zero. `/tmp/verify029-precommit2.log` retains the result.
This passing run does not establish the exact cause of the first truncated
inventory failure.

The tested source is captured over base `4bd7d237` in tree
`638740925766b883b8fd74c2bd0749615f79d026`. All eight changed test/support file
hashes in `/tmp/verify029-full2-source.sha256` still match after the gate; the
formatter makes no further edits. Its manifest SHA-256 is
`9ebac0dedfd53d74a9c629ea78a34da7dcdeadb87317881010fed3e2a84a02e0`.
Subsequent changes close only this evidence record, campaign status and governance
receipt. The later external Lilly recovery commit `186a1ea4` is outside this
execution. Marshall has no direct references to its changed native modules;
the relevant transport fixtures configure empty pools. Integration must preserve
that limit and must not turn this cleanup verification into native recovery proof.

The final read-only audit passes after the gate drains. All 262 earlier rows,
including the first full run's 26 unattributed job-history rows, remain identical.
The run adds 28 retained rows: 13 job events, 13 job snapshots, one image and one
image version. Their owning fixtures remain unattributed; no broad deletion or
reset removes them. The 290-row final inventory has SHA-256
`ad3d4fc344ceb7390167c632e4883e2e69d48fb13e221ede150490e29d8c8e01`.
`/tmp/verify029-{before,after}-full2-rows.log`,
`/tmp/verify029-added-full2-rows.log` and `/tmp/verify029-audit-full2.log`
retain this distinct run and its delta. The older `verify025` partition's 630
recorded agent rows retain the `38027748` digest above. There are zero other
connections, zero advisory locks and no remaining fixture BEAM processes; only
the four expected production triggers remain.

All-file `prek` passes all eight Elixir logging catalogs, HLDD receipts, Ruff,
Python formatting and `ty`. ADR structure, contract format/discovery, HLDD
references, generated options/scenarios/domain/topology views and the Nix `hldd`
check pass. The latter completes with exit zero in 19 seconds;
`/tmp/verify029-static2.log` records these checks. Structural validation is not
native acceptance. No ADR decision/status, production history semantics or user
scenario scope changes. Further fixture attribution for retained whole-suite rows
is separate work; no new Inception tests or validation were performed.
