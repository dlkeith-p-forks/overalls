# ADR-0041: Declarative fleet users and recovery recipients

- ID: ADR-0041
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: NixOS access, SecretSpec, SOPS, host administration
- Supersedes: ADR-0032
- Superseded by: ADR-0043, ADR-0044

## Context

[ADR-0044](0044-recovery-only-secret-documents.md) carries forward this policy
and adds explicit recovery-only bootstrap documents. The original rationale
and historical verification scope below are preserved.

[ADR-0043](0043-declarative-host-provisioning.md) replaces generic host deployment
and inventory boundaries while carrying forward the other decisions below.
This record preserves the historical rationale and evidence.

ADR-0032 coupled secret preparation to ghuntley's root SSH authorization and
hardcoded a single recovery recipient. The user approved a shared attribute set,
named fleet-wide accounts, explicit passwordless administrators, the same
Ed25519 keys for login and recovery, authoritative human SSH access, global
recovery membership and repository-wide ciphertext reconciliation.

## Decision

Carry forward ADR-0032's SecretSpec/SOPS provider selection, SSH-derived host
identities, private runtime custody, persistent-key and fresh-image rules,
per-host document selection, atomic bundle publication, sanitized failures and
application credential/recovery constraints. Host-key generation is independent
of SSH login. The human access and recipient policy changes as follows.

One reviewed public registry defines username, SSH keys, login, primary and
supplementary groups, administration and secret recovery. Permissions default
off. Every participating host creates the same login-enabled named accounts;
administrators receive explicit passwordless sudo. Recovery-only users need no
host account. No live GitHub key fetch or private key enters evaluation or builds.
The initial registry preserves the existing reviewed ghuntley key.

Access-enabled hosts require a keyed administrator, use declarative Unix account
and group databases, centrally managed keys and a named-user SSH allowlist.
Root/password SSH and home-directory keys are disabled. Account/key/group
removal takes effect at activation for new sessions, preserving home data.
Existing sessions and privileged processes require separate operator action.

A public inventory assigns repository ciphertext documents to authenticated
host public keys. Each document includes precisely those host recipients and
all recovery-enabled users. Host and user key lists permit overlap during
rotation. Empty deployment inventories are valid; populated documents require
known hosts and at least one recovery recipient. The generic images do not
invent production host keys or ciphertext.

Explicit local tooling checks metadata, encrypts, decrypts and reconciles
recipients using pinned tools. Reconciliation requires a retained recovery
identity, stages every change, updates recipients and rotates the data key,
then verifies payload and recipient equality before publication. Preparation
failure preserves originals; publication is atomic per file, with partial
publication reported and safely rerunnable. Private inputs/outputs stay outside
the repository and store; private conversion files are cleaned up. Tooling does
not deploy, terminate sessions or rotate application credentials.

## Alternatives

Shared root authorization loses named-account attribution. Additive key policy
would leave undeclared home-directory keys usable. Per-host human policies and
per-document human recovery grants were considered; the user selected uniform
fleet login and global recovery flags. Recipient export alone leaves repetitive
reconciliation to operators. Automatic boot-time re-encryption would require
operator custody on hosts and mixes deployment with repository mutation.

## Consequences

Named accounts and global recovery have independent switches. Recovery grants
access to all inventoried secrets, whereas a host receives only its documents.
Declarative users remove manually created accounts on activation; rollout must
review existing users and verify named administration. Group membership retains
ordinary Unix privileges; root administrators can already access host identities
and local secrets regardless of the recovery flag. Host-local trust assumptions,
including ADR-0040's loopback relay, remain in force. Removing recipients cannot
revoke older plaintext knowledge; application credentials still need separate
rotation. Multi-file publication is
not a filesystem transaction and may need rerunning after interruption.

## Invariants and verification

- Evaluate typed users, denied defaults, groups, admin requirements and recovery
  independence; secret preparation must not implicitly enable SSH.
- Exercise real SSH and sudo on two NixOS machines, ignored home keys, root and
  unlisted-user rejection, and activation revocation with retained host identity.
- Exercise actual SOPS with synthetic operator/host identities, additions,
  removals, idempotence, malformed input, safe paths and failed preparation.
- Retain custody, credential rotation, updater, ACME and installation/image tests.
- Never use a production private identity or claim production deployment from
  local machine verification.

## Implementation evidence

The [registry](../../../nix/users.nix), [typed normalization](../../../nix/lib/registry.nix)
and [access module](../../../nix/modules/access.nix) implement named-account policy.
The [inventory](../../../nix/secrets.nix), [public packages](../../../nix/packages/secrets/default.nix)
and [local tool](../../../nix/packages/secrets/cli.py) implement recipient derivation
and reconciliation. The [runtime module](../../../nix/modules/secrets/default.nix)
retains privileged preparation without granting SSH access.

[Evaluation](../../../nix/tests/evaluation/access.nix),
[cryptographic tests](../../../nix/tests/evaluation/secrets_test.py) and
[SSH machine tests](../../../nix/tests/machines/access/default.nix) cover these
boundaries. The [review](../reviews/2026-09-17-fleet-users.md) records executed
verification and limits. Production identities, ciphertext and host rollout
remain unsupplied, so deployment acceptance stays partial.

## Open questions

Actual deployment host public keys and ciphertext must be supplied and verified.
Existing hosts need an account inventory before activating authoritative users.

## Related decisions

[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0040](0040-host-local-smtp-relay.md),
[operator guide](../../fleet-users.md).
