# ADR-0029: Database durability and recovery boundaries

- ID: ADR-0029
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: Marshall persistence, PostgreSQL deployment, recovery tooling
- Supersedes: none
- Superseded by: ADR-0048

## Context

[ADR-0048](0048-single-host-service-deployment.md) carries forward this policy
with an explicit nonredundant single-host service/database deployment option.
The rationale and verification scope below remain historical evidence.

Marshall's accepted physical commands, reservations, credential revocations and
terminal fences depend on PostgreSQL retaining acknowledged transactions.
Restarting a writable database or passing a readiness probe does not establish
that a promoted replica contains those acknowledgments. A historical backup may
also contain authority that has since been revoked, while guests continue running
outside the database. The authorized implementation plan and ADR-0003 require
durable coordination through database failures.

## Decision

Preserve acknowledged transactions across the supported primary-failure case.
Production Repo connections explicitly request `synchronous_commit=on`; a role
or database default of `off` must not silently weaken this contract. PostgreSQL
must retain `fsync` and `full_page_writes`, and production infrastructure must
provide synchronous replication to the failover candidates that its HA controller
may promote. One application's connection parameter does not create this topology.

Promotion requires proof that the old primary cannot accept writes and that the
candidate contains the acknowledged history. Keep a stable, verified-TLS primary
endpoint. A TCP health check or a writable server alone does not establish
leadership. An external HA provider/controller owns election and infrastructure
fencing; Marshall does not implement a second consensus system. Restore synchronous
redundancy before admitting new application writes after promotion. Never silently
downgrade replication to preserve availability.

Back up database state and preserve the matching external encryption keyring.
Verify physical backup manifests and perform actual restores. A successful checksum
check alone is insufficient. Recovery artifacts require private access, encryption
at rest in production, independent failure domains, retention and restore drills.

Restore historical backups into an isolated environment with no serving Marshall,
AshOban workers or provisioner traffic. Begin with read-only inspection. A backup
can resurrect credential/access records and older host epochs; it is not eligible
for ordinary HA failover. Before making a restored control plane authoritative,
fence the previous authority and reconcile surviving hosts, VM generations,
reservations, credentials, terminal/login authority and pending physical commands.
Retain unknown allocations until physical evidence settles them. This fleet
reconciliation workflow remains required work, not an operation automated by the
local restore test.

These durability and quarantine boundaries implement the authorized platform plan.
The production provider, automatic HA controller, backup store and failure-domain
placement remain unselected; this record does not select a vendor.

## Alternatives

Asynchronous promotion can lose acknowledged reservations or revocations. Reusing
a backup as an immediately writable control plane can replay stale authority
against newer physical state. Health-check-only promotion cannot fence a previous
primary. Storing encryption keys only in the database backup makes lost-key
recovery impossible and combines independent security boundaries.

## Consequences

Synchronous durability increases commit latency and can withhold acknowledgments
when no required standby is available. Client timeout is an uncertain result,
not proof of rollback; existing idempotency keys still govern retries. Complete
database disaster recovery has a longer operational path than lossless promotion.
Guest disks remain host-local under ADR-0005 and are not backed up by PostgreSQL.

## Invariants and verification

- A role default of asynchronous commit cannot override the production connection.
- A host-session mutation waits for its synchronous standby before HTTP success.
- Old-primary termination is confirmed before promotion; routing never includes
  both writable histories. Rebuild a synchronous standby before resuming traffic.
- Three existing Marshall processes reconnect without losing the acknowledged
  session epoch or idempotent response.
- Corrupted backups fail verification. An actual isolated restore can decrypt a
  credential with its preserved keyring and fails without that keyring.
- A post-backup revocation remains effective in the live cluster even when the
  isolated snapshot contains the older credential. Never attach workers to it.

## Implementation evidence

[Production runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex)
sets the connection's durability parameter alongside primary selection and TLS.
ADR-0030 additionally requires a 15-second server-side idle-transaction limit,
so loss of a client cannot leave its idle transaction holding locks indefinitely.
The [fleet review](../reviews/2026-09-16-nixos-fleet.md) records the deterministic
client-machine-loss regression and its verification status. This does not change
commit durability, cancel active statements or turn an uncertain commit into
proof of rollback.
[Configuration tests](../../../marshall/test/marshall/operations/runtime_config_test.exs)
retain the malformed-input and budget properties; the
[recovery harness](../../../nix/tests/README.md) exercises actual
role-default override, synchronous waiting, promotion, replacement replication,
three production services and physical backup restoration. It uses the
[NixOS deployment checks](../../../nix/tests/README.md). See the
[recovery guide](../../../docs/database-recovery.md) and
[review](../reviews/2026-09-16-database-recovery.md) for executed results and limits.

The 2026-09-26 [historical-authority characterization](../reviews/2026-09-26-historical-authority-characterization.md)
records native restore-drill evidence that an operator-mode release boot against
the isolated restored database binds no serving listeners and runs no background
consumers, and fixed Lilly tests pinning provisioner-side replay/fence behavior;
it adds evidence for the isolation boundary only and does not close the fleet
reconciliation gap below.

The harness manually controls disposable local PostgreSQL processes. Production
automatic election/fencing, off-host encrypted backup/WAL retention, PITR, fleet
reconciliation after historical restore and independent failure-domain acceptance
remain unimplemented or unverified. Status remains partial.

## Open questions

[ADR-0030](0030-nixos-deployment-and-tls.md) selects an external AWS-managed
PostgreSQL deployment; the concrete service, HA/fencing behavior, synchronous
durability policy, failure domains, backup store, retention and recovery time
objectives still need selection and validation. Operator deployment-key custody
is implemented and machine-tested under
[ADR-0032](0032-ssh-derived-age-identities.md); actual deployment documents and
provider configuration remain to be supplied.
Complete historical-restore reconciliation before supporting authoritative fleet
recovery. Measure commit latency and workloads across the production network.

## Related decisions

[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0003](0003-control-plane-coordination.md), [ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0025](0025-protected-provisioner-enrollment.md),
[ADR-0027](0027-production-release-deployment.md).

Primary references: [PostgreSQL commit durability](https://www.postgresql.org/docs/18/runtime-config-wal.html),
[failover and fencing](https://www.postgresql.org/docs/18/warm-standby-failover.html),
[base backups](https://www.postgresql.org/docs/18/app-pgbasebackup.html),
[backup verification limits](https://www.postgresql.org/docs/18/app-pgverifybackup.html).
