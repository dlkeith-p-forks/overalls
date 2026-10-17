# ZFS identity and capacity contract

## Scope and architectural impact

This implements the control-plane and shared-contract portion of ADR-0031, in
its required upgrade order: Marshall validation/persistence before native ZFS
provisioners. The accepted decision remains unchanged and its implementation is
now partial. ADRs 0006, 0010 and 0023 supply the existing admission transaction and
telemetry boundaries; ADRs 0012, 0016 and 0033 supply compatibility and acceptance
requirements. User authorization comes from the accepted plan implementation.

## Evidence

- [Storage values](../../../protocol/lib/overalls_protocol/storage.ex) and the
  [report codec](../../../protocol/lib/overalls_protocol.ex) preserve unsigned
  GUIDs as bounded decimal strings. A v2 pool may include explicit ZFS identity,
  physical/logical use, quota and compression ratio. Physical totals/credit must
  agree; unknown quota remains null. V1 exchanges reject the extension and ext4
  report encoding remains unchanged.
- [Enrollment](../../../marshall/lib/marshall/compute/enrollment_request.ex)
  retains v1 ext4 requests and adds v2 ZFS entries with a separate logical cap.
  Two dataset GUIDs from the same zpool cannot create two schedulable pools on
  one host. [Public descriptions](../../../marshall/lib/marshall/compute/storage_pool.ex)
  expose the immutable descriptor and budget without changing ext4 response shape.
- The Ash resource, generated migrations and snapshots add backend identity,
  budget and observations. PostgreSQL enforces host/zpool uniqueness and backend
  consistency. The first migration refuses to discard identity while any ZFS
  pool remains enrolled; production migration remains an explicit operator step.
- [Ingestion](../../../marshall/lib/marshall/compute/host_reports.ex) checks exact
  enrolled identity, effective physical totals and quota inside the existing
  host-row transaction. Missing or contradictory storage observations reject
  the whole report without refreshing capacity/history. V1 cannot establish ZFS
  report freshness or an executable ZFS session.
- [Budgeting](../../../marshall/lib/marshall/compute/budget.ex) implements
  `max(0, min(B, F + A) - H - C)` with B from enrollment. A missing ZFS budget
  yields no admission. Compression/logical usage never enter A; only physical
  allocation for retained commitments does, capped per VM. Deletion does not
  increase available bytes until free space is observed.
- Telemetry (`marshall/lib/marshall/telemetry/observations.ex` at overalls revision `a99f74f0`, repository deleted) records
  physical use, logical use, quota, compression and logical budget separately
  with units and backend/GUID context. Historical values remain outside admission.

## Findings and resolution

1. **High — mixed accounting semantics, addressed at the shared boundary.** A
   compressed sparse dataset cannot use apparent disk size as physical credit.
   The new contract keeps physical accounting and the enrolled logical budget
   separate. The privileged collector must still establish exclusive ownership
   and coherent observations; a parsed report does not prove those facts.
2. **High — duplicate backing capacity, addressed for enrolled ZFS parents.**
   Filesystem/dataset identity alone permits two parents from one zpool. Both
   input validation and a PostgreSQL unique index reject that duplication.
   Lilly must still detect real device arrangements and ext4/ZFS overlap.
3. **High — downgrade identity loss, guarded.** Generated rollback would discard
   ZFS identity and budgets. The field-removal migration now refuses while ZFS
   pools remain enrolled. Do not enable ZFS before all Marshall nodes and shared
   validation are upgraded. Existing application packages cannot operate a native
   ZFS Lilly host yet.
4. **High — explicitly unimplemented storage execution.** Lilly still validates
   ext4 and preallocates disks. Native datasets, LZ4/no-reservation enforcement,
   physical sampling, writeback/Sync configuration, owned deletion/recovery and
   real ZFS/Firecracker acceptance remain required. No physical acceptance claim
   is made by these unit, property or database tests.

## Verification

All three `devenv shell` / `mix precommit` gates passed:

- Protocol: **25 checks** (13 properties, 12 tests), compiler and Dialyzer clean.
- Lilly: **84 checks** (19 properties, 65 tests), forced Dialyzer clean; its
  application source remains unchanged in this phase.
- Marshall: **227 checks** (25 properties, 202 tests), with the four opt-in host
  checks excluded as before. The gate includes distributed tests, browser-state
  checks and forced Dialyzer. Only the existing documented upstream exclusion
  remains; there are no new application findings or unused exclusions.
- Structural gates: **34 ADRs**, **47 CONTRACTS files**, **417 maintained sources**.
  `mix ash.codegen --check` confirms resource/migration/snapshot agreement and
  `git diff --check` passes.

The new [three-node race](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
uses three independent Marshall BEAM instances and committed PostgreSQL state.
Nine requests compete for a 4 GiB usable logical budget while 99 GiB is physically
available. Exactly two 2 GiB VMs succeed; increasing reported compression/logical
usage permits no further reservation. CPU/RAM are deliberately ample so the
result tests the logical disk cap. The database tests also verify identity/quota
rejection without refreshing sequence or capacity, PostgreSQL duplicate-pool and
backend constraints, public enrollment persistence and v1 session refusal.

The exact rollback-guard SQL from the migration was executed against temporary
PostgreSQL tables: ext4 permits continuation and enrolled ZFS raises the fixed
refusal. This tests the guard itself, not a production downgrade or full rollback.
The test transaction/temp tables leave persistent application tables unchanged.

Both source-built Nix release checks passed with the new protocol and Marshall
schema. The four-machine service-role suite passed in **72.78 seconds**, including
actual package startup, explicit migration, verified proxy TLS and Lilly inner-KVM
startup checks. Its forced KVM execution and unchanged ext4 role behavior do not
establish native ZFS or guest failure acceptance.

Targeted protocol/Marshall checks also passed before these complete gates. Unit
and property tests use synthetic observations. Ordinary database tests use SQL
sandbox ownership; the distributed fixture commits and cleans only its own rows.
No real ZFS datasets or guest disks were created in this phase. The temporary
`nixbld` KVM ACL was removed after test cleanup; original root/kvm access remains.

## Follow-up

Implement Lilly's native backend against this contract, retaining ext4 behavior.
Verify identity/property drift, asynchronous accounting and reclamation under
real writes, missing initialized disks, stop/start/restart survival and safe
cleanup. Add the NixOS storage module, reference host/images and mandatory
multi-node ZFS/Firecracker tests. Numerical tuning remains proposed in ADR-0034.
