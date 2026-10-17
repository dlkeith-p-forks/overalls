# Capacity admission and Cedar implementation review

## Scope and evidence

This review covers the Compute Ash domain, database admission/host reporting,
Cedar entry points, AshOban operation notification, VM paper trail, JSON logging,
and regression/property/three-node tests. It implements another portion of the
authorized platform plan; the overall vertical slice remains incomplete.

Review [ADR-0010](../decisions/0010-capacity-admission-transactions.md) for the
transaction and report contracts and links to the implementation. The original
Marshall source relocation remains staged independently of these changes;
pre-existing generated UI and starter work are preserved.

Affected decisions: ADR-0002, ADR-0003, ADR-0005, ADR-0006, ADR-0008, ADR-0009,
and new ADR-0010. Existing rationale remains accepted; only implementation
evidence/status is updated. No record is superseded.

## Findings

### Resolved implementation defects

- Ash notifications initially escaped collection inside direct Repo transactions.
  Coordinator transactions now use `Ash.transact`, which collects notifications
  and sends them after successful commit. Durable operations are the authority;
  notification delivery is only a latency hint.
- A closed connection's late report could otherwise restore host freshness.
  Disconnect now increments the persisted epoch while holding the host lock;
  tests cover old reports and old disconnects after reconnect.
- Disk credit must not include orphan allocations or credit beyond logical
  reservations. Budget properties verify materialization-invariant admission,
  and malformed report totals are rejected before any pool update.

### High: host execution and observation remain unimplemented

Evidence: [Dispatch](../../../marshall/lib/marshall/compute/dispatch.ex) only
notifies a relay; no authenticated Lilly transport or Firecracker driver exists.
The ledger cannot establish physical capacity or lifecycle behavior by itself.
Complete authenticated enrollment, cgroup/device collection, consistent disk
sampling and pool-overlap checks before enabling hosts for remote provisioning.
No HTTP/LiveView provisioning endpoint is exposed in this stage.

### High: lifecycle, isolation and terminal requirements remain unimplemented

VMs have initial intent and durable operations, but no confirmed stop/start/delete,
address reservation, archival/cleanup, bounded recovery, independent VM/console
supervision, NixOS guest, NAT/isolation or terminal writer enforcement yet.
Generation fields and role-policy tests do not prove those runtime behaviors.
Two actual KVM hosts remain required for end-to-end validation.

### Medium: assurance and scale remain partial

Cedar policies are compiled and schema-validated using the real native evaluator.
The Ash bridge protects provision and internal compute actions; persisted sharing,
record-scoped user reads and established-session revocation still need implementation.
Paper trail covers initial VM intent, not all future lifecycle/grant actions.
AshCloak/key management and archival are still absent. JSON logging is configured
in Marshall; Lilly and complete HTTP/terminal redaction still need coverage.

Three test instances use independent BEAM processes and Repo pools on one machine
with one PostgreSQL server. This proves the exercised transaction races, not HA
PostgreSQL, network partitions, rolling compatibility, 100-node scale or VM load.
Per-host reservation scans need representative workload measurements.

## Dependency review

`ex_cedar` 0.1.2 and `logger_json` 7.0.4 are published packages. Cedar requires
Rustler 0.38. Mishka 0.0.9 pins an older igniter_js whose Rustler requirement
conflicts. A narrow development-only override uses published igniter_js 0.5.0;
its optional dialect argument preserves the existing JavaScript call arities.
No generated UI is replaced. Native binding and JS compatibility probes are part
of validation; no blanket Rustler constraint override is used.

Primary documentation: [ExCedar source](https://github.com/edlontech/ex_cedar),
[igniter_js 0.5.0 changelog](https://github.com/ash-project/igniter_js/blob/v0.5.0/CHANGELOG.md),
[LoggerJSON configuration](https://logger-json.hexdocs.pm/LoggerJSON.html), plus
installed Ash/AshOban/AshPaperTrail source and documentation.

## Verification

Initial targeted verification passed 15 tests and two properties, including
three independent Marshall nodes racing nine requests for two CPU slots and nine
identical requests producing one VM. A database-triggered Oban insertion failure
left no VM, reservation, operation or audit version. No sleeps simulate ordering.

Final verification passed under Elixir 1.20.4 / OTP 29.0.6:

- Marshall `mix precommit`: 39 tests and four properties, including all three-node
  tests, duplicate AshOban worker delivery, disk/RAM exhaustion, report/disconnect
  fencing, and the existing governance/web suite. Compiler and test warnings are
  errors. An expected database connection-error log is emitted by the deliberately
  failing Oban-insert test; its transaction rolls back and assertions pass.
- Dialyzer passed with the same one exact upstream AshAuthenticationPhoenix
  typespec exclusion documented in the [toolchain review](2026-09-15-toolchain.md).
  No new exclusions; no unnecessary filters.
- `mix ash_postgres.generate_migrations --check` passed after reviewing the new
  migration. Its `up` creates compute tables and references only; destructive
  statements belong to the rollback path. Existing tables/data are preserved.
- ADR validation passed for ten records; formatting and `git diff --check` passed.
- Native probes confirmed Cedar engine 4.11.2, igniter_js import inspection and
  insertion with its existing JavaScript call arities, and JSON correlation
  metadata with an unlisted token field excluded.
- All three peer applications stopped after the distributed suite. Source hashes
  against the original workspace backup confirm pre-existing assets, generated
  UI and unrelated application work remain intact. Intentional original-file
  changes in this slice are Mix dependencies/gates, formatter import, application
  supervision, configuration and distributed test selection.

The affected ADRs, overview and index were reconciled against the final code.
ADR-0005 moves from planned to partial because VM intent/operations now exist;
ADR-0010 is accepted/partial. Physical execution and the other open requirements
remain explicitly unimplemented. Lilly was unchanged in this slice; its previous
precommit/release verification is recorded in the toolchain review.

## Follow-up

The subsequent [guest/console review](2026-09-15-guest-console.md) records local
KVM execution, image reproducibility and Lilly logging progress after this slice.


Implement the authenticated Lilly report/command boundary and image/address
validation, then VM execution and lifecycle reconciliation. Continue domain audit,
encryption, archival, sharing and terminal work alongside their resources. Keep
the full platform goal active and retain the actual-host validation requirement.
