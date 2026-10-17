---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "03 — Failure Recovery"
status: complete-source-discovery
---

# Failure recovery property discovery

Sixteen candidates follow the research skill's catalog format. The fresh
[assertion scan](../existing-assertions.md) reports no current Antithesis SDK
callsites: **all proposed instrumentation is missing**. Evidence files supply
literal unique messages, exact functions/lines, independent oracles, failure
histories, value menus, branch/replay anchors and scope limits. No hosted baseline,
native run, new mutant or current correctness claim is established here.

Scope inspected: Lilly Runtime/Store/Actor/Journal/Executor/Driver/private files
and native lock owner; Marshall retained intent, outcomes/crash budget and
inference accounting; Ziggy HTTP/agent admission/spool/reporter; independent
request recorder/checkpoint and trace SQLite archive/exporter; Enrico manager,
atomic fetch and retained Git heads; backup host cleanup/manifest/retention;
Lyra guest source/checkouts; Nix updater activation/restoration/cleanup. The whole
SUT synthesis supplied the remaining app/browser/cache/transfer context. This
focus did not perform an exhaustive transfer/clone/Brady/browser audit; those
require the other focuses' properties and must not inherit these proofs.

Architecture/HLDD impact before and after: no design, source contract, behavior,
configuration or verification status changed. These are proposed research
assertions, not newly passing evidence or implementation. ADR-0017, 0016, 0013,
0070, 0128, 0136, 0149 and 0152 remain claims/constraints to test; no ADR status,
handbook chapter, scenario ledger or governance receipt was refreshed. No
production files or other agents' artifacts changed. No children spawned.

### lilly-interrupted-launch-at-most-once — Interrupted launch authority

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Recovery never physically resubmits the same placement/epoch/generation launch authority. |
| **Invariant** | `Always(actual submissions <= 1)`; conservative consumed-but-unsubmitted refusal is permitted. |
| **Antithesis Angle** | Actor/release/helper loss before and after separate actor and physical launch marker commits, systemd acceptance and outcome recording. |
| **Why It Matters** | Prevents duplicate physical execution and crash-budget bypass. [Evidence](property-candidates-03/lilly-interrupted-launch-at-most-once.md) |

**Open Questions:** Can the hosted adapter retain independently durable submission witnesses with production marker semantics?

### lilly-receipt-survives-control-loss — Durable delivery acknowledgment

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Acknowledged command remains backed by matching or newer host-bound durable intent after restart. |
| **Invariant** | `Always(ACK implies valid durable reread after reopen)`; receipt is not physical completion. |
| **Antithesis Angle** | Control loss, release death and write/rename/directory sync uncertainty around ACK. |
| **Why It Matters** | Keeps accepted work available without fabricating rollback on unproven writes. [Evidence](property-candidates-03/lilly-receipt-survives-control-loss.md) |

**Open Questions:** Which hosted filesystem faults exercise directory fsync uncertainty?

### lilly-outcome-replay-exact-ack — Physical outcome custody

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Identical physical facts retain outcome identity and only exact current ACK can clear pending custody. |
| **Invariant** | `Always(stable identical-fact ID/sequence && old ACK cannot clear newer pending outcome)`. |
| **Antithesis Angle** | DB commit/reply loss, reconnect, newer generation and delayed ACK/old task completion. |
| **Why It Matters** | Prevents loss of pending evidence and release of newer authority from stale facts. [Evidence](property-candidates-03/lilly-outcome-replay-exact-ack.md) |

**Open Questions:** Can the observer take lock-respecting snapshots without masking the crash window?

### transient-observation-is-not-absence — Unavailable physical evidence

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Retryable observation/ownership failure cannot fabricate absent physical state or release allocation. |
| **Invariant** | `Always(retry leaves durable physical outcome and held allocation intact)`. |
| **Antithesis Angle** | Running adoption under pool/VM/network contention, transitional systemd status and unavailable probes. |
| **Why It Matters** | Preserves surviving guests and custody during control or sampling outage. [Evidence](property-candidates-03/transient-observation-is-not-absence.md) |

**Open Questions:** Which hosted probe faults preserve real production observation?

### native-owner-recovery-keeps-descendant-custody — Native ownership retirement

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Successor mutation/release acknowledgment waits for retirement of all prior utility descendants. |
| **Invariant** | `Always(no successor mutation while any prior owned descendant can mutate)` on original lock inode. |
| **Antithesis Angle** | Caller/helper death, EOF/timeout/overflow and descendants escaping process groups/sessions. |
| **Why It Matters** | BEAM death or direct-child exit cannot create competing physical custody. [Evidence](property-candidates-03/native-owner-recovery-keeps-descendant-custody.md) |

