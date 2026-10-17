# ziggy-completion-once-accounted

P0; high confidence; safety. Planned SDK callsites are **missing** per the [fresh scan](../../existing-assertions.md). Proposed `Always` message: **"Ziggy completion acknowledgment conserves one Marshall accounting update"**. For each admitted request with a committed Marshall completion, its immutable accounting projection remains the same after duplicate reports, and the matching daily aggregate contains exactly one contribution from that request. A Ziggy slot may be removed only after an exact matching Marshall acknowledgment. `Always` checks a safety invariant on every settled snapshot; a lost response is not a refusal.

Source: `ziggy/lib/ziggy/spool.ex:87-117` durably reserves a bounded slot before effect, `:128-140` persists a completion once, `:172-198` deletes completed slots on ACK, and `:260-286` syncs the slot/directory or fences on uncertainty. `ziggy/lib/ziggy/reporter.ex:35-65` projects the same completion, requires acknowledged request ID, then asks the spool to remove it. `marshall/lib/marshall/inference/requests.ex:121-155` locks request, accepts identical replay, rejects conflict, and adds totals in one Ledger transaction. `marshall/lib/marshall/inference/totals.ex:11-46` serializes the day/owner/provider/model aggregate with a transaction lock. ADR-0063/0100/0132 describe the intended boundaries.

History and independent oracle: use a local deterministic provider fixture that records each effect request ID and completion bytes separately from Ziggy and Marshall. Admit, produce a completed response, lose the Marshall completion reply, restart Ziggy before/after spool removal, race two reporters, and resend the identical or conflicting projection. Take a consistent PostgreSQL snapshot of admitted request completion plus daily totals before and after each targeted request. To avoid falsely attributing concurrent unrelated usage, use a unique test owner/day/provider/model bucket or subtract an independent pre-run baseline and freeze other writers for the bucket. The provider witness only proves the effect occurred; the durable slot plus DB row establish handoff. An interrupted admitted call with unknown usage contributes an unknown request, never fabricated token amounts.

SUT guidance: `Reachable` **"Ziggy replayed completion after Marshall reply loss"** when a real duplicate is reported, and **"Marshall accepted identical inference completion replay"** at `Requests.complete/3:137-140`; these are useful replay anchors, not violation assertions. A narrowly placed `AlwaysOrUnreachable` **"Ziggy removed only a Marshall acknowledged completion slot"** at spool ACK is suitable because no ACK path in a short run is acceptable but any execution must satisfy it. Metadata must contain only request ID, closed outcome and numeric usage, never provider payload.

Value menu: spool maximum 1/2/default; duplicate reports 1/2/8; one/two reporters; ACK loss before/after DB commit; restart before/after spool delete; complete/unknown usage; zero/positive/boundary token counts; conflict replay. Hosted BEAM services, PostgreSQL and actual spool files cover this property; real external provider delivery is represented by the fixture and is not claimed. Physical guest execution is irrelevant.

Open questions: Which query-level fixture can isolate a daily aggregate bucket without bypassing current credential/host admission? Can an external observer read the spool between deletion and directory sync without treating an uncertain interval as settled?

### Investigation Log

#### Which query-level fixture can isolate a daily aggregate bucket?

- Examined: `inference/totals.ex:11-46`, `inference/requests.ex:121-155`.
- Found: grouping is day, owner, provider and model; no per-request aggregate ledger is exposed.
- Not found: an existing fixture with a dedicated owner/model bucket.
- Conclusion: derive a real credential-backed isolated bucket before evaluating the conservation assertion.

#### Can a spool read during deletion establish absence?

- Examined: `spool.ex:172-198,260-286`.
- Found: removal is followed by directory sync and failure fences further ACKs.
- Not found: an atomic cross-process snapshot API for the spool.
- Conclusion: sample only after ACK response/recovery settles and reconcile uncertain transitions by request ID.
