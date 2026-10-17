# ADR-0048: Single-host service deployment

- ID: ADR-0048
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: host deployment, Marshall, Lilly, PostgreSQL, TLS, recovery
- Supersedes: ADR-0029, ADR-0043
- Superseded by: ADR-0050

## Context

[ADR-0050](0050-usage-based-overcommit.md) replaces the capacity admission and
mutable resource-budget requirements while carrying forward unrelated requirements.
This record preserves the original rationale and implementation evidence.

The operator explicitly requested one Marshall, one Lilly and local PostgreSQL
on the installed Hetzner host overalls, with public hostname ghuntley.dev.
The inherited deployment decisions require at least three planned Marshall
replicas and an external AWS database. Inventing two additional replicas or
claiming a local database is external would misrepresent the requested topology.
This explicit deployment instruction authorizes the replacement below.

## Decision

Carry forward ADR-0043's reviewed inventory, pinned installation, strict SSH,
ZFS topology/budget/identity, non-destructive enrollment, secret custody and
verified automatic-update decisions. Carry forward its inherited decisions
except the minimum replica count and mandatory external database location.

Allow 1..100 explicitly declared Marshall replicas; retain three as the Nix
module default and preserve the exact pool/notifier/operator/migration connection
budget calculations. A single instance is a supported nonredundant deployment,
not evidence of multi-host resilience. Distributed verification still requires
three real Marshall processes and independent-host claims retain their own tests.

For overalls, run exactly one Marshall and one Lilly with PostgreSQL 18 on the
same host. PostgreSQL listens only on loopback, requires SCRAM and verified TLS
for Marshall TCP connections, and remains the sole durable application authority.
Retain fsync, full_page_writes and synchronous_commit. Root-controlled SOPS
bundles supply passwords and private certificates; a public host-specific CA
verifies database and backend identity. Public HTTPS uses the declared DNS name
and the existing ACME/proxy policy. Serving units never run schema migrations.
Provision the database and credentials before publishing the serving-role change,
so the updater's existing pre-activation migrator can connect.

Carry forward ADR-0029's acknowledged-WAL, primary-selection, fencing, backup
custody and historical-restore quarantine requirements. Its synchronous standby
and lossless failover requirements apply to deployments claiming primary-failure
availability. This explicitly nonredundant host has no automatic failover and
makes no claim of availability through machine loss. Do not invent a standby or
relax synchronous durability during promotion. Adding failover later requires
independent failure domains and verified synchronous history before promotion.

Lilly enrollment uses the actual installed machine identity and existing ZFS GUID
receipt. Enable scheduling only after authenticated control, fresh capacity and
guest prerequisites pass. Service activation must preserve disks, host keys and
installation bindings. Public DNS and authenticated SMTP remain real deployment
inputs; no fixture mail transport or TLS verification bypass is a substitute.

## Alternatives

Declaring three replicas while running one would make the fleet description and
budget misleading. Provisioning an external database contradicts the requested
local deployment. Disabling database TLS or commit durability is unnecessary on
a colocated host and would weaken existing guarantees. Pretending one machine
provides HA would conceal a shared failure domain.

## Consequences

The host can bootstrap a complete small deployment without extra machines.
Marshall, database and local guests share a failure domain. Mirrors do not replace
backups; off-host backup retention and tested restore remain operational work.
Existing multireplica deployments keep their defaults and transport/durability
policy. No serving startup migration, automatic schema rollback or storage reset
is introduced.

## Invariants and verification

Verify one replica is accepted only with its complete connection budget, and zero
or more than 100 are rejected. Preserve verified TLS, writable-primary selection
and synchronous_commit in runtime tests. Evaluate exactly one local Marshall and
one Lilly. Verify loopback-only PostgreSQL, SCRAM, real TLS name/CA checks, schema
migration, HTTPS readiness, authenticated Lilly enrollment, fresh reports and
post-activation host receipts on overalls. State DNS/SMTP and backup acceptance
limits separately from unit and local machine checks.