**Open Questions:** Does the hosted kernel support helper subreaping and descriptor inheritance, with observer pidfds for independent descendant identity?

### lilly-finite-obstruction-recovery-progress — Eligible retained intent progress

| | |
|---|---|
| **Type** | Liveness; P1; high confidence in conditional target |
| **Property** | A designated still-eligible retained operation and its neighbor progress after restart and finite obstruction removal. |
| **Invariant** | `Sometimes(probe physically completed and committed && neighbor completed)` under valid authority/capacity and quiet interval. |
| **Antithesis Angle** | Lost dispatch hint, supervisor restart, sampling contention and journal/pool lock release. |
| **Why It Matters** | Detects starvation that pure safety checks tolerate; consumed-before-submission generations are excluded. [Evidence](property-candidates-03/lilly-finite-obstruction-recovery-progress.md) |

**Open Questions:** What measured baseline interval supplies the workload budget? `(partial: cadence/retries found, no universal SLA)`

### marshall-crash-recovery-budget-and-stale-capacity — Bounded recovery decision

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Crash recovery charges durable budget once and keeps stale-capacity work held until a fresh decision. |
| **Invariant** | `Always(no unauthorized/exhausted restart && stale capacity retains hold)`; future timestamps remain charged. |
| **Antithesis Angle** | Crash/report/ACK replay, concurrent coordinators, DB restart/time reversal and fresh capacity arrival. |
| **Why It Matters** | Avoids retry storms, oversubscription and permanent refusal caused solely by stale telemetry. [Evidence](property-candidates-03/marshall-crash-recovery-budget-and-stale-capacity.md) |

**Open Questions:** Can supported hosted DB-time faults reach backward time with real Ledger.now?

### ziggy-interrupted-inference-never-reexecutes — External effect recovery

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Restart/reporter replay never repeats an original inference effect and unfinished work remains interrupted/unknown. |
| **Invariant** | `Always(zero additional recovery-originated provider effects && unproven usage unknown)`. |
| **Antithesis Angle** | Kill around durable admission, upstream acceptance/streaming/completion and spool publication uncertainty. |
| **Why It Matters** | Prevents duplicated provider cost or fabricated known usage from uncertain execution. [Evidence](property-candidates-03/ziggy-interrupted-inference-never-reexecutes.md) |

**Open Questions:** Which safe HTTP/agent fixture correlation observes effects without changing production payload semantics?

### inference-accounting-ack-loss-counted-once — Immutable completion replay

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Immutable admitted inference completion contributes once despite lost ACK and repeated reporting. |
| **Invariant** | `Always(totals equal unique accepted projections; conflicting/foreign replay adds zero)`. |
| **Antithesis Angle** | Receipt/totals transaction commit then response loss, Ziggy restart/removal uncertainty and VM relocation/stop. |
| **Why It Matters** | Preserves durable accounting without granting new execution authority. [Evidence](property-candidates-03/inference-accounting-ack-loss-counted-once.md) |

**Open Questions:** None for semantics; execution/instrumentation remains missing.

### request-recorder-restart-conserves-custody — Independent recorder recovery

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Recorder restart preserves lifetime and settles admitted work once only after valid finish, proven producer death or expiry. |
| **Invariant** | `Always(no fabricated death, duration or duplicate settlement; monotonic identity/counters)`. |
| **Antithesis Angle** | Admit/Finish reply loss, recorder death with producer alive, proc/pidfd uncertainty and checkpoint poison. |
| **Why It Matters** | Separates measurement outage from producer death and conserves durable numeric custody. [Evidence](property-candidates-03/request-recorder-restart-conserves-custody.md) |

**Open Questions:** Which hosted deployment preserves exact systemd producer authentication while faulting parties independently?

### trace-archive-ack-loss-preserves-replay — SQLite observation archive

| | |
|---|---|
| **Type** | Safety; P1; high confidence |
| **Property** | Accepted trace bytes/digest/original expiry survive intake/export ACK loss and archive replay until original expiry. |
| **Invariant** | `Always(unexpired accepted custody remains immutable)`; duplicate export is permitted. |
| **Antithesis Angle** | FULL WAL commit/reply windows, Collector response loss, quota poison and interrupted 128-row replay chunks. |
| **Why It Matters** | Retains independent observability without making diagnostic delivery business authority. [Evidence](property-candidates-03/trace-archive-ack-loss-preserves-replay.md) |

**Open Questions:** Which hosted fault reaches actual SQLite commit uncertainty beyond process restart?

### enrico-interruption-preserves-published-head — Published Git custody

