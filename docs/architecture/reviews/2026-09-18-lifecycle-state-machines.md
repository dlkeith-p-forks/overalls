# Lifecycle state machines and audit review

## Scope and authorization

The user authorized explicit lifecycle state machines, tests, structured logging,
durable audit and 90-day retention in an isolated worktree, followed by verified
integration to main and an origin push. No production VM or host metadata is
modified by this implementation work. No compatibility/reset path is supplied.

Affected decisions: ADR-0002, ADR-0017, ADR-0037, ADR-0053, ADR-0055 and the accepted
[ADR-0074](../decisions/0074-durable-lifecycle-state-machines.md). The new decision
adds explicit graphs and history while retaining physical ownership, fencing,
transactional capacity and independent cleanup requirements.

## Findings and resolutions

- **Liveness:** the full relocation run reached a ready destination but timed out
  after 15 minutes of source-cleanup contention. Native evidence showed the
  source stopped with its deletion fence and disk retained, while a ZFS process
  held the pool lock. Single-attempt pool acquisition can repeatedly collide with
  periodic sampling. Lifecycle callers now retry only contended acquisition in a
  one-second monotonic window; observations stay nonblocking. The callback still
  runs once under the original lock inode, and exhausted acquisition grants no
  ownership. Native-lock regression tests and both consumer gates pass. The
  updated first native relocation passed in 213.00s, including source cleanup,
  guest data, networking and producer audit. Remaining fleet scenarios are pending.
- **Recovery:** persisted relocation phases initially missed unknown activation
  observations. Distributed tests exposed the discrepancy. Current activation
  outcomes now mark uncertainty through a named transition; a later exact running
  observation can resume readiness checking without reviving failed readiness.
- **Durability:** computing audit correlation from the latest local payload would
  change a replay's meaning after a new generation or snapshot-pointer binding.
  Correlation fields now persist in the original atomic event envelope.
- **Concurrency:** using an actor's lifetime lock for audit acknowledgment would
  prevent acknowledgment while it runs. Execution journal writes and audit
  acknowledgments share a separate short-lived lock, with actor ownership still
  required for execution. Other journals retain their existing pool/export lock.
- **Recovery:** physical deletion can first be uncertain and later confirmed under
  the same generation. The execution graph and regression test admit that receipt;
  deleted journals still reject new starts.
- **Verification:** synthetic fixtures formerly rewound completed operations or
  skipped workflow phases. They now use named transitions, or explicitly labeled
  SQL fixture construction where testing a read projection rather than execution.
- **Privacy:** transition logs and lifecycle events project only identifiers and
  finite states/actions. PaperTrail excludes clone payloads/snapshots and request
  keys. Native effect logging excludes arguments and returned utility bytes.
  Expected SSH admission refusals use a finite event suffix drawn from the
  existing public error set, retained by the authentication privacy filter;
  command text, tokens and arbitrary error values remain excluded. This adds
  diagnostic evidence without changing admission or Porsche's response mapping
  under ADR-0046.
- **Retention:** lifecycle expiry is independent of permanent producer replay
  cursors, physical receipts, reservations and ownership tombstones. Full cleanup
  batches schedule continuation inside the transaction.

## Contract assessment

Reviewed journal write/load/publish/acknowledgment paths and their VM, dataset,
snapshot, receive, permit and resize callers; reviewed named Marshall transition
dispatch, event insertion, credential/session ownership checks and capacity
settlement call paths. No native GUID/nonce guards or host-before-VM locks were
removed. Existing binary intent and native lock-owner protocols are unchanged.
Source reads, state and audit are not substitutes for physical absence.

Structural contract checks passed. They do not establish these semantic claims;
the runtime tests and direct control-flow review provide the supporting evidence.

## Verification and remaining work

- Marshall: 730 tests passed, including 65 properties and independent three-node
  races, plus Dialyzer with no errors. Incoming fixtures now use stop intent and
  named readiness/completion transitions. Authorization properties refresh their
  host report per generated case; production freshness guards remain unchanged.
- Lilly: 311 tests passed, including 35 properties, plus Dialyzer, including
  origin's closed export-failure logging. Global log assertions run sequentially. The outbox-capacity test
  proves full queues retain their bytes and resume after accepted acknowledgments.
- Protocol: 132 tests passed, including 51 properties, plus Dialyzer.
- Both current source-release checks passed. The SSH refusal regression verifies
  the closed event survives filtering while both credentials and command text do not.
- Audit tests cover transactional rollback (including logs), requester attribution,
  authentication/session binding, deduplication/conflicts, expiry/replay fences,
  bounded retention/continuation, PaperTrail expiry and administrator views.
