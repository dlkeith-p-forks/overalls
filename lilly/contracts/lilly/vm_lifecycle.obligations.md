---
modules: [Lilly.Lifecycle, Lilly.Lifecycle.BackupHistory, Lilly.Lifecycle.BackupSnapshot, Lilly.Lifecycle.CloneCopy, Lilly.Lifecycle.Dataset, Lilly.Lifecycle.Execution, Lilly.Lifecycle.GuestTrust, Lilly.Lifecycle.ImageTemplate, Lilly.Lifecycle.Import, Lilly.Lifecycle.Journal, Lilly.Lifecycle.Observability, Lilly.Lifecycle.Permit, Lilly.Lifecycle.Persist, Lilly.Lifecycle.Provisioning, Lilly.Lifecycle.PublicationDiagnostics, Lilly.Lifecycle.Resize, Lilly.Lifecycle.Resource, Lilly.Lifecycle.SnapshotPointer, Lilly.Lifecycle.SnapshotSet, Lilly.Lifecycle.WorkspaceSource, Lilly.VM.API, Lilly.VM.Actor, Lilly.VM.Boot, Lilly.VM.Config, Lilly.VM.Credentials, Lilly.VM.DeleteRetry, Lilly.VM.Disk, Lilly.VM.Driver, Lilly.VM.Executable, Lilly.VM.Executor, Lilly.VM.Flush, Lilly.VM.GuestTrust, Lilly.VM.InceptionExchange, Lilly.VM.Intent, Lilly.VM.Jail, Lilly.VM.Journal, Lilly.VM.Logging, Lilly.VM.Observation, Lilly.VM.Provisioning, Lilly.VM.Readiness, Lilly.VM.Spec, Lilly.VM.Unit, Lilly.VM.WorkloadBundle, Lilly.VM.WorkspaceSource]
---

# Vm Lifecycle obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.vm_lifecycle.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### lilly.vm_lifecycle.I2 — VM specifications validate before effects
- **scope:** `Lilly.VM.Spec.new/1` and `storage/1`
- **must:** Reject invalid identities or resource shapes and clear delivery-only workspace data from persisted storage shape.
- **kind:** security
- **status:** active

### lilly.vm_lifecycle.I3 — Persisted storage shape excludes delivery sources
- **scope:** `Lilly.VM.Spec.storage/1`
- **must:** Storage identity MUST clear optional workspace delivery data while preserving the validated VM specification fields.
- **kind:** persisted-format
- **status:** active

### lilly.vm_lifecycle.I4 — Liveness evidence fails closed and owns rows
- **scope:** `Lilly.Execution.Liveness.step/2` and `rows/1`
- **must:** A fresh liveness state MUST hold no rows; boot evidence MUST publish only the boot row, running evidence MUST hold both rows, inconclusive evidence MUST have no effects, and invalid events MUST be rejected.
- **kind:** security
- **status:** active
