# ADR-0066: Invitations and cascading account retirement

- ID: ADR-0066
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, authorization, web, compute, terminal, ingress, SSH
- Supersedes: ADR-0049
- Superseded by: ADR-0131

## Context

[ADR-0131](0131-automatic-magic-link-sign-in.md) replaces the inherited
second-click magic-link requirement and carries forward all other decisions
below.

[ADR-0158](0158-durable-guest-identities.md) now supplies the inherited guest
identity policy: retirement retains the old GuestAccount UUID/UID reservation;
a fresh same-email User UUID receives a new generated login and home. Historical
ADR-0125 results below remain scoped to the former email-derived implementation.

The user explicitly requested invitations, deletion of users and all their owned
machines, and immediate eligibility for fresh same-email registration afterward.

## Decision

Carry forward ADR-0049's exact, case-insensitive organizational-domain eligibility,
verified-email-only account creation, generic feedback and ordinary sharing rules.
An elevated administrator may send an invitation through the existing encrypted
magic-link outbox; accounts are ordinary until separately promoted.

Deleting a user requires recent MFA and typed email confirmation. Prohibit
self-deletion and removal of the last administrator. Serialize against administrator
membership and new owned-work admission. Atomically retire the identity, revoke
stored tokens, audit the request and enqueue bounded durable machine cleanup.
Retirement immediately denies the account and access to its owned workloads;
cleanup uses existing lifecycle/placement/storage fencing and physical outcomes.
Busy resize/clone work and unavailable hosts are retried. Never release capacity
or claim completion before every owned VM is physically reclaimed and archived.
Machines merely shared with the retired account are not deleted. ADR-0064's
Customer isolation stays authoritative. Account retirement is a fleet revocation
and cleanup operation covering every owned profile, including Customer; it gives
no administrator access to guest contents.

Retain the historical UUID and foreign keys using an inaccessible tombstone email;
keep the prior email on the deletion receipt. Release the active email identity at
retirement. A newly verified registration gets a different UUID and inherits no
credentials, grants, machines or administrator role. Reject pre-retirement email
links even when they were previously valid. Cleanup remains bound to the old UUID.

The requesting administrator's later demotion or elevation expiry cannot cancel
already accepted retirement. The cleanup coordinator uses a narrow trusted entry
point that validates the persisted deletion and VM owner, rather than impersonating
a currently privileged administrator.

## Alternatives

Hard deletion would destroy audit/operation references and could release capacity
before host cleanup. Synchronous deletion cannot finish reliably during host loss.
The user rejected blocking re-registration and chose fresh identities instead.

## Consequences

Retired identities and deletion history remain for provenance. Deletion can stay
pending while a host is unavailable or another operation requires recovery. Existing
cleanup rules are preserved; user deletion does not bypass them.

## Invariants and verification

Test stale email links, new UUID registration, no inherited access, self/last-admin
protection, idempotent deletion, concurrent provisioning, restart and physical outcome
requirements. Test that unrelated and shared-only workloads survive.
Credential registration must share the account admission fence through its outer
transaction: a registration committed first is visible to cleanup; a retirement
committed first refuses registration without leaving keys or audit versions.
Completed cleanup must leave no active key for the retired UUID and permit an
explicit fresh registration of the released fingerprint with a new key ID.

## Implementation evidence

[Account actions](../../../marshall/lib/marshall/accounts/account_lifecycle.ex),
[durable cleanup](../../../marshall/lib/marshall/accounts/delete_user_machines.ex),
[registration fence](../../../marshall/lib/marshall/accounts/registration_fence.ex),
and [tests](../../../marshall/test/marshall/accounts/account_lifecycle_test.exs)
implement and exercise the lifecycle. Native validation status is retained in the
[review](../reviews/2026-09-18-passkey-administration.md).

[Generated identity histories](../../../marshall/test/marshall/accounts/account_lifecycle_history_test.exs)
exercise repeated same-email generations, rejected-action inventories, real signed
passkey registration, prior keys/grants/membership, receipt replay, pending holds
and cleanup bound to the retired UUID. The new
[native journey](../../../nix/verification/tests/machines/account-lifecycle/driver.py) pairs
browser invitation and elevated typed retirement with actual Firecracker/ZFS
reclamation; its execution status and exact scope are recorded in the
[account lifecycle verification review](../reviews/2026-09-25-account-lifecycle-verification.md).
No product policy or decision is replaced. Independent-Marshall transfer/retirement overlap is recorded below under ADR-0077.

Improvement 009's native journey observed that the fresh UUID could not allocate the prior
email-derived guest username: ADR-0110 permanently reserves that name to protect
old homes. Fresh application registration and plain VM running state therefore
do not establish fresh guest SSH usability. [ADR-0125](0125-fresh-guest-identities.md)
now permits a fresh bounded email-derived name while preserving every historical
username and UID. Generated histories and three independent BEAM schedules verify
the allocator, durable account discovery and shared roster behavior. The
[018 review](../reviews/2026-09-25-fresh-guest-identity-verification.md) records their
execution and the complete extended NixOS native journey: fresh SSH/browser
identity, retained retired shared homes, explicit re-sharing and managed Lyra
SSH passed. Native Ubuntu, migration and rollout retain separate gaps.
Historical 009 acceptance retains its original scope; the old home is never reassigned.

[Three independent Marshall nodes](../../../marshall/test/marshall/teams_retirement_distributed_test.exs)
now execute the full public deletion action against team membership admission and
ownership acceptance in both committed orders. The [resource review](../reviews/2026-09-25-team-resource-verification.md)
records mutation-sensitive account fences, atomic receipts and bounded cleanup;
these tests do not establish native VM reclamation or physical-host availability.

The [credential workflow review](../reviews/2026-09-25-credential-lifecycle-verification.md)
records a reproduced late-registration defect and the existing-fence repair in
[key admission](../../../marshall/lib/marshall/ssh/key_actions.ex).
[Generated credential histories](../../../marshall/test/marshall/ssh/credential_retirement_history_test.exs)
cover explicit same-email reuse, pending/completed cleanup and stale actor retries;
[three-independent-BEAM schedules](../../../marshall/test/marshall/ssh/credential_retirement_distributed_test.exs)
cover both manual/approval orderings through real Ash actions and completed cleanup.
This updates evidence and enforces the accepted decision; it does not establish
native transport or physical cleanup beyond the earlier scoped machine results.

The [administrative account authority review](../reviews/2026-09-25-admin-account-authority-verification.md)
records the audit-commit overlap baseline and sorted participant correction for
role changes, global browser revocation, invitations, MFA reset and retirement.
Generated histories, 27 three-Marshall schedules and the captured native browser
reset/stale-page journey pass; the frozen full gate passed 1,124 checks and forced
test Dialyzer with zero findings. Exact source attribution remains in the review.
Existing durable cleanup, bootstrap, account fences and implementation status are preserved.

The [clone cancellation review](../reviews/2026-09-25-clone-cancellation-verification.md)
records an observed three-party schedule with actual clone activation, public clone
submission and queued exclusive account retirement. All calls completed on unchanged
production source; this bounded regression adds no new account authority or fence.

## Open questions

None for product policy. Remaining executed acceptance is tracked in the review.

## Related decisions

[ADR-0064](0064-customer-workspace-isolation.md), [ADR-0065](0065-passkey-administration.md),
[ADR-0049](0049-organizational-email-registration.md), [ADR-0022](0022-browser-terminal-and-live-login-checks.md).
