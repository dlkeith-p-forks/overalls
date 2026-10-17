# Host maintenance and retirement review

## Scope and evidence

The authorized platform implementation adds audited operator drains, retained
stops, guarded resume and empty-host retirement under
[ADR-0026](../decisions/0026-host-maintenance-and-retirement.md). It extends
ADRs 0005/0006/0016/0017/0025 and reuses ADR-0019's terminal invalidation.
No shared protocol change is required. The root instruction to implement the plan
authorizes this work; stop-and-retain is the stated default maintenance behavior.

The [coordinator](../../../marshall/lib/marshall/compute/drains.ex) holds the host
lock before the drain and VM rows. Admission, user starts, recovery and outcomes
already share that host lock. The [Ash resource](../../../marshall/lib/marshall/compute/host_drain.ex)
uses AshPaperTrail and AshOban; Cedar grants its actions only to the internal
coordinator actor. Requests and stops commit with their jobs. Batch size is twenty,
continuations have distinct job arguments, and periodic scheduling recovers work.

Retirement checks live VMs, held reservations, active addresses including archived
VM associations, and fresh empty physical pool allocations. Credentials are
revoked in the same transaction. The [migration](../../../marshall/priv/repo/migrations/20260916032917_host_maintenance.exs)
preserves historical user work and identifies prior unkeyed recovery starts.
Downgrade refuses to discard provenance or drain history.

## Findings and disposition

1. **High — fixed implementation defect: transient local contention could undo a
   confirmed stopped observation.** The real three-guest drain first observed all
   guests stopped, then timed out with two `unknown/cleanup_failed` states. Each
   stopped actor repeatedly re-entered network cleanup; shared lock acquisition
   failure became a new unknown outcome. The [executor](../../../lilly/lib/lilly/vm/executor.ex)
   now defers execution/network lock unavailability for stops and deletes, matching
   existing start retry behavior. This preserves the prior durable observation
   without releasing an unconfirmed reservation. Other physical cleanup failures
   still produce unknown. The real root probe deliberately holds the network lock;
   [actor regression](../../../lilly/test/vm/actor_test.exs) verifies that a retry
   preserves the stopped journal result across restart. ADRs 0017/0026.
2. **High — fixed integration defect: operator startup lacked job insertion
   infrastructure.** Enrollment's small runtime previously omitted Oban entirely.
   Drain requests require its registry/configuration to enqueue atomically. The
   [operator application](../../../marshall/lib/marshall/application.ex) now starts
   Oban with queues, plugins, leadership and staging disabled. Serving instances
   remain responsible for work. Verification must inspect Oban's own registry;
   it does not register its supervisor directly under the `Oban` atom. ADRs 0025/0026.
3. **Medium — fixed implementation defect: null equality hid open drain rows.**
   The initial lookup used a dynamic `closed_at: nil` equality. Explicit Ash
   `is_nil(closed_at)` now selects the unique open drain. Worker and authenticated
   exchange tests prove physical outcomes advance confirmation. ADR-0026.
4. **Retirement rejection was correct.** A fresh report sampled just before the
   last deletion still listed a disk after its cleanup outcome arrived. The KVM
   harness initially expected immediate retirement; it now waits for a subsequent
   fresh empty pool report. Production retains both checks. Freshness alone does
   not mean that a report includes the latest operation. ADRs 0006/0026.

## Verification

- [Drain tests](../../../marshall/test/marshall/compute/drains_test.exs) exercise
  actual generated AshOban workers, 21-guest continuation, idempotency, stale and
  unknown observations, recovery suppression, Cedar rejection, retained data,
  archived-address inconsistencies and randomized reordered outcomes.
- [Three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
  pass concurrent drain/start/provision and duplicate-worker scenarios. Injected
  initial/continuation job failure rolls back admission or the entire stop batch.
  verifies session archival and writer fencing during a maintenance stop.
- [Disposable database check](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/scripts/verify_maintenance_migration.exs)
  passes historical backfill, admission/provenance constraints and rollback refusal.
  It leaves existing enabled hosts normal and removes only its temporary database.
- Lilly precommit passes 82 cases (18 properties, 64 tests), runtime/compiler/ADR
  checks and Dialyzer with no errors. Both production releases build.
- Built Marshall release commands pass enrollment/rotation regression checks,
  drain enqueue/idempotency, status, synthetic fresh-host resume and retirement.
  With `PHX_SERVER=true`, Oban's registry/config confirms no queue consumers,
  plugins, leadership or staging, and the endpoint is absent. Captured outputs
  contain no issued credentials or environment secrets; named fixtures are removed.
- Complete real KVM/HTTPS execution run passes: all three profile guests reach
  running; terminal relay and Lilly crash recovery work; drain confirms stops;
  held network lock defers reconciliation; resume leaves guests stopped until
  explicit starts; guest data persists; bounded crash recovery and credential
  rotation work; deletion retires actors; fresh empty pool reports permit host
  retirement and credential fencing. Physical and database fixtures are cleaned.
- Final Marshall precommit passes 209 cases (21 properties, 188 tests), including
  the three-node deletion/worker race, plus six browser terminal state tests.
  Four root-host tests remain excluded from this standard gate; the KVM harness
  supplies the real execution evidence for this change. Compiler/runtime checks
  pass. Dialyzer has no new errors, with the one existing narrow upstream exclusion.
  `mix ash.codegen --check` passes without schema drift. The structural validator
  passes all 26 ADRs. ADR-0026 is accepted and implemented.

The [KVM harness](../../../marshall/scripts/smoke_execution.exs) includes actual
three-profile shutdown, retained disk content, explicit starts after resume,
network-lock deferral and empty-host retirement. It cleans physical fixtures before
their database history. The browser-specific extension was not rerun for this
change; the existing HTTPS terminal probe runs in the integration harness.

## Remaining work

The [operator guide](../../operations/host-maintenance.md) documents prerequisites and the
difference between historical confirmation and current quiescence. Install the
migration and compatible code on all Marshall nodes, plus the updated Lilly
executor, before enabling this workflow.
There is no migration of guest disks or forced resource release for lost hosts.

Deployment-specific shutdown/reinstallation, backup procedures and key custody
remain operational work. The full platform still requires deployment automation,
HA PostgreSQL, a second independent KVM host, terminal failover/load acceptance and
measured workload targets before any 100-node capacity claim. These are explicit
unimplemented requirements, not evidence against the local maintenance contract.

## Reproduction

Use the pinned `devenv shell`. Run `mix precommit` in Marshall and Lilly, then
`mix ash.codegen --check` in Marshall. Run the historical-data check from Marshall
with `MIX_ENV=test mix run --no-start scripts/verify_maintenance_migration.exs`.
The test PostgreSQL account needs permission to create its disposable database.

For real execution, use the dedicated-host command in
[Lilly's historical integration guide](https://github.com/antithesishq/kittens/blob/5af65d3fe47626523707d7aafe2c1993f91e568c/lilly/README.md#marshall-to-firecracker-integration).
This run used `devenv build outputs.guest outputs.vmm outputs.hostTools`, static
Firecracker/jailer 1.16.1 and the pinned NixOS guest. Pass canonical executable
paths for dtach/unshare; the runtime rejects symlink launcher paths. The release
command smoke used `MIX_ENV=prod mix release --overwrite`, the migrated test DB,
private temporary keys/files and a synthetic empty-host report; physical execution
is established separately by the KVM harness.
