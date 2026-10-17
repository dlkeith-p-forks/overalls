# ADR-0123: Remembered browser authentication and revocation

- ID: ADR-0123
- Date: 2026-09-25
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, authorization, web
- Supersedes: ADR-0119
- Superseded by: ADR-0160

## Context

[ADR-0160](0160-privileged-administrator-step-up.md) replaces the inherited
five-minute administrator elevation and redirect flow with fixed fifteen-minute
step-up and exact pending-action continuation. It preserves remembered-browser
revocation, ordinary signed-in reads and the other authority boundaries here.

The verification campaign found that the real magic-link form issued persistent
remember credentials but the browser pipeline never exchanged them for a login.
Enabling that existing feature while revoking only `user` tokens would let a
no-MFA account immediately resume from the copied persistent cookie after the
administrator selected **Sign out everywhere**. The previous token-purpose
implementation was narrower than the user-facing operation.

The user delegated bounded missing implementations, defect repairs and associated
architectural decisions during this campaign. This record clarifies persistent
browser authority and carries forward every other requirement and rationale of
[ADR-0119](0119-authenticated-control-room-reads.md), including the inherited
MFA, account lifecycle, guest/SSH boundaries and fixed elevation lifetime.

## Decision

Exchange a valid remembered credential for a new stored browser login. This is
neither fresh email authentication nor completed MFA. Enrolled accounts must
verify their passkey independently for each resumed login; remembered logins
cannot establish the fresh-email receipt required for first enrollment.

**Sign out everywhere** revokes both `user` and `remember_me` token purposes for
the selected account. It preserves separate SSH/service credentials and intentional
fresh email sign-in. Hold the existing account row lock through remembered-token
revalidation and login issuance. Revocation uses that same lock: an exchange
committed first is included in revocation; an exchange ordered afterwards refuses.
MFA reset and retirement retain their existing account locks and broader revocation.

Fresh magic-link sign-in issuance is fenced by the same boundary: the sign-in
already holds the installation latch (and takes the account row lock through the
identity upsert) until its commit, and the authoritative browser login is minted
inside that commit. A revocation ordered afterwards observes and revokes that
login. The authentication strategy's own post-commit token insert cannot join the
transaction; it is revoked before the action returns, never becoming a returned
credential. A login revoked between issuance and the final server callback is
refused with a generic message instead of a crashed request. A magic-link sign-in
ordered after **Sign out everywhere** remains an intentional fresh email sign-in;
MFA reset and retirement revoke the link token itself, so a sign-in ordered after
them is refused.

Ordinary sign-out revokes its supplied browser and remember credentials, even when
the current login is absent or expired. If cookies refer to different accounts,
lock their validated subjects in sorted order before revocation. A completed MFA
receipt is never copied to a new token. Required LiveView authentication checks
pending MFA before invoking a protected view's mount callback.

## Alternatives

Leaving remember-me inert preserves a broken advertised option. Merely adding the
browser plug permits reauthentication after the global sign-out operation. Updating
token purposes without serializing exchange permits validation before revocation
followed by issuance afterwards. A new token-generation schema is unnecessary
because the existing account row and PostgreSQL token store supply the required
serialization boundary.

## Consequences

Remembered sessions now work, and administrators revoke persistent browser access
together with ordinary browser sessions. Sign-out may wait briefly for an exchange
holding the account lock. No schema, JWT format, guest or service protocol changes.
Deploy all serving Marshall replicas together before relying on this guarantee:
older replicas do not hold the exchange lock or revoke remembered credentials.
This change does not deploy production or validate independent-host availability.

## Invariants and verification

- Subsequent magic-link and remembered logins have independent MFA completion.
- Wrong-session, replayed, expired or non-UV assertions cannot complete a login.
- Elevation expiry does not undo completed login MFA.
- Global revocation prevents copied remember cookies restoring even a no-MFA login.
- Both committed exchange/revocation orders preserve the account lock boundary.
- Magic-link issuance committed before a revocation is included in it; a sign-in
  ordered after global session revocation remains a fresh email sign-in, while
  MFA reset and retirement order refusal.
