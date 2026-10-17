# Clone competing activation histories

## Scope and architecture impact

Test and evidence maintenance under ADR-0055 and ADR-0037. Queue admission,
host-locked capacity allocation, cleanup authority and generation fencing are
unchanged. Clone slots require source restoration and complete cleanup;
relocation stream slots instead require both endpoint revocation receipts and
may release while disk cleanup or source restoration remains pending.

The existing published-clone property moved from `cloning_test.exs` to
`clone_restoration_history_test.exs` and retains duplicate authenticated
receipts, source restart failure/retry, destination-first settlement and newer
source intent. Every draw owns a fresh SQL sandbox checkout; checkin always
rolls back that draw. Actual coordinator refusal can return normally and record
its failed request without an enclosing test transaction swallowing the refusal.

## Added property scope

A second independent, stopped VM has settled operations on the occupied host.
Its clone submission accepts a queued identity without allocating a VM,
placement, reservation, address, operation or transfer slot. One, two or four
activation attempts refuse with `source_unavailable`; complete sorted resource
inventories remain unchanged. Explicit retries preserve queued request and
destination identity and allocate nothing.

After original restoration, both endpoint revocations, pruning and destination
settlement, refreshed ordinary reports permit the competitor to activate.
Duplicate terminal advances preserve the original exact first-release timestamps
and the competitor's full allocation inventory. A newer-intent branch retains
the original slots and does not overwrite newer power intent. Its synthetic
injection takes host then VM locks inside a short transaction.

The fixture uses a coherent 32 GiB physical report and enrolled logical budget
so four eventual disks and temporary headroom fit independently of occupancy.
Six resource inventories include complete records, not just counts or IDs.

## Validation

The reviewed combined focused suite passed 14 checks (two properties and twelve
tests), seed `364992`, in 24.9 seconds. Log:
`/tmp/overalls-clone-competitor-reviewed-focused.log`.

Earlier extension attempts failed: the initial fixture returned
`insufficient_capacity`, with its exact failing phase not retained; the revised
attempt returned `source_unavailable` from the enclosing draw transaction.
Logs: `/tmp/overalls-clone-competitor-focused.log` and
`/tmp/overalls-clone-competitor-focused-revised.log`. Moving to per-draw checkout
fixed isolation. Fresh contract review then found the newer-intent injection's
missing transaction; the final focused result includes its repair and immediate
post-retry inventory checks. Pre-integration full Marshall precommit passed: 1,413 checks (214 properties
and 1,199 tests), two exclusions, seed `392701`, in 1,236.8 seconds. Forced
Dialyzer passed in 36.93 seconds with zero errors, skips or unnecessary skips.
Log: `/tmp/overalls-clone-competitor-full-gates.log`. This captures the tested
4994a933 base plus this batch.

Integrated Marshall precommit passed after rebasing as `e2a7dfaa` on upstream
`f4e7e878`, including workflow SLO source `6a0b3c32`: 1,417 checks (216 properties,
1,201 tests), two exclusions, seed `505231`, in 1,006.0 seconds. Forced Dialyzer
passed in 43.99 seconds with zero errors, skips or unnecessary skips; the complete
command exited 0. Log: `/tmp/overalls-namespace-clone-integrated-full-gates.log`.
The subsequently added competing relocation and workflow backlog extensions were
not in this test collection and require their separate checks.

## Remaining gaps

These are real Ash/PostgreSQL actions in a rollback sandbox with synthetic
physical outcomes. Independent processes, native source restoration, uncertain
transport, hosted faults, competing relocation admission and distinct endpoint
placement remain separate scopes. Passing local tests does not establish physical
stream cessation or production availability.
