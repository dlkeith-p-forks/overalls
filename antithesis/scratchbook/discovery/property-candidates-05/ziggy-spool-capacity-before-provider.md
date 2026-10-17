---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# ziggy-spool-capacity-before-provider

**Claim, priority, confidence.** P0 safety, high confidence in intended semantics. When the durable completion-slot maximum is full or unavailable, a new inference request must refuse before any upstream provider or agent effect; existing admitted effects retain room to publish a terminal receipt. Proposed unique assertion: Always("ziggy provider effects require a previously durable bounded spool slot", provider_effect_ids subset_of durable_admitted_ids && admitted_slot_count <= configured_max). Reachable("ziggy full spool refuses new provider work and retains admitted receipts") is a valid saturation branch goal. Both are missing per ../../existing-assertions.md.

**Source and history.** ziggy/lib/ziggy/config.ex:49 validates max_requests in 1..100000. Spool.init at ziggy/lib/ziggy/spool.ex:44-77 opens and recovers the journal; Spool.handle_call admission at :87-126 checks failed state, duplicate ID and map_size against maximum before persist; completion at :131-145 replaces the reserved slot; acknowledgment at :174-200 deletes only a completed counted receipt. The contract at :87-93 requires fsync of metadata and directory before effect. Ziggy.Application.children at ziggy/lib/ziggy/application.ex:18-51 separately caps task and lease supervisors at 2048 and configures 8 x 256 Finch connections. Ziggy.Reporter.report at ziggy/lib/ziggy/reporter.ex:33-80 takes 128 completed entries per pass. The local reporter history review docs/architecture/reviews/2026-10-03-ziggy-reporter-histories.md says one persistent conflict does not prove fairness when the first 128 are all conflicts; do not assert all receipts necessarily drain under permanent conflict.

**Workload and oracle.** Use real Ziggy HTTP and agent entry points, real spool files, a local provider fixture that records accepted requests, and real Marshall accounting. Hold completions unacknowledged by losing Control responses, fill N slots, then submit N+1 distinct valid requests while one provider is slow and while Ziggy restarts. Correlate provider fixture effect IDs with independently reread on-disk admission IDs and completion receipts. Verify no upstream accept for refused IDs, no evicted admitted receipt, and a completed ACK frees exactly one slot. A timeout is an uncertain effect until fixture and spool are reconciled. Never count a task exit or HTTP status alone as effect proof.

**Limit menu.** max_requests 1, 2, 127, 128, 129, 2048 and a value above 2048 to distinguish durable slots from task/lease ceilings; exact N/N+1 admission and one-free-slot recovery. Check config validation for 0 and 100001 outside the runtime property.

**SUT guidance and limits.** Instrument after durable slot fsync, on spool_full refusal and at provider fixture accept; use accepted-id/replay markers. A host file fault that produces uncertain persistence must fence admission rather than be treated as free capacity. Hosted real services suffice with durable volumes; provider fixture is an effect witness, not an external provider guarantee. Open questions: Which HTTP and agent routes share a single spool under the selected configuration? Can hosted filesystem faults expose directory-sync uncertainty beyond process restart?

**Architecture/HLDD impact.** No source or handbook change; ADR-0100/0132 remain claims to test.
