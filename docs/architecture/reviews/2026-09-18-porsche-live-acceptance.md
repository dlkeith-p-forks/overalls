# Porsche live acceptance on Overalls

## Scope and architecture impact

The operator requested real SSH command acceptance and 50 simultaneous VMs, then
explicitly excluded `share add`, `share show` and `share remove`. The run uses an
existing account, dedicated Ed25519 keys and Porsche on port 22. Bootstrap writes
public-key authority through Marshall's Ash action using the configured operator
release under sudo. Administrative OpenSSH remains on 2222.

[ADR-0046](../decisions/0046-porsche-ssh-management.md) remains unchanged:
Porsche uses authenticated HTTPS and Marshall owns durable requests and account
authority. [ADR-0042](../decisions/0042-host-observability.md) remains unchanged:
the diagnostic change reports fixed disk-preparation stages, local error atoms
and placement IDs without paths, utility output or guest contents. It preserves
results and quiet `storage_busy` retries. Bounded ZFS resampling preserves the
inherited storage/accounting requirements: every attempt rechecks backing identity,
and all non-usage properties are pinned across attempts. Invalid samples never
grant credit. No architecture decision or implementation status changes are proposed.

The [runner](../../../scripts/porsche_acceptance.py) records request IDs before
submission, checks names/ownership before lifecycle mutations, and uses recorded
UUIDs for cleanup. Its [safety tests](../../../scripts/test/test_porsche_acceptance.py)
exercise ownership rejection, generated-name custody, sharing exclusion, SSH
transport errors, approval-link redaction and stable-ID admission retries.
The [operator guide](../../acceptance/porsche-acceptance.md) describes setup and resume limits.

## Executed evidence

Run `porsche-20260918-012013` began against deployed revision
`3c331ab94b09e6ab55e76c63f8bb045e08d566d8`. The 50 named machines each received
1 vCPU, 512 MiB RAM and a 2 GiB sparse disk from the configured NixOS image.
All 50 reached physical running state simultaneously, verified against Ash
receipts, active Lilly units, individual Firecracker PIDs and native ZFS GUIDs.
The first full stop pass confirmed all 50 processes absent and unchanged dataset
GUIDs. Seven pre-existing machines were outside the mutation set.

All 13 non-sharing verbs were exercised in text and JSON modes, with per-command
help. `ls` pagination returned 50 then seven machines. Lookup by name and UUID,
invalid commands/sizes/images/profile/cursor, duplicate names, conflicting request
IDs and pinned replay were exercised. Interactive `whoami`, `images`, `ls`,
`help new` and `exit` completed; exec `exit` completed too.

One additional VM exercised generated naming, an explicit image digest, OSS
profile and explicit shape. A one-second stop timeout returned exit 4 with an
accepted receipt and later completed. Killing a client after the server reported
waiting did not cancel its start. A disposable key submitted a stop, was revoked,
then could no longer run commands or inspect the request; the primary key observed
the accepted stop complete. This additional VM was deleted through Porsche.

## Findings

- **Transient admission conflicts:** the unpaced initial batch admitted 12 of
  50 requests. Retrying identical request IDs with bounded backoff eventually
  reached 50 without duplicates. The public error is `conflict`, which also
  represents other rejection reasons; this evidence does not establish the exact
  cause of every rejected admission. No capacity policy was changed.
- **Restart failures:** the initial fleet restart failed request
  `porsche-20260918-012013-start-796c10ed-5a87-4506-9da1-0b5324b17f31`
  with `execution_failed`. Lilly logged `disk_prepare_failed` for placement
  `3fb436d2-3bc3-4bb6-a7e2-5680e89a0de8` at 01:30:00 UTC. Subsequent observations
  alternated failed/unknown with `cleanup_failed`; that is not successful recovery.
  Existing diagnostics did not identify the failed disk check. Commit `4ff01c6`
  added bounded stage diagnostics and reached healthy status through autodeploy.
  A fresh stop and start restored the VM, and a subsequent start pass restored all
  50 with unchanged disk GUIDs. Another complete cycle reproduced a failure on VM
  `f0ba6272-8f57-4393-824a-aff7a9c8b1c8`: the stage logs identified
  `incoherent_zfs_observation` in dataset preparation. Both original receipts
  remain failed.
  The follow-up change retries unsettled accounting at most three complete reads,
  requires unchanged non-usage properties across every attempt, and fails closed
  on identity/policy drift or exhaustion. This addresses transient inconsistent
  accounting; the log does not identify which native counter changed.
  A first, broader retry implementation failed the existing native quota-change
  rejection test and was rejected before deployment. The narrowed implementation
  adds an explicit cross-attempt property-binding regression.
- **Startup inventory output limit:** deploying the ZFS correction with 56 active
  VM units exposed `vm_reconciliation_required`. The ownership scan requested
  verbose `systemctl list-units` output: 73,304 bytes exceeded its 65,536-byte
  utility limit. All listed units had durable command identities. Querying only
  `Id` properties returned the identical 56-unit set in 3,079 bytes. The correction
  preserves the existing unit/cgroup membership checks and failed-scan rejection.
  A native regression creates 56 services with long descriptions and checks both
  missing tracked identities and an unrelated child cgroup.
- **Malformed-input output:** parser rejection produces text even when the
  malformed input contains `--json`. Valid commands produce JSON as requested.
  Negative tests verify domain rejection rather than accepting SSH exit 255.

## Validation and final outcome

Lilly's full pinned-runtime `mix precommit` passed 272 tests/properties and
Dialyzer. Marshall's full gate passed 535 tests/properties, distributed tests,
terminal checks and forced Dialyzer. It used an isolated PostgreSQL instance on
55432 and an explicit repository port override, with OpenSSL on PATH; no test
fixtures were created in the production database. The six runner safety tests
passed. Contract format/discovery and the 52-record ADR check passed; these
structural checks do not establish physical correctness.

The narrowed ZFS correction passed the native ZFS check in 114.82 seconds,
including drift rejection, invalid snapshots, 400 datasets and physical pressure.
The final native check, including the 56-service inventory regression, passed in
114.52 seconds. Commits `c3bb6a6` (bounded accounting resampling) and `0626b20`
(compact unit inventory) were pushed through autodeploy; `0626b20` reached healthy
status. On that revision, a fresh full cycle completed all 50 stop requests and
all 50 start requests successfully. Physical inspection confirmed all 50 running
simultaneously with the original dataset GUIDs.

Cleanup completed for all 50, with no remaining active units, Firecracker processes
or datasets and with both reservation flags released. Name reuse created a new
UUID; replay of the archived create/delete requests remained pinned to the old
UUID and left the replacement running. The replacement was then deleted. Including
the generated-name scenario, all 52 test VMs were archived and physically removed.
The seven original VMs retained their IDs, names, shapes, generations and running
states, corroborated by active units, Firecracker processes and datasets.
The [sanitized evidence](2026-09-18-porsche-live-evidence.json) records the fleet
identities, dataset continuity, final cleanup, original-machine preservation and
command attempt counts. The two earlier failed start receipts remain failures;
the successful final cycle uses new, explicitly recorded request IDs.

Raw receipts and command transcripts remain in the private operator directory
`~/.local/state/porsche-acceptance/porsche-20260918-012013`. Its primary Ed25519 key
remains registered for reuse; the disposable key is revoked. No private keys or
approval URLs are committed. Final review found no change to accepted authority,
ownership or storage-accounting contracts; the fixes restore their implementation.
Sharing is excluded by request. This is one physical host with idle guests,
not a multi-host availability or sustained guest-load benchmark.
