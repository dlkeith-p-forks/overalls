# Lifecycle state-machine implementation ledger

> **Historical record:** This ledger preserves revision-specific implementation or verification evidence. It is not a current operational runbook, and its claims retain the original scope and execution gaps.

This work implements the user-authorized lifecycle refactor in the isolated
`feat/lifecycle-state-machines` worktree. Existing machines and production data
must not be modified. No compatibility layer is required.

## Required work

- [x] Marshall named state transitions: operations, VM intent, clone, resize,
  relocation, transfer/readiness/cleanup obligations and maintenance.
- [x] Lilly Ash resources with locked durable journal persistence for execution,
  datasets, snapshots, transfers, resize and cleanup.
- [x] Explicit evidence guards, idempotent replay, monotonic fencing and
  physical-evidence-based capacity settlement.
- [x] Structured allowlisted transition/effect logging in both applications.
- [x] Transactional full-lifecycle audit and redacted PaperTrail history;
  90-day retention, indexed bounded reads/cleanup and administrator views.
- [x] Lilly atomic state/audit outbox, authenticated ingestion, stable identities,
  acknowledgements, replay and backlog observability.
- [x] Protocol/client/UI integration and generated state-machine diagrams.
- [x] Unit, independent reference-model property, database and three-node tests.
- [ ] Native isolated NixOS/ZFS/KVM/fleet failure and recovery acceptance.
- [ ] Architecture decision/review, code-contract reconciliation, all three
  precommit gates, schema consistency and affected Nix checks.
- [ ] Commit completed work, integrate intervening main changes, revalidate,
  fast-forward main and push origin without force. Keep all worktrees and data.

## Evidence

The merged application gates and release checks pass. Native verification of the
combined revision is still running; predecessor results below are not claimed
as acceptance of the latest merge.

The initial full relocation run exposed pool-lock contention during source
cleanup. Bounded acquisition fixed the ordinary move, return move, stopped move,
deletion and cancellation cases. The subsequent run ended at its source-reboot
cleanup deadline: destination running, source inactive, deletion fence and ready
disk claim retained, with the pool lock unheld at the diagnostic observation.
Inspection found the fleet reboot fixture mounted only its parent after import
-N, leaving existing children unmounted. Commit 0e90403 restores only canmount=on
mounts and asserts source mounting before the unchanged recovery checks.
Verification of this fixture correction remains pending.

- Marshall merged precommit: 739 passing tests (65 properties and independent
  three-node races), contracts and zero Dialyzer errors. Two host/capacity-tagged
  tests are intentionally excluded from this gate; native checks remain separate.
- Protocol merged precommit: 137 passing tests (53 properties), contracts
  and zero Dialyzer errors.
- Lilly post-merge precommit with Ash 3.33.6: 340 passing tests (40 properties),
  contracts and zero Dialyzer errors. Export-log capture runs sequentially to
  exclude unrelated concurrent effect logs without weakening redaction assertions.
- Schema generation after merge ce9e24e detected no changes. Generated state
  diagrams are current.
- Both current source-release checks passed, including the bounded SSH refusal
  diagnostic and its credential/command redaction regression test.
- Audit tests cover attribution, transactional/log rollback, authenticated replay,
  permanent expiry replay fences, administrator authorization and bounded cleanup.
- Post-acquisition-fix, pre-merge native checks all passed: ZFS lifecycle
  (505.86s), transfer (247.70s), and nested-KVM guest (1202.02s). These cover
  interrupted creation/deletion, foreign GUID refusal, snapshot recovery,
  interrupted receive/adoption, cancellation, disk reuse, data survival after
  source reclamation, resize with a running neighbor, and Inception data disks.
  The merged revision's corresponding checks subsequently passed: lifecycle
  549.99s, transfer 235.96s, guest 1218.72s. The later cleanup-only integration
  retains ordinary deletion behavior; its full relocation acceptance is separate.
- The positive restoration and disk-reuse fixtures retry only the documented
  pre-effect storage_busy result under unchanged identity/fencing and bounded
  deadlines. Negative ownership assertions and subsequent data hashes remain.
