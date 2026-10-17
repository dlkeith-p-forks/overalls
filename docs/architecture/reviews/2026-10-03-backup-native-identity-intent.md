# Native backup identity replacement and pre-GUID intent

## Architecture impact

Baseline `141508d02504dbee2c28209631c47e0994da3477`. This verifies existing
ADR-0070 native ownership and intent-before-effect requirements. Production
HostCapture, backup runtime, formats, credentials and deployment are unchanged.
Earlier thirteen ownership/inspection-outage and eight worker-death histories
retain their separately recorded native scopes and passing executions.

## Identity replacement property

Four fixed witnesses and four generated combinations vary dataset/snapshot
replacement, mounted/unmounted cleanup location and one/two/three refusal replays.
The fixture publishes the original descriptor, creates its real snapshot, then
renames the original native object aside and creates a different native object
at the recorded name with the same locally set nonce. The descriptor is never
rewritten to adopt that replacement. Both native GUIDs are inspected independently;
snapshot replacement changes only the snapshot GUID, while dataset replacement
also changes the dataset GUID.

Actual cleanup must retain exact descriptor bytes with zero unmount/destroy
attempts. Replacement GUIDs, mounted snapshot source and real snapshot contents
remain intact. An independent sentinel snapshot retains its GUID and immutable
contents. Fixture retirement of the introduced replacement verifies its observed
GUID before direct native removal; these fixture commands are deliberately outside
the production audit. Returning the original native object restores both original
GUIDs and original snapshot contents without descriptor changes. Actual cleanup
then destroys only that originally recorded snapshot once and replay is inert.

Replacement occurs between cleanup calls. This establishes native sequential
identity refusal; it does not prove fencing of a replacement during a cleanup call.
An alternate read-only snapshot view provides the content oracle when the cleanup
location is unmounted. The destructive-attempt audit prevents a mounted snapshot's
native busy refusal from concealing an unauthorized destroy attempt.

## Pre-GUID intent property

Four fixed witnesses and four generated combinations vary native snapshot
absent/created, empty/absent mount directory, inspection outage and one/two/three
replays. Intent is durably written first and its recorded snapshot GUID remains
nil. Unavailable inspection must preserve exact bytes with zero destructive
attempts. Confirmed native absence must remove intent without destroy; a present
locally tagged snapshot must be destroyed exactly once. Dataset GUID/data and
foreign snapshot contents remain unchanged. Empty-directory variation tests
cleanup handling, not an additional claimed producer execution stage.

## Contracts and review

Reviewed root/nix/test and backup ancestor contracts, actual HostCapture release
branches, helper interfaces and both new property contracts. Fresh source review
found no blocking finding and confirmed that successful commands use real pinned
ZFS rather than fabricated output. Fresh independent native evidence review
confirmed terminal success, cases through thirty-seven and the stated scope,
with no blocking finding.

## Execution

The final copied fixture and production backup modules passed pinned Python 3.13
Ruff format/lint and ty in `backup-types`, exit 0, in 10 seconds; archive
`1791015173465-2786229-0.jsonl`, log `/tmp/kittens-backup-native-identity-types.log`.
Existing state/workflow/status tests execute too; this is typing evidence, not
native fixture execution.

The combined native suite passed in 169 seconds, exit 0; archive
`1791015235097-2825945-0.jsonl`, log `/tmp/kittens-backup-native-identity-machine.log`.
The actual property command/subtest took 101.13 seconds; VM script 120.28 seconds.
All thirty-seven histories completed: thirteen original ownership, eight worker
death, eight actual identity replacement and eight pre-GUID intent histories.
Native mount records reach precreation case thirty-seven. Composed driver checks
passed. Independent evidence review, all-file Ruff/format/ty, logging, handbook
receipts, ADR structure (136 decisions) and generated options/coverage/views
passed. Evaluated Nix handbook validation passed in 34 seconds, exit 0; archive
`1791016035296-3120147-0.jsonl`. Contract discovery/parser checks passed
(117 CONTRACTS, 2335 native notes, 189 parsed and 2493 maintained source files);
these are structural checks, separate from semantic source and native reviews.

## Remaining gaps

Concurrent replacement during native inspection/destruction, complete packaged
backup/cleanup orchestration, deliberately surviving autonomous utilities, host
power loss, hosted Antithesis faults and historical authority reactivation remain
separate requirements. No new production adoption or recovery authority follows
from the fixture's restoration of its own original native objects.