- Current native ZFS lifecycle (518.49s) and transfer (242.89s) checks passed. Updated nested-KVM
  guest acceptance passed (1753.47s), including resize crash recovery with a
  running neighbor, separate Inception data-drive retention, and clone data
  surviving source deletion. The restoration fixture retries only pre-launch
  `storage_busy` with unchanged epoch/generation and a bounded deadline.
  The disk-reuse fixture likewise retries only that documented transient result
  and still requires successful preparation and unchanged data hashes.
- Fresh fleet migration, enrollment and the first data-preserving cross-host
  relocation passed, including all five producer audit types. Full cloning fleet
  acceptance passed (825.42s), including SSH/browser copies, independent data
  after source deletion and retained physical-copy audit. Full relocation recovery
  acceptance remains pending. Closed refusal events exclude arbitrary SSH output.
- Main's account-security, network-isolation and mandatory Ziggy changes are
  integrated. The upstream isolated provider fixture and real inference-only
  control credential preserve updater readiness without external providers.

The [implementation ledger](../../history/ledgers/lifecycle-implementation.md) tracks completion.
This review remains a checkpoint until final integration and native verification.

### Integration with origin/main at a4c1e5f

The merge preserves lifecycle audit and Brady egress endpoints independently, and
retains both branches’ native storage-lock tests. Pool mutations retain their
one-second default acquisition window; transfer receivers may explicitly wait
two seconds, while observations explicitly use zero. Only ownership contention
is retried, never an effect, and the same native lock inode remains authoritative.
ADR-0074 is the lifecycle decision; upstream ADR-0068 and ADR-0069 are preserved.
This reconciliation preserves ADR-0017 and ADR-0037 ownership requirements.

Merged-tree verification: protocol precommit passed 137 cases (53 properties),
Lilly passed 337 (39 properties), and Marshall passed 738 (65 properties), with
two normal host/capacity exclusions. All three gates passed compiler, contract,
ADR and Dialyzer checks with zero Dialyzer errors. Native acceptance of the
combined revision remains separate and pending.

### Fleet reboot mount fixture

The post-reboot relocation reaches a running destination but cannot confirm
source snapshot cleanup. Inspection found that fleet-storage imports with -N
and mounts only zroot/lilly: existing children remain unmounted after reboot,
while snapshot_source correctly requires a mounted, GUID-bound disk. The fixture
now mounts only existing canmount=on, unmounted filesystems beneath its Lilly
parent; noauto/off receive staging remains unmounted. A native assertion checks
source mounting after reboot before the unchanged fencing, data and cleanup
assertions. This corrects test boot setup under ADR-0017/0037; no production
mount, ownership or cleanup guard is weakened. Full native verification of this
change remains pending, and other recovery failures are not ruled out.

The predecessor storage command completed successfully: lifecycle 505.86s,
transfer 247.70s, guest 1202.02s. The predecessor relocation command exited with
a cleanup-stage timeout in the source-reboot case. Its final source observation
was inactive with the deletion fence, ready disk claim and data metadata retained;
the destination was active. The corrected merged fleet run and merged storage
checks remain pending; these observations are not proof of the fixture fix.

### Integration with origin/main at 788a94a

Incoming utility uncertainty logging is composed with lifecycle effect logging.
Both preserve the original command result and exclude arguments, paths and
returned bytes. Incoming source retirement and final deletion use explicit
two-second pool acquisition windows. Ordinary Disk.delete retains this branch’s
one-second default, so the merge does not silently restore immediate contention
failures. Native ownership and effect replay rules remain unchanged under
ADR-0017/0037/0070. Shared Logger silence assertions run synchronously, as in the
existing transfer endpoint tests. The pending corrected relocation run will
exercise these source-cleanup changes; independent storage effects and ordinary
delete behavior remain equivalent to the currently running storage suite.

Both consumer precommit gates passed after the cleanup integration: Lilly
340 cases (40 properties), Marshall 738 (65 properties; two normal exclusions),
with zero Dialyzer errors. Both source-release checks passed. Protocol and state
resource definitions are unchanged from the preceding verified merge.

### Queued clone capacity refusal

The merged cloning fleet failed before physical preparation. Inspection of a
copy of its retained database established phase=failed, insufficient_capacity,
active=false, no source operation and no captured snapshot. Production admission
correctly retained the source; the fixture had treated the terminal workflow
receipt as an opaque SSH failure. The fixture now permits only this specific
preparation refusal to reach a bounded explicit public request-retry loop. It
checks the unchanged source process, absent native snapshots, absent destination
and absent transfer slots before retrying the same clone, with a new SSH receipt
for each retry. Unknown and physical failures still fail immediately.

