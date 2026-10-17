# ADR-0042: Host-local observability and restricted diagnostic evidence

- ID: ADR-0042
- Date: 2026-09-17
- Status: accepted
- Implementation: partial
- Components: Marshall, Lilly, Porsche, Fluent Bit, NixOS, auditd, CloudWatch
- Supersedes: ADR-0009
- Superseded by: none

## Context

The user approved optional per-machine direct log export, full host execution
auditing, Firecracker diagnostics, application/OTP logging, boot evidence,
aggregate metrics and optional encrypted crash dumps. They subsequently selected
Fluent Bit so destinations can change without changing applications. No central
log forwarding machine is permitted. Full execution arguments and VM memory can
contain credentials, requiring a narrow replacement of ADR-0009's blanket
diagnostic prohibition rather than an implicit exception.

## Decision

Carry forward every ADR-0009 decision about AshArchival, AshPaperTrail, AshCloak,
AshOban, Cedar, physical cleanup, types, property tests and real-machine evidence.
Ordinary application and operational diagnostics continue to exclude credentials,
authentication tokens, terminal bytes and decrypted payloads. PostgreSQL retains
durable domain authority; diagnostic delivery is not business audit persistence.

An opt-in host audit module records execution arguments and administrative
security events, without K3s rules or guest disk-I/O auditing. These records are
restricted evidence: root-only local custody and explicit source selection on
every remote destination. Native Firecracker diagnostics are separately bounded;
guest console content never becomes a host log source.

Each host runs its own pinned Fluent Bit collector with trusted origin metadata,
source classification, persistent cursors, bounded storage and independent output
queues. Provide CloudWatch, OTLP and native plugin outputs. Destination credentials
come from private runtime files through ADR-0032 custody; neither application
code nor the neutral event envelope depends on AWS. Delivery permits duplicates,
reports rejection/loss and never authorizes domain actions or stops guests.

CloudWatch uses per-environment/source groups, host streams and 90-day default
retention. One explicit manager reconciles resources and expected-host alarms;
it never receives fleet logs. A 24-hour buffering target requires measured rates
plus 50% headroom and explicit host/per-destination budgets. Capacity limits and
provider acceptance remain operational evidence, not implied guarantees.

Application outcome logs follow successful transaction commit. Safe correlation
includes immutable placement, epoch and generation, separate from origin host
identity. Aggregate metrics have bounded dimensions and destination-specific
serialization. Enable OTP/SASL reports only with source-side diagnostic protection.

Optional encrypted-dump release variants preserve the pinned runtime versions.
They require a dedicated public encryption key at runtime; the private key stays
off-host. Dumps have private persistent storage and byte/time/count/age limits.
Only sanitized artifact metadata may enter any log destination. When enabled,
Linux core-content processing/storage is disabled to prevent a plaintext bypass.

## Alternatives

A CloudWatch-specific collector couples applications and deployment to AWS.
Central forwarding contradicts the independent-host requirement. Unbounded logs
can exhaust disks and interfere with workloads. Plaintext crash dumps and raw
OTP process reports undermine application secret and console privacy guarantees.

## Consequences

Operators must treat full audit records as sensitive even when application logs
are sanitized. Multiple destinations increase traffic and storage requirements.
Runtime/plugin delivery semantics require fault tests; configuration alone does
not establish durability. Crash dump encryption changes the release capability
and all launch entrypoints must supply the selected public key.

## Invariants and verification

- Disabled modules cause no AWS access or new export services.
- Payload fields cannot overwrite origin or routing decisions.
- Each destination explicitly selects audit evidence; secrets never enter store configuration.
- Destination outages, collector restarts and queue pressure preserve guest execution.
- Verify journal replay, boot capture, rotation, partial rejection and fan-out independently.
- Verify actual OTP reports, rollback behavior, crash encryption and secret exclusion.
- Run application gates and real NixOS/Firecracker fixtures; report live-provider gaps.

## Implementation evidence

[Logging module](../../../nix/modules/logging/default.nix) defines neutral inputs,
conditional routes, destination presets and resource limits. Its
[runtime preparation](../../../nix/modules/logging/runtime.py) resolves private
credentials. [Audit module](../../../nix/modules/security-audit.nix) defines
restricted rules and native rotation. [CloudWatch management](../../../nix/modules/cloudwatch/default.nix)
is separate from collection. [Fluent Bit patches](../../../nix/packages/fluent-bit/default.nix)
address checkpoint ordering, persisted route recovery, partial rejection, verified
TLS, durable metric emission and explicit AWS identity selection.
[Lilly native logging](../../../lilly/lib/lilly/vm/logging.ex) creates generation-bound
FIFOs read by an [independent collector](../../../nix/modules/firecracker-logging/collector.py).
[OTP report translation](../../../marshall/lib/marshall/otp_reports.ex) prevents raw
process data from reaching formatters; [aggregate telemetry](../../../marshall/lib/marshall/observability.ex)
retains numeric observations. [Crash dump runtime](../../../nix/modules/crash-dumps/runtime.py)
validates the encryption-enabled release and operator key and bounds artifact retention.
The [three-host machine check](../../../nix/tests/machines/logging/default.nix),
[native transport fixtures](../../../nix/tests/evaluation/logging-transports.py), and
[actual OTP encryption test](../../../nix/tests/evaluation/encrypted-crash-dumps.py)
provide executable evidence. [Operational guidance](../../observability.md) documents
configuration, credential rotation, queue sizing, IAM and provider acceptance.
These checks do not establish live AWS policy/KMS enforcement or measured production
capacity; implementation remains partial pending those deployment-specific checks.

