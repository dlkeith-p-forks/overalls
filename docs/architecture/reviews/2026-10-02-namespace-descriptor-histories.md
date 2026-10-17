# Native namespace descriptor histories

## Scope and architecture impact

Test-only verification under ADR-0112. Production namespace discovery, exact-root
checks, ordinary unmount, retained deleting fence, physical absence requirement
and inventory limits are unchanged. No domain, protocol or cleanup authority
changes. The source-built Lilly release and real Firecracker/ZFS machine fixture
remain required; pure planner checks do not establish these native effects.

Reviewed fixtures:
`nix/verification/tests/machines/zfs-guest/hold-namespace.py`, `namespace-inventory.py`,
`namespace-cleanup.py` and their installation in `default.nix`.

## Generated histories and oracles

Seed 135 shuffles six explicit histories across one, two and four distinct empty
mount namespaces, one or four duplicate descriptors, retained or closed originals,
and visible or hidden foreign proc. These are bounded lifecycle histories;
the seed changes submission order, not kernel scan order or race timing. Each
generated disk is started at generation 1 and stopped normally at generation 2
before namespace creation; deletion uses generation 3. This preserves the
strict single-root precondition after normal jail cleanup.

The holder creates each private namespace, duplicates its descriptor, optionally
closes the original and reaps its child before atomically publishing owner-only
readiness. The driver independently compares the complete actual namespace
descriptor map with the declared identities and confirms all children exited.

A separate observer enters every retained descriptor and reads current mountinfo
through proc pinned before entry, including when foreign proc is hidden. Every
descriptor must expose the exact owned root before deletion and no target mount
afterward. Native dataset absence, unchanged holder descriptors, an active holder,
and exact surviving guest process/data checks are mandatory for every history.
The original late-copy, single-descriptor, hidden-proc and busy-file cases remain.

## Validation

Pinned Ruff check/format and ty for both standalone helper scripts passed in
`/tmp/kittens-namespace-native-static.log`. Fresh source review found no blocker. A second fresh review of the corrected
stopped-disk setup found no blocker in fencing, exact descriptor/current-mount
inventories or survivor assertions; running jail-bind copies and during-sweep
races remain distinct gaps.
The composed driver passed Nix type checking and lint (capture
`1790974965975-3195748-0.jsonl`, lines 795–800). The first full native execution terminated with exit 1 before deletion in the
first generated history (one namespace, one duplicate, original retained,
visible proc; VM 106). Readiness, child reaping and exact descriptor inventory
passed. The exact-root precondition failed at driver line 209, but the observed
mount list was not retained, so that capture alone could not establish the cause. This is fixture or
observer evidence, not evidence of a deletion failure. The assertion now reports
its exact synthetic-target mountpoints without weakening the precondition.

The original late-copy, descriptor-only and hidden-proc cases passed in
445.75, 199.99 and 114.60 seconds respectively (capture lines 1938, 2027 and
2110). The other generated histories and final busy-file case were not reached.
Structural contract checking and discovery passed in
`/tmp/kittens-namespace-history-contracts.log`; semantic source review remains
separate from syntax checking. The survivor oracle's
`nix/verification/tests/support/vm-processes.py` collects actual cgroup PIDs, kernel start times
and executable device/inode identities, and requires a Firecracker row before
returning its snapshot.

The focused diagnostic passed in 164.09 seconds, recorded in
`/tmp/kittens-namespace-focused-isolated.log`. Both retained descriptors saw four
exact-target mounts while running: canonical root and kernel/initrd/rootfs jail
bindings. After normal stop, newly retained namespaces exposed only the canonical
root through both descriptors. This establishes the precondition mismatch and
supports copying stopped disks for the generated histories. The original running
guest deletion cases remain. This diagnostic establishes the fixture precondition; the separate complete
corrected run below establishes generated deletion outcomes.
Command: `nix build --max-jobs 1 --no-link .#checks.x86_64-linux.zfs-namespace-cleanup`.

The corrected full native check passed, exit 0, in 2,008 seconds (VM script
1,986.83 seconds). Capture: `1790976634771-19384-0.jsonl`.
All six generated histories passed exact per-descriptor before/after mount and
complete identity checks, native dataset absence, active unchanged holders and
exact neighboring guest processes/data. The original running late-copy,
descriptor-only and hidden-proc cases passed in 260.26, 146.98 and 118.90 seconds.
The final busy-file case passed in 204.93 seconds: busy refusal retained the
`deleting` claim and dataset, survivor access remained usable, and release of
the holder allowed ordinary retry and an empty final allocation snapshot.

| Case | Namespaces | Duplicate copies | Originals closed | Hidden proc | Seconds |
| --- | --- | --- | --- | --- | --- |
| 0 | 1 | 1 | no | no | 217.85 |
| 1 | 2 | 1 | yes | no | 296.49 |
| 2 | 1 | 4 | yes | yes | 192.54 |
| 3 | 4 | 1 | no | yes | 166.75 |
| 4 | 2 | 4 | no | yes | 178.06 |
| 5 | 4 | 4 | yes | no | 186.75 |

Capture lines 1834/1919/2005 record the original cases, 2125/2252/2378/2526/
2678/2859 the generated cases, and 2992–2998 the final busy case and cleanup.
Earlier failed capture `1790974965975-3195748-0.jsonl` remains retained separately.

## Remaining gaps

Original descriptor closure occurs before cleanup. Descriptor closure/reuse
during the sweep, arbitrary process churn, denied inventory, aliases/descendants,
native inventory-cap witnesses and hosted faults remain unverified. The observer
does not mutate mounts or authorize deletion. No force/lazy detach, process
termination, fence release or production acceptance follows from this fixture.

Final pre-integration static/reviewed receipt and evaluated HLDD checks passed;
evaluated capture `1790978746640-1314192-0.jsonl` exited0 in9seconds. Marshall’s
full gate passed1,413checks and forced Dialyzer with zero errors. Integration
verification subsequently passed: integrated Marshall precommit recorded 1,417
checks (216 properties, 1,201 tests), two exclusions, seed505231, in1006.0seconds,
with forced Dialyzer43.99seconds and zero errors. The complete command exited0;
log `/tmp/kittens-namespace-clone-integrated-full-gates.log`.

The integrated native check reused the exact corrected derivation
`/nix/store/swcl2xhrrf36wrfggrwpswnglvaz2m4m-vm-test-run-kittens-zfs-namespace-cleanup.drv`.
The original native capture names that same derivation at line689. The integrated
build exited0 in3seconds (capture `1790979436446-1723747-0.jsonl`); this is reuse
of the recorded native execution, not another VM run. Integrated evaluated HLDD
passed9seconds in capture `1790979460571-1738534-0.jsonl`.