- Mounted and fresh access recheck shared authority across serving replicas.
- An expired challenge is refused without elevation on any serving replica, and
  a fresh ceremony afterwards succeeds on a different replica.

## Implementation evidence

[Exchange preparation](../../../marshall/lib/marshall/accounts/remembered_login.ex),
[browser pipeline](../../../marshall/lib/marshall_web/router.ex),
[sign-out](../../../marshall/lib/marshall_web/controllers/auth_controller.ex) and
[administrative revocation](../../../marshall/lib/marshall/accounts/admin_users.ex)
implement the boundary. [Generated histories](../../../marshall/test/marshall_web/mfa_login_history_test.exs),
[cookie regressions](../../../marshall/test/marshall_web/remember_me_login_test.exs),
[committed races](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
and a [three-replica browser scenario](../../../nix/verification/tests/machines/mfa-login/browser.py)
provide assertions; execution and remaining acceptance are recorded in the
[verification review](../reviews/2026-09-25-mfa-login-verification.md).

The [job-history verification](../reviews/2026-09-25-job-history-verification.md)
extends inherited administrative retry evidence: account row locking orders
retry with elevation lock and ordinary sign-out through audit commit, with
passing generated/three-Marshall checks and the captured complete native
browser/worker journey. Physical hosts and production rollout remain separate.

The [credential self-service review](../reviews/2026-09-26-credential-self-service.md)
records that an ordinary account's last-passkey removal revokes its browser
credentials — including the mounted session that issued the removal — and that
signed-out stale views refuse navigation and mutation with unchanged stored
inventory; see its
[domain regressions](../../../marshall/test/marshall/accounts/security_credential_test.exs)
and [native journey](../../../nix/verification/tests/machines/credential-self-service/browser.py).

The [administrative account authority review](../reviews/2026-09-25-admin-account-authority-verification.md)
records the audit-commit overlap baseline and sorted participant correction for
role changes, global browser revocation, invitations, MFA reset and retirement.
Generated histories, 27 three-Marshall schedules and the captured native browser
reset/stale-page journey pass; the frozen full gate passed 1,124 checks and forced
test Dialyzer with zero findings. Exact source attribution remains in the review.
Existing durable cleanup, bootstrap, account fences and implementation status are preserved.

The [cross-replica revocation review](../reviews/2026-09-26-cross-replica-revocation.md)
verifies the shared-authority recheck invariant on non-login read surfaces:
generated three-BEAM schedules prove that session revocation committed on one
replica refuses mounted Control room reads, handbook and machine pages, the
usage export and the account projection read on the other replicas at the next
recheck, that the bound is transaction commit, and that a database-partitioned
replica fails closed and enforces the revocation on rejoin. The per-replica
native browser boundary for these surfaces keeps its 003/005 scope, and the
cross-replica native browser boundary keeps this review's 007 scope.
The [login race review](../reviews/2026-09-26-login-races.md) records the
fenced issuance repair for magic-link sign-in: change
[magic_link_sign_in.ex](../../../marshall/lib/marshall/accounts/magic_link_sign_in.ex)
mints the authoritative browser login inside the sign-in commit and revokes the
strategy's unfenced post-commit token before the action returns, and
[auth_controller.ex](../../../marshall/lib/marshall_web/controllers/auth_controller.ex)
refuses a login revoked between issuance and the session callback instead of
crashing on it. The deterministic reproduction failed before the repair — an
issued session survived a revocation committed during the post-commit issuance
window — and passes after it; the missing-fence mutation is detected by the
race oracle. The same review covers the native expired-ceremony refusal with a
cross-replica fresh retry and the sign-out/exchange serialization evidence.

## Open questions

Hardware authenticators, independent physical hosts and production rollout remain
external acceptance. The review records passing generated, committed-race and
colocated native browser evidence separately from those limits.

## Related decisions

[ADR-0058](0058-administrative-authority.md),
[ADR-0065](0065-passkey-administration.md),
[ADR-0119](0119-authenticated-control-room-reads.md),
[ADR-0022](0022-browser-terminal-and-live-login-checks.md).
