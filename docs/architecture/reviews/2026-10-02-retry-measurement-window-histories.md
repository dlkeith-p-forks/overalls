# Retry measurement window histories

## Scope and architecture impact

Baseline `7e38d7838d1ed86ce1c8eb81e9f39293432fdc33`. This verification change
preserves ADR-0037 relocation authority and ADR-0133 measurement-only accounting.
No domain, protocol, persistence or execution contract changes. Measurement
expiry cannot release capacity, cancel a workflow or replay physical work.

## Actual-action fixture and independent oracle

[Retry property](../../../marshall/test/marshall/compute/retry_measurement_window_history_test.exs)
drives actual public provision and precopy relocation, authenticated stream and
physical receipts, destination activation, expired original readiness, public
retry, accepted measured SSH receipt, retry stop and fresh-report reactivation.
Early readiness is refused before the retry running proof; exact complete
allocation and readiness-request inventory remains unchanged by that refusal.
Physical running permits an offered readiness request; its receipt uses the
canonical protocol encoder and decoder. The first run exposed a fixture encoder
error: plain JSON conversion omitted the descriptor version. Canonical source,
receive/import and readiness result encoding repaired the fixture.

Each history owns a fresh SQL sandbox. Only after real authenticated receipt
acceptance do isolated SQL controls place received times at admission minus one
second, admission, deadline minus one second, exact deadline or deadline plus
one second. Before/after-deadline phases and missing both/physical-only/both
proofs include fixed future, missing and inclusive-boundary witnesses on every
one of four generated draws. One/two/four scans must preserve terminal state.
This is defensive consumer verification; timestamps do not establish reachable
receipt order, elapsed time, native boot or transport timing.

The independent oracle requires both proofs within the inclusive window and
not in the future. Completion is the later proof time; missing/invalid evidence
fails once at the deadline or remains pending before it. Exact duration,
requests/successes/failures, complete eight-bucket vector and source lifetime
are checked. Repeated terminal scans compare the complete measurement and total.
Complete VM, placement, reservation, address, operation, stream-slot, relocation,
retry, readiness-request, SSH, physical-proof and lifecycle-event inventories
remain unchanged during reconciliation.

## Verification

The focused run passed one property, seed `405587`, in 38.6 seconds,
with warnings-as-errors and terminal exit0. Log:
`/tmp/kittens-retry-window-history-focused.log`.
An extension fills missing proofs through authenticated actions after terminal
failure, then preserves the complete original terminal measurement/total. Fresh
review required actual ready-state and matching success-audit assertions so an
acknowledgement alone cannot count as accepted boot evidence. The strengthened
extension passed one property, seed `768114`, in 44.3 seconds,
with warnings-as-errors and terminal exit0. Log:
`/tmp/kittens-retry-window-history-reviewed-focused.log`.
Full Marshall precommit passed 1,419 checks (218 properties, 1,201 tests), two exclusions, seed404257,1135.7seconds; forced Dialyzer42.61seconds with zero errors, skips or unnecessary skips; terminal exit0.
Log: `/tmp/kittens-retry-window-history-full-gates.log`.
All-file hooks and evaluated HLDD passed before the full suite, capture
`1790982781705-3654295-0.jsonl` (9seconds). Final evidence-only all-file, ADR, handbook/reference/view checks and evaluated
HLDD passed, capture `1790984109001-205889-0.jsonl` (9seconds), log
`/tmp/kittens-retry-window-history-final-doc-gates.log`.

## Remaining gaps

The existing fixed retry history checks old and wrong-generation readiness.
This new property composes proof windows; it does not generate independently
mutated operation/relocation/placement/epoch/host bindings, or elapsed pending-to-
deadline transitions while retaining the original window. Independent committed
publishers, native retry/cancellation, lost delivery, process restart and hosted
faults remain open. Early readiness is a refusal witness because ordinary
readiness requests are created only after exact physical activation.
