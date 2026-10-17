# Local Compose acceptance, 2026-10-13

## Control-core acceptance

The pinned rootless Podman/Compose environment completed a no-cache build of
the selected control-core images. The selected graph was materialized at
`antithesis/runtime/configs/control-core`, and identity freeze succeeded. The
materialization receipt records these inspected image IDs:

- Marshall: `sha256:1d266774c335216e7a0efe74d66226f825ad62d0152dcf1cb287711cf0439a10`
- Lilly: `sha256:e5b62b12eb280e64faa3a4fd99751d643835415e46ee20302630bae365a5b6b1`
- PostgreSQL: `sha256:3cb266621ed1fd7bda9152b58dd0a68c215554def11c1ba8965c0b7a9a30bf8f`
- Workload: `sha256:5ce4f3660c9ac0afd3f81063ea48bb5e31ddfa8113fadefa042c404147bb8ee6`

`snouty validate antithesis/runtime/configs/control-core --timeout 300`
succeeded. It observed the workload's `setup_complete` signal and recognized
nine drivers. Snouty validation checks startup and driver structure; it does not
execute the drivers. The frozen identity is valid for the recorded source and
image bytes only; a source or image change during the final cutoff requires a
new materialization and freeze. No hosted Antithesis launch was performed.

## Diagnostic4 historical acceptance

This is local rootless Podman evidence, not a hosted Antithesis result. No run
was launched, and the selected command manifest in the first workload image
was stale relative to four packaged runtime modules. The command record at
`antithesis/runtime/diagnostic4-control-commands/README.md` identifies the
actual image bytes and limits the claim to those bytes.

The fresh `overalls-antithesis-diagnostic4` base graph started with
`docker-compose up -d --no-build` after new Marshall and Lilly Nix contexts and
images were built. The startup transcript is
`/tmp/overalls-antithesis-diagnostic4-up-20261013.log`. PostgreSQL, migration,
both Marshall servers, enrollment and Lilly reached their health checks. A
read-only workload SQL oracle observed three users and three
`account_passkeys`, then a Lilly host row with protocol version 4, report
sequence 44, a non-null Control session and a report newer than 60 seconds.
The workload journal recorded `Antithesis setup complete` at 14:33:49 UTC.
Enrollment had no TCP listeners. Its one-shot fixture was published before the
workload signal.

The running images at that observation were workload
`e5700675b9121be9f523503247120c62a6f3745a9e41f2e94a1909130e9cd18d`,
Marshall `cf6a56e6880cd95fa1070a2e7d9ac96b46822c57b2013c9b54c0a7e1aec8b00b`
and Lilly `668b56e6e3ed4bfcf86626ad02043572242d79a9e0ec056f5606ac17faa5c2ca`.
The Lilly collector samples the process cgroup leaf and its ancestors, and
withholds the report if measurement fails. Its committed host row later had
effective cores 32 and effective memory 134558031872 bytes, with null
schedulable capacity and `execution_ready=false`. This observation does not
establish native storage or VM isolation.

Six serial Control commands in that workload container exited zero and emitted
13 local SDK assertion records, each with `hit=true` and `condition=true`.
Their exact commands, output files and assertion messages are in
`antithesis/runtime/diagnostic4-control-commands/README.md`. A separate
read-only SQL witness after those commands observed Lilly report sequence 392,
connected and fresh. That sequence is a live host report counter, not a
command count. The three terminal singleton commands were not run in this
project. Four selected runtime dependency hashes in its embedded manifest
disagreed with the packaged modules; the modules matched current source. A
restaged manifest and rebuilt workload image are required before immutable
identity or hosted readiness can be claimed.

The optional measured private host used the existing direct VM and original
`overalls-antithesis_lilly-host-secrets` and
`overalls-antithesis_guest-fault-control` volumes. A local-only overlay attached
those volumes to diagnostic4 enrollment; it did not start a second VMM. After
both Marshall servers were recreated healthy with a shared terminal replay
volume, the operator published the private host credential, pool ID and CA at
14:42:19 UTC. The read-only SQL oracle observed a separate `lilly-host` v4 row.
No host report or authenticated session was present at that point.

The optional inner Ziggy issuance then refused: enrollment exited at 14:42:21
with `Inner satellite credential outcome uncertain`. A fresh read-only SQL
query bound the private credential's host ID to the one `lilly-host` row and
found `enabled=false`, report sequence 0 and zero inference credential rows.
The output `inner-ziggy.token` was exactly zero bytes, mode 0600, one link;
`.inner-ziggy.started` existed, while Galileo had not been attempted.
`Marshall.Inference.Credentials.rotate/2` refuses a disabled host before
creating authority. Under the reviewed exact-refusal recovery, both zero-byte
files were moved, not deleted, into the private root-owned 0700 directory
`forensics/2026-10-13T14-42-21Z-inner-ziggy-disabled` inside the original host
secret volume. No role credential was retried or issued. A rebuilt Marshall
entrypoint now compares retained CA SHA-256 digests using the installed tool;
the prior `cmp` was absent from the image and had falsely reported a mismatch
despite equal CA hashes. The operator was restarted with inner issuance
disabled and returned healthy. Measured private-host Control, role readiness,
and guest execution remain separate pending checks.

Failed earlier fixture projects were stopped without `-v`. Their named volumes
remain retained and their partial one-time bootstrap is not replayed. The
diagnostic4 full Compose build and its final image identity check remain a
separate historical record; the control-core acceptance above is the completed
local validation for the currently selected profile. The source cutoff can still
invalidate its frozen identity.
