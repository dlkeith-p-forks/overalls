# marshall-admission-atomic-allocation

P0; high confidence; safety. Planned Antithesis instrumentation is **missing** in the [fresh scan](../../existing-assertions.md). Proposed `Always` message: **"Marshall acknowledged admission has one joined allocation and dispatch job"**. Check each acknowledged *new* VM, by immutable VM ID, against a consistent PostgreSQL snapshot: one placement, matching capacity reservation and network address, one provision operation for its placement/epoch/generation, and its persisted Oban dispatch job. Conversely a deliberately failed admission must publish no rows bearing that new VM ID. `Always` fits an invariant on every completed observation; a timed-out call is an uncertain attempt, not a failed admission.

Source: `marshall/lib/marshall/compute/admission.ex:34-42,46-85` states and scopes the transaction, locks owner/key before history lookup, and returns an existing VM on shape-identical retry; `:220-277` creates VM, placement, reservation, address and operation. `marshall/lib/marshall/compute/operation.ex:1-5,87-107` binds operation creation to its AshOban trigger; `marshall/lib/marshall/compute/ledger.ex:21-26,92-106` wraps the Ash transaction. `marshall/lib/marshall/compute/dispatch.ex:3-16` says the job/control hint is not the durable operation. The accepted design is in ADR-0010/0050; source contracts are hypotheses to test, not passing evidence.

History and oracle: race equal and changed requests with the same owner/key across two Marshall nodes; kill a caller or BEAM worker before commit, immediately after commit, and after a lost HTTP reply; inject job insertion failure. A workload-owned request ledger records owner, key, shape, returned VM ID and definite refusal. A separate read-only PostgreSQL connection takes a transactionally consistent snapshot of base tables (`virtual_machines`, `workload_placements`, `compute_reservations`, network-address and operation tables, `oban_jobs`, audit), including archived history. Cross-check IDs and row counts without trusting an API response or diagnostic event as durable proof. Avoid asserting zero rows for timeout or for an already existing idempotent VM.

SUT guidance: branch anchors at `Admission.run/3` after the idempotency lookup and after `Operation :enqueue` should use distinct `Reachable` messages **"Marshall admission reused durable idempotency history"** and **"Marshall admission reached joined dispatch enqueue"**. A crash hook needs to sit outside/around the actual PostgreSQL commit, not between mock row writes. Safe metadata: owner/VM/placement/job IDs and closed outcome; no request payload or secrets.

Value menu: concurrent callers 1/2/8; same-key identical versus one changed shape/source/name; host candidates 0/1/2; capacity exactly fitting versus one unit short; dispatch insert succeeds/fails; response dropped 0/1; archive state active/archived. Hosted real Marshall plus PostgreSQL and real Oban are required; TCG/native guest execution is unnecessary to establish DB atomicity. Physical allocation is outside this property.

Open questions: Can the harness correlate the AshOban job to operation ID from persisted job args across the pinned AshOban version without relying on transient in-process state? Which audit table/version row should be mandatory for a newly created VM when PaperTrail evolves?

### Investigation Log

#### Can the harness correlate the AshOban job to operation ID?

- Examined: `compute/operation.ex:52-64,87-107` and `compute/dispatch.ex:1-28`.
- Found: creation invokes `run_oban_trigger(:dispatch)` in the transaction; dispatch is also periodically schedulable.
- Not found: pinned persisted `oban_jobs.args` shape in this pass. The oracle should derive the correlation from a fixture row before implementing the assertion.
- Conclusion: open source-resolvable implementation question; the VM/placement/reservation/operation subset is already checkable.

#### Which audit row is mandatory?

- Examined: `compute/virtual_machine.ex:11,341` and `compute/operation.ex:133-135`.
- Found: PaperTrail/LifecycleAudit hooks exist on the resources.
- Not found: exact persisted audit table and row linkage for this admission path.
- Conclusion: keep audit in the evidence query plan but do not claim a precise cardinality until schema inspection.
