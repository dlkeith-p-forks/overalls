# ADR-0003: Control-plane coordination

- ID: ADR-0003
- Date: 2026-09-15
- Status: accepted
- Implementation: partial
- Components: Marshall, PostgreSQL, AshOban
- Supersedes: none
- Superseded by: none

## Context

Marshall must operate as one instance for convenient development and at least
three in integration testing and production, with deployments potentially
reaching 100 instances. Requests and jobs can be handled by different nodes.

## Decision

Use shared highly available PostgreSQL as the authoritative durable store.
Marshall instances coordinate through database transactions and AshOban jobs;
node messaging may distribute notifications but cannot become a separate source
of truth. Use AshOban for domain background work, including provisioning and
reconciliation. A request that needs capacity atomically commits its reservation,
operation and job before reporting acceptance.

Daily development may use one Marshall; distributed integration tests and
production use at least three. Support for 100 requires measured connection,
job and notification budgets. These choices follow the accepted platform plan;
this ADR does not choose a database HA vendor or claim deployment is complete.

## Alternatives

An application-level consensus system would duplicate database coordination and
expand failure modes. In-memory ownership or PubSub-only state cannot safely
coordinate reservations after restarts. A single production node fails the
availability requirement.

## Consequences

Database availability and transaction contention become central. Jobs must be
idempotent under retries and uncertain acknowledgments. Connection pools must be
budgeted across all nodes; adding 100 instances cannot mean multiplying default
pools without a database capacity plan.

## Invariants and verification

- Concurrent requests cannot reserve the same allocatable capacity twice.
- The operation, reservation and AshOban enqueue succeed or roll back together.
- Duplicate/retried jobs converge on one operation result.
- A node restart or missed notification does not erase durable state.
- Exercise three-node races, node/DB disconnects and rolling compatibility;
  validate 100-node load before claiming that scale is supported.

## Implementation evidence

[Application supervision](../../../marshall/lib/marshall/application.ex)
starts Repo, Cedar, PubSub and Oban using AshOban configuration.
[Admission](../../../marshall/lib/marshall/compute/admission.ex) atomically creates
VM intent, reservation, operation and its AshOban job using shared PostgreSQL.
[Three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
exercise capacity/idempotency races with three separate BEAMs and Repo pools.
See [ADR-0010](0010-capacity-admission-transactions.md) for transaction details.

Authenticated remote execution and reconciliation are implemented under ADRs
0012/0016/0017. Remaining: HA topology/failover, rolling compatibility across
incompatible releases, measured workload budgets and 100-node verification.

[ADR-0016](0016-executable-generations-and-lifecycle.md) adds host-serialized
lifecycle/outcomes and the executable v2 client/API. The same three-node suite now
checks restart admission against new provisioning and lifecycle AshOban rollback.

[ADR-0027](0027-production-release-deployment.md) adds a declared fleet connection
budget and [NixOS deployment checks](../../../nix/tests/README.md) with
three unprivileged production systemd releases, actual PostgreSQL TLS, HAProxy
pass-through, shared authenticated sessions, node stop/restart and database
outage/recovery. All processes in this fixture share one physical host. These
checks do not establish HA PostgreSQL or 100-node workload capacity.

[ADR-0029](0029-database-durability-and-recovery.md) adds explicit durable commit
parameters and a [database recovery harness](../../../nix/tests/README.md).
Three unchanged Marshall processes survive a manually fenced local PostgreSQL
promotion, with synchronous replication rebuilt before traffic resumes. Real
backup verification/restoration also demonstrates that historical snapshots can
contain revoked credentials and must remain isolated. Automatic production HA,
independent failure domains and authoritative historical recovery remain open.

The [NixOS fleet suite](../../../nix/tests/machines/fleet/default.nix) boots three separate
Marshall machines sharing PostgreSQL and coordinating two actual Lilly machines.
The complete immutable run passed authenticated browser sharing/terminal recovery,
concurrent admission, machine/database loss and stale-capacity rejection. The
[fleet review](../reviews/2026-09-16-nixos-fleet.md) records the completed run and
distinguishes trusted fixture domain calls from real browser session acceptance.

## Open questions

[ADR-0030](0030-nixos-deployment-and-tls.md) selects externally managed AWS
PostgreSQL and NixOS service deployment. Select the concrete database service/HA
configuration and production failure domains. Measure pool/job/notification
budgets against explicit workload targets. Operation fencing/versioning and
reconciliation ownership now have implementation evidence under ADRs 0016/0017;
deployment-specific rolling compatibility remains required.

## Related decisions

[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0027](0027-production-release-deployment.md),
[ADR-0029](0029-database-durability-and-recovery.md).
