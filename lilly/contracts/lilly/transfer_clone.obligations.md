---
modules: [Lilly.Clone.Effects, Lilly.Clone.Reason, Lilly.Clone.Runtime, Lilly.Transfer.CloneCopy, Lilly.Transfer.CloneCopyJournal, Lilly.Transfer.DestinationCleanup, Lilly.Transfer.DestinationRevocation, Lilly.Transfer.Endpoint, Lilly.Transfer.ExportRequest, Lilly.Transfer.Exporter, Lilly.Transfer.ImportCleanup, Lilly.Transfer.ImportJournal, Lilly.Transfer.Importer, Lilly.Transfer.Key, Lilly.Transfer.KeyRuntime, Lilly.Transfer.Permit, Lilly.Transfer.PermitJournal, Lilly.Transfer.Probe, Lilly.Transfer.ProbeRequest, Lilly.Transfer.ReadinessProbe, Lilly.Transfer.ReceiveRuntime, Lilly.Transfer.ReceivedDataset, Lilly.Transfer.Receiver, Lilly.Transfer.ResumeToken, Lilly.Transfer.SSH, Lilly.Transfer.SnapshotIndex, Lilly.Transfer.SnapshotJournal, Lilly.Transfer.SnapshotOwnership, Lilly.Transfer.Source, Lilly.Transfer.SourceCleanup, Lilly.Transfer.SourceExport, Lilly.Transfer.SourceRevocation, Lilly.Transfer.SourceRuntime, Lilly.Transfer.SourceSnapshotCleanup, Lilly.Transfer.SourceSnapshots, Lilly.Transfer.Stream]
---

# Transfer Clone obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.transfer_clone.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### lilly.transfer_clone.I2 — Invalid transfer identity fails closed
- **scope:** `Lilly.Transfer.Key.ensure/4`
- **must:** Reject malformed transfer identity inputs without creating key state.
- **kind:** security
- **status:** active

### lilly.transfer_clone.I3 — Export request grammar is exact and shell inert
- **scope:** `Lilly.Transfer.ExportRequest.parse/1` and `token?/1`
- **must:** Accept only canonical v4 relocation commands and bounded hexadecimal resume tokens; reject alternate whitespace, shell syntax, malformed UUIDs, and oversized tokens without normalization.
- **kind:** security
- **status:** active