## Implementation evidence

The [experimental Antithesis foundation review](../reviews/2026-10-13-antithesis-harness-foundation.md)
records a disposable two-Marshall, PostgreSQL 18 and Lilly Compose diagnostic
with real migration and healthy processes. The first connected v4 host had no
committed report, but a later local project published a fresh report and emitted
setup; six serial Control commands then passed with 13 SDK assertion records.
Its selected runtime-dependency manifest remains stale. This isolated fixture does not
change overalls' declared one-Marshall deployment or establish its acceptance.

- [Marshall runtime](../../../marshall/lib/marshall/operations/runtime_config.ex)
  and [runtime tests](../../../marshall/test/marshall/operations/runtime_config_test.exs)
  preserve connection budgets and TLS/durability while accepting one replica.
- [Marshall Nix module](../../../nix/modules/marshall.nix) retains the default of
  three while allowing explicit single-instance deployments.
- [Overalls configuration](../../../fleet/hosts/overalls/configuration.nix)
  declares the local PostgreSQL bootstrap and runtime secret delivery.
- [Overalls services](../../../fleet/hosts/overalls/services.nix) deploy one
  Marshall, verified backend TLS, public ACME HTTPS, Resend SMTP and Lilly's
  locally verified guest image directory.
- [Image catalog bootstrap](../../../fleet/hosts/overalls/image-catalog.nix)
  registers the same manifest advertised by Lilly through the operator catalog.
- [Host inventory](../../../fleet/hosts/overalls/host.json) retains actual hardware,
  network and storage identity. [Host workflow](../../host-provisioning.md) retains
  the published installation and enrollment protocol.

Physical deployment is verified: PostgreSQL, Marshall and Lilly are active;
Lilly reports execution readiness and scheduling is enabled. Public HTTPS
readiness returns 200 with a Let's Encrypt certificate. Resend TLS authentication
passed with encrypted credentials and sender noreply@ghuntley.dev; delivery of
an actual email was not tested. Backup/recovery acceptance remains incomplete.
See the [deployment review](../reviews/2026-09-17-overalls-services.md).

The 2026-09-26 [historical-authority characterization](../reviews/2026-09-26-historical-authority-characterization.md)
records evidence for the carried-forward ADR-0029 restore-isolation requirement
on this deployment class: the native drill boots the release in operator mode
against the isolated restored database with no listeners or background consumers,
and Lilly fence pins characterize the provisioner side. It adds evidence text
only; historical-fleet reactivation stays delegated.

On 2026-10-16 the public hostname moved from `overalls.dev` (no longer
registered) to `ghuntley.dev`: Marshall's public host, proxy ACME identity,
mail sender, Porsche origin, fleet control origin and the delegated
`apps.ghuntley.dev` Audi zone. The internal service CA was then rotated:
a single new CA in [`service-ca.crt`](../../../fleet/hosts/overalls/service-ca.crt)
signs the backend certificate (`ghuntley.dev` only) and the PostgreSQL
certificate, the retired `overalls` CA is no longer trusted, and the CA key is
custody-only in `secrets/service-ca-recovery.enc.json`.

Later on 2026-10-16 the product was renamed from Overalls to Overalls
throughout code, Nix options, units, paths, metrics and the CLI (`overalls`).
Every secret document now uses `overalls-*` SecretSpec projects. The Brady
fleet root and signers, the Audi private-services root and issuer, the log
store CA, the internal service CA and the crash-dump key were regenerated; the
git deploy key, Marshall application keys and SSH host CA were carried over
from their host copies. The decisions recorded here are unchanged.

## Open questions

Off-host database backups, retention and recovery drills are not established by
local PostgreSQL installation. These gaps keep implementation partial.

## Related decisions

[ADR-0029](0029-database-durability-and-recovery.md),
[ADR-0043](0043-declarative-host-provisioning.md),
[ADR-0045](0045-declarative-lilly-enrollment.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0024](0024-durable-magic-link-email.md).
