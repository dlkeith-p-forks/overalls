---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# Native ZFS I/O subinventory

Read-only source inventory on 2026-10-13, checkout `/home/ghuntley/src/kittens-antithesis-reset`, HEAD `9fe1e493b2090d44bacd16089049cd12b316d58a`. Scope: `nix/verification/tests/machines/zfs-io/{default.nix,driver.py,probe.exs}` plus called-source contracts and repository review evidence. No builds, evaluations, test executions, repository changes, secret reads, or retired Antithesis harness reads. `external_references=[]`.

## Present-source incompatibility

The current check is still exported at `nix/verification/tests/catalog.nix:354`, but its probe and driver depend on legacy `io` fields that the present collector/control schema deliberately omit. This is a source-level finding, not an executed failure:

- `probe.exs:25` invokes `Collector.sample(pools, "/sys/fs/cgroup", nil, 1)`; `probe.exs:26` checks shared-protocol encode/decode equality; `probe.exs:27` extracts `[:id, :io, :total_bytes, :free_bytes, :allocations]` for JSON output.
- `lilly/lib/lilly/host/collector.ex:46-49` contract `diagnostics-do-not-delay-sample` says capacity collection must not wait for native I/O or attach diagnostic counters to control reports. The implementation ignores `_native_io`, calls only `Pool.report/1` at `:53`, and stores those snapshots as report pools at `:78`.
- `lilly/lib/lilly/host/pool.ex:212-219` returns `id`, `total_bytes`, `free_bytes`, `storage`, and `allocations`, with no `io` field. `protocol/lib/overalls_protocol.ex:142-149` encodes precisely those fields; its measured pool validator requires a five-field map at `:190-209`.
- Consequently, if the probe reaches successful JSON output, `Map.take` omits absent `:io`; the initial driver `sample()` at `driver.py:59` then requires `pool["io"]["zpool_name"]` at `:25`, so the current source cannot satisfy the written I/O assertions.
- This matches accepted ADR-0149 (`docs/architecture/decisions/0149-independent-observability.md:37-44`), which retains physical capacity in control reports and moves pool I/O to infrastructure export. The fixture requires reconciliation with that boundary; reattaching I/O to the collector would contradict its present contract.

`Lilly.Host.ZFSIO` remains implemented (`lilly/lib/lilly/host/zfs_io.ex:19-50`); the control runtime samples it independently (`lilly/lib/lilly/control/runtime.ex:299-313`). This probe exercises neither that independent measurement path nor infrastructure export. The fault wrapper only changes the `zpool` selected through PATH after pool binding (`probe.exs:20-23`), so it cannot make the current capacity collector call `zpool iostat`.

## Exact assertions written in the native fixture

Paths below are relative to `nix/verification/tests/machines/zfs-io/` unless expanded.

| Assertion | Source location | Claimed observable behavior |
| --- | --- | --- |
| Native binding and protocol round trip | `probe.exs:7-18`, `:25-27` | Inspect both real dataset mountpoints, construct two Pools with encoded native identity, shared host UUID and explicit 1 GiB logical budget; collector report must survive encode/decode exactly. |
| Exactly two pools | `driver.py:21-25` | Successful command output decodes to two JSON records, indexed by `io.zpool_name`. |
| Native logical pool scope and independent dataset capacity | `driver.py:28-36` | Both tank/archive I/O status measured; source `openzfs_zpool_iostat`; scope/kind `zpool`/`logical`; capacity provenance `zfs_dataset_properties`/`dataset`. |
| Timing and live import identity | `driver.py:37-44` | Requested interval 1000 ms; precise sample interval null; collection elapsed at least 1000 ms; rate clock `openzfs_vdev_timestamp`; returned load GUID equals a fresh native `zpool get`. |
| Rate types, explicit unknowns, bounded capacity | `driver.py:45-56` | Four read/write IOPS/bytes-per-second fields are nonnegative integers; latency, queue, busy percentage and max IOPS null; `0 < free <= total <= 512 MiB`; allocations empty. The driver does not explicitly assert `in_flight` null. |
| Traffic outside Lilly dataset reaches the zpool observation | `driver.py:59-70` | Initial sample measured; create separate `tank/workload`, initialize an 8 MiB file, start writer/direct reader, await nonempty output and completed-read marker; all four tank rates strictly positive; stop workloads. |
| Faults withhold uncertain rates and retain capacity | `driver.py:72-89` | For malformed, timeout and reload faults, sample completes in less than 30 seconds; every pool's I/O status unavailable; four rates and load GUID null; free capacity positive and allocations empty. No exact source/status provenance assertion is repeated in this fault loop. |
| Actual import discontinuity and subsequent recovery | `driver.py:90-93` | Reload leaves permanent tank GUID equal, changes load GUID, and every fault is followed by a clean fully measured sample. |

Shell `storage.succeed` calls also require successful pool/dataset setup, file initialization, workload start/stop and GUID retrieval. `wait_for_unit("multi-user.target")` gates boot (`driver.py:8-9`); `wait_until_succeeds` gates workload readiness (`:65`).

## Topology, resources, controls and bounds

