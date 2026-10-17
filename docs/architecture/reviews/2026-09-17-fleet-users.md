# Fleet users and recipient reconciliation

## Scope and architecture impact

The approved plan changes human SSH authorization and recovery membership.
ADR-0041 replaces ADR-0032's single-operator policy while carrying forward its
runtime custody and publication obligations. ADR-0033 supplies machine assurance;
ADR-0040's host-local relay trust remains applicable to named local users.
Marshall application accounts, service roles and guest identities are unchanged.
Unrelated in-progress application/relocation and SMTP changes are preserved.

## Findings and decisions

- **Resolved design limitation:** secret enablement previously authorized a
  fixed root key. The access module now owns named accounts and SSH policy;
  preparation independently creates the persistent host identity.
- **Resolved design limitation:** the public package previously hardcoded one
  recovery recipient. Access and tooling now consume the reviewed user registry;
  each document adds its selected hosts and every recovery-enabled user.
- **Operational boundary:** recipient revocation rotates the document data key
  but cannot erase previously decrypted application credentials or old ciphertext.
  Credential rotation and delivery remain explicit operator workflows.
- **Operational boundary:** all candidates validate before publication, but
  atomicity is per file. Interrupted publication reports completed names and is
  rerunnable; filesystem/editor coordination outside this tool remains necessary.

- **Integration boundary (concurrent relocation work):** the permit-bound
  production SSH export server remains unimplemented. The separate in-progress
  SSH transfer fixture configures its own service account without enabling fleet access. An
  authoritative management SSH allowlist rejects such non-registry logins;
  production transfer endpoint composition needs an explicit review when that
  server is implemented, rather than silently bypassing human access policy.

## Verification performed

- Passed NixOS access evaluation, including combined access/secret identity
  generation, and the existing module/storage configuration evaluations.
- Passed all ten real SOPS tests, including data-key rotation, revoked-key
  rejection, host/recovery continuity, safe paths, private-file cleanup,
  idempotence, preflight failure and interrupted publication recovery.
- Passed the two-machine SSH/sudo suite with account, key and group revocation,
  root/home-key rejection and retained home data and host identity.
- Passed public recipient/CLI builds and the empty-inventory metadata check.
- Passed secret custody and exported bootstrap-image machine tests, including
  both single-disk survivors. The unchanged updater check builds successfully
  from its cached verified output.
- Passed the full credential-rotation/updater integration suite: staged
  encryption-key changes, coordinated signing/database credential cutover,
  retirement rejection, concurrent migrations, failed candidate preservation
  and compatible key additions.
- Passed the ACME/Route53 suite on an unchanged rerun, including renewal,
  connection continuity, provider failure and certificate publication recovery.
  Its first run timed out establishing the fixture WebSocket before renewal
  (15-second deadline); the intermittent failure was not hidden by changing
  assertions or timeouts.
- Passed full flake evaluation without building every check, scoped Nix contract
  coverage/validation and the ADR checker (42 decisions). These structural
  checks do not substitute for runtime verification.
- The installed-disk regression passed installation, healthy boot, named SSH
  and passwordless sudo. Its first single-disk survivor entered emergency mode:
  `var-lib-lilly-pool.mount` reported `zfs_mount_at() failed: mountpoint or
  dataset is busy` while native ZFS mounting started concurrently. The run was
  stopped after this failure; neither survivor is claimed as verified in that
  suite. The mirrored-storage configuration was not changed by this work;
  the apparent mount-ordering race remains unresolved.
- Repository-wide contract coverage is blocked by uncovered assets in the
  independently added Antithesis skill directories. Scoped Nix coverage passes;
  those unrelated files and contract rules were left intact.

Commit preparation isolated the fleet-user changes from concurrent relocation,
observability and skill work. The isolated tree passes repository-wide contract
coverage/validation and ADR validation (40 decisions). The machine regressions
above ran against the combined working tree; their results do not claim to
validate the independently edited application changes for inclusion here.
The isolated access, SOPS reconciliation, module-configuration and
storage-configuration checks also build successfully.

## Remaining gaps

No production host public keys, deployment ciphertext or private credentials
were supplied or invented. No existing machine was activated. Machine tests use
private keys generated inside isolated fixtures. Their runtime public-key
injection checks central lookup; separate evaluation verifies registry-to-key
configuration. Local functional tests do not establish independent physical
failure domains or production deployment acceptance.
