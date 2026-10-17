# marshall-admission-atomic-allocation

P0; high confidence; safety. Planned Antithesis instrumentation is **missing** in the [fresh scan](../existing-assertions.md). Proposed `Always` message: **"Marshall acknowledged admission has one joined allocation and dispatch job"**. Check each acknowledged *new* VM, by immutable VM ID, against a consistent PostgreSQL snapshot: one placement, matching capacity reservation and network address, one provision operation for its placement/epoch/generation, and its persisted Oban dispatch job. Conversely a deliberately failed admission must publish no rows bearing that new VM ID. `Always` fits an invariant on every completed observation; a timed-out call is an uncertain attempt, not a failed admission.

Source: `marshall/lib/marshall/compute/admission.ex:34-42,46-85` states and scopes the transaction, locks owner/key before history lookup, and returns an existing VM on shape-identical retry; `:220-277` creates VM, placement, reservation, address and operation. `marshall/lib/marshall/compute/operation.ex:1-5,87-107` binds operation creation to its AshOban trigger; `marshall/lib/marshall/compute/ledger.ex:21-26,92-106` wraps the Ash transaction. `marshall/lib/marshall/compute/dispatch.ex:3-16` says the job/control hint is not the durable operation. The accepted design is in ADR-0010/0050; source contracts are hypotheses to test, not passing evidence.

History and oracle: race equal and changed requests with the same owner/key across two Marshall nodes; kill a caller or BEAM worker before commit, immediately after commit, and after a lost HTTP reply; inject job insertion failure. A workload-owned request ledger records owner, key, shape, returned VM ID and definite refusal. A separate read-only PostgreSQL connection takes a transactionally consistent snapshot of base tables (`virtual_machines`, `workload_placements`, `compute_reservations`, network-address and operation tables, `oban_jobs`, audit), including archived history. Cross-check IDs and row counts without trusting an API response or diagnostic event as durable proof. Avoid asserting zero rows for timeout or for an already existing idempotent VM.

SUT guidance: branch anchors at `Admission.run/3` after the idempotency lookup and after `Operation :enqueue` should use distinct `Reachable` messages **"Marshall admission reused durable idempotency history"** and **"Marshall admission reached joined dispatch enqueue"**. A crash hook needs to sit outside/around the actual PostgreSQL commit, not between mock row writes. Safe metadata: owner/VM/placement/job IDs and closed outcome; no request payload or secrets.

Value menu: concurrent callers 1/2/8; same-key identical versus one changed shape/source/name; host candidates 0/1/2; capacity exactly fitting versus one unit short; dispatch insert succeeds/fails; response dropped 0/1; archive state active/archived. Hosted real Marshall plus PostgreSQL and real Oban are required; TCG/native guest execution is unnecessary to establish DB atomicity. Physical allocation is outside this property.

Open questions: Which lifecycle-audit event, if any, is mandatory for a newly admitted VM? `(partial: VM PaperTrail version linkage is concrete; admission-specific lifecycle event cardinality needs an execution probe)`

### Investigation Log

#### Can the harness correlate the AshOban job to operation ID?

- Examined: `compute/operation.ex:52-64,87-107` and `compute/dispatch.ex:1-28`.
- Found: creation invokes `run_oban_trigger(:dispatch)` in the transaction; dispatch is also periodically schedulable.
- Found in the follow-up: `marshall/test/marshall/compute/distributed_admission_test.exs:1201-1211` queries `oban_jobs.args->'primary_key'->>'id'` against operation IDs and asserts the joined count after distributed admission. This is a persisted-row query against the pinned application dependency, not transient process state.
- Not found: a freshly executed database query in this research pass; job retention or execution timing can change how long an individual row remains visible.
- Conclusion: resolved for the admission-time oracle. Query the committed `primary_key.id` with worker/queue qualification in a consistent snapshot before job retention removes it; do not demand one job forever.

#### Which audit row is mandatory?

- Examined: `compute/virtual_machine.ex:11,341` and `compute/operation.ex:133-135`.
- Found in the follow-up: `marshall/priv/repo/migrations/20260915144339_add_compute_admission.exs:217-239` creates `compute_virtual_machines_versions` with `version_source_id` foreign-keyed to VM ID; `marshall/lib/marshall/compute/virtual_machine.ex` has a PaperTrail extension. `marshall/lib/marshall/compute/operation.ex:133-135` invokes `LifecycleAudit` on operation create.
- Not found: a source-backed invariant requiring exactly one particular lifecycle event for every newly admitted VM, or a fresh committed admission row query demonstrating the version/event cardinality.
- Conclusion: partial. Catalog can name VM version linkage as an optional audit cross-check; keep the atomic allocation invariant on VM, placement, reservation, address, operation and enqueued job. Probe a fresh admission's `compute_virtual_machines_versions` and `compute_lifecycle_events` rows before making a particular event mandatory.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/scenarios.py:144`. One serial trusted-operator admission joins a terminal domain receipt to one-statement PostgreSQL VM, placement, reservation, address, provision-operation and dispatch-job rows; no cross-node same-key race, commit-cut run, or positive integrated-host checkpoint. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
