---
modules: [Lilly.Control.StatusServer, Lilly.Host.BackupSnapshot, Lilly.Host.Collector, Lilly.Host.Command, Lilly.Host.Counters, Lilly.Host.EmptyDirectory, Lilly.Host.Hostd, Lilly.Host.Identity, Lilly.Host.Image, Lilly.Host.ImageCatalog, Lilly.Host.ImagePrewarm, Lilly.Host.ImageTemplate, Lilly.Host.InceptionProof, Lilly.Host.Inventory, Lilly.Host.Lease, Lilly.Host.Limits, Lilly.Host.Lock, Lilly.Host.LockOrder, Lilly.Host.MountTable, Lilly.Host.Ownership, Lilly.Host.Paths, Lilly.Host.Pool, Lilly.Host.PoolQueue, Lilly.Host.PoolSnapshot, Lilly.Host.PrivateFiles, Lilly.Host.Privilege, Lilly.Host.Sockets, Lilly.Host.Storage, Lilly.Host.TemplateSteward, Lilly.Host.UIDReservation, Lilly.Host.Usage, Lilly.Host.ZFS, Lilly.Host.ZFSDataset, Lilly.Host.ZFSIO, Lilly.Host.ZFSNamespaceMounts, Lilly.VM.Disk, Lilly.VM.Driver]
---

# Host Ownership obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.host_ownership.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### lilly.host_ownership.I2 — Memory observations conserve capacity
- **scope:** `Lilly.Host.Inventory.parse_memory/1`
- **must:** Parse required Linux memory fields in bytes, derive used as total minus available, and reject incomplete observations.
- **kind:** functional
- **status:** active

### lilly.host_ownership.I3 — Unknown CPU topology stays unknown
- **scope:** `Lilly.Host.Inventory.parse_cpu/1`
- **must:** Count unique logical processors while returning nil physical topology when source fields are absent; duplicate processors are rejected.
- **kind:** functional
- **status:** active

### lilly.host_ownership.I4 — ZFS observations are complete and bounded
- **scope:** `Lilly.Host.ZFSIO.parse_rates/2` and `parse_identities/2`
- **must:** Native rows MUST be complete, unique, bounded, and tied to requested pool names; malformed, duplicate, overflowing, or extra rows MUST remain unavailable.
- **kind:** security
- **status:** active

### lilly.host_ownership.I5 — Pool turns are exclusive and releaseable
- **scope:** `Lilly.Host.PoolQueue.enter/4` and `leave/2`
- **must:** A held directory turn MUST reject a zero-wait second entrant as busy; releasing the holder MUST make the lane available again, while an unqueued environment remains a successful no-op turn.
- **kind:** ordering
- **status:** active