- Fleet fresh database migration and first cross-host relocation passed, including
  guest data and all five expected producer audit types. Predecessor cloning fleet
  acceptance passed (825.42s): native SSH and browser copies, independent data
  after source deletion, and retained physical-copy audit. Full relocation
  recovery acceptance remains pending. The updated full run passed its first
  move (213.72s) and return move (968.46s), including confirmed cleanup and
  retained data; the latter recovered within the existing stage deadline.
- Main is integrated through 5765ca9 (merge 91de874). Lifecycle is ADR-0074,
  preserving upstream's ADR-0067 for reciprocal builders, ADR-0068 for Ubuntu
  guests and ADR-0069 for Brady. Overlapping Ziggy fixtures use origin's
  integrated real control credentials and isolated TLS model catalog; the local
  alternative is preserved in checkpoint 9087c15. No production provider is used.
- The merged cloning fleet ended with a queued insufficient_capacity refusal
  before source operations or snapshots. A retained database copy verified the
  closed failure; the fixture now exercises explicit public retry of that same
  clone only after checking no physical work began. The original failed SSH
  receipt remains pinned. The SSH regression and full Marshall gate passed; native acceptance passed after correcting the fixture receipt type assertion
  (377.63s), including SSH/browser copies, data after source deletion and audit.
- Serialized predecessor cloning passed fresh-host cadence but stopped at a refused Start.
  Porsche returned its generic `conflict`; Marshall now emits a finite refusal
  event through the existing authentication privacy filter. The next full native
  run passed; no generic refusal was retried or bypassed.
- Fresh fleet databases use PostgreSQL 18, matching Marshall's declared minimum
  and native UUIDv7 migration defaults. Production data has not been changed.

Unchecked items still require final review and/or execution evidence. No main
commit or push has been made by this worktree. Test logs are retained under
`/tmp/overalls-lifecycle-*`; pending checks must not be represented as passes.

## Latest recovery investigation

The full merged relocation run subsequently failed the stopped-guest move at its
unchanged 900-second cleanup deadline. Both units were inactive, disk claims
remained ready and source deletion intent had not been written. A journal-replayed
private copy of the retained test filesystem and database confirmed matching
source command, workload, epoch 3 and generation 6, with a revoked export permit.
This narrows the failure but does not establish its cause. Closed pre-deletion
stage diagnostics now preserve the existing guard order and payload redaction;
the next native run must identify and resolve the remaining prerequisite.
Original test artifacts remain untouched. The private diagnostic PostgreSQL
instance was stopped after inspection.

The corrected full cloning fleet run passed in 377.63 seconds with real packages,
PostgreSQL migration, authenticated enrollment, SSH/browser lifecycle operations,
independent clone data after source deletion and retained physical-copy audit.
Lilly precommit after the closed cleanup-stage diagnostic change passed 340 cases
(40 properties) with zero Dialyzer errors. Native relocation with those diagnostics
is running; no cleanup-recovery success is claimed yet.

Marshall's corresponding full gate also passed: 739 cases (65 properties), two
normal host/capacity exclusions, contracts and zero Dialyzer errors. Protocol has
not changed since its recorded 137-case gate. This validates application checks;
the pending native relocation result is still required for milestone completion.

The diagnostic relocation run identified `source_execution_unavailable` before
retirement guards. A bounded per-VM acquisition window now retries only definite
native contention for source retirement, with no callback replay. Real native-lock
properties pass; a full relocation rerun must validate this candidate correction.
The diagnostic run continues independently and its artifacts remain retained.

Native helper classification now distinguishes actual flock contention from
rejected inode/permission/other failures. After refreshing the cached development
shell helper, Lilly's full gate passed 345 cases (41 properties), including the
real inode-rejection regression, with zero Dialyzer errors. The preceding
classification run used an old helper and failed; it is not acceptance evidence.
The diagnostic fleet's first move recovered in 627.40 seconds and has entered its
return move. Full verification of bounded per-VM acquisition remains pending.

