# Native host snapshot cleanup ownership

## Architecture impact

Baseline `8b584ca88795a15a206a5867a7e0feeb0490a7ef`. This is verification of
ADR-0070's existing durable intent and exact native snapshot cleanup authority.
Production HostCapture, storage formats, credentials and deployment are unchanged.
The test uses pinned Python 3.13, Hypothesis and real mirrored ZFS on one disposable
NixOS machine. The existing guest-backup fixture exercises Lilly.Backup and does
not establish Python HostCapture ownership.

## Property and independent oracle

`nix/tests/machines/backup-cleanup/native_cleanup.py` invokes actual HostCapture
cleanup/release with native ZFS and actual mounted snapshots. Seven fixed cases
and six generated combinations vary dataset/snapshot GUID mismatch, wrong local
nonce, inherited nonce, an actual foreign tmpfs mount, unavailable snapshot
inspection and unavailable inspection after successful destruction. Repetition
menu is one/two/three; recorded GUID is present or absent. The snapshot mismatch
case records a deliberately incorrect GUID regardless of that optional axis.
Intent is durably published before native snapshot creation.

The fixture audits unmount/destroy attempts while delegating the production
command method unchanged. Its ZFS executable wrapper delegates successful work
to pinned native ZFS; outage injection fails actual listing commands and never
supplies fabricated successful data. Independent direct native GUID/findmnt
queries bypass that outage wrapper. Refusal retains exact journal bytes, zero
destructive calls, unchanged snapshot GUID and actual mount source. Valid proof
restoration must unmount and destroy the exact owned snapshot once and remove
its descriptor/mount directory. Post-destroy uncertainty must retain intent,
confirm actual snapshot/mount absence and converge without another destroy.
An unrelated foreign snapshot retains its GUID and its immutable snapshot
contents, as well as live dataset contents, throughout every history.

## Contracts and review

Reviewed root/nix/test and backup ancestor contracts, HostCapture cleanup/release,
and native fixture/delegation contracts. Initial fresh review identified that
snapshot-content preservation was only checked against the live dataset; the
fixture now also reads the immutable `.zfs/snapshot/keep` view. Source review
otherwise found no blocker. Final fresh source, contracts and runtime evidence
review independently confirmed terminal success and found no blocker.

## Execution

The final `backup-types` check passed in 18 seconds, exit 0; archive
`1791013244912-1886145-0.jsonl`, log `/tmp/kittens-native-backup-types-final.log`.
Ruff format/lint and ty analyze the copied native fixture beside the real backup
modules using pinned Python 3.13/Hypothesis. Existing state/workflow/status tests
also execute; this check does not execute native fixture actions. An earlier
formatting failure preceded successful type analysis and is not product defect
or native runtime evidence.

The native cleanup check passed in 98 seconds, exit 0; archive
`1791013269708-1902661-0.jsonl`, log `/tmp/kittens-native-backup-machine.log`.
The actual cleanup property command took 28.37 seconds; VM script 45.77 seconds.
Native mount histories reached case `0d` (thirteen fixed/generated histories).
Composed driver validation passed. Contract structural checks passed separately;
these do not replace the semantic source/oracle review (117 CONTRACTS, 2335
native notes, 189 parsed and 2493 maintained source files).
All-file Ruff/format/ty, logging, handbook receipts, ADR structure (136 decisions),
generated options/coverage/views passed. Evaluated Nix handbook check passed in
40 seconds, exit 0; archive `1791013665126-2087609-0.jsonl`. All 83 scenario IDs
are preserved and unrelated scenario rows are unchanged.

## Remaining gaps

One process performs bounded retries; no worker death, power loss, concurrent
identity replacement or complete backup/systemd workflow is established here.
GUID mismatch is introduced in the recorded descriptor, not by replacing an
actual dataset under a running cleanup. Unmounted/pre-creation native intent
histories and hosted Antithesis faults remain separate requirements. There is
no new production recovery authority or historical reactivation claim.
