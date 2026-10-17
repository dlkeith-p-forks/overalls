# Transient pool contention and capacity freshness

## Scope

ADR-0031 capacity reports, ADR-0140 liveness. Two native scenarios refused
admissions with `insufficient_capacity` that was not real exhaustion: the fleet
"generated races re-spend confirmed releases exactly once" round (host pool
`reported_at` was NULL at race time, `pool_age: None`) and clone-cancellation's
post-cancel restart. Neither emitted any diagnostic.

## Evidence

A transition-only diagnostic (`pool.snapshot_withheld` with the withholding
stage, `pool.snapshot_recovered`; Lilly `b8224ac6`) on the native fleet showed
both pools withheld for 1-5 s many times a minute during ordinary VM activity,
almost always at stage `storage_busy` (the zero-wait `Pool.snapshot` lock held
by another storage operation) or `observe` (usage counters moving between the
two exact reads, `storage_busy` from the bounded resampler). Each such report
was `unavailable`, which by contract cleared the pool's freshness, credit and
observation in Marshall; admission in that window saw unknown capacity.

## Finding and decision

The `unavailable` entry conflated "this pool's observation is invalid" with "a
coherent observation was not available this instant". The latter is slowness,
not evidence of lost capacity (ADR-0140). Reports gain an identity-only `busy`
entry for exactly the two transient causes; Marshall leaves the pool row
unchanged, so the last honest observation keeps its original sample time and
credit and ages out of the five-second capacity window as if late. Invalid
identity, ownership, binding or other observation failures stay `unavailable`.
Exposure while busy equals a report delayed by up to the capacity window, which
admission already tolerates; credit is never invented or refreshed.

## Rollout

Protocol decode and Marshall acceptance ship first; Lilly sends `busy` only in a
later push, after the Marshall host reports healthy, because an unknown entry
rejects the whole report.

## Verification

Protocol round-trip/rejection test, Marshall ingest test (busy preserves the row,
wrong identity rejects the report), Lilly report and transition tests. Native
fleet and clone-cancellation runs are recorded in the ADR-0031 evidence when
complete.