A database-backed SSH regression verifies that retry preserves the clone and
destination IDs, that no holds or operations leaked from refused preparation,
and that the original failed receipt remains pinned. Its module passed 11 cases
(one property). Seven focused generated-helper cases rejected physical failures,
active/published claims and incorrectly successful exit statuses. This extends
verification of ADR-0055/0070 without changing production admission or capacity
policy. The full native retry run remains pending.

Marshall’s full gate with the new SSH retry regression passed 739 cases
(65 properties; two normal exclusions), contract/ADR checks and Dialyzer with
zero errors. The corrected native clone test is queued after the running
relocation test; its return move currently awaits source cleanup.

### Merged native storage acceptance

The merged storage command exited successfully: ZFS lifecycle 549.99s, transfer
235.96s, and nested-KVM guest 1218.72s. The full relocation run also completed
its first move in 213.72s and return move in 968.46s, including verified source
cleanup and data. The earlier unconfirmed return cleanup recovered within the
existing deadline; it is no longer an unresolved failure. Subsequent relocation
scenarios and the corrected cloning fleet remain pending. No deadline or native
ownership/data assertion was relaxed.

### Stopped-source cleanup investigation

The subsequent merged fleet run failed the stopped-source cleanup deadline after
its first and return moves passed. Retained private fixture copies prove the
source command and cleanup obligation agree on workload, placement, epoch and
generation; the source intent is stopped and its export permit revoked. Neither
physical deletion nor capacity release was reported. The actual failing guard
remains unproven. Cleanup diagnostics now classify pre-deletion local stages as
closed atoms, preserving guard order, launch fencing, native proofs and all
receipt semantics (ADRs 0017, 0037 and 0070). The runtime diagnostic property
covers the new reasons and rejects wrapped private payloads. Full native recovery
acceptance remains required; this diagnostic refinement is not a cleanup fix.

The cloning fixture additionally asserts the successful callback retained a
receipt before reading it. This satisfies the native Python type checker and
fails explicitly if the callback violates its existing postcondition; it changes
no admission, retry or physical-data assertions. The conflict-free main merge
91de874 preserves origin 5765ca9 and the lifecycle work. No deployment or push has
been performed.

The corrected cloning fleet subsequently passed its complete 377.63-second run,
including source deletion, independent data in both SSH/browser copies and audit
retention. Its type assertion preserves the successful receipt postcondition.
Lilly's full diagnostic-change gate passed 340 cases (40 properties), contracts
and zero Dialyzer errors. Relocation remains the unresolved native acceptance gate.

### Per-VM acquisition follow-up

The diagnostic native run reported `source_execution_unavailable` before source
retirement reached its ownership/intent guards. The stopped source actor still
reconciles each second under the same per-VM lock; cleanup previously made only
one attempt per five-second retry. Transfer retirement now permits at most two
seconds of acquisition retries, only for definite native contention. Other VM
entry points retain a single attempt. Guards and effects execute once after
ownership, with the same inode and existing helper handshake/cancellation rules.
This refines ADR-0074's bounded acquisition policy within ADR-0017's ownership
contract; it grants no authority from elapsed time. Real unprivileged native-lock
properties cover release-and-acquire, exclusion, inode retention, bounded failure,
cancellation and unavailable paths. Lilly's first gate passed 344 cases (41
properties) with no Dialyzer errors; final formatted-source gates and native
relocation validation are pending. This remains a candidate liveness correction,
not a claim that the recovery failure is resolved.

The helper review found that all pre-handshake exits were previously classified
as contention, including rejected inodes. The native helper now reserves exit 75
for flock EWOULDBLOCK/EAGAIN; Elixir maps all other early exits to unavailable.
Ownership still requires the exact nonce echo, and no rejected inode is replaced.
The native rejection regression retains unsafe file bytes and inode. Reviewed
retry consumers in Storage and SocketCustody: only genuine contention retries;
other acquisition callers still require a successful port before proceeding.
The development shell initially reused its old helper binary; refreshing its Nix
evaluation rebuilt the source package. With that actual helper, the full Lilly
gate passed 345 cases (41 properties), contracts and zero Dialyzer errors.
The diagnostic fleet's first move recovered and passed in 627.40s; its later
scenarios and the bounded-acquisition revision's native acceptance remain pending.

Final source gates for the bounded per-VM acquisition and native classification
change passed: Lilly 345 cases (41 properties), Marshall 739 cases (65 properties,
two normal host/capacity exclusions), contracts and zero Dialyzer errors in both.
The diagnostic fleet passed the return move in 190.25s and reproduced the same
execution-gate refusal on its stopped-guest cleanup. The new revision's full
relocation check is queued behind that still-live run. No native recovery success
is claimed for the new acquisition behavior yet.

