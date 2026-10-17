# ADR-0009: Audit, secrets, logging and verification

- ID: ADR-0009
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, testing and operations
- Supersedes: none
- Superseded by: ADR-0042

## Context

[ADR-0042](0042-host-observability.md) carries forward these decisions and adds
explicit restricted host-audit and encrypted-crash-artifact boundaries.

The user requires ash_archival, ash_paper_trail, ash_cloak, ash_oban, structured
logging, property-based tests and Cedar policies. Provisioning has privileged,
distributed side effects that unit tests alone cannot establish as safe.

## Decision

Use ash_archival for logical archival of appropriate domain resources,
ash_paper_trail for durable domain change history, ash_cloak for encrypted
sensitive resource attributes, and ash_oban for background domain work. Define
which data each covers when its resources are implemented; installing extensions
alone does not satisfy these requirements. Confirm physical VM cleanup before
archiving a VM or releasing retained disk/address allocations.

Emit structured JSON logs with consistent event names and correlation identifiers
for request, operation, host and VM where applicable. Exclude secrets, credentials
and terminal bytes from logs and audit fields. Use Cedar for authorization as in
ADR-0008. Distinguish business audit history from diagnostic logs and metrics.

Use property-based tests for lifecycle transitions, reservations, authorization
and protocol invariants; use compiler/Dialyzer gates and targeted integration
tests. Exercise at least three Marshall nodes and two real x86-64 KVM hosts for
the vertical slice, including retries, partitions and host/process restarts.

## Alternatives

Log-only auditing is unsuitable for durable domain history. Broad record dumps
would leak sensitive fields. Mock-only tests cannot prove Firecracker execution,
NAT, isolation or restart behavior. A passing structural ADR checker cannot prove
any of those runtime properties.

## Consequences

Encryption needs operational key ownership and rotation. Archival and audit
retention must be designed together so deletion, secrets and history do not
contradict each other. Distributed tests need explicit workload targets and real
host availability; telemetry retention is separately specified in ADR-0006.

## Invariants and verification

- Repeated lifecycle jobs are idempotent and cannot skip physical cleanup.
- Audit entries identify actor/action and relevant change without recording
  secret plaintext or terminal data; encryption covers the selected attributes.
- Property tests seek counterexamples under varied operation ordering and input.
- KVM tests prove the chosen isolation/connectivity and survival properties;
  fault injection proves reconciliation after uncertain outcomes.
- State test environment and measured load alongside any scale/readiness claim.

## Implementation evidence

[Precommit](../../../marshall/mix.exs) has compiler warnings-as-errors and tests;
[validator tests](../../../marshall/test/architecture/adr_validator_test.exs)
introduce property-based checks for the governance mechanism.
[Application](../../../marshall/lib/marshall/application.ex) wires Oban/AshOban.

[VM resource](../../../marshall/lib/marshall/compute/virtual_machine.ex) now
creates changes-only AshPaperTrail versions. [JSON log configuration](../../../marshall/config/config.exs)
uses an explicit metadata allowlist. Cedar and three-node admission tests are
implemented under [ADR-0010](0010-capacity-admission-transactions.md).

[Host credentials](../../../marshall/lib/marshall/compute/host_credential.ex)
now apply AshCloak encryption, AshArchival revocation and secret-free
AshPaperTrail versions. [Vault](../../../marshall/lib/marshall/vault.ex) requires
a production keyring and supports retained decryption tags. Credential, TLS and
three-node revocation verification are recorded in
[ADR-0012](0012-provisioner-control-transport.md).

[ADR-0024](0024-durable-magic-link-email.md) now applies AshCloak and AshOban to
short-lived authentication email. The
[mail and authentication log filter](../../../marshall/lib/marshall/mailer/log_filter.ex)
redacts tagged diagnostics before handlers; the
[SMTP tests](../../../marshall/test/marshall/mailer/smtp_test.exs) verify sanitized
provider failures. Completed payloads become SQL NULL, and expired outbox rows
are physically deleted without archival/audit copies of usable links.

[ADR-0025](0025-protected-provisioner-enrollment.md) now provides private operator
credential files, guarded release commands and
[diagnostic redaction](../../../marshall/lib/marshall/operations/privacy.ex).
Its tests distinguish unavailable verification from inactive authority and
retain uncertain output artifacts. SSH-derived deployment key custody and
coordinated credential rotation now have passing machine evidence under ADR-0032.

VM archival is gated by confirmed physical cleanup under ADRs 0016/0017/0031,
including deletion while other guests survive in the passing NixOS fleet. Full
domain audit/retention review, bulk re-encryption, independent physical-host
acceptance and representative workload validation remain open.
[Lilly JSON logging](../../../lilly/config/config.exs) and a
[real guest/console smoke test](../../../lilly/scripts/smoke_guest.exs) are now
implemented under [ADR-0011](0011-nixos-guest-and-console.md). Both applications pass the compiler, tests and Dialyzer gates
under ADR-0002; the [foundation review](../reviews/2026-09-15-toolchain.md) records
the precise scope and one upstream typespec exclusion. ADR-0065 subsequently removes
that obsolete exclusion after upgrading the authentication dependency.

## Open questions

[ADR-0032](0032-ssh-derived-age-identities.md) selects SecretSpec/SOPS custody,
SSH-derived host identities and pinned operator recovery. Actual synthetic
SecretSpec/SOPS delivery, host replacement, recipient rotation and coordinated
application-credential rotation pass the machine suites. Deployment documents and
real provider acceptance remain operator inputs.
[ADR-0033](0033-nixos-machine-verification.md) records passing NixOS/nested-KVM
checks and the missing existing reference-host adapter/external boot test.
Complete audit retention/redaction review, production backup/restore validation,
independent physical failure domains and workload targets before claiming
production readiness.

## Related decisions

[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0008](0008-identity-sharing-and-terminal.md).
