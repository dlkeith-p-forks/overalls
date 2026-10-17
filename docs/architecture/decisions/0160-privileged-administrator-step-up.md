# ADR-0160: Privileged administrator step-up and pending-action continuation

- ID: ADR-0160
- Date: 2026-10-11
- Status: accepted
- Implementation: partial
- Components: Marshall Accounts, authorization, web
- Supersedes: ADR-0123
- Superseded by: none

## Context

[ADR-0123](0123-remembered-browser-authority.md) carried the original
five-minute administrator elevation and the Control room read/mutation split.
That flow makes a sensitive action a navigation decision: an administrator who
has no passkey, or whose elevation has expired, must leave the action and find a
separate setup or Security page. A successful ceremony therefore cannot safely
resume the exact action that caused the step-up, and an ordinary signed-in read
can be confused with an administrator operation.

The product is still in development and permits a breaking change. The new
boundary must make the authority that is being exercised explicit, preserve the
exact pending action through a bounded ceremony, and leave Cedar's Customer
isolation unchanged. It must also define what happens when a newly promoted
administrator has no credential yet and what verification is required when the
credential inventory itself changes.

## Decision

Keep every bounded, redacted Control room projection available to a current
signed-in user. A read checks the stored browser login and `admin_read`; it does
not require administrator membership or elevation. Reads never grant VM,
terminal, SSH, guest-web or internal-system authority.

Email authentication establishes the ordinary signed-in session even when the
account has no passkey or has a pending first-key setup. Passkey verification is
required at the privileged mutation boundary, not at the ordinary read
boundary. This lets a newly promoted administrator inspect the Control room and
reach credential setup without treating an unverified credential as
authority.

Require both current persisted administrator membership and a fresh passkey
step-up for every administrative mutation. A completed step-up creates a
session-bound elevation receipt with a fixed fifteen-minute lifetime measured by
database time. The lifetime never slides. Every mutation rechecks the stored
login, administrator role, receipt, and the relevant Cedar action after its
transactional locks. Demotion, login revocation, passkey reset or removal of
the proving credential invalidates the receipt immediately. Other durable work
that already committed remains valid after expiry or demotion.

When an enrolled administrator's mutation needs step-up, Marshall keeps one
exact pending action in the current LiveView socket. The continuation binds the
actor and stored login, the target/resource, action name, canonical arguments
and a five-minute expiry. It is single-use and discarded before the retried
action enters its current admission boundary.
After a successful ceremony the UI retries that exact action inline; it never
replays an arbitrary browser event, broad form, or caller-supplied authority.
Changed actor/login/view/route/resource bindings, withdrawn authority or a
currently invalid domain precondition refuse the continuation without a
mutation. Relevant workflow generations and idempotency identities retain their
existing transactional admission checks. A harmless projection refresh need not
invalidate an otherwise valid submission. A second tab cannot replace or
broaden the pending action.

An administrator without a passkey is directed to Security settings with an
allowlisted return path to the original page. No administrative action or form
arguments are retained across this setup navigation. First enrollment requires
a current email authentication completed within five minutes. If email freshness
is absent, setup requires a fresh email sign-in. After enrollment the user
returns to the original page and explicitly retries the action; its enrolled-key
step-up can then continue that new exact submission inline. Enrollment alone
does not elevate the login or execute an administrative action. The credential
being enrolled cannot prove its own prior enrollment or bypass login and role
checks.

Passkey credential changes are separately protected. Renaming or removing a
passkey and adding another passkey require a current stored login and an
existing passkey verified within fifteen minutes. The first passkey uses the
fresh-email setup path above. An administrator cannot remove the last passkey;
removing the credential that proved the current elevation ends that elevation
and requires a new verification. Credential operations retain their account-row
locking and audit requirements. Owner-managed SSH key registration and removal
retain their existing current-login and owner checks; administrator SSH overrides
remain privileged operations requiring elevation.

Cedar remains the authorization authority. Administrator elevation grants only
the Cedar administrator actions explicitly covered by the mutation. The exact
Customer owner check continues to deny Customer reads and lifecycle operations
to administrators who are not that immutable owner, even while elevated.
Machine ownership, sharing, terminal, SSH, guest-web and service credentials
remain separate decisions.

If an administrator loses the receipt while using another user's non-Customer
machine through an override, the domain refuses the operation. Detail and
terminal pages return to Fleet workloads with a verification-expiry explanation;
the user selects the machine again and verifies before reopening it. Resize
removes its mutation controls, keeps the draft in the page URL and offers the
same recovery destination. Recovery grants no authority and never suggests
passkey verification can unlock a foreign Customer machine. Normal owner and
sharing permissions remain usable independently of elevation.

## Alternatives