### Integration with origin e0486c7

The conflict-free merge efcdde9 retains independent backup snapshot expectations
in transfer capacity/GUID policy checks and required transfer-service evaluation.
ADR-0074 is now the lifecycle decision, preserving upstream ADR-0070 backups and
ADR-0071 required transfer. Incoming backup exclusion must remain in every native
transfer proof. The backup coordinator already has a durable typed state machine;
its native snapshot journal requires a local Ash graph and audit integration.
A shared 64-event recurring outbox would violate the backup independence rationale
in ADR-0070. Use per-run producers and terminal local audit history with bounded
90-day expiry instead; do not expire active journals or operational evidence.
This integration is pending implementation and native verification, not an
implemented-architecture claim. ADR-0070's earlier no-Ash-runtime assumption must
be reconciled with ADR-0074 while retaining its independent coordinator rationale.

### Backup snapshot graph and independent audit implementation

Native backup create/cleanup now publish through `Lilly.Lifecycle.BackupSnapshot`.
The graph forbids ready/cleaned shortcuts and terminal resurrection. A new run
first proves native snapshot absence, then atomically archives the exact cleaned
producer envelope through the pool-lock owner and syncs its directory. The next
run receives a new producer identity. Delayed acknowledgments bind the old identity
and cannot edit the new current journal; duplicate delivery remains idempotent.
Per-run archives keep offline backups independent of control-plane availability.

The outbox recognizes current and strictly named archived backup journals under
the existing pool lock. Events bind host/placement, never a made-up control workflow
for the host-local run ID. Nonces and native GUIDs stay out of audit events. Local
preparation inspects at most sixteen old archive candidates for ninety-day expiry;
only matching valid cleaned producers may be removed, with directory sync. Corrupt
or active metadata is retained. Directory enumeration remains proportional to
history, and corrupt early candidates can require operator repair before all old
history is reclaimed. Expired archives are not exported even before reclamation.
No native claim, tombstone or VM data is an expiry target.

ADR-0070's original no-Ash-runtime assumption is reconciled with ADR-0074 without
changing its independent Python coordinator or native ownership rationale. The
CLI starts Ash dependencies only. Unit/reference-model tests cover eighty pending
events across twenty offline runs, archive crash gaps, delayed acknowledgment,
active/corrupt retention, bounded expiry and illegal state histories. Protocol and
Marshall tests cover the closed resource and placement-bound ingestion. Native
backup tests now assert phase/audit agreement and per-run identity alongside the
unchanged real snapshot, flush, process-survival and restored-data checks. Final
gates and native acceptance of this implementation remain pending.

## Final acceptance (2026-09-19, merged tree 388f69b)

All application gates passed on the merged tree: protocol (138 cases, 53
properties), Lilly (351 cases, 42 properties), Marshall (707+ cases, 65
properties), Porsche, `python-static` (ruff 0.16.3 and ty), the structural
logging catalogs for every application, and `elixir scripts/check_adrs.exs`
with 72 decisions. Dialyzer reported zero errors in every consumer with
forced rechecks.

Native acceptance passed on the same revision, serially, with real nested-KVM
ZFS:

- `overalls-zfs-guest` passed in 1367 s: real guest sync, sparse retained
  storage, backup phase/audit agreement, per-run producer identity,
  interrupted-process cleanup authority and restored-data checks.
- `overalls-zfs-lifecycle` passed in 470 s: sparse provision, unknown-content
  and mount-alias destruction refusals, crash-after-real-mutation recovery,
  resize growth without reinitialization and retired-cleanup guardrails.
- `overalls-zfs-transfer` passed in 237 s: pre-copy and stopped adoption,
  incremental recovery between snapshot removals, Inception two-drive
  adoption with the corrected incomplete-set refusal, idempotent
  re-adoption, `Disk.prepare` reuse and fenced cleanup.
- `overalls-relocation-fleet` passed in 3584 s with zero failed subtests:
  running and stopped moves, return moves, baseline-write verification,
  pre-handoff and post-stop cancellation with verified source restoration,
  logical Delete reclaim, dual endpoint daemon-restart recovery, readiness
  failure retry, stopped-copy fallback under source pressure, destination
  ENOSPC resumption and interrupted native transfer resumption. The
  stopped-source cleanup stage that blocked the original implementation
  completes under the fixed `lilly-host-lock` contention classification and
  bounded acquisition.

The bounded lock-acquisition fix (86d803a), the corrected Inception
incomplete-set fixture, and catalogued lifecycle diagnostics are natively
verified. Remaining gaps: production deployment and production data changes
stay outside this implementation task, and the ADR-0074 index entry remains
`partial` until operator deployment evidence exists.
