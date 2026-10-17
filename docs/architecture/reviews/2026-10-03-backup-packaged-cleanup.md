# Packaged backup cleanup recovery

## Scope and architecture

Baseline `05ff3afb05e9ecb097104f5beafd4392583c0cd7`. ADR-0070 remains accepted
and implemented with its existing acceptance limits. This fixture adds evidence
for existing recovery semantics; production code, configuration defaults,
protocols and authority are unchanged. It runs the actual source-built backup
module on mirrored native ZFS with no repository credentials or remote services.

## Property and contracts

`packaged_cleanup` covers three fixed plus six generated histories through the
installed `kittens-backup-cleanup.service` and `kittens-backup cleanup` CLI.
The menu is preparing/capturing/cleaning, service/operator, and one/two/three
refusals and replays. There is no configured capacity threshold in this path.
Shared lock contention preserves exact journal/status/intent bytes and native
snapshot identity. A foreign local nonce leaves exact intent and snapshot GUID
intact, the interrupted run in cleaning without cleanup confirmation, visible
cleanup_pending=1 and failure=cleanup. Restoring the exact local nonce permits
native cleanup, confirms absence and closes the same run as failed/interrupted.
Terminal replay preserves the exact run journal, last_success_at and seeded
status metadata. Seeded manifest_id retention is not manifest publication.
An independent native sentinel snapshot retains its GUID and immutable contents.

Root, Nix, test and backup contracts and actual runtime/journal/HostCapture
branches were reviewed. Fresh read-only review found an incorrect success-field
oracle, corrected to production last_success_at, and no remaining source blockers.

## Execution

Pinned Python 3.13 backup-types passed Ruff format/lint and ty, exit 0 in
12 seconds; final archive `1791016678011-3551929-0.jsonl`. Existing state/workflow/status
tests also execute. The first native execution failed in fixture reset-failed
for a successful unloaded oneshot; aborted examples retained extra intents and
caused a secondary pending-count failure. Reset now runs only after service failure.
Failed archive `1791016472333-3414628-0.jsonl` is retained separately. No production
defect is inferred. The corrected packaged cleanup native check passed in 138 seconds, exit 0;
archive `1791016699709-3567345-0.jsonl`. The property subtest took 36.14 seconds
and VM script 55.12 seconds. The successful Hypothesis command runs three fixed
and six generated histories. Composed driver static checks passed. Fresh independent archive review confirmed terminal exit 0 and the exact subtest
and script timings. Contract structural checks passed (117 CONTRACTS, 2335 native
notes, 190 parsed and 2495 maintained source files). Evaluated Nix handbook gate
passed in 36 seconds, exit 0, archive `1791017116282-3630515-0.jsonl`.
ADR structure and generated options/coverage/views checks passed.

## Remaining gaps

Publishing-phase interruption, capture/upload/retention pipeline composition,
concurrent mutation during cleanup, mounted namespace recovery, physical power
loss, hosted faults and historical authority reactivation remain separate.
No production enablement or historical execution authority is established.