Final source gates for the bounded per-VM acquisition and native classification
change passed: Lilly 345 cases (41 properties), Marshall 739 cases (65 properties,
two normal host/capacity exclusions), contracts and zero Dialyzer errors in both.
The diagnostic fleet passed the return move in 190.25s and reproduced the same
execution-gate refusal on its stopped-guest cleanup. The new revision's full
relocation check is queued behind that still-live run. No native recovery success
is claimed for the new acquisition behavior yet.

## Backup integration after origin e0486c7

Merge efcdde9 preserves origin's host-recovery backup and required-transfer work.
Lifecycle moved to ADR-0074; upstream ADR-0070 and ADR-0071 retain their identities.
The incoming Python backup coordinator already has explicit durable transitions.
Its native Lilly backup snapshot journal still assigns phases directly and needs
integration with the local Ash graph/audit boundary. Preserve backup independence
from Marshall: putting recurring runs into one 64-event outbox would eventually
block otherwise healthy offline backups. Plan per-run snapshot producers, retaining
completed audit envelopes locally for 90 days and delivering them through the
existing placement-bound outbox. Only terminal, physically cleaned runs may move
to audit-only history; active journals, native claims and fences must remain.
The CLI must start only Ash dependencies, not a control-plane runtime. Tests must
cover repeated runs beyond 64 undelivered events, illegal transitions, interrupted
publication/cleanup, replay, bounded expiry and unchanged native backup data.

The queued pre-merge relocation launcher was intentionally cancelled before it
started any build or VM. The diagnostic run remains live and unchanged. Schedule
merged native acceptance after the integration and gates are ready; do not treat
the cancelled queue as a failed native run. Current pre-merge passes remain useful
regression evidence but do not establish acceptance of the backup integration.

The diagnostic relocation run subsequently exited 1 at the stopped-source cleanup
stage deadline, reporting `source_execution_unavailable`. Source unit inactivity,
ready disk claim and absence of deletion intent were retained. Nix preserved the
fixture at `/nix/var/nix/builds/nix-1469951-2843118236/build`; the log is
`/tmp/overalls-lifecycle-relocation-stages.log`. No native job or queued launcher
from this worktree remains running. The bounded acquisition change still needs
merged native acceptance after backup journal integration.

Post-mortem of the retained fixture identified the failed run's actual defect:
its evaluation resolved a stale `lilly-host-lock` build (`p57vmxwscalg…`, verified
to exit 73 on `flock` contention) even though `86d803a` had introduced the
distinct contention exit 75 that `Lilly.Host.Lock` retries. With the stale helper,
contention was classified as an uncertain `host_lock_unavailable`, which
`acquire/2` must not retry, so transfer cleanup could never win the per-VM lock
against the per-second stopped-source actor while ordinary actor ticks kept
succeeding on their single attempts. The identical-failure log dedup in
`Lilly.Transfer.ReceiveRuntime` made one warning stand in for the whole window.
A fresh evaluation of the current tree builds a helper verified to exit 75 under
held-lock contention, so the fleet rerun exercises the bounded-acquisition fix
for the first time.

## Delivery record (2026-09-19)

The branch integrated origin/main three times (nix-ld profiles; typed Python
gates with multi-disk transfer; structured event catalogs and bounded Nix
store reclamation), reconciling the lifecycle ADR to 0074, adopting the
upstream event catalogs for every lifecycle diagnostic, and preserving the
named-transition state machines. Upstream defects found and fixed en route:
the Inception `reject-prepare` expectation was unsatisfiable as written
(unsatisfiable also on pristine origin/main) and the fleet auto-update
fixture substituted a Logger message that the catalog had replaced.

Final gates on 388f69b: protocol, Lilly, Marshall and Porsche precommits,
`python-static`, every application logging catalog and the ADR check all
pass with zero Dialyzer errors. Native acceptance ran serially with nested
KVM: zfs-guest 1367 s, zfs-lifecycle 470 s, zfs-transfer 237 s and
relocation-fleet 3584 s, all passing with zero failed subtests. The stopped
guest move, cancellation restoration and dual daemon restart recovery now
complete natively. The review records the remaining deployment gap; this
log is closed with the branch ready for integration.