[Porsche command admission](../../../marshall/lib/marshall/ssh/commands.ex), under
[ADR-0046](0046-porsche-ssh-management.md), now emits its fixed diagnostic after
the outer command/receipt transaction commits. Nested Compute and Access calls
defer their success diagnostics to that caller. The
[receipt fault-injection test](../../../marshall/test/marshall/ssh/commands_test.exs)
checks that failed receipt storage rolls back work and emits no false provisioning
or sharing success, while a committed command still logs admission. The
[SSH API tests](../../../marshall/test/marshall_web/ssh_api_test.exs) also verify
credential and command-argument exclusion at debug level. Porsche's own SSH
runtime now uses the [NixOS service](../../../nix/modules/porsche.nix), with explicit
Fluent Bit classification from trusted journal unit identity. Its
[source privacy filter](../../../porsche/lib/porsche/privacy.ex) and JSON stderr
configuration are installed before its SSH listener accepts peers. The
[privacy tests](../../../porsche/test/privacy_test.exs) inspect raw handler events
and an actual process crash, verifying that process state, exception contents and
report callbacks do not survive source redaction. Events emitted through the
reviewed [Porsche.Events](../../../porsche/lib/porsche/events.ex) catalog are the
only informative exception: the filter reconstructs them from fixed catalog text
with shape-validated atoms, so private SSH processes gain closed diagnostic
events without payloads. The
[native collector check](../../../nix/tests/evaluation/logging-metrics.py) now checks
Porsche synthetic summaries and fixed metric dimensions as well as Lilly.
[Porsche aggregation](../../../porsche/lib/porsche/observability.ex) now records only
fixed numeric HTTP/command totals, SSH proof candidate/proved totals and BEAM
gauges. Its
[model and raw-handler tests](../../../porsche/test/observability_test.exs) verify
bounded storage, metadata exclusion, sanitized reports and command execution
without its metrics process. The service wires the shared
encrypted-dump wrapper and retention. The [Porsche capture machine check](../../../nix/tests/machines/porsche-crash-dumps/default.nix)
now forces actual service crashes, decrypts on a separate analyst node, verifies
private artifact custody, configured 256-MiB/10-second bounds, three-file/seven-day
retention and metadata-only journal reports, and rejects weak/missing public keys.
This is local service evidence; live cloud export remains deployment-specific.

Fleet-wide catalogued structured events now exist under this decision: each
application owns a reviewed [event catalog](../../../marshall/lib/marshall/events.ex)
with compile-time name/key validation and runtime shape validation, and a
[structural logging gate](../../../scripts/check_logging.exs) runs in every
precommit. The [fleet logging review](../reviews/2026-09-19-structured-logging-fleet.md)
records the 224-event surface, the Ziggy/Porsche reviewed-event filter branches,
after-commit corrections and verification; live provider acceptance remains open.
The follow-up [audit hardening review](../reviews/2026-09-22-structured-logging-audit-hardening.md)
replaces terminald's arbitrary string logger with typed events carrying placement
and execution correlation. Porsche's accepted identity-minimal posture is unchanged.

The [team resource review](../reviews/2026-09-25-team-resource-verification.md)
found that authentication privacy filtering discarded Galileo's catalogued
refusal reason. The [filter](../../../marshall/lib/marshall/mailer/log_filter.ex)
now preserves four explicitly reviewed atoms only for the exact authorization-
denied event. Fixed messages, arbitrary payload exclusion and mail-tag precedence
remain intact. [Generated privacy cases](../../../marshall/test/marshall/mailer/log_filter_test.exs)
and an actual refusal, now a [control-socket refusal](../../../marshall/test/marshall/control/galileo_service_test.exs)
since ADR-0142 retired the Galileo HTTPS routes, verify the scoped correction. The recorded native denied integration request
additionally requires one fresh `unauthorized` event across three Marshall journals
alongside HTTP 503 and an unchanged origin count.

The [Porsche review](../reviews/2026-09-17-porsche-ssh-management.md) records the
resolved parity defect in Marshall and Lilly's translators. Both now rebuild
metric reports through primary filters and permit only closed numeric summaries
through translation. Their existing aggregation and crash privacy remain intact.
The [actual-application metric check](../../../nix/tests/machines/application-metrics/default.nix)
passes periodic emission from source-built Marshall and Lilly services through
journald and native Fluent Bit output. It does not inject synthetic summaries or
establish guest execution, replication or live AWS delivery. The review records
focused checks and unrelated whole-worktree gate failures separately.

## Open questions

Live provider acceptance, independently measured workload capacity and production
recipient/IAM configuration remain deployment inputs.

## Related decisions

[ADR-0009](0009-assurance-and-testing.md), [ADR-0020](0020-local-console-fences-and-bounded-streams.md),
[ADR-0021](0021-console-relay-connections-and-mailboxes.md), [ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md), [ADR-0037](0037-workload-placement-and-relocation.md).
