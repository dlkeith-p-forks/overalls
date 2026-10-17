# ADR-0058: Administrative account authority

- ID: ADR-0058
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, authorization, web, terminal, ingress
- Supersedes: ADR-0018
- Superseded by: ADR-0064, ADR-0065

## Context

[ADR-0064](0064-customer-workspace-isolation.md) restricts Customer workspace
access to its owner, including for administrators. Fleet administration remains.

The approved admin-console plan requires an explicit persisted administrator role,
first-user bootstrap and administrative access to all workloads. Ordinary sharing
must remain unchanged. This replaces ADR-0018's exhaustive user-role matrix while
carrying forward its other sharing, archival and authorization requirements.

## Decision

The user's implementation instruction authorizes one administrator role, read
freshly from PostgreSQL for Cedar decisions. Separate administrative actions grant
fleet reads, account management, operations, configuration and job intervention.
Administrators also receive VM read/write/manage/web permissions. They never
become the internal system actor. Administrative queries remain distinct from
ordinary owner/shared lists and expose explicit field projections.

The first successful verified registration on a fresh installation becomes its
administrator. A permanent singleton latch serializes registration and role changes.
Existing installations consume that latch at migration and require the explicitly
authorized one-time promotion of the operator’s verified organizational mailbox. That operation may
use sudo once; subsequent administration uses authorized application actions.
There is no standing operator promotion endpoint or CLI command.

Administrators can promote/demote others but never themselves. The singleton lock,
fresh permission check and remaining-admin check serialize competing changes.
Membership updates and append-only audit events commit together. Admin controls
must revalidate login and role for events, navigation and refresh. Session/terminal
and placement fencing remain required. Audit excludes secrets and terminal bytes.

The administrative access console may inventory and revoke SSH keys and live SSH
sessions through bounded projections. It exposes fingerprints and expiry metadata
only; public-key material, token hashes, session tokens and gateway credentials
remain unavailable to the browser. Revocation closes the durable session or
archives the key under the current administrator's audit context.
Administrators may also revoke all stored browser login sessions for another
account. This action is serialized on the authority latch, writes a redacted
audit event and relies on the existing fresh-login checks to halt active views.

## Alternatives

A deployment email allowlist would make routine membership changes require
deployment. Multiple operator roles were offered and the user selected one role.
Client-side flags and ordinary-user-to-system-actor conversion cannot establish
current domain authority. Reopening bootstrap when no admins exist would enable
account takeover and is prohibited.

## Consequences

Role checks add account reads and require migration before deploying dependent
code. Existing installations are not silently promoted. Administrative access is
broader than ordinary sharing and must be exercised across browser, terminal and
ingress/SSH paths. Accepted durable operations remain valid after requester demotion.

## Invariants and verification

- Concurrent successful registrations produce one bootstrap administrator.
- Failed registration consumes neither bootstrap nor audit state.
- Re-login and loss of all accounts cannot reopen completed bootstrap.
- Spoofed/stale user structs cannot authorize administrative actions.
- Self-demotion always fails; competing role changes cannot remove the last admin.
- Ordinary users retain their sharing matrix and cannot coordinate internal actions.
- Login/role revocation is enforced during live browser and guest sessions.

## Implementation evidence

[Bootstrap change](../../../marshall/lib/marshall/accounts/bootstrap_administrator.ex)
locks the persistent latch inside registration and couples role/audit changes.
[Membership coordinator](../../../marshall/lib/marshall/accounts/administrators.ex)
serializes changes and rejects self-demotion.
[Cedar adapter](../../../marshall/lib/marshall/authorization/cedar.ex) obtains
persisted membership. These are source evidence, not executed acceptance.
The [migration](../../../marshall/priv/repo/migrations/20260918031222_admin_authority.exs)
and [user page](../../../marshall/lib/marshall_web/live/admin/users_live.ex) now exist.
[Focused tests](../../../marshall/test/marshall/accounts/administrators_test.exs)
and [browser checks](../../../marshall/test/marshall_web/admin_users_live_test.exs)
pass. The [bootstrap probe](../../../marshall/scripts/verify_admin_bootstrap.exs)
also passed with three independent peers. Full-gate, guest-session revocation acceptance and the
one-time deployed-account promotion remain pending; see the
[implementation ledger](../../history/ledgers/admin-implementation.md).
The [admin access console](../../../marshall/lib/marshall_web/live/admin/access_live.ex)
and redacted [SSH admin actions](../../../marshall/lib/marshall/ssh/admin_actions.ex)
provide bounded key/session inventory and revocation; focused browser coverage is
in [admin_access_live_test.exs](../../../marshall/test/marshall_web/admin_access_live_test.exs).
The users page's `Sign out everywhere` action uses the same current-authority
boundary and is covered by [admin_users_live_test.exs](../../../marshall/test/marshall_web/admin_users_live_test.exs).

Administrator lifecycle and relocation requests append redacted `vm_lifecycle`
and `vm_relocate` events from their durable coordinators. The event is written
inside the operation or reservation transaction, so retries remain idempotent and
failed mutations leave no audit claim; focused lifecycle and relocation tests cover
both properties.

## Open questions

None for role semantics. Verification and the wider admin console remain in progress.

## Related decisions

[ADR-0018](0018-persisted-sharing-and-user-machine-access.md) retains the sharing rationale.
[ADR-0022](0022-browser-terminal-and-live-login-checks.md) defines fresh login checks.

[ADR-0065](0065-passkey-administration.md) replaces the authority/lifecycle policy while retaining the rationale above.
