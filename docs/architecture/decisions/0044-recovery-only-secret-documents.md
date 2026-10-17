# ADR-0044: Recovery-only secret documents

- ID: ADR-0044
- Date: 2026-09-17
- Status: superseded
- Implementation: implemented
- Components: secret inventory, SOPS, operator recovery
- Supersedes: ADR-0041
- Superseded by: ADR-0067

## Context

[ADR-0067](0067-reciprocal-nix-builders.md) carries forward every policy here
and adds a restricted machine account for reciprocal Nix builds and SSH caches.

The Git deploy key was committed as recovery ciphertext before any production
host existed. ADR-0041 required every document to select a host, leaving this
copy outside inventory checks, decryption and repository-wide reconciliation.
The user explicitly requested completing that integration rather than maintaining
an unmanaged exception.

## Decision

Carry forward every ADR-0041 decision, with one explicit exception to the
requirement that a document select hosts. A document may set `recoveryOnly = true`
with an empty `hosts` list. It receives exactly all recovery-enabled users and
must have at least one recovery recipient. Reject a recovery-only document with
host recipients. The flag defaults to false; ordinary documents still require
known authenticated hosts. No identities are invented for bootstrap custody.

Register `git-bootstrap` in the public secret inventory. Both document kinds use
the same check, encrypt, decrypt and rekey commands, private identity handling,
data-key rotation, staged validation and per-file atomic publication. Recovery
membership changes reconcile bootstrap ciphertext alongside host ciphertext.
An encrypted bootstrap copy alone does not grant any machine decryption access.

## Alternatives

Manual SOPS instructions leave bootstrap ciphertext outside repository-wide
reconciliation. Silently accepting an empty host list hides missing deployment
recipients. A fake host or a recovery user's key registered as a host invents
deployment identity. The explicit flag avoids all three behaviors.

## Consequences

Bootstrap credentials can be managed before host enrollment. Public inventory
consumers gain an optional boolean field without changing ordinary documents.
Existing retained-recovery-identity and historical-plaintext limitations remain.
Machine enrollment still supplies authenticated host keys and distinct host
documents. This does not rotate the GitHub credential or deploy any machine.

## Invariants and verification

Verify real SOPS recovery-only encryption/decryption, host exclusion, recipient
addition/removal, data-key replacement, idempotence, recipient drift detection
and mixed-document failure isolation. Reject implicit hostless documents,
nonboolean flags, mixed recovery-only/host selection and missing recovery users.
Validate the actual bootstrap inventory and ciphertext metadata without using
the production recovery private key in tests.

## Implementation evidence

- [Inventory](../../../nix/policy/secrets/secret-documents.nix) registers the existing bootstrap ciphertext.
- [Typed registry](../../../nix/platform/lib/registry.nix) defaults `recoveryOnly` to false.
- [Secret CLI](../../../nix/domains/artifacts/secrets/cli.py) enforces document selection
  and routes both kinds through the existing custody and reconciliation paths.
- [Cryptographic tests](../../../nix/verification/tests/evaluation/secrets_test.py) exercise
  synthetic identities with actual SOPS and SSH-to-age tools.
- [Operator instructions](../../../secrets/README.md) use the managed commands.

The [review](../reviews/2026-09-17-recovery-secret-inventory.md) records executed
verification. Inherited production fleet and physical-host acceptance obligations
remain as recorded in ADR-0041; this implementation claim covers the new document
class, not those inherited deployment capabilities.

The inherited named-host access policy now also provides Mosh and systemd
lingering for login-enabled users through the [access module](../../../nix/domains/system/access.nix).
Mosh bootstraps through the existing administrative SSH policy, with UDP
60000–61000 for its terminal transport; existing sessions retain the explicit
revocation limitation. Recovery-only entries still create no account and guest
access is unchanged. The [fleet access review](../reviews/2026-09-18-fleet-mosh.md)
records evaluation and machine verification separately from live deployment.

The [operator-history review](../reviews/2026-09-26-secret-recipient-histories.md)
adds composed recipient, recovery-only, preflight and partial-publication retry
verification with actual SOPS/age. Its execution record distinguishes generated
local CLI evidence from the existing native custody and credential-rotation
results. Accepted policy and implementation status are unchanged.

## Open questions

Actual host recipients and production recovery decryption remain deployment inputs.

## Related decisions

[ADR-0041](0041-declarative-fleet-users.md),
[ADR-0032](0032-ssh-derived-age-identities.md).
