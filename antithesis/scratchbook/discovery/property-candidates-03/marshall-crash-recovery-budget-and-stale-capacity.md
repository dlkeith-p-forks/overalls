# marshall-crash-recovery-budget-and-stale-capacity

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(each recovery-start consumes durable budget once; stale capacity retains
compute hold; drained/retired/exhausted/measured-shortfall never authorizes start)`;
message **"Marshall crash recovery preserves its budget and waits for fresh capacity proof"**.
Scope is the recovery decision transaction, not arbitrary API retries.

Evidence: `marshall/lib/marshall/compute/outcomes.ex:252-291` (`recover!`,
`recovery_decision!`) keeps future timestamps charged, allows at most three starts
inside 600,000,000 microseconds, leaves stale capacity pending, releases only
compute on terminal refusal; `:304-357` (`resume_recoveries_locked!`,
`restart_after_crash!`) locks current state, checks no pending operation and creates
new generation/start with appended timestamp. `lilly/lib/lilly/vm/executor.ex:517`
labels crashed only after same-revision durable running evidence. ADR-0017/0016.

History: prove running, kill actual guest, commit crash outcome with report stale;
replay crash under response loss and restart Marshall. Deliver valid fresh report,
then duplicate report concurrently from two real application processes. Repeat to
budget exhaustion; test future timestamps after a deliberate supported DB-clock
fault, and drain/retire races. Initial unproven launch failure is a negative control.

Independent oracle: committed VM crash_restart_times, Operation generations,
reservation compute/disk/address holds, host lifecycle and exact reports from real
physical observer. Count DB-authorized recovery operations and actual boot
identities, not job attempts. Physical failure must be independently established.

Guidance: proposed `Reachable` **"Marshall retained crashed VM recovery while capacity evidence was stale"**
at :stale with held compute; **"Marshall resumed retained crash recovery from a fresh fitting report"**
after outer commit; **"Marshall conservatively charged a future crash restart timestamp"**
when future timestamp remains in budget. These are good semantic states, not violations.

Values: 0/1/2/3 retained starts, timestamp ages just below/equal/above 600 seconds
and future time, fresh/expired reports relative to configured deadline,
enough/exactly-full/shortfall capacity, enrolled/draining/retired host. Hosted real
PostgreSQL/services cover transactions. Real TCG/native effects verify guest truth;
clock faults must be explicitly enabled/supported, not presumed automatic.

Open questions: Can current hosted DB-time fault enablement reach backward time
without replacing `Ledger.now/0` with a fake source?
