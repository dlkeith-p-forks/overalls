# source-stop-after-committed-placement-holds

P0; medium-high confidence; safety. Planned `AlwaysOrUnreachable` message: **"Clone source interruption follows committed placement and capacity holds"**. When a clone path requests source interruption, the durable transaction must already retain the destination placement, source temporary-disk hold, destination reservation and endpoint transfer slots; abort/cancellation must not strip the recoverable source before destination proof. The source-stop branch is optional, so `AlwaysOrUnreachable` fits its reached checks. This SDK assertion is **missing** in the [fresh scan](../existing-assertions.md).

Source: `marshall/lib/marshall/compute/clone_placement.ex:1-17,69-93,126-155` explicitly prepares source headroom, destination placement/reservation and transfer slots before source interruption. `marshall/lib/marshall/compute/clone_coordinator.ex:47` calls this preparation before driving the clone. `lilly/lib/lilly/transfer/source_cleanup.ex:13` fences local launch after source exports. ADR-0155 defines relocation's separate stopped-only full-copy path with no temporary headroom, so relocation is excluded from this exact hold oracle. Accepted source and ADR claims require a composed test.

Workload and independent oracle: race clone admission, cancellation, host report and source-stop delivery across two Marshall instances. At the instant a physical source-stop is independently observed, take a PostgreSQL consistent snapshot of placement/reservation/transfer slots and inspect source/destination dataset identities; later reconcile pending cleanup and recovery. A Control timeout is uncertain, so read durable intent and physical VM state before classifying. A `Reachable` message **"Clone source stop followed committed placement and holds"** can anchor the rare transition.

Value menu: running versus stopped clone source; same versus distinct destination host; exactly fitting versus insufficient disk/compute; cancel before/after commit; host report before/after lock; lost Control reply; source restore success/refusal. Hosted PostgreSQL/Marshall can establish transaction order with a lower executor seam, but source-stop and ZFS two-copy safety require native or scoped TCG storage/guest execution. Open questions: None.

Answer: The physical stop witness is systemd unit inactivity plus process_snapshot absence for the source placement, tied to the exact stopped outcome ID rather than a request or Control timeout. Immediately before that event sample clone destination WorkloadPlacement and Reservation, source Reservation.temporary_disk_bytes, and source/destination transfer slot records in one repeatable-read PostgreSQL transaction. ClonePlacement persists these before CloneCoordinator proceeds to stop.

### Investigation Log

#### Which physical stop event and reservation fields best witness the clone transition?

- Examined: `marshall/lib/marshall/compute/clone_placement.ex:69-155; marshall/lib/marshall/compute/clone_coordinator.ex:47-65; nix/tests/machines/fleet/scenarios/lifecycle.py:37-60`.
- Found: The physical stop witness is systemd unit inactivity plus process_snapshot absence for the source placement, tied to the exact stopped outcome ID rather than a request or Control timeout. Immediately before that event sample clone destination WorkloadPlacement and Reservation, source Reservation.temporary_disk_bytes, and source/destination transfer slot records in one repeatable-read PostgreSQL transaction. ClonePlacement persists these before CloneCoordinator proceeds to stop.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: resolved; Remove witness-selection question; add exact DB fields and physical stop observer.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
