# Backup operator verification

## Scope and architecture impact

Campaign improvement 026 starts from published `08ae4faa` in
`verify/026-backup-operators`. It adds verification of the existing operator
runtime under [ADR-0070](../decisions/0070-host-recovery-backups.md). No production
implementation, repository format, retention decision, recovery authority or
service configuration changes. The accepted/implemented ADR status is unchanged.
Its invariant wording now
explicitly distinguishes invalid manifests from missing retained references,
matching its latest-complete-point policy, existing local contract and code.
Expired points may already have missing components; they do not block pruning.

Reviewed the backup module, public runtime dispatch, complete manifest parser,
reference retention, private-directory checks and command subprocess lifetime;
root, Nix, module, backup, test, documentation and handbook contracts apply. The
new fixture contract requires explicit disposable paths and an independent
reference/inventory oracle. Only the new test and its Nix check call the fixture.

## Missing evidence and bounded implementation

The existing generated retention test replaces `Repository.manifest` and supplies
only component references. It establishes graph reachability but does not exercise
the complete manifest parser or public operator dispatch. The new
[operator histories](../../../nix/verification/tests/evaluation/backup-operators.py) invoke the
actual `runtime.py` in child processes with pinned Restic against local encrypted
repositories. They do not replace Repository methods or copy its validity predicate.

| Test family | Independent assertion |
| --- | --- |
| Eight complete histories, seed 26001 | List/inspect select the created candidates; shared host/guest references of the latest generated points and a recent orphan survive real prune; expired points and old unreferenced components disappear; a second prune is stable. Missing references in expired points remain compatible with current retention. |
| Nineteen enumerated malformed manifest cases, shuffled with seed 26002 | Unsupported version, foreign host, incomplete marker, invalid UUID/timestamps/revision/component kinds/references/schema/JSON/path all refuse inspect, restore and prune. Repository names/modes/bytes and original source are unchanged; no restore target or completed point is fabricated; last success survives the failed prune. |
| Six component-order/failure histories, seed 26003 | A missing retained component refuses prune without deletion. A restore failure after one or two verified components leaves inspectable partial output without `manifest.json`; same-target retry refuses unchanged. After fixture-only repair of the exact encrypted snapshot descriptor, explicit fresh-target restore returns every original byte and the manifest, preserving the prior partial directory. |
| Four shuffled host-lock histories, seed 26004, plus target refusals | After ordinary runtime initialization, a real flock held by the test process makes public list/inspect/restore/init return 75; scheduled operations skip with zero and no repository/source/state changes. Release permits inspect/restore. Nonempty, public-mode, symlink, symlink-ancestor, relative and parent-traversal targets refuse without changing existing data. Invalid/unknown snapshot IDs refuse. |

List is a candidate inventory; it does not promise that every listed manifest is
valid or every component is available. Inspect validates complete manifest shape.
A successful component restore is verified before final `manifest.json`
publication. Failure is not cross-component rollback: operators retain partial
output for inspection and explicitly choose a fresh empty destination after
resolving the cause. No automatic historical authority activation is introduced.

Every command supplies its own descriptor, private state/lock/password/cache,
repository and subprocess working directory. Environment construction excludes
ambient Restic, AWS, database and service configuration. The invocation boundary
gives each child a private session, signals the runtime
to drain its separate Restic reader session, then escalates to the recorded
process groups and drains output before returning. A forced CLI timeout probe
checks an isolated blocking reader and its child are no longer live, with
`interrupted` status and retained last success. Temporary trees are removed in a
finally block; intentional assertion and command failures after real restoration
check that cleanup preserves an unrelated sentinel. No shared database, S3
service, NixOS machine runtime or production data/credentials is used.

## Execution record

Nix `backup-operators` passed six methods in **686.622 seconds**, with zero
failures. Captured source tree
`37c2e3a5573ec6fc1c746acca88ad286e6d9948f`, based on `08ae4faa`, ran the six
methods with Python 3.13.15 and Restic 0.19.1 in the isolated Nix derivation
`/nix/store/1afrg8g1a8zv9li5bfzqxfq3m0f0c6v4-kittens-backup-operator-histories.drv`.
Its resolved-module Ruff and ty checks passed before runtime execution. The
normal test process and Nix session exited zero; code/check files remain identical
to this capture, with only documentation/evidence changes afterward.

The standalone timeout/assertion/command-failure probes passed two methods in
20.242 seconds before the final timeout-race refinement. The isolated guard
mutation removed only `references <= all_ids` from a copied `restic.py`:
all six partial/recovery histories failed at the intended public prune refusal
(returned zero instead of one), in 76.716 seconds. The original production module
was untouched; mutant fixtures and the copied module tree were removed.

The all-file Python Ruff format, Ruff and ty prek hooks passed. Nix
`python-static` passed 648 formatted source files and both static checks. The
existing `backup-types` gate passed its resolved typing, eight state tests,
eleven workflow/retention/command tests and two status tests. Contract syntax,
coverage and new contract discoverability passed. Final all-file prek and
ADR/HLDD/options/coverage/views checks passed. Reviewed receipts and the Nix
`hldd` check passed. The source/check files and evaluated operator derivation
remained identical to the passing capture. The final process/fixture audit found
zero operator processes and zero local fixture or mutant trees. No Marshall,
Lilly or shared governance implementation changed, so their application suites
were not rerun for these documentation and Python verification additions.

The first isolated Nix attempt stopped at two fixture-only invariant-list typing
errors before running the histories. Those were corrected by narrowing fixture
JSON with the existing typed boundary. No production defect was reproduced.
The first four-method runtime capture
(`/nix/store/3vff82p6xzk91hz332ydk2d5kj2lsyyf-kittens-backup-operator-histories.drv`)
finished in 660.814 seconds with one failure: a fixture precondition error in the
first lock schedule. Runner initializes its private `host-snapshots` directory before acquiring the host lock. Repository and source
inventories were unchanged. A focused run reproduced that exact directory-only
difference in 23.097 seconds; the lock history now first performs ordinary public
list initialization and retains full state/repository/source equality thereafter.
The other three methods (reference graphs, all nineteen malformed cases and
partial recovery)
passed in that capture.

## Existing acceptance and remaining gaps

The [original recovery review](2026-09-18-host-recovery-backups.md) retains its
recorded native ZFS, verified TLS S3, configured PostgreSQL, matching/wrong Cloak
keyrings, packaged list/inspect/restore/prune, guest capture and cleanup evidence.
The existing state/workflow properties remain credited. This change does not
rerun those native suites solely to update their revision, and the new local
Restic processes do not establish systemd, S3 transport, native snapshot ownership
or physical recovery acceptance.

Production backup enablement/provider IAM, independent off-host key recovery,
physical power loss, replacement GUID reconciliation and safe reactivation of
historical database authority remain separate. The failure histories exercise
missing components, not arbitrary process-kill points during Restic writes.
Inception testing/validation is excluded by the user's campaign instruction.
