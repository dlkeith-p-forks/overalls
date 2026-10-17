# ADR-0119: Authenticated read access to the Control room

- ID: ADR-0119
- Date: 2026-09-25
- Status: superseded
- Implementation: implemented
- Components: Marshall Accounts, authorization, web, compute, fleet, SSH, access
- Supersedes: ADR-0059, ADR-0062, ADR-0065, ADR-0114
- Superseded by: ADR-0123

## Context

[ADR-0123](0123-remembered-browser-authority.md) clarifies remembered browser
authentication and revocation while carrying forward the other requirements.

The user explicitly selected read-only access to every Marshall administrator
page for all signed-in users and approved implementation. The Control room
navigation, LiveView hooks, Cedar policy and some projection coordinators
previously required administrator membership. Accounts also shared a read
permission check between its listing and mutation admission policies.

## Decision

Grant `admin_read` on the Marshall ControlPlane to every current user. Show the
Control room navigation to all signed-in users and expose its existing bounded,
redacted projections, including user identities, access inventories, workload
metadata, job history, monitoring, audit, Git mirrors and fleet usage exports.
Completed browser authentication remains mandatory, including configured MFA.

Keep the persisted administrator role and five-minute passkey elevation for all
administrative changes. Account reads and mutations use separate Ash policy
checks. Hide mutation controls for ordinary users, and recheck current role,
elevation and Cedar mutation permission before LiveView mutation callbacks.
Explicit read events remain available; unrecognized events halt. Domain mutation
coordinators retain their fresh checks and transactional guarantees.

Recheck stored login and read authority during navigation, events, refreshes and
asynchronous history completion. Demotion preserves read access and removes
mutation authority; account retirement or login revocation/expiry removes access.
No projection grants VM, terminal, SSH, guest-web or internal system authority.

This replaces only the administrator-only read and navigation requirements of
ADR-0059, ADR-0062, ADR-0065 and ADR-0114. Carry forward their other requirements,
including job retention/redaction/retry auditing, monitoring bounds and cache
behavior, MFA and account lifecycle, VM override restrictions, and presentation.
ADR-0117's terminal workspace and inherited removal of the Overview usage summary
continue to apply.

## Alternatives

Showing only the navigation leaves ordinary users unable to inspect its pages.
Granting full administrative access exceeds the selected read-only behavior.
Bypassing domain authorization in web handlers would leave alternate entry points
inconsistent. The existing distinct Cedar read action provides a shared boundary.

## Consequences

Signed-in users can see fleet-wide metadata, including other account identities
and usage. Existing redaction excludes credentials, terminal content and raw job
payloads. No database migration, new dependency or public URL change is needed.
Cedar policies are loaded at application startup: restart serving Marshall
replicas as part of deployment. Older replicas retain the narrower read policy.
Implementation and push do not establish production deployment acceptance.

## Invariants and verification

- Ordinary signed-in users can browse every Control room page and usage export.
- Ordinary users, including recently elevated users and forged role structs,
  cannot invoke administrative mutations through browser events or domain actions.
- Demoted administrators retain reads but cannot mutate; other administrator
  controls retain their existing elevation requirement.
- Anonymous, revoked, expired and retired sessions cannot retain browser access.
- Existing redaction, bounded projections and ordinary VM access remain enforced.

## Implementation evidence

[Cedar policy](../../../marshall/priv/cedar/compute.cedar),
[Accounts policies](../../../marshall/lib/marshall/accounts/user.ex), and
[LiveView guard](../../../marshall/lib/marshall_web/live_admin_auth.ex) separate
read and mutation admission. [Navigation](../../../marshall/lib/marshall_web/components/layouts.ex)
exposes the Control room for signed-in users.
[Browser coverage](../../../marshall/test/marshall_web/control_room_access_test.exs)
exercises populated projections, forged events and session invalidation.
[Domain coverage](../../../marshall/test/marshall/accounts/control_room_authority_test.exs)
checks ordinary readers and administrative mutation denial. Existing administrator
and elevation regression tests remain in place. Full validation is recorded in
the [review](../reviews/2026-09-25-control-room-read-access.md); deployment remains
outside the implementation evidence.

[Generated Control room histories](../../../marshall/test/marshall_web/control_room_history_test.exs)
and a [focused native browser journey](../../../nix/tests/machines/control-room/browser.py)
extend current-role, elevation and stored-login coverage. Exact execution and
remaining cross-replica/hardware limits are recorded in the
[verification review](../reviews/2026-09-25-control-room-verification.md).

The
[credential self-service journey](../../../nix/tests/machines/credential-self-service/browser.py)
additionally exercises a mounted Control room page losing its elevation
mid-session when the proving passkey is removed from a second self-service tab;
the next role click is refused into the step-up flow and persisted role and
audit rows are unchanged. Execution is recorded in the
[credential self-service review](../reviews/2026-09-26-credential-self-service.md).

## Open questions

None. Application validation passed; production deployment is separate.

## Related decisions

[ADR-0059](0059-administrative-job-history.md),
[ADR-0060](0060-detailed-fleet-monitoring.md),
[ADR-0062](0062-interactive-monitoring-dashboards.md),
[ADR-0065](0065-passkey-administration.md),
[ADR-0114](0114-overalls-workspace-design.md),
[ADR-0116](0116-overview-without-usage-summary.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md),
[ADR-0022](0022-browser-terminal-and-live-login-checks.md).
