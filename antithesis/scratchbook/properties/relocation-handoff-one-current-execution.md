# relocation-handoff-one-current-execution

P0; high confidence; safety. Proposed `Always` message **"Relocation handoff has one current placement epoch and one activation outbox"** on consistent committed snapshots, plus a separate physical condition that source and destination are never both executing as current authority. SDK instrumentation is **missing** per [fresh scan](../existing-assertions.md). The successor here is the **VM execution epoch**, not the host Control connection epoch.

Source: `marshall/lib/marshall/compute/relocation_coordinator.ex:18-45` locks both endpoint hosts in sorted order then the VM, and `:123-166` commits a probe-bound source stop intent. `marshall/lib/marshall/compute/relocation_receives.ex:173-185` requires final source-confirmed receive evidence. `marshall/lib/marshall/compute/relocation_coordinator.ex:174-239` commits destination placement/epoch/generation, exact activation operation and relocation references together, releasing source compute but retaining both disks. `marshall/lib/marshall/compute/relocation_readiness_state.ex:94-129` requires exact physical activation evidence before readiness. `marshall/lib/marshall/compute/relocation_cleanup.ex:19-27,63-80` retains source disk until delete and key-retirement proofs. `marshall/lib/marshall/compute/relocation.ex:117-141` enforces a successor epoch. ADR-0155 makes every move a stopped full copy. Existing `distributed_admission_test.exs:2567,3224` races three Marshall nodes; it does not establish a new hosted/native run.

History: take a real running VM on source and a reachable destination, admit one relocation, prove destination connectivity, stop source with physical receipt, transfer/import the controlled disk, and race two Marshall coordinators with result delivery and response loss. Also exercise an originally stopped VM. At the handoff edge, kill a coordinator before/after commit and replay the work. Keep a sentinel guest workload that records boot identity and writable storage effects on each host.

Independent oracle: one fresh DB snapshot joins VM current placement/epoch/generation, relocation `committed_at` and activation operation, source/destination reservations and outbox job. Compare to independent native VMM/guest process identities and a guest-owned monotonic sentinel. Before commit only source tuple is current; after commit exactly destination tuple is current with one activation outbox and no concurrently writable old source. Imported bytes or API success alone are not proof. If physical witness is unavailable, label the result DB authority only.

SUT guidance: `AlwaysOrUnreachable` **"Relocation commit references exact destination activation and retained source disk"** at the optional committed path, and `Reachable` **"Relocation handoff committed after physical source stop and final import"** at the post-commit event, provide branch/replay anchors. The primary workload `Always` checks persisted and physical state.

Values: original running/stopped; one/two/three Marshall coordinators; response lost before/after commit; source/destination host report fresh/expired; final import missing/present; guest activation delay and failure; operation queue size 0/1/max configured. Stable shared PostgreSQL primary establishes cross-replica serialization; actual TCG/native host storage and VMMs are required for one-execution/no-dual-writer evidence. No automatic database HA is assumed.

Open questions:

- Which native observer can identify both VMM custody and guest write authority during handoff? `(partial: VMM observer exists; synchronized dual-host write witness unproven)`

Next probe: Native fleet helpers can snapshot VMM process custody, and guest SSH can produce a boot ID or write sentinel. The inspected relocation scenario does not time-align a source and destination writable sentinel with the handoff commit. Probe per-host VMM PID/start time/cgroup and guest-owned monotonically numbered writes on both hosts while sampling one DB commit identity; absence of a guest response alone is not absence of execution.

### Investigation Log

#### Which native observer can identify both VMM custody and guest write authority during handoff?

- Examined: `nix/tests/machines/fleet/scenarios/submission-recovery.py:79-86; nix/tests/machines/fleet/scenarios/user-ssh-journey.py:626-655; marshall/lib/marshall/compute/relocation_coordinator.ex:174-239`.
- Found: Native fleet helpers can snapshot VMM process custody, and guest SSH can produce a boot ID or write sentinel. The inspected relocation scenario does not time-align a source and destination writable sentinel with the handoff commit. Probe per-host VMM PID/start time/cgroup and guest-owned monotonically numbered writes on both hosts while sampling one DB commit identity; absence of a guest response alone is not absence of execution.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Keep partial simultaneous physical/writable oracle; DB authority check remains separate.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