Keeping five-minute elevation and redirecting every verification to a separate
Security page loses the action intent. The separate first-enrollment page remains
appropriate because setup changes the account's credential inventory and the
user explicitly retries afterwards. Retaining broad form contents across that
navigation would introduce a second continuation protocol. Granting
all signed-in users mutation authority collapses the role boundary. Replaying a
browser event or trusting a hidden form after setup permits argument substitution
and stale-resource mutations. A sliding timer makes authority depend on page
activity rather than a fixed receipt. Giving elevation to the newly enrolled
credential before its enrollment ceremony completes would allow an unverified
credential to authorize itself. Blocking all ordinary reads until passkey setup
would make enrollment circular and is therefore rejected.

## Consequences

Administrative work remains usable after a step-up without repeating a form,
while ordinary readers never see an elevation prompt. The server must retain a
small, expiring continuation and must validate its binding during retry.
Navigation, socket loss and reconnect discard a continuation; the user explicitly
retries and existing mutation idempotency rules handle any uncertain result.
A fifteen-minute receipt broadens the exposure window relative to the
old policy, so revocation and current Cedar checks remain mandatory on every
mutation. This is a breaking development cutover: all serving replicas must use
the new continuation and receipt semantics before protected traffic is enabled;
old replicas are not a supported mixed deployment.

## Invariants and verification

- A signed-in non-administrator can read every bounded Control room projection
  but cannot perform an administrator mutation.
- A signed-in user without a passkey can complete ordinary reads; missing or
  pending setup becomes a step-up requirement only for privileged mutations.
- Every accepted administrator mutation has a current login, administrator
  membership, unexpired fifteen-minute receipt and current Cedar decision.
- A pending continuation can authorize only the exact actor, resource, action
  and arguments that created it, once, before expiry.
- No-key enrollment returns to the allowlisted original page for explicit retry;
  setup writes no administrator mutation. Missing email freshness, stale targets,
  changed role, replay and substituted arguments refuse the privileged action.
- Passkey credential changes require a live login and verified existing credential,
  preserve the last-administrator/last-passkey guards, and immediately end
  elevation when its proving credential is removed.
- Elevated administrators remain refused for Customer resources they do not
  own. Other VM overrides retain current Cedar action and lease checks;
  elevation never authorizes SSH or internal service credentials.

## Implementation evidence

The [LiveView guard](../../../marshall/lib/marshall_web/live_admin_auth.ex),
[continuation grammar](../../../marshall/lib/marshall_web/admin_elevation.ex),
[security coordinator](../../../marshall/lib/marshall/accounts/security.ex),
[browser ceremony](../../../marshall/assets/js/admin_elevation.js) and
[Security settings](../../../marshall/lib/marshall_web/live/security_live.ex)
add the fifteen-minute receipt, enrolled-key modal, socket-local continuation
and no-key setup return path. The focused backend run passed 35 checks (3
properties, 32 tests), including real signed-assertion continuation/refusal
examples and fixed receipt expiry arithmetic, as recorded in the
[review](../reviews/2026-10-11-privileged-administrator-step-up.md).
The initial packaged `mfa-login-browser` and `admin-account-browser` checks
passed ordinary/remembered access, inline continuation, cancellation/focus
recovery and colocated cross-replica revocation. That capture predates the final
no-key return, browser state/copy and machine recovery changes; final merged
acceptance is recorded separately. The final integration on origin/main
`1722fbdf` passed both packaged browser checks, including ordinary and remembered
access, no-key Security return and explicit retry, inline continuation,
cancellation/focus restoration and colocated cross-replica revocation. It
includes the final browser state and copy; VM target recovery is included in the
release but was not exercised by these native journeys.
The [machine workspace](../../../marshall/lib/marshall_web/machine_workspace.ex)
and [recovery examples](../../../marshall/test/marshall_web/admin_machine_recovery_test.exs)
add expiry explanations and a route back to Fleet workloads. All five focused
machine recovery examples passed; they establish mounted authorization and
recovery behavior, not native VM/browser execution.
Existing Control room,
credential and Customer-isolation evidence retains its historical scope and does
not prove this decision. Exact artifacts, execution scopes and remaining gaps are
recorded in the review and scenario ledger.

## Open questions

Native timed receipt expiry, machine-page recovery, broader mutation families,
hardware authenticator behavior and production rollout remain open. Three serving
replicas in one VM establish independent-process browser behavior, not physically
independent hosts. Socket-local continuations intentionally do not survive
navigation or reconnect; PostgreSQL receipts and mutation admission remain the
cross-replica authority.

## Related decisions

[ADR-0119](0119-authenticated-control-room-reads.md),
[ADR-0065](0065-passkey-administration.md),
[ADR-0058](0058-administrative-authority.md),
[ADR-0064](0064-customer-workspace-isolation.md),
[ADR-0022](0022-browser-terminal-and-live-login-checks.md).