- Exactly one NixOS machine `storage`, no Marshall nodes, Lilly daemon/service module, Firecracker guest or network/fleet topology: `default.nix:2-4`, `:48-56`. It invokes the actual source-built Lilly release via `lilly eval`; distribution is explicitly disabled and the scheduler count is fixed at two (`:49-56`).
- Explicit machine settings: state version 26.05, hostId `aabbccdd`, ZFS support, root force import false, ZED disabled (`default.nix:5-9`); 2048 MiB RAM, two cores, three 2048 MiB empty virtual disks, forced acceleration and `-cpu host` (`:10-14`). There is no fixture-declared `requiredSystemFeatures` or nested-KVM feature. KVM/acceleration is an explicit VM setting, not a checked physical-capability acceptance claim.
- Real `tank` mirror uses `/dev/vdb` and `/dev/vdc`; independent single-device `archive` uses `/dev/vdd`; both roots have lz4 compression. `tank/lilly` at `/pool` and `archive/lilly` at `/otherpool` each have 512 MiB quota (`driver.py:10-15`). Pool logical budget is separately set to 1 GiB in the probe (`probe.exs:13-16`).
- Workload deliberately lives at `/outside` on `tank/workload`, outside Lilly's dataset. `primarycache=metadata` is fixture-only, explicitly not a deployment default (`driver.py:60-63`). Writer repeatedly copies 8 MiB random data with `conv=fsync`; independent reader uses direct I/O and emits a completed-read marker (`default.nix:31-46`). This is generated functional I/O, not a benchmark.
- Fault wrapper at `default.nix:16-30`: timeout sleeps 10 seconds only for `iostat`; malformed fault appends an extra row only after successful native iostat; reload performs real export/import of tank after successful native iostat and propagates failure. No successful counters are fabricated. Probe installs that wrapper only after native identity/capacity binding (`probe.exs:12-23`).
- Explicit local bound: each fault sample is asserted to take `<30` seconds (`driver.py:75-77`). The native sampler's intended interval is `zpool iostat -Hpy ... 1 1` (`lilly/lib/lilly/host/zfs_io.ex:27`), bracketed by native GUID reads (`:25-30`); each intended I/O/GUID command inherits the short 3000 ms utility default (`lilly/lib/lilly/host/command.ex:95-99`, `:227-229`). That sampler is not invoked by this current probe.
- No local `globalTimeout`, command timeout, readiness timeout, `meta.timeout`, or framework feature override is supplied by `default.nix`/`driver.py`. Framework global timeout/default readiness bounds are unoverridden and unevaluated in this inventory; no numeric framework default is asserted. The package input is stable `testPkgs` (`nix/verification/tests/catalog.nix:1-5`, `flake.nix:113-119`).

## Recorded execution and physical acceptance boundary

- `docs/architecture/reviews/2026-09-16-native-zfs-io.md:62-68` records the corrected suite **passed in 81.96 s** with KVM and OpenZFS 2.4.4, source-built collector/protocol round trips, both pools, nonzero outside-dataset direct reads/writes, quota-limited capacity, malformed output, timeout, actual export/import invalidation and recovery. `:38-43` and `:79-80` explicitly retain the earlier nonzero-read failure caused by a weak cached-read fixture. `:76-78` records an earlier **28.97 s interface probe**, explicitly not collector acceptance.
- `docs/architecture/reviews/2026-09-16-zfs-only-provisioning.md:63` records a later **74.83 s** zfs-io machine-script pass, derivation `s0l8fzhyzi2h8ry56ag9wyxagms003w5-vm-test-run-overalls-zfs-io.drv`. Its evidence baseline is `aa5ecf1` plus a credential-rotation fixture correction, not the present checkout (`:98-108`).
- Historical native-I/O review `:44-48` says two virtual pools establish functional collection, not physical IOPS ceilings, density, concurrent guest accounting under pressure, or three-Marshall/two-Lilly behavior; storage/disko/UEFI/provider/physical failure-domain acceptance remains outstanding and ADR-0034 tuning stays proposed. `docs/operations/nixos.md:766-772` and ADR-0033 (`docs/architecture/decisions/0033-nixos-machine-verification.md:228-235`) repeat the functional/physical calibration distinction.
- ZFS-only review `:110-118` disclaims physical-host activation, hardware performance and production rollout from unit/nested VM tests. These historical passes do not establish acceptance of the current collector/schema boundary or a current passing zfs-io derivation.

## Contract and review limits

Reviewed local notes `driver.py:4-7` (`zfs-io-native-interval`) and `probe.exs:1-4` (`zfs-io-real-collector`) plus called-source notes on canonical native identity, pool ownership/accounting, independent diagnostics and unknown capacity. Ancestor root/Nix/test obligations were supplied as already read by the parent; `nix/CONTRACTS`, `nix/verification/tests/CONTRACTS`, `lilly/CONTRACTS`, `lilly/lib/lilly/host/CONTRACTS` and `protocol/CONTRACTS` were inspected for called context. Contract discovery was manual; `cc-check` was unavailable on PATH, and no structural/type/native verification was run. No architecture change is made by this report; ADR-0149 is relevant to the documented source mismatch.
