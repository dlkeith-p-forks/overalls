# Audit scan-boundary fairness review

## Scope and architecture impact

Base: `b5c9c1339f7b12d914114e31288d9062e1effc40`. ADR-0074 remains
accepted and partial. This change adds local verification of its existing
128-path/16-event traversal limits. It changes no production behavior, API,
authorization, storage format or execution authority. No replacement decision
is required. Self-review only; no independent agent review was performed.

## Discovery and new property

The empty-metadata startup property crosses the path limit but has no real events.
The dirty-restart sender property checks real events and actors with at most
three placements. Neither establishes fair offers across a larger retained
journal inventory. The new `pending journals beyond scan and offer bounds are
not starved` property uses production Journal writers, OS locks, Outbox,
AuditRuntime and Client with an isolated loopback HTTP fixture. Generated
inventories contain17/63/64/65/127/128/129/257placements with1/2/17events each.
Each draw also includes129placements with one event. The actor-root alone has
more than128children in that fixed case, before counting journal and lock files.

Zero-acknowledgment traversal must offer every pending resource without repeating
a previously observed resource before the roster is exhausted. Every offered
event must match the exact durable inventory, with at most16events per request.
No readiness may precede drain. Exact accepted event IDs then retire under real
writer locks, and a fresh offer-free pass must establish readiness.

## Contracts and limits

Reviewed repository, Lilly and Lilly test CONTRACTS, the local dirty-restart,
roster and readiness contracts, and Outbox's bounded-scan contract. All fixture
files and sockets are temporary and unprivileged. The existing restart property
retains duplicate/partial-ACK, sender death and stale readiness checks. The new
property adds scan geometry; it does not claim TLS authentication, Marshall
authorization, actual Runtime bootstrap, native hosts/VMMs, competing sustained
appends, multiple resource classes or hosted Antithesis coverage.

## Verification

The corrected focused run passed two properties in155.3seconds, seed937797,
log `/tmp/overalls-audit-scan-fairness-focused2.log`, exit0. The fixed129-placement
case runs in every draw. Generated257placement cases are available in the
property; this record does not assert that every random geometry was selected.
Full component/governance gates and targeted mutation checks subsequently passed as recorded below.
Native authenticated fairness remains an explicit follow-up.

The first focused execution exited2: one existing property passed and the new
property hit ExUnit's60second timeout, seed937797, total79.5seconds. Its
stacktrace was in the oracle's repeated full-inventory lock release, not an
asserted fairness failure. The new drain oracle now validates exact remaining
event IDs per offer, monitors actual acknowledgment task completion, and checks
the complete on-disk inventory at the final boundary. An unchanged-inventory
check still follows the entire zero-ACK pass. This removes quadratic whole-tree
lock scans. The larger fixture has a bounded300second property timeout;
request, task and lock deadlines remain unchanged. The corrected focused run recorded above passed.

ADR structure/link checking passed138decisions. The native Elixir contract
adapter passed118CONTRACTS files,2442native notes and203parsed source files;
structural checks only. Direct cc-check rejected `.exs` as unsupported, and the
first adapter attempt found its cache missing; matching pinned package-lock
SHA256 was verified before copying an independent tool cache and rerunning.

### Exact path budget

The new `metadata traversal retains the exact suffix after its path budget`
property passes two properties in0.9seconds, seed820551, exit0, log
`/tmp/overalls-audit-scan-path-budget-focused2.log`. Generated file counts cover
0/1/126/127/128/129/255/256/257and each draw also includes129files. The configured
actors root consumes one visit; the first batch must retain exactly the sorted
suffix after127regular files, and the next batch retains the suffix after a
further128visits. Neither batch may produce events or origins for these empty
metadata files. The first attempt was a fixture compilation failure because
Config's enforced client/cgroup fields were missing; it ran no properties.
The corrected fixture constructs the ordinary validated Client and required
Config fields. No network request is needed for this path-budget oracle.

### Local mutation attribution

