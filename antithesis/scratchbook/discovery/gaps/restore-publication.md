---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Backup restore and publication gap investigation

The current 75-property catalog has backup graph closure, owned cleanup, and
mixed-time historical quarantine, but no primary assertion for interrupted
*restore-target* publication or for a newly published manifest's acceptance by
its later retention validator. The proposed candidates below add those two
independent boundaries. Safe *reentry* from an isolated historical restore is
recorded as a policy and implementation gap rather than asserted as an existing
capability. No source, catalog, property, service, or deployment file was changed.
The [fresh assertion scan](../../existing-assertions.md) found zero Antithesis
SDK callsites; these assertions are proposed and missing.

| Candidate | Type / priority | Why separate |
| --- | --- | --- |
| [Interrupted restore never publishes a partial target](restore-publication/backup-interrupted-restore-target-unpublished.md) | Safety `Always`, P0 | A retained manifest can have valid references while the selected restore target has only a verified prefix. |
| [Published backup points pass retention schema](restore-publication/backup-published-manifest-retention-compatible.md) | Safety `Always`, P1 | A new Restic `host-manifest` can be tag-visible before `retain` validates its separately sampled wall times. |
| [Historical restore reentry requires reconciliation](restore-publication/backup-historical-restore-reentry-reconciliation.md) | Deferred policy candidate, P1 | Existing quarantine tests no activation. A positive activation receipt and its checks have no source contract or CLI today. |

## Source and existing evidence

`nix/modules/backups/runtime.py:313-345` validates the selected manifest,
requires an absolute empty private target, restores indexed components with
`restic restore --verify`, then atomically writes `manifest.json`. This is a
restore-target publication marker, separate from the repository's uploaded
`host-manifest` point. `:277-285` holds one owner lock through the operation.
The generated real-local-Restic test already covers SIGTERM, SIGKILL, timeout,
verified prefix, absent marker, and fresh-target retry
(`nix/tests/evaluation/backup-operators.py:858-959`). Other existing histories
cover a missing component and explicit retry (`:673-728`), concurrent lock
contention (`:1261-1341`), and a mid-restore password change (`:1354-1427`).
These tests are relevant past execution evidence under ADR-0070's review, not
Antithesis fault coverage or a current rerun. The native backup machine restores
host bytes and PostgreSQL into an isolated database
(`nix/tests/machines/backups/driver.py:187-255`); it does not show an interrupted
native guest-disk restore.

`nix/modules/backups/journal.py:113-133` samples backup start from wall time.
`nix/modules/backups/runtime.py:207-225` separately samples completion,
uploads the complete manifest, records completion, then calls retention.
`nix/modules/backups/restic.py:213-254` rejects `started_at > completed_at`,
and `:256-295` validates every manifest before any forget operation. The
`reversed_time` operator test constructs an invalid manifest and confirms
inspect/restore/prune refusal (`nix/tests/evaluation/backup-operators.py:580-665`).
The assumptions report A12 already records a **modeled** 2000→1000 boundary;
no controlled clock step through the actual coordinator plus Restic is recorded.
Thus publication of a retention-poisoning point remains a source-grounded
hypothesis, not a confirmed SUT defect. Retention's refusal is the expected safe
response to invalid input. ADR-0070 states nominal RPO as thirty minutes plus
up to five minutes' jitter and capture runtime, with older points during outages
(`docs/architecture/decisions/0070-host-recovery-backups.md:29-47,120-125`);
this proposal adds no hard RPO or simultaneous capture claim.

ADR-0070 requires isolated logical database restore, fencing and explicit
reconciliation before serving (`:86-102`). ADR-0158 says an older database
alongside newer retained guest disks cannot safely allocate guest UUIDs/UIDs
until reservations and sequence are reconciled, and provides no automatic
historical repair (`docs/architecture/decisions/0158-durable-guest-identities.md:106-110`).
The backup CLI has no activation command (`runtime.py:252-345`). Existing
`backup-time-skew-never-activates-historical-authority` rightly asserts negative
quarantine; a successful reentry assertion needs a separate specified receipt,
identity/sequence proof and fenced native drill. No production restore is in
scope.

## Campaign boundary and balance

A hosted/local-Restic operation can test operator lock, component restore bytes
and marker ordering with synthetic secrets. A native isolated NixOS campaign
with real ZFS, TLS S3, remote PostgreSQL and the actual service wrapper is
needed for guest disk, database and systemd fault claims. It must use disposable
repo/target identities, never live fleet credentials or production restore.
The topology's `native-kvm` row (`deployment-topology.md:96`) and existing native
backup machine are appropriate starting points; hosted TCG/storage does not
become Firecracker or physical recovery evidence. The root's authorized native
isolated campaign permits later execution, but this discovery subtask ran no
build, heavy test, or remote campaign. Injected clock steps require an isolated
clock namespace/VM or a typed scoped fault seam that still runs real coordinator
and Restic; merely constructing a malformed manifest is weaker evidence.

This selection balances one restore safety invariant and one producer/consumer
schema invariant without duplicating reference closure, cleanup ownership or
historical quarantine. The reentry file documents the missing positive policy
without converting an unsupported transition into a liveness promise.

## Investigation log

- Inspected: root/backup/test contracts, ADR-0070/0158, backup runtime/journal/
  Restic, operator tests, native backup driver, recovery guide, existing backup
  property evidence, discovery assumptions, catalog, SUT analysis, topology and
  coverage/wildcard evaluation. The source and test evidence support the
  candidate boundaries above.
- Not established: current green execution at this checkout, actual backward
  clock-step publication with Restic, hosted clock-fault availability, or an
  implemented safe activation/reconciliation receipt.
- No architecture decision or documented behavior changes were made; these are
  research notes. The diff preserves ADR-0070/0158 and HLDD contracts. No HLDD
  update or architecture review artifact is triggered by this source analysis.
