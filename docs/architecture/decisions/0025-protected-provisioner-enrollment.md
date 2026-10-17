# ADR-0025: Protected provisioner enrollment files

- ID: ADR-0025
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Marshall Compute and operator commands, Lilly startup configuration
- Supersedes: none
- Superseded by: ADR-0035

## Context

[ADR-0035](0035-zfs-only-provisioning.md) replaces the ext4/provisioner-v1
compatibility portions and carries forward the other requirements. The decision
and implementation evidence below describe the historical revision.

ADR-0012 provides encrypted, revocable provisioner credentials, but an operator
still has to assemble host/pool resources and handle the returned secret manually.
The authorized platform plan requires a protected enrollment workflow. Execution
must remain bound to the enrolled physical identity under ADR-0017.

## Decision

Provide trusted release-level enrollment, rotation, verification and revocation
commands. Operating-system access to the Marshall release and its database keys
is the administrative authority; these commands are not public user APIs.
Standalone commands use the small database, vault and Cedar operator tree, without
web listeners or background consumers. ADR-0026 extends this tree with an Oban
instance for transactional job insertion; its consumers, scheduler, leadership and
stager are disabled. Explicit enable/disable commands take the
host lock; enabling requires a fresh v2 execution-ready report.
Use a bounded, versioned JSON enrollment request with explicit machine identity,
x86-64 architecture, host/pool overheads, distinct ext4 pool identities and a
credential lifetime. Enroll the host disabled, pools and credential atomically
through the existing Ash resources. Return only public identities and metadata.

Write the credential to a new file owned by the service account, mode 0600, in an
existing private 0700 directory. Reject symlinks, unsafe parents and existing
destinations. Do not accept credential contents in process arguments or print
them. Sync file data and the containing directory before database commit. This
does not make PostgreSQL and the filesystem a single atomic storage system:
crashes or uncertain commits can leave an empty, inactive or active output file.
Retain that artifact and provide an explicit verification command that checks the
credential against current database authority without printing it. Never blindly
retry into an existing path or delete the only copy after an uncertain commit.
Distinguish invalid files, inactive credentials and unavailable verification.
Public metadata lookup by host name recovers IDs when the response was lost.

Rotation uses the existing host lock, archives prior credentials, invalidates
observations and retains VM reservations. File-write failure rolls back issuance
and invalidation. Revocation follows the same existing lifecycle. Diagnostic
handling excludes operator credential payloads and raw exception values.

Lilly accepts a private credential file as an alternative to the existing inline
credential. The envelope binds host and credential IDs and carries expiry
metadata; runtime host identity and authoritative expiry checks remain in the
existing server/client protocol. Reject ambiguous inline-plus-file configuration.
Read credentials at startup; installation/rotation requires an intentional Lilly
restart with its original state. Existing inline configuration remains compatible.

The operator transfers the protected file over their authenticated administrative
channel and installs it with Lilly's ownership/permissions. No new public
enrollment endpoint, secret-discovery service or automatic SSH transfer is added.
Physical readiness and fresh reports still gate admission; enrollment alone does
not prove that a host can execute guests. The user instruction to implement the
plan authorizes these operational details.

## Alternatives

Printing secrets in a release console or including them in command arguments
exposes them to history, logs or process listings. Automatically overwriting a
credential file can destroy the only recoverable result of a prior commit.
Claiming atomicity across local files and PostgreSQL hides the crash boundary.
A public enrollment API would require a separate administrative identity and
bootstrap-authentication design before it could replace release-level authority.

## Consequences

The deployment needs protected operator access, local durable filesystems and a
secure transfer/install procedure. Filesystem and database recovery require
verification after uncertain results. Host names and physical identities remain
unique; repeated enrollment does not silently mutate an existing host. No wire
protocol revision or production dependency between Marshall and Lilly is needed.

## Invariants and verification

- Invalid requests, unsafe paths and existing files cannot issue credentials.
- Enrolled hosts remain disabled and have no fabricated capacity.
- File-write/database failures cannot commit a partial host/pool/credential set.
- Rotation and revocation retain reservations and fence old authority.
- Output and logs contain no usable secret; private-file readers enforce owner,
  permissions, type, link count and bounds.
- Lilly can use Marshall's real exported file; mismatched host envelopes and
  ambiguous configuration fail closed. Exercise the resulting client over TLS.
- Property tests cover request/input boundaries and sanitized diagnostics.

## Implementation evidence

[Enrollment coordinator](../../../marshall/lib/marshall/compute/enrollment.ex),
[private files](../../../marshall/lib/marshall/operations/private_files.ex),
[release CLI](../../../marshall/lib/marshall/operations/cli.ex) and
[Lilly reader](../../../lilly/lib/lilly/control/credential_file.ex) implement the
workflow. [Integration tests](../../../marshall/test/marshall/compute/enrollment_test.exs)
exercise the exported file through Lilly's real TLS client, commit uncertainty,
verification failures and allocation-preserving operator actions. Final precommit
passed 198 Marshall cases and 81 Lilly cases, including properties and Dialyzer.
Both production releases built; the Marshall CLI and Lilly file configuration
passed release smoke checks. See the
[review](../reviews/2026-09-16-provisioner-enrollment.md) for scope and remaining
deployment/physical-host acceptance.

## Open questions

[ADR-0032](0032-ssh-derived-age-identities.md) selects administrative SSH with the
supplied operator key and SecretSpec/SOPS custody using host SSH-derived age
identities. Its NixOS preparation, synthetic custody, host replacement and
coordinated fleet credential-rotation tests pass; actual host recipients,
deployment documents and fleet rotation
scheduling remain deployment work. ZFS enrollment extends validation
under [ADR-0031](0031-sparse-zfs-storage-and-capacity.md). The separate
[NixOS fleet](../../../nix/verification/tests/machines/fleet/default.nix) now proves two simulated provisioner
hosts; physical failure-domain and representative workload acceptance remain open.

## Related decisions

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0027](0027-production-release-deployment.md).

File durability uses documented [OTP file operations](https://www.erlang.org/doc/apps/kernel/file.html).

Host maintenance extends the operator workflow under
[ADR-0026](0026-host-maintenance-and-retirement.md).

[ADR-0035](0035-zfs-only-provisioning.md) supersedes this decision as described above.
