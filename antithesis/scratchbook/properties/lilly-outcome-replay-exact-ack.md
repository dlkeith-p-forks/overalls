# lilly-outcome-replay-exact-ack

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
`Always(replayed_identical_facts keep event ID/sequence and ACK(old_ID) cannot clear newer pending_ID)`;
message **"Lilly recovery preserves outcome identity until its exact acknowledgment"**.
This is one stable-outcome custody invariant across interrupted delivery.

Evidence: `lilly/lib/lilly/vm/journal.ex:95-141` (`record/3`) persists validated
facts, reuses exact identical outcome and advances changed facts; `:145-158`
(`acknowledge/2`, `pending/1`) matches only current ID. Actor `:345-459` records
before publishing. Async result `actor.ex:222-242` rereads Store and drops
superseded task results. ADR-0017 requires retained replay and current generation.

History: actual effect finishes, journal records outcome A, Marshall commits A
but loses ACK, Lilly restarts/replays A, then newer intent produces B. Deliver
delayed ACK(A), kill at ACK persistence, reconnect. Repeat exact facts versus
changed state/disk-presence facts; inject older task completion after new intent.

Independent oracle: observer retains real physical effect identity and raw
journal records plus committed Marshall outcomes/reservations. Check identity
stability only for identical facts, not all observations. Changed facts may
replace the latest pending outcome; this is not an unlimited historical queue.
No old outcome may release the newer generation's hold.

Guidance: `Reachable` **"Lilly ignored an acknowledgment for a replaced outcome"**
at mismatched ID with newer pending fact; **"Lilly replayed an outcome after commit reply loss"**
after same ID is observed on two exchanges with independent DB commit witness.
Do not make the reach condition a violation. Safe metadata: placement, revision,
event IDs, sequence, matching boolean; no guest/payload data.

Values: revisions (1,1),(1,2),(2,1); pending ACK delay 0/1/2 exchanges; 1/2/8
duplicate deliveries; outcome sequences 1/2 and MAX-1/MAX in focused boundary
fixture. Hosted real actors/Store/Journal/Marshall cover replay, with native or
TCG guest physical witness for effect truth. Preserve actual supervisor order.

Open questions: None.

Answer: A lock-respecting observer can snapshot after a controlled boundary or owner death, not while holding the live Store/Journal lock during the crash interval. Use external exchange/DB commit timestamps as the in-window history; reopen the journal only after owner release and compare exact pending IDs. That avoids moving the crash boundary with inspection.

### Investigation Log

#### Can the observer take lock-respecting snapshots without masking the crash window?

- Examined: `lilly/lib/lilly/vm/journal.ex:95-158; lilly/lib/lilly/vm/actor.ex:345-459; lilly/lib/lilly/host/lock.ex:41-113`.
- Found: A lock-respecting observer can snapshot after a controlled boundary or owner death, not while holding the live Store/Journal lock during the crash interval. Use external exchange/DB commit timestamps as the in-window history; reopen the journal only after owner release and compare exact pending IDs. That avoids moving the crash boundary with inspection.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: resolved; Remove observer-lock question; specify post-boundary snapshots and external in-window ledger.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
