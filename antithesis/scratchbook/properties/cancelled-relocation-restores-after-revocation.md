# cancelled-relocation-restores-after-revocation

P0; high confidence; safety and progress. Primary `Always` message **"Cancelled relocation restores source only after revocation and retains cleanup custody"**. A separate `Sometimes(condition)` message **"Cancelled relocation regained its original source state after physical proof"** means one admitted, healable cancellation records exact source-state restoration after physical proof. Both proposed assertions are **missing** per [fresh scan](../existing-assertions.md).

Source: `marshall/lib/marshall/compute/relocation_cancellation.ex:6-49` serializes user cancellation against handoff under endpoint and VM locks; an intent cannot itself restore execution or free holds. `marshall/lib/marshall/compute/relocation_coordinator.ex:90-102` routes cancellation before handoff and `:241-255` releases stream slots only after both endpoint revocation receipts. `marshall/lib/marshall/compute/relocation_restoration.ex:14-64` waits for source revocation, writes a new source epoch and stop operation, and requires exact physical stop/start proof before marking source restored; `:67-109` bounds failed-start retries to three per ten minutes; `:146-162` retains destination reservation until independent cleanup and both revocations. `:164-225` shows successor VM epoch reused for restored source placement and operation. `marshall/lib/marshall/compute/relocation.ex:89-119` constrains cancellation references. Existing distributed race coverage is `marshall/test/marshall/compute/distributed_admission_test.exs:2567-2760` and focused source restoration is `relocation_sources_test.exs:830-1101`; these are test presence, not hosted native proof.

History: cancel at source stop, transfer, receive and immediately before handoff while another Marshall replica coordinates. Drop source/destination revocation responses independently and replay them; crash a coordinator between accepted cancellation and fresh stop outbox. For an originally running source, withhold physical stop receipt and assert no restart, then deliver exact stop and start receipts; for originally stopped source, assert it remains stopped. Heal all finite faults and complete destination reclamation/source snapshot cleanup.

Independent oracle: consistent DB snapshot of cancellation/commit identity, current source placement and **VM** epoch, stop/start operation IDs and immutable physical outcomes, endpoint revocation receipts, transfer slots, destination reservation and finish marker. Independently inspect source and destination transfer endpoints, native VMM/guest boot identities, disk/snapshot existence and stream custody. No cleanup slot or destination commitment may disappear merely because cancellation was requested or a reply was lost. The `Sometimes` progress precondition excludes permanent endpoint/guest failure, retry-budget exhaustion and operator refusal; those remain retained obligations rather than automatic defects.

SUT guidance: proposed `AlwaysOrUnreachable` **"Cancellation source restart followed exact fresh epoch stop receipt"** at `RelocationRestoration.restart!/2`, `Reachable` **"Cancellation retained destination hold while revocation was unproven"**, and `Reachable` **"Cancellation completed after both endpoint revocations and physical cleanup"** give rare branch anchors. The workload checks both persisted custody and physical effect.

Values: running/stopped original state; cancellation before/after source stop and before handoff; zero/one/both endpoint revocation receipts; stop/start receipt missing/duplicate/exact/stale; retry count 0/1/2/3; fresh/failed/unknown source observation; one/two/three Marshall replicas. Use the configured ten-minute window and recorded host report freshness, not an arbitrary timeout. Service mode establishes durable gating; real TCG/native host evidence is required for stream quiescence and execution restoration. No source restoration is expected after committed handoff, which must refuse cancellation.

Open questions:

- Can the native fixture cut between source revocation and stop without breaking the owner lock? `(partial: no lock-preserving coordinator pause found; test receipt-loss schedule)`

Next probe: Revocation is a committed receipt gate before a fresh source epoch and stop outbox. The inspected native scenarios expose no pause between those two coordinator steps while retaining the production host owner. Probe by pausing the coordinator after the revocation receipt commit, then verify host lock continuity and exact physical stop; until then use response loss as the narrower schedule.

### Investigation Log

#### Can the native fixture cut between source revocation and stop without breaking the owner lock?

- Examined: `marshall/lib/marshall/compute/relocation_restoration.ex:16-51; marshall/lib/marshall/compute/relocation_coordinator.ex:243-255; nix/tests/machines/fleet/scenarios/audi-relocation.py`.
- Found: Revocation is a committed receipt gate before a fresh source epoch and stop outbox. The inspected native scenarios expose no pause between those two coordinator steps while retaining the production host owner. Probe by pausing the coordinator after the revocation receipt commit, then verify host lock continuity and exact physical stop; until then use response loss as the narrower schedule.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Keep an open partial question about a lock-preserving coordinator pause; scope current oracle to response loss and receipts.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
