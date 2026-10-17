# resize-retains-exact-guest-bytes-and-grown-shape

**Candidate:** P0 safety; proposed primary `Always` message **"Confirmed resize preserves fsynced guest bytes and reports exact physical shape"**. Instrumentation is missing per `antithesis/scratchbook/existing-assertions.md`. `Always` checks each confirmed resize against a captured acknowledged-data baseline and the *actual* guest/VMM/native shape. A `Sometimes(condition)` probe, **"Interrupted resize recovered to a boot with retained bytes and exact target shape"**, is appropriate only after a finite injected obstruction heals and one interrupted request reaches a new current boot. It does not weaken the safety assertion for any confirmed request.

## Invariant and sequence

An authorized owner writes a unique marker to the guest root filesystem, fsyncs file and directory, and records its digest/length, current boot ID, disk block length, filesystem length, CPU count, VMM memory, placement and dataset GUID outside the SUT. Submit a resize with a retained request key. For a completed resize, compare the same guest marker bytes after a fresh current boot, unchanged placement/dataset GUID, exact target `blockdev --getsize64 /dev/vda`, grown usable filesystem, guest CPU count and VMM API RAM. Compare the confirmed Marshall shape only *after* these independent probes. On an interrupted or unknown effect, preserve the baseline and holds; never label a pending resize completed from its target row or a command receipt. Originally stopped resize must remain without a running VMM until an explicit later start, when the same data and exact shape are checked.

No source copy is involved in resize. Byte comparison is against the acknowledged pre-resize marker, not a command echo; an in-flight unfsynced write cannot be a durability oracle. Disk growth can be irreversible even when restart fails, so a failed restart is an uncertain/retained state rather than permission to assert old physical size.

## Source trail and fault interleaving

- ADR-0051 (`docs/architecture/decisions/0051-vm-resizing.md:20-64`) requires journaled stopped-only growth, no image copy/shrink, matching physical evidence before confirmed sizes, preserved guest data and current identity; ADR-0053 carries it forward. `marshall/lib/marshall/compute/resize.ex` and `resize_request.ex` persist phases and request identity. `lilly/lib/lilly/vm/driver.ex:430-474` checks stopped unit/jail/network, writes the exact source/target journal before `Disk.resize`, then writes `vm.json`. Cut before/after each of those boundaries, physical grow, result receipt and restart.
- `nix/verification/tests/machines/resize/guest.exs:5-42` seeds a synchronized marker and checks it, CPU count, guest `MemTotal`, exact block length and grown root filesystem inside the current Firecracker boot. `nix/verification/tests/machines/resize/driver.py:297-308,382-452` also probes VMM API CPU/RAM, exact persisted target shape, running and stopped variants. The existing fixture marker is a fixed string and uses `sync`; a workload-owned unique fsync/digest ledger would make mutation or accidental wrong-disk reuse discriminate more sharply. Existing fixture source/historical pass statements do not establish this new Antithesis run.

## Values, boundary, questions

Use the fixture's exact shapes: disk 4,294,967,296→5,368,713,216→6,442,450,944 bytes, running 1 vCPU/512 MiB→2 vCPU/768 MiB, and a stopped resize back to 1 vCPU/512 MiB with further disk growth. Vary failure before/after journal, native truncate/grow, `vm.json`, physical outcome, Marshall commit and restart; retry the identical key and refuse a changed target under that key. Put markers near the beginning and beyond the old filesystem end *after* growth; only the preexisting marker is a pre-resize durability obligation. Keep a neighboring guest as an isolation control.

This needs actual guest/VMM and backing disk observations. Marshall rows or a mocked executor can test request identity and holds only. A hosted TCG guest could substantiate bytes and virtual shape if executed and labeled as TCG, but cannot claim Firecracker/ZFS acceptance or native isolation.

**Open questions:** Can the composed Antithesis guest fixture expose the VMM API and retained block device across a Lilly crash while preserving exact boot/placement identity? `(partial: native resize fixture does; proposed hosted guest composition is unrun)`

### Investigation Log

#### Can the composed Antithesis guest fixture expose VMM shape and retained block device across Lilly crash?

- Examined: `nix/verification/tests/machines/resize/driver.py:297-308,382-452`, `nix/verification/tests/machines/resize/guest.exs:5-42`, `antithesis/scratchbook/deployment-topology.md:90-103`, `antithesis/scratchbook/emulated-guest-feasibility.md`.
- Found: The native fixture reads Firecracker API and guest device/data in a real KVM topology; the hosted plan describes a TCG guest but no executed composed resize acceptance.
- Not established: A hosted result with retained guest boot, disk and independent source of exact target after injected Lilly crash.
- Conclusion: partial; keep native as the full physical evidence path and TCG as a separately scoped future probe.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