The queue-reset mutant changes only AuditRuntime's real tick traversal to restart
from configured roots every time. The unchanged new fairness property failed
after28.8seconds, seed937797, exit2, with count17/backlog1: a later offered
resource was already in the independently observed roster before the roster was
complete. Log `/tmp/overalls-audit-scan-fairness-mutant.log`; patch
`antithesis/scratchbook/mutation-testing/patches/local-audit-reset-scan-queue.patch`,
SHA256 `597e1fe97f971889b16ee599af4870972071f7478624854c272c2997641fc0bd`.
This is a local property falsification, not a hosted SDK catalog result.
The mutant was restored before the separate path-budget mutant.

The path-budget mutant changes only Outbox.batch's128visit limit to129. The
unchanged suffix property failed in0.1seconds, seed296931, exit2: fixed129file
case retained only`99`, while the independent128visit oracle required`98`and`99`.
Log `/tmp/overalls-audit-scan-path-budget-mutant.log`; patch
`antithesis/scratchbook/mutation-testing/patches/local-audit-path-budget-129.patch`,
SHA256 `11344868fa2136a4d06aa713bb61bc529e1d6b75bc080025e49cfaf1c4afe2f7`.
Both mutations were restored in the disposable fork; `git diff --exit-code HEAD
-- lilly/lib` passed before fork removal. The baseline worktree has no production
Lilly source changes. These two falsifications do not close native/hosted gaps.

## Full Lilly component gate

The pinned full Lilly `mix precommit` completed exit 0, passing 505 checks
(94 properties and 411 tests), seed 429293, in 212.2 seconds. Forced Dialyzer
passed in 15.0 seconds with zero errors, skips or unnecessary skips. Runtime,
compiler, formatter, contracts, logging, ADR and HLDD gates passed. Log:
`/tmp/overalls-audit-scan-fairness-lilly-precommit.log`. This records the frozen
b5c9c133 baseline plus the owned property/evidence draft, before main integration.

All-file hooks and evaluated HLDD passed immediately before the full component
gate; evaluated archive `1791214411115-2796427-0.jsonl`, 22 seconds. Integrated
Marshall and final documentation/receipt checks remain required before publishing.
The larger generated inventory, exact path suffix and two targeted local mutant
falsifications retain the native/authentication/concurrent-append/hosted limits
stated above. These gates establish no new physical execution authority.

## Main integration

Main c96f21255449981eb587fce0dcffeecf553f007e was fast-forwarded into this
worktree after saving the complete owned draft in the retained
`antithesis-audit-scan-fairness-before-main-c96-2026-10-05` stash. Index restoration
first refused the changed one-line receipt file; ordinary stash application
merged the source/chapters and left only that receipt conflicted. Main's receipt
definitions were retained for a fresh reviewed receipt pass. Both property
files match the retained stash byte-for-byte; no production Lilly or protocol
source changed in the main merge. Native recorder evidence and local fairness
evidence remain separate in the merged scenario ledger. Integrated Marshall subsequently passed as recorded below.

## Integrated Marshall gate and latest main

Full integrated Marshall precommit passed exit0:1452checks (238properties,
1214tests), two exclusions,seed344724,in1649.5seconds. Forced Dialyzer passed
41.53seconds with zero errors, skips or unnecessary skips after PLT checking.
Log: `/tmp/overalls-audit-scan-fairness-marshall-precommit2.log`.
The first attempt stopped before compilation because this worktree lacked
dependencies; matching locked independent dependency/build caches were copied
before the passing run. That attempt is not test evidence.

Saved the owned draft in retained stash
`antithesis-audit-scan-fairness-before-main-9a71-2026-10-05`, then fast-forwarded
main9a71e12a. Only the receipt file conflicted on restoration; main definitions
were retained for fresh reviewed receipts. Both property files remain byte-identical
to the saved draft. Upstream changes Enrico native ownership and documentation,
not Marshall/Lilly/protocol implementation or these tests. Recorded test scope
is preserved. Final all-file hooks, ADR checks, generated references and views,
and evaluated HLDD passed exit0; evaluated build completed in20seconds, archive
`1791221254103-3173626-0.jsonl`, log
`/tmp/overalls-audit-scan-fairness-final-publish-checks.log`.
Publication follows normal commit hooks. Final diff preserves ADR-0074 and
existing production contracts; architecture impact is verification evidence only.
Stored mutation patch files retain the unified-diff blank context marker; raw
git whitespace checking reports that marker as trailing whitespace. Source and
documentation whitespace checks exclude patch artifacts, whose original hashes
and tested mutations remain unchanged.
