# ADR-0045: Declarative Lilly enrollment preparation

- ID: ADR-0045
- Date: 2026-09-17
- Status: accepted
- Implementation: implemented
- Components: Marshall operator, Compute, Nix host declarations, secret custody
- Supersedes: ADR-0012
- Superseded by: none

## Context

Reviewed hardware declarations and encrypted secret inventory already exist, but
operators separately assemble Marshall requests, copy UUIDs and prepare host
credential files. A lost response after issuance makes blind repetition unsafe.
The user approved one explicit preparation command, immediate credential rotation
and a five-year default, with publishing and activation remaining separate.

## Decision

Replace ADR-0012's one-year credential ceiling while preserving its random-secret,
single-active-credential, encrypted-custody, audit, host-lock and revocation
requirements. Current v3 protocol, ZFS and placement decisions remain governed by
ADR-0037; this does not restore the historical v1 protocol described in ADR-0012.
The user-approved plan authorizes this replacement and the new operator workflow.

Add preparation and explicit rotation to the existing host CLI. Authenticate the
installed target and Marshall through pinned administrative SSH, verify the
installation receipt and native storage identities, and obtain application
machine identity using Lilly's existing implementation. Derive the version-3
request from reviewed declarations and authenticated observations.

Run the Marshall operator in a bounded unprivileged process using systemd's
protected environment-file loading and verified database TLS. Administrative
SSH/sudo remains the authority; no public enrollment HTTP endpoint is added.
Export the credential through private files and the captured SSH pipe only.

Serialize registration by name before a host exists, then retain the existing
host-row lock for credential effects. Store each caller-generated operation UUID,
exact public request, action, host and credential ID in an immutable Ash resource
in the same transaction as issuance. Matching retries export the same current
credential. A different request under the same operation UUID, conflicting host
or storage bindings, retired host or inactive result fails closed. A fresh
preparation may export a matching active registration but cannot revive revoked
or expired authority. Explicit rotation immediately fences the prior credential,
without releasing guest reservations, and retries cannot rotate twice.

Use a maximum of 157680000 seconds (five 365-day years) at every issuance boundary.
The Nix preparation default is that maximum; the manual API still requires an
explicit TTL. Shorter integer lifetimes remain valid. Existing expiry timestamps
are never extended implicitly.

Before creating authority, persist the public retry identity outside Git and
verify recovery access. Encrypt the complete credential envelope as a raw
SecretSpec value for the authenticated host and every current recovery user.
Recover the shared Git deploy key from its managed bootstrap document. Stage
ciphertext and public host/pool/expiry metadata before per-file atomic publication.
Retain a private local journal containing public metadata and ciphertext, never
plaintext keys, to recover partial publication. Generated host bindings own
Lilly's runtime credential path, pool IDs and secret prerequisite service.

Preparation never commits, pushes, activates, enables scheduling, formats storage
or replaces host identity. Existing manual enrollment and deployment remain valid.
New registrations remain disabled until deployed and explicitly enabled after a
fresh execution-ready report. Rotation has no overlap or automatic renewal.

Explicit enrollment may replace stale Marshall host and pool UUIDs after loss of
the control-plane database only when the operator requests an empty-host rebind.
The installed and candidate declarations must describe the same physical host,
state paths, pool paths and native ZFS identities. After stopping Lilly, the host
must prove that no VM unit or cgroup, actor, command, VM, guest network claim,
transfer, active/import pool state, child dataset or snapshot remains. Lilly's
reviewed network cleanup must then confirm and remove only the old empty host-owned
namespace, links and tables; persistent host network configuration and lock files
are not guest state. Retired deletion tombstones do not represent live authority
and remain intact. Pool owner records change before the host owner record under a
private prepared/complete journal; mixed old/new records are accepted only as a
retry of that exact journal. Lilly is restarted on pre-mutation refusal, but stays
fenced after any authority record changes. A retry after candidate activation
treats the already-equal binding as an idempotent completion and resumes the
remaining enrollment phases. Ordinary automatic updates continue to reject every
Lilly binding change.

Enrollment writes a private in-progress marker before removing the old enrollment
receipt. Candidate activation applies the reviewed native resource policy but
defers replay of an older resource-transition journal while this marker exists.
Only enrollment health may publish the new receipt and clear the marker before
polling is enabled; interruption leaves polling gated and the retry intent intact.

