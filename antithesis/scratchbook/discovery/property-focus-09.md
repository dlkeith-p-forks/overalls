---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "09 — Idempotency and Replay"
status: complete
---

# Property discovery focus 09: Idempotency and replay

Read the fresh [SUT analysis](../sut-analysis.md), [assertion scan](../existing-assertions.md), source contracts and ADR chains. All planned SDK assertions are **missing**. The six candidates concern different replay lifetimes: permanent VM admission identity, bounded terminal opening, one CLI invocation, one guest boot, retained Enrico attempts and one terminal stream channel. They are hypotheses to test, not confirmed defects or passing execution. This research-only documentation changes no architecture, HLDD behavior or accepted contract.

### marshall-admission-key-survives-archive — Permanent admission identity

| | |
|---|---|
| **Type** | Safety |
| **Property** | One owner/key always refers to its original VM ID across lost replies and archival; changed shape refuses without allocation. |
| **Invariant** | `Always` **"Marshall replayed admission key never allocates a second VM"** against independent request ledger and PostgreSQL history. |
| **Antithesis Angle** | Drop first reply, race cross-node retries, then physically delete/archive and replay again. |
| **Why It Matters** | Duplicate VMs under one request can consume capacity or bypass intended lifecycle history. [Evidence](property-candidates-09/marshall-admission-key-survives-archive.md); P0, high confidence. |

**Open Questions:** Which HTTP/SSH wrapper preserves caller key? Which TCG/native deletion path reaches archival with physical cleanup?

### terminal-create-reply-loss-one-pty — One terminal creation

| | |
|---|---|
| **Type** | Safety |
| **Property** | One create request ID binds at most one guest PTY, registry Session and opened receipt despite duplicate or lost replies. |
| **Invariant** | `Always` **"Terminal create replay retains one guest PTY and one opened receipt"** with guest effect witness and consistent DB snapshot. |
| **Antithesis Angle** | Cut after guest PTY birth but before Marshall receipt, duplicate request and race cancellation. |
| **Why It Matters** | Duplicate PTYs can consume guest resources and create ambiguous authority. [Evidence](property-candidates-09/terminal-create-reply-loss-one-pty.md); P0, high confidence. |

**Open Questions:** How can the guest count past PTY births? Does TCG composition use real terminal host stream end to end?

### porsche-wait-never-resubmits-mutation — Poll without second mutation

| | |
|---|---|
| **Type** | Safety and conditional progress |
| **Property** | A Porsche CLI invocation submits one mutation and waits through read-only, receipt-correlated polls; eligible transient polling can still reach a matching terminal receipt. |
| **Invariant** | `Always` **"Porsche wait submits one mutation and only polls its receipt"** on ingress command history; conditional `Sometimes(matching_terminal_receipt_seen)` has its own message and finite tail precondition. |
| **Antithesis Angle** | Lose admission/poll replies, inject transient errors and mismatched receipt IDs. |
| **Why It Matters** | Automatic resubmission could repeat physical effects; premature failure hides a still-running command. [Evidence](property-candidates-09/porsche-wait-never-resubmits-mutation.md); P0, high confidence. |

**Open Questions:** Which ingress counter records safe command metadata? Can the physical operation finish inside controlled hosted timeout?

### guest-workspace-source-replay-once — One source per boot

| | |
|---|---|
| **Type** | Safety |
| **Property** | A boot-bound source delivery persists before acceptance; identical redelivery preserves it, while changed or stale-boot delivery cannot replace it. |
| **Invariant** | `Always` **"Guest workspace source replay preserves one boot-bound source"** against guest file/checkout and independent Git fixture effect history. |
| **Antithesis Angle** | Lose accepted reply and cut before/after source publication, checkout rename and done marker. |
| **Why It Matters** | Replay could clone a second repository or replace the source after a guest begins work. [Evidence](property-candidates-09/guest-workspace-source-replay-once.md); P0, high confidence. |

**Open Questions:** How can clone effects be counted without exposing source? Does Lilly integrated retry resend the exact source reference?

### enrico-attempt-replay-bounded-receipts — Finite local deduplication

| | |
|---|---|
| **Type** | Safety |
| **Property** | Replaying an active or retained completed Enrico attempt starts no second Git fetch; local deduplication ends on eviction/restart. |
| **Invariant** | `Always` **"Enrico retained attempt replay starts no second fetch"** while within receipt retention, using external Git fixture fetch count. |
| **Antithesis Angle** | Duplicate same attempt amid status loss, generation races and 1024-receipt eviction. |
| **Why It Matters** | Duplicate fetches waste quota and obscure which attempt Marshall can safely settle. [Evidence](property-candidates-09/enrico-attempt-replay-bounded-receipts.md); P1, high confidence. |

**Open Questions:** How can a real-effect fixture reach 1025 completions cheaply? Which Marshall status is authoritative after local receipt loss?

### terminal-input-frame-replay-once — Ordered channel input

| | |
|---|---|
| **Type** | Safety and conditional progress |
| **Property** | Repeating one input sequence on the same authorized terminal channel cannot write bytes twice to the guest; gaps fence the channel. |
| **Invariant** | `Always` **"Terminal replayed input sequence reaches guest once"** against guest-recorded token count/order; conditional `Sometimes(guest_recorded_two_contiguous_tokens_in_order)` tests useful progress. |
| **Antithesis Angle** | Suppress input ACK, duplicate a frame, then send contiguous/gapped frames under the same channel. |
| **Why It Matters** | Duplicate terminal input can execute a command twice. [Evidence](property-candidates-09/terminal-input-frame-replay-once.md); P0, medium-high confidence. |

**Open Questions:** Which transport seam can replay an authenticated frame on the same channel? Which guest program can witness tokens with low perturbation?

## Breadth and limits

This pass inspected Marshall admission/history, terminal creation/reconciliation and stream sequence handling, packaged Porsche Runner, Lilly stream/channel, Lyra workspace receiver, Enrico Manager/Marshall Worker, plus the Ziggy provider/accounting paths and Restic/Brady retention semantics. Ziggy inference recovery, Lilly outcome ACK, backup manifest closure and Brady complete cache publication are already separately evidenced in focuses 01/03; repeating their invariants here would add no independent oracle. Backup `Journal.create` assigns a new run ID after a terminal run and `Runtime.recover` cleans interrupted work before new capture; retries are new backup points rather than replay of one capture. Brady is disposable, so a miss after restart is not failed idempotency. Enrico receipts are capped at 1024 and end on restart; permanent identity belongs to Marshall. Hosted service checks do not establish guest effects; TCG guest witnesses and native Firecracker/ZFS evidence remain separate. No aggregate suite exit substitutes for any candidate oracle.