| | |
|---|---|
| **Type** | Safety; P1; medium-high confidence |
| **Property** | Last successfully Marshall-published immutable commit remains browsable after failed/interrupted refresh. |
| **Invariant** | `Always(published commit resolves and matches known tree/blob bytes)`; mutable refs may advance before final receipt. |
| **Antithesis Angle** | Force push/default branch change, atomic fetch/HEAD/retained-ref interruptions and native/release death. |
| **Why It Matters** | Keeps established source content usable; Manager receipt eviction/restart legitimately ends local replay retention. [Evidence](property-candidates-03/enrico-interruption-preserves-published-head.md) |

**Open Questions:** Which deterministic fixture arrangement preserves fixed production github.com origin policy?

### backup-interrupted-cleanup-owned-only — Physical cleanup authorization

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Backup recovery destroys only positively matched owned snapshots and retains uncertainty. |
| **Invariant** | `Always(destroy matches nonce/GUID/local marker; unavailable inspection preserves journal)`. |
| **Antithesis Angle** | Snapshot created before GUID receipt, uncertain destroy/unmount and same-name foreign dataset/snapshot. |
| **Why It Matters** | Prevents cleanup from deleting unrelated data or abandoning still-owned physical resources. [Evidence](property-candidates-03/backup-interrupted-cleanup-owned-only.md) |

**Open Questions:** Can hosted storage observation stay independent through pool inspection faults?

### backup-recovery-manifest-reference-closure — Retained recovery graph

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Retained completed recovery points preserve all successful component references through interrupted upload/retention. |
| **Invariant** | `Always(retained complete manifest has required successful restorable component closure)`; no global simultaneous snapshot claim. |
| **Antithesis Angle** | Component/manifest response loss, failed capture, shared references and interrupted forget batches. |
| **Why It Matters** | Preserves the last good recoverable data graph while new runs fail. [Evidence](property-candidates-03/backup-recovery-manifest-reference-closure.md) |

**Open Questions:** What policy governs later cross-component restore consistency/RPO? `(partial: closure/sequential capture found, no global snapshot/RPO guarantee)`

### guest-workspace-restart-publication-no-clobber — Guest checkout recovery

| | |
|---|---|
| **Type** | Safety with supplementary progress; P1; high confidence |
| **Property** | Recovery preserves accepted source and published developer checkout, including rename-before-done interruption. |
| **Invariant** | `Always(no source replacement/published checkout overwrite)`; supplementary `Sometimes(real accepted unpublished source completes)` under restored preconditions. |
| **Antithesis Angle** | Source accepted reply loss, partial clone death, rename/done/status gaps, branch movement and redelivery. |
| **Why It Matters** | Keeps user edits intact and distinguishes source receipt from actual checkout completion. [Evidence](property-candidates-03/guest-workspace-restart-publication-no-clobber.md) |

**Open Questions:** How does the TCG restart retain filesystem and independently witness publication durability?

### updater-failed-activation-recovers-live-roles — Interrupted activation handling

| | |
|---|---|
| **Type** | Safety with supplementary progress; P1; high confidence in conditional contract |
| **Property** | Caught incomplete activation attempts every prior live role independently and cannot advance unverified health. |
| **Invariant** | `Always(no skipped role after restoration failure && lastHealthy requires verification)`; supplementary `Sometimes(all prior roles restored)` after finite fault. |
| **Antithesis Angle** | Canceled systemd jobs, secret/switch/socket/role failure and surviving migration effects; whole-updater SIGKILL is separately scoped. |
| **Why It Matters** | Keeps one failed role from hiding neighbor restoration and avoids false healthy deployment receipts. [Evidence](property-candidates-03/updater-failed-activation-recovers-live-roles.md) |

**Open Questions:** Which source-built native fixture can independently observe updater/migrator death and all restoration effects?

## Portfolio boundaries and synthesis guidance

Main overlap groups: delivery/launch/outcome/native custody versus concurrency and
replay focuses; crash budget/capacity versus resource/lifecycle; accounting versus
integrity/replay; backup and updater versus lifecycle. Keep physical effect,
delivery receipt and accounting receipt separate when deduplicating. Progress
needs valid restored preconditions and measured budget. A permanent refusal,
unknown effect, ended volatile receipt namespace or insufficient native evidence
is not automatically a defect.

All candidates include source grounding but no new empirical guarantee. Most
hosted campaigns can use real services/DB/files/native helpers; TCG or native
storage/guest witnesses are necessary where the oracle depends on guest bytes,
ZFS lineage or real process custody. Pure task status/logs/aggregate suite exit
cannot replace these independent observations. Automatic fault enablement is
unconfirmed. Read-only source/file consistency checks are the validation for this
research artifact; production gates need not be rerun for unchanged code.
