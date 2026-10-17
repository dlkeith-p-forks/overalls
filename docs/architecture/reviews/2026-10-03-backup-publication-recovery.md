# Interrupted publishing recovery

## Scope and architecture

Baseline `7dcc00ffc2ca9be48050f51c46ef7ff1533ab72e`. This verification extension
preserves ADR-0070 and its rationale. Production behavior, authority, configuration
and protocols do not change. The installed cleanup unit/operator reads a publishing
journal built through production Journal transitions with cleanup already confirmed.
Component and manifest references are synthetic: no upload or repository publication
is established by these histories.

## Property and review

`publication_recovery` adds three fixed plus six generated histories. The menu
covers recorded/unrecorded manifest reference, service/operator, zero/one/three
components and one/two/three replays. Zero components tests recovery of a valid
journal, not completeness of an actual captured backup. No configured capacity
threshold controls this branch. The lock-contention prefix preserves exact persisted
journal/status bytes. Recovery closes the same run as failed/interrupted, retaining
component references, recorded manifest reference, hostname, nonempty revision and
start timestamp without advancing last_success_at. Terminal replay leaves the exact
journal intact; an independent native snapshot retains its GUID and contents.

Reviewed root/Nix/test/backup contracts, Runner.recover, Journal validators and
transitions, service and operator paths. Fresh review found no functional blocker;
revision preservation was strengthened and field comparisons made explicit.
The property tests persisted publishing boundaries through real packaged processes;
it does not kill the capture producer at a physical upload boundary.

## Execution

The initial combined native check passed in 175 seconds, exit 0; archive
`1791017434971-3741154-0.jsonl`. The final fixture strengthens revision and immediate
status checks. Final pinned Python 3.13 format/lint/ty passed in 15 seconds, exit 0; archive
`1791017627025-3859254-0.jsonl`. The final combined packaged cleanup and publishing
check passed in 155 seconds, exit 0; archive `1791017642705-3868573-0.jsonl`.
The combined property subtest took 63.88 seconds and VM script 85.39 seconds.
Each property has three fixed plus six generated histories; individual history
prints are hidden by the driver. Fresh review independently confirmed terminal
archive success and found no source blockers. All-file pinned static gates and
contract structural checks passed (117 CONTRACTS, 2335 native notes, 190 parsed,
2495 maintained files); semantic source review remains separate. Evaluated Nix
handbook gate passed in 32 seconds, exit 0; archive `1791017857624-4017922-0.jsonl`.
ADR and generated coverage/options/views checks passed. Earlier packaged
cleanup evidence retains its separate nine-history/138-second scope.

## Remaining gaps

Actual upload/manifest durability under producer death, complete capture/upload/
retention composition, concurrent cleanup mutation, mounted namespace recovery,
physical power loss, hosted faults and historical authority reactivation remain.
