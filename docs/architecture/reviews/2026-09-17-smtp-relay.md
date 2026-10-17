# Host-local SMTP relay review

Date: 2026-09-17

## Scope and architecture impact

ADR-0040 replaces ADR-0024's immediate-hop TLS requirement for explicit host-local
submission and carries forward its encrypted outbox and retry guarantees. The
relay is optional, synchronous, unprivileged and loopback-only. ADR-0032 secret
custody and ADR-0033 machine verification apply. Existing unrelated working-tree
changes are outside this review.

## Findings and resolution

- The selected Grafana v2.2.3 sender used unbounded `smtp.SendMail` and raw provider
  error logging. The maintained patch adds explicit verified TLS, authenticated
  forwarding, socket deadlines/cancellation and fixed external error diagnostics.
- Serving and migration paths both load production mail configuration. They now
  share the local-mail environment fragment so migrations need no provider secrets.
- The updater's shared-key comparison treats `marshall-*` health units as BEAM
  processes. Naming the relay `overalls-smtprelay` avoids accidental comparison;
  generic descriptor staging and dependency discovery remain the secret mechanism.
- Loopback submission intentionally trusts host-local users. The managed listener
  and metrics are not public, and the sender restriction does not claim per-user
  authentication. No retry queue or mail spool is introduced.

## Validation

The final implementation preserves encrypted outbox authority and existing
secret preparation contracts. ADR-0040 is implemented; ADR-0032 and ADR-0033
retain their broader partial statuses.

Passed using the pinned toolchains and an immutable copy of the working tree:

- Marshall `mix precommit`: 26 properties and 262 tests, six browser tests,
  contract checks, ADR checks, compilation and forced Dialyzer analysis
  (one existing suppressed warning).
- The pinned relay package and its Go tests: implicit TLS and STARTTLS,
  PLAIN/LOGIN, trust/hostname/authentication failures, missing STARTTLS,
  cancellation, deadlines, credential bounds and sanitized provider errors.
- Nix `module-configuration`, `marshall-release` and `flake check --no-build`.
- The `smtp-relay` KVM machine suite: loopback isolation, actual SOPS/SecretSpec
  resolution, wrong-host refusal, private credential delivery, delayed upstream
  acceptance, rejection and retry with stable Message-ID, relay outage,
  bounded stalls, missing credentials, rotation, STARTTLS/LOGIN specialization,
  candidate migration and descriptor-bound staged-secret handoff. Successful
  delivery clears encrypted payloads; unsuccessful attempts retain them.
- Existing `auto-update` check (cached successful derivation), plus KVM
  `secret-custody` (138 seconds), `service-roles` (147 seconds), and
  `credential-rotation` (461 seconds), including interrupted update recovery
  and refusal to retire a still-needed encryption key.

The first machine run exposed a test-fixture error: setting Oban queues to
`false` prevented AshOban validation. The fixture now retains queue configuration
and selects manual test mode; the complete rerun passed in 204 seconds.
Machine tests used KVM with a temporary build-group device ACL. The daemon did
not advertise nested KVM; after confirming the host kernel enables nesting,
`service-roles` passed through the local builder with that feature declared.
No machine-test capability requirement was weakened. The temporary KVM ACL
was removed after verification.
A final repository-wide ADR rerun found a concurrent, unrelated observability decision title
mismatch with its index entry. The earlier 40-decision structural check passed;
ADR-0040 and its links remain consistent. The concurrent observability decision
was left untouched. Local fixture results do not establish provider inbox delivery.

## Remaining deployment work

Supply authenticated host recipients, encrypted provider credentials, verified
sender DNS and provider quota/abuse configuration. Exercise actual inbox delivery.
