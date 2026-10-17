# lilly-outcome-replay-exact-ack

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
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

Open questions: Can an observer read journal and DB snapshots under their real
locks without extending the critical crash window enough to mask it?
