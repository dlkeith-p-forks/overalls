---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# G3: physical data journeys

This is candidate research for the coverage-balance and wildcard gap, not an addition to the canonical property catalog. It uses current repository source and the accepted stopped-only ADR-0155. No retired harness/history, remote tenant, build, or fresh native/hosted execution was consulted. The three candidates have distinct primary messages and scopes:

| Candidate | Priority/type | Missing user-visible witness | Existing property it complements |
| --- | --- | --- | --- |
| [clone-two-drive-copy-survives-source-deletion](data-journeys/clone-two-drive-copy-survives-source-deletion.md) | P0 safety | Independent bytes from both copied drives after divergence and source deletion | `source-stop-after-committed-placement-holds` guards preparation/holds, not copied bytes; `delete-release-follows-physical-retirement` guards cleanup authority. |
| [resize-retains-exact-guest-bytes-and-grown-shape](data-journeys/resize-retains-exact-guest-bytes-and-grown-shape.md) | P0 safety | Preexisting guest data plus actual device/filesystem size and CPU/RAM after a confirmed resize | `marshall-admission-measured-physical-capacity` checks reservations, not the resized guest. |
| [stopped-relocation-retains-bytes-and-routes-to-destination](data-journeys/stopped-relocation-retains-bytes-and-routes-to-destination.md) | P0 safety with a conditional P1 progress probe | Destination bytes and live DNS/SSH/HTTPS route, with old-source refusal | `relocation-handoff-one-current-execution` guards placement/epoch and dual execution, not useful ingress or data. |

## Shared proof discipline

Capture a unique workload-generated marker and digest **after the guest has fsynced the file and its containing directory** on each drive. Record the VM ID, placement, execution epoch, physical boot ID, drive name, length and digest in a workload-owned ledger outside the SUT. A guest command success, a Marshall row, a transfer receipt, and a dataset GUID answer different questions; no one of them substitutes for the independent post-effect read. Reread from the *destination guest* after boot, plus read actual native ZFS dataset GUID/origin and drive-file shapes. Distinguish a source dataset GUID from the two ordinary drive files inside that one dataset; no per-drive ZFS GUID exists here. Sample the stable marker after it has been acknowledged, and compare it to that captured baseline. An unacknowledged write at the crash edge is uncertain and cannot be called lost.

The candidates concern retained data and user access, not a claim that a current defect exists. Existing Nix machine source gives bounded witness patterns; historical pass statements in ADRs are evidence for their stated revisions and scopes only. Current `existing-assertions.md` reports no Antithesis SDK callsites. Any proposed SDK assertion is therefore missing instrumentation. The physical suite needs real ZFS and Firecracker or a separately proven equivalent for the exact boundary. The proposed hosted TCG guest and one-pool storage sketches do not prove multi-host Firecracker, native SSH transfer, per-drive guest mounts, or Audi route convergence. `control-core` simulated effect receipts cannot close any of these three physical claims.

## Shared fault and value menu

- Clone: original running/stopped; same-pool block copy enabled/disabled; cross-pool/host full stream; one or two drive profile; lost capture/copy/adopt receipt; interrupted stream or offload; source write before/after capture; source deletion after independent destination read; destination write after copy. Do not interpret a crash-consistent snapshot as a transaction across guest filesystems.
- Resize: originally running/stopped; CPU 1→2, RAM 512→768 MiB, disk 4,294,967,296→5,368,713,216→6,442,450,944 bytes from the native fixture; interruption before/after resize journal, physical grow, vm.json publication, outcome and restart; duplicate original key versus changed payload. The exact byte values test off-by-one behavior, not a performance guarantee.
- Relocation: originally running/stopped; source/destination host A/B; probe unavailable/available; interrupted single full stream/resume; import before/after adoption; coordinator loss around handoff; destination readiness delay/failure; route publication lag across both authoritative replicas; stale pinned old-source HTTPS and SSH transports. Every running move stops before its only full copy under ADR-0155; no live pre-copy premise remains.

## Environment and implementation handoff

Use a native KVM/ZFS fleet fixture with two Lilly hosts and real guest networking for relocation; the clone and resize physical legs can reuse the existing native `zfs-guest` and `resize` fixtures. Keep an independent client on the tested DNS/TLS/SSH path. An Antithesis-hosted transfer override would need two separate Lilly instances, persistent ZFS state and a demonstrated full destination guest plus Audi route before it can use these literal property messages unqualified. A storage-only TCG experiment may report a narrower storage result under a different message.

The candidate probes should store digests and bounded identity facts only; do not emit raw customer bytes, command arguments, terminal output, credentials or token-bearing URLs through application diagnostics. Workload-private synthetic fixture bytes are separate from production logging. A timer expiry or network error is inconclusive until a fresh positive/negative physical observation is obtained.

## Architecture and documentation impact

Research-only scratchbook additions preserve ADR-0155 (stopped single full stream), ADR-0072's carried-forward multi-drive transfer, ADR-0145's same-pool independent copy, and ADR-0051/0053 resize contracts. They do not change code, configuration, protocol, operations, architectural decisions, or documented product behavior. No ADR, architecture review, or HLDD edit is warranted for this candidate-only diff. An implemented harness would require its own architecture/HLDD impact review and verification claim boundaries.

## Open questions

- Can the native fixture pause **after destination readiness but before source cleanup** without altering production authority? The relocation evidence logs the need to compare the destination while the source disk is still held. If it cannot pause, read at the last externally observable safe point and report the narrower boundary.
- Which Inception image and guest mount path provide a true in-guest fsync and read of `data.raw` alongside `rootfs.ext4`? Current source test presence demonstrates a guest data command but does not by itself show the exact independent per-drive digest witness proposed here.
- Can a two-Lilly hosted Antithesis composition run actual storage, guest, Audi DNS and strict SSH/HTTPS together at useful search speed? Until measured, keep the full property on the native campaign.

### Investigation Log

- Examined: `docs/architecture/decisions/0155-stopped-only-relocation.md:43-70,125-158`, `nix/verification/tests/machines/zfs-guest/driver.py:250-271`, `nix/verification/tests/machines/zfs-guest/clone-matrix.py:4-13,31-70,137-180`, `nix/verification/tests/machines/zfs-transfer/driver.py:360-450`, `nix/verification/tests/machines/resize/driver.py:297-308,386-452`, `nix/verification/tests/machines/resize/guest.exs:5-42`, `nix/verification/tests/machines/fleet/scenarios/relocation.py:44-84`, `nix/verification/tests/machines/fleet/scenarios/audi-relocation.py:130-313`, `antithesis/scratchbook/deployment-topology.md:88-103`.
- Found: These files expose real native data, shape, GUID and route probes and the appropriate physical topology. The clone matrix and two-drive adoption exercise independent placement and source deletion. Resize checks guest data and exact device size. Audi relocation checks replica DNS, live SSH/HTTPS and old-source failure.
- Not established: This investigation did not execute the fixtures; there is no fresh combined per-drive fsync/digest ledger or combined clone/resize/relocation Antithesis campaign. Existing individual tests do not establish that composition, and a storage-only or modeled hosted success cannot do so.
