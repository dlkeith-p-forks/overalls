# ziggy-completion-once-accounted

P0; high source confidence; safety `Always`, message **"Ziggy completion acknowledgment conserves one Marshall accounting update"**. The SDK assertion is **missing** per [scan](../existing-assertions.md). For each admitted immutable completion, Marshall Request projection and the matching owner/day/provider/model total must gain exactly one contribution, even if commit reply is lost and reporters replay. Identical replays do not add; conflicting or foreign-host completions add zero. A Ziggy slot is removed only after exact matching ACK. Unknown usage stays unknown, and a completion after VM stop can still settle original admitted custody.

## Evidence and fault history

`ziggy/lib/ziggy/spool.ex:87-198,260-286` reserves durable effect space, persists completion, and deletes only after ACK/sync. `reporter.ex:35-65` retries an immutable projection. `marshall/lib/marshall/inference/requests.ex:121-155` locks Request, accepts identical replay, refuses conflict, and adds totals in one Ledger transaction; `totals.ex:11-46` serializes aggregate grouping. Lose Marshall's reply after commit, restart Ziggy before/after slot removal, race reporters, and vary complete/unknown projection. [Focus 01](../discovery/property-candidates-01/ziggy-completion-once-accounted.md) supplies spool and aggregate witness; [focus 03](../discovery/property-candidates-03/inference-accounting-ack-loss-counted-once.md) adds foreign-host, post-stop and 128-report boundary histories.

## Oracle, environment, and instrumentation

Use a real credential-backed isolated aggregate bucket, external provider effect ledger, a consistent PostgreSQL Request/Totals snapshot, and settled spool-file reads. Compare unique accepted projections to the total delta from an independent baseline. Provider effects are tested separately by `ziggy-interrupted-inference-never-reexecutes`; a provider receipt alone cannot prove accounting. Hosted real Ziggy/Marshall/PG/Control/spool suffices. Vary duplicates 1/2/8/128, reporters 1/2, known/partial/unknown usage, ACK loss before/after commit. `Reachable` marks identical replay after lost reply; optional `AlwaysOrUnreachable` at slot removal checks exact ACK.

## Open questions

- Which hosted composition will combine the existing synthetic provider fixture with real Marshall/PostgreSQL current host credentials and a dedicated owner/day/provider/model bucket? The current packaged Ziggy machine uses synthetic Control authority.
- Can the hosted fault setup power-cut the spool filesystem after ACK and directory sync? Process restart can verify recovery behavior, but cannot establish physical power-loss durability.

### Investigation Log

#### Which aggregate bucket is isolated?

- Examined: `totals.ex:11-46` and `requests.ex:121-155`.
- Found: grouping keys are day, owner, provider and model; no per-request aggregate ledger.
- Not found: a ready fixture with an isolated credential-backed bucket.
- Conclusion: retain fixture question; build it before checking exact contribution.

2026-10-13 source follow-up:

- Examined: `marshall/test/marshall/inference/requests_test.exs:1-80,108-155`, `marshall/lib/marshall/inference/totals.ex:11-46`, `nix/verification/tests/machines/ziggy-service/default.nix:94-100`, and `driver.py:1-72`.
- Found: Marshall's test fixture rotates a real current host credential and creates an owner whose Daily row starts absent. Daily keys are day of admission, owner, provider and model; the existing packaged Ziggy machine records provider calls and completions but substitutes a synthetic Control service for Marshall.
- Conclusion: partial on integration, resolved on construction. Use a dedicated owner/VM/host credential and one model/provider in a real Marshall PostgreSQL composition; baseline that exact Daily key and quiesce other writers. Do not infer total conservation from the synthetic Control machine.

#### How can an observer sample spool removal after directory sync/recovery settles?

- Examined: `ziggy/lib/ziggy/reporter.ex:35-57`, `ziggy/lib/ziggy/spool.ex:174-200,260-285,473-480`, and `nix/verification/tests/machines/ziggy-service/driver.py:70-75,135-145`.
- Found: reporter removes only after exact `acknowledged` ID; `Spool.acknowledge/2` removes the file and syncs the directory before removing the in-memory entry. The packaged machine waits until no `*.json` slot remains. A restarted Ziggy re-reads slots from disk, so the observer can require both no slot after ACK and no resurrected slot after process restart.
- Conclusion: resolved for process/restart scope. Read only after confirmed ACK and quiescence, then restart Ziggy and re-read; a physical power-cut claim still needs a faultable filesystem and belongs to the remaining question above.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: durable Ziggy spool ID, independent provider accept log and Marshall aggregate; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `satellite-standin` selects this command with the origin and satellite overlays and a labelled guest stand-in. The command still needs a current running VM; the hosted controlled Lilly pool reports unavailable capacity, so it records unexercised in that graph. The stand-in is not a guest and supplies no VM binding. No hosted run exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Supporting assertion snapshot

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/satellite/scenarios.py:73`. A normal admitted guest inference joins one private provider acceptance to one settled Request and a Daily delta. Exact ACK-loss/replay and restart witnesses are absent, and the hosted guest-to-Audi graph is not ready. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.
