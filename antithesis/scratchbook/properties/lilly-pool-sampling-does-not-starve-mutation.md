# lilly-pool-sampling-does-not-starve-mutation

P1; medium-high source confidence; conditional liveness `Sometimes(condition)`, message **"Lilly independent pool mutation completes during sustained sampling pressure"**. Missing SDK assertion per [scan](../existing-assertions.md). After finite lock obstruction clears, a still-eligible designated mutation and an independent neighbor should obtain physical receipts while periodic sampling continues. Preconditions include valid authority, capacity, source/image and a measured quiet interval. A companion missing `Always` **"Lilly pool contention preserves retained placement and outcome"** checks that `storage_busy` never converts unavailable observation into physical absence or discards retained intent.

## Evidence and fault history

`lilly/lib/lilly/host/storage.ex:4-51` gives mutations a bounded acquisition attempt and samples zero wait; `control/runtime.ex:252-296,404-478` has one sample in flight and drops ticks; `host/pool.ex:147,191,202,224` classifies busy as unavailable. `marshall/lib/marshall/compute/host_reports.ex:227-241` does not refresh report age from a busy observation. The source note about earlier sampler starvation motivates the schedule but is not current defect proof. [Focus 02](../discovery/property-candidates-02/pool-contention-preserves-neighbor-progress.md) adds preservation of placement/outcome under busy; [focus 05](../discovery/property-candidates-05/lilly-pool-sampling-does-not-starve-mutation.md) specifies two-pool fairness under continuous sampling.

## Oracle, environment, and instrumentation

Run actual Lilly Runtime/native locks and two real ZFS pools in TCG storage or native machine. Block one pool briefly, continue 1-second production sampling, enqueue create/delete/clone/refill plus another pool's eligible work, then release obstruction. Inspect ZFS dataset GUID/content, lock retirement, durable operation receipts and retained reservations; a sample task counter or Ash job alone is insufficient. Vary one/two pools, sample 0/1/continuous, lock hold below/above one-second mutation wait, report age around five-second freshness. A `Reachable` anchor can mark acquisition after sampled contention. Hosted fake Collector tests cadence only, not physical fairness.

## Open questions

- Which measured post-release interval is sufficient for each selected operation? `(partial: operation baseline and hosted two-pool fixture unmeasured)`
- Can hosted TCG maintain two independent real pools with genuine contention under faults? `(partial: operation baseline and hosted two-pool fixture unmeasured)`

Next probe: Storage.locked permits bounded mutation acquisition and Runtime drops or defers samples while one is in flight, but neither supplies an end-to-end post-release completion bound. The repository has multi-host ZFS native fixtures; the hosted TCG design does not yet prove two independently mounted real pools. Probe each operation under a measured quiet interval and two actual pools before assigning a physical-neighbor oracle.

### Investigation Log

#### Which measured post-release interval is sufficient for each selected operation?

- Examined: `lilly/lib/lilly/host/storage.ex:9-30; lilly/lib/lilly/control/runtime.ex:252-313,445-478; nix/verification/tests/machines/fleet/scenarios/capacity.py:114-155; antithesis/scratchbook/emulated-storage-feasibility.md`.
- Found: Storage.locked permits bounded mutation acquisition and Runtime drops or defers samples while one is in flight, but neither supplies an end-to-end post-release completion bound. The repository has multi-host ZFS native fixtures; the hosted TCG design does not yet prove two independently mounted real pools. Probe each operation under a measured quiet interval and two actual pools before assigning a physical-neighbor oracle.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Keep both measured interval and hosted two-pool feasibility partial.

#### Can hosted TCG maintain two independent real pools with genuine contention under faults?

- Examined: `antithesis/scratchbook/emulated-storage-feasibility.md`, `lilly/lib/lilly/host/storage.ex:9-30`, and `nix/verification/tests/machines/fleet/scenarios/capacity.py:114-155`.
- Found: the source lock is per pool and the native fixture has real ZFS observations; the hosted design is a feasibility proposal.
- Not established: two concurrently mounted independent TCG pools with controllable lock contention have not been built or run in this tree.
- Conclusion: partial; run a two-pool hosted bring-up with separate GUIDs and an independent neighbor mutation witness.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. `R7`: Bind contested pool-lock acquisition and release to the same designated operation before measuring post-release progress. An uncontended completion cannot establish this property. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
