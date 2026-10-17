# enrico-attempt-replay-bounded-receipts

P1; high confidence; safety with explicit retention bound. Planned SDK assertions **missing** per [fresh scan](../existing-assertions.md). `Always` **"Enrico retained attempt replay starts no second fetch"**: while an attempt is active or its completed receipt remains in Enrico's bounded memory, repeated `{repository ID, attempt ID}` calls return that attempt's current/final status without starting another native Git fetch. After receipt eviction, service restart, or repository removal, this local guarantee ends; Marshall's PostgreSQL attempt/audit decides the next authorized action. `Always` fits each retry inside the retained window.

Source: `enrico/lib/enrico/manager.ex:58-82` checks attempt map before active/budget admission; `:89-123` starts a supervised Git task and records running identity; `:170-225` settles only matching generation and retires monitor; `:257-288` caps completed receipts at 1024 and evicts oldest. `marshall/lib/marshall/enrico/worker.ex:48-63,66-108,112-169` locks current repository attempt and settles only matching result. `marshall/lib/marshall/enrico/CONTRACTS` and ADR-0097 describe durable versus local authority.

History/oracle: drive real Marshall refresh through its API/Oban worker and Enrico HTTPS service against a local Git source fixture that counts actual fetch/clone connections and records requested refs. Lose Enrico status replies, duplicate the same attempt while running and after completion, race a stale `:finished` generation, then fill the 1024 completed-receipt queue and restart Enrico. Observer retains attempted/acknowledged API requests, durable Marshall repository/attempt/audit snapshot, and fixture fetch count independently of Enrico status. Inside retention, no duplicate Git effect. After eviction/restart, do not assert Enrico deduplication; assert the Marshall worker reconciles its durable current attempt rather than treating a missing local receipt as evidence of failed fetch.

SUT guidance: `Reachable` **"Enrico returned retained attempt receipt without new fetch"** at `Manager.handle_call/3:75-76`; `Reachable` **"Enrico evicted oldest completed attempt receipt at cap"** at `complete/4:268-278`. Both are positive path anchors. A separate `AlwaysOrUnreachable` **"Marshall ignored stale Enrico generation settlement"** at `Worker.settle/3:123-125` is useful if stale results are injected; no stale result in a run is acceptable. Safe metadata: repository/attempt IDs, generation equality and closed outcome; no Git URL content or credentials.

Value menu: duplicate calls 1/2/8; active 1/8/9 (configured cap 8); completed receipts 1023/1024/1025; status reply delivered/lost; process running/completed/restarted; Marshall attempt current/replaced/removing. Hosted real Marshall/PostgreSQL/Oban, Enrico and native Git with local source fixture cover this; no guest/KVM needed. Physical ZFS persistence is not implied by hosted receipt checks.

Open question: Can the 1,025-receipt boundary be exercised in a dedicated native-Git campaign within the hosted run budget? The existing generated Manager fixture reaches the cap with controlled Git replies; that evidence must remain distinct from a real Git effect sample.

### Investigation Log

#### Can the cap boundary be reached with real effects?

- Examined: `manager.ex:257-288` and task start at `:89-123`. Found: fixed completed cap 1024, active cap 8. Not found: a low-cost production-compatible fixture for 1025 real Git refreshes. Conclusion: use a bounded dedicated campaign; do not claim cap evidence from a direct state injection alone.

2026-10-13 source follow-up:

- Examined: `enrico/test/manager_history_property_test.exs:349-427,601-618`, `enrico/test/support/controlled_git.sh`, `nix/verification/tests/machines/enrico-service/default.nix:12-40`, and `driver.py:190-245`.
- Found: the generated Manager history uses a controlled Git executable and reaches the receipt cap cheaply, but it is not native Git/network proof. The packaged Nix fixture redirects fixed `github.com` to a local verified HTTPS Git origin and exercises real fetches. A small bare repo can supply 1,025 sequential attempts to one registered repo with distinct attempt IDs, but that is a dedicated longer campaign.
- Conclusion: partial on run cost, resolved on mechanism. Keep the cap-state property backed by generated histories and sample the native fetch counter on selected attempts. Claim cap plus real Git only after executing the dedicated campaign.

#### Who owns retry after local receipt loss?

- Examined: `marshall/lib/marshall/enrico/worker.ex:48-63,66-108` and Enrico manager contract. Found: Marshall retains attempt state in PostgreSQL and worker chooses whether to submit/resume. Not found: exact missing-status branch outcome in this pass. Conclusion: trace worker `attempt_to_run`/`wait_for_attempt` before specifying a post-eviction assertion; the within-retention property is already precise.

2026-10-13 source follow-up:

- Examined: `marshall/lib/marshall/enrico/worker.ex:171-230`, `:66-108`, `enrico/lib/enrico/manager.ex:70-82,131-132,257-288`, and `marshall/lib/marshall/enrico/CONTRACTS`.
- Found: a `missing` Enrico status while Marshall's repository is `refreshing` or `failed` causes `attempt_to_run/1` to allocate a new attempt ID and record `:service_unavailable` as abandonment; a transient transport error resumes the old ID without submitting again. During an active wait, `missing` is a service-unavailable failure, which is settled only for the current locked repository attempt.
- Conclusion: resolved. The durable PostgreSQL row and locked settlement own post-loss reconciliation. After local receipt loss, a *new* authorized attempt may fetch again; no exactly-once native effect claim extends across restart or receipt eviction.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R8`: Keep exact production-capacity saturation in a measured campaign. Use lower-cost bounded replay or refusal histories for routine search; do not claim the full 4,096-worker or 1,025-receipt cap without reaching it. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:213`. Direct Enrico native Git receipt/origin journal, including separate 1025-attempt cap; hosted campaign unexecuted. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
