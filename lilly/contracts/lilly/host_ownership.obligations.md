---
modules: [Lilly.Host.BackupSnapshot, Lilly.Host.Collector, Lilly.Host.Command, Lilly.Host.Counters, Lilly.Host.EmptyDirectory, Lilly.Host.Hostd, Lilly.Host.Identity, Lilly.Host.Image, Lilly.Host.ImageCatalog, Lilly.Host.ImagePrewarm, Lilly.Host.ImageTemplate, Lilly.Host.InceptionProof, Lilly.Host.Inventory, Lilly.Host.Lease, Lilly.Host.Limits, Lilly.Host.Lock, Lilly.Host.LockOrder, Lilly.Host.MountTable, Lilly.Host.Ownership, Lilly.Host.Paths, Lilly.Host.Pool, Lilly.Host.PoolQueue, Lilly.Host.PoolSnapshot, Lilly.Host.PrivateFiles, Lilly.Host.Privilege, Lilly.Host.Sockets, Lilly.Host.Storage, Lilly.Host.TemplateSteward, Lilly.Host.UIDReservation, Lilly.Host.Usage, Lilly.Host.ZFS, Lilly.Host.ZFSDataset, Lilly.Host.ZFSIO, Lilly.Host.ZFSNamespaceMounts, Lilly.VM.Disk, Lilly.VM.Driver]
---

# Host Ownership obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.host_ownership.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
