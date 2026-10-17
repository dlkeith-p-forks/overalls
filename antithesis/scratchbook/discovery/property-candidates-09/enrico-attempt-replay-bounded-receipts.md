# enrico-attempt-replay-bounded-receipts

P1; high confidence; safety with explicit retention bound. Planned SDK assertions **missing** per [fresh scan](../../existing-assertions.md). `Always` **"Enrico retained attempt replay starts no second fetch"**: while an attempt is active or its completed receipt remains in Enrico's bounded memory, repeated `{repository ID, attempt ID}` calls return that attempt's current/final status without starting another native Git fetch. After receipt eviction, service restart, or repository removal, this local guarantee ends; Marshall's PostgreSQL attempt/audit decides the next authorized action. `Always` fits each retry inside the retained window.

Source: `enrico/lib/enrico/manager.ex:58-82` checks attempt map before active/budget admission; `:89-123` starts a supervised Git task and records running identity; `:170-225` settles only matching generation and retires monitor; `:257-288` caps completed receipts at 1024 and evicts oldest. `marshall/lib/marshall/enrico/worker.ex:48-63,66-108,112-169` locks current repository attempt and settles only matching result. `marshall/lib/marshall/enrico/CONTRACTS` and ADR-0097 describe durable versus local authority.

History/oracle: drive real Marshall refresh through its API/Oban worker and Enrico HTTPS service against a local Git source fixture that counts actual fetch/clone connections and records requested refs. Lose Enrico status replies, duplicate the same attempt while running and after completion, race a stale `:finished` generation, then fill the 1024 completed-receipt queue and restart Enrico. Observer retains attempted/acknowledged API requests, durable Marshall repository/attempt/audit snapshot, and fixture fetch count independently of Enrico status. Inside retention, no duplicate Git effect. After eviction/restart, do not assert Enrico deduplication; assert the Marshall worker reconciles its durable current attempt rather than treating a missing local receipt as evidence of failed fetch.

SUT guidance: `Reachable` **"Enrico returned retained attempt receipt without new fetch"** at `Manager.handle_call/3:75-76`; `Reachable` **"Enrico evicted oldest completed attempt receipt at cap"** at `complete/4:268-278`. Both are positive path anchors. A separate `AlwaysOrUnreachable` **"Marshall ignored stale Enrico generation settlement"** at `Worker.settle/3:123-125` is useful if stale results are injected; no stale result in a run is acceptable. Safe metadata: repository/attempt IDs, generation equality and closed outcome; no Git URL content or credentials.

Value menu: duplicate calls 1/2/8; active 1/8/9 (configured cap 8); completed receipts 1023/1024/1025; status reply delivered/lost; process running/completed/restarted; Marshall attempt current/replaced/removing. Hosted real Marshall/PostgreSQL/Oban, Enrico and native Git with local source fixture cover this; no guest/KVM needed. Physical ZFS persistence is not implied by hosted receipt checks.

Open questions: How can the test fill 1025 completed receipts cheaply while preserving a real native Git effect per sampled attempt? Which Marshall status path is authoritative after Enrico receipt eviction or restart?

### Investigation Log

#### Can the cap boundary be reached with real effects?

- Examined: `manager.ex:257-288` and task start at `:89-123`. Found: fixed completed cap 1024, active cap 8. Not found: a low-cost production-compatible fixture for 1025 real Git refreshes. Conclusion: use a bounded dedicated campaign; do not claim cap evidence from a direct state injection alone.

#### Who owns retry after local receipt loss?

- Examined: `marshall/lib/marshall/enrico/worker.ex:48-63,66-108` and Enrico manager contract. Found: Marshall retains attempt state in PostgreSQL and worker chooses whether to submit/resume. Not found: exact missing-status branch outcome in this pass. Conclusion: trace worker `attempt_to_run`/`wait_for_attempt` before specifying a post-eviction assertion; the within-retention property is already precise.