The empty command store's persistent protocol/host binding is authority state even
when its command directory is empty. Rebind changes that identity atomically only
after the same execution and durable-state absence checks. A host whose owner
journal completed before this identity was changed may repair only the journal's
exact old-to-new binding after revalidating those empty-state fences.

## Alternatives

Automatic deployment-time issuance was rejected in favor of one operator command.
Staged rotation was considered; the user explicitly selected immediate replacement.
A shared fleet credential would broaden authority and lose host-specific revocation.
A pure Nix evaluation cannot safely perform authenticated issuance or handle private
keys. Repeating an unjournaled rotation after a lost response creates new authority
and invalidates the artifact the operator may already be deploying.

## Consequences

The database needs the enrollment-operation migration before the new helper runs.
Operators need installed host receipts, pinned SSH access and a current recovery
identity. Immediate rotation interrupts control exchanges until the new document
is deployed. Five-year credentials require explicit revocation when a host is
retired or compromised; expiry remains enforced on every authenticated exchange.
An empty-host authority rebind is deliberately unavailable for workload recovery:
any durable or executing guest state requires reconciliation under the original
authority rather than reassignment to a fresh control plane.

## Invariants and verification

Verify lifetime bounds and exact expiry, matching retries, concurrent registration,
conflicts, retired/revoked results and immediate rotation fencing. Inject lost
responses, encryption failure and partial publication. Exercise real SOPS host and
recovery decryption, outsider rejection and inventory rekey. Evaluate derived Nix
configuration and conflicting overrides. Run application gates and an authenticated
SSH/systemd machine workflow separately from simulated client tests.

## Implementation evidence

The [host transport](../../../nix/packages/host/cli.py) now selects explicit
administrative ports for SSH and Nix copies. Plans bind source and installer ports;
post-kexec calls use the installer port. Enrollment preparation selects Marshall's
operator port independently. [Planning tests](../../../nix/tests/evaluation/host-planning.py)
cover port binding and phase selection; [preparation tests](../../../nix/tests/evaluation/enrollment-preparation.py)
verify the independent Marshall choice. This preserves existing identity and
erasure authorization boundaries.


- [Coordinator](../../../marshall/lib/marshall/compute/enrollment_preparation.ex)
  and [resource](../../../marshall/lib/marshall/compute/enrollment_operation.ex)
  implement durable retry identity and private export.
- [Host preparation](../../../nix/packages/host/preparation.py),
  [operator module](../../../nix/modules/marshall-operator.nix) and
  [host profile](../../../nix/hosts/profile.nix) implement the deployment boundary.
- [Application tests](../../../marshall/test/marshall/compute/enrollment_test.exs)
  and [custody tests](../../../nix/tests/evaluation/enrollment-preparation.py)
  exercise the scoped failure and cryptographic boundaries.
- [Machine acceptance](../../../nix/tests/machines/enrollment-operator/default.nix)
  exercises actual pinned SSH, SOPS delivery and Lilly readiness across rotation.
- [Review](../reviews/2026-09-17-declarative-enrollment.md) records passing scoped
  checks, release artifacts, unrelated checkout failures and deployment limits.

## Open questions

Physical provider enrollment and production recovery access remain deployment
acceptance, independent of synthetic fixture results.

The [explicit enrollment runner](../../../nix/packages/host/enrollment.py)
validates initial resource budgets and native GUIDs against the installed host
without requiring a prior enrollment receipt. Existing policies cannot change
through enrollment; ordinary resource-update journals remain separate. The
[host-planning tests](../../../nix/tests/evaluation/host-planning.py) exercise this
first-enrollment boundary and rejection of changed budgets and identities.
They also exercise empty-host rebind refusal boundaries, retained tombstones,
partial owner-write retry, completed-journal retry and the unchanged ordinary
updater binding fence. The [host deployment manifest](../../../nix/modules/auto-update/default.nix)
supplies the declared transfer-state path to that check. Production use remains
separate acceptance evidence and is recorded in the associated architecture
review rather than inferred from these simulated filesystem checks.

## Related decisions

[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0025](0025-protected-provisioner-enrollment.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0043](0043-declarative-host-provisioning.md),
[ADR-0044](0044-recovery-only-secret-documents.md).
