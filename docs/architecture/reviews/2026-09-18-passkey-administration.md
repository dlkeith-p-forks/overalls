# Passkey administration and account retirement review

Date: 2026-09-18. Scope: Marshall authentication, Cedar, browser/terminal/ingress
identity, account lifecycle and packaged verification.

## Decisions and boundaries

ADR-0065 replaces ADR-0058's role-only administrative authority while carrying
forward its bootstrap, last-administrator and audit rules. ADR-0066 replaces
ADR-0049's identity lifecycle while preserving exact-domain verified registration.
ADR-0022's fresh login checks now also enforce completed MFA and privilege expiry.
The concurrent ADR-0063 integration retains usage views and adds retirement checks
to inference admission/renewal while preserving accounting completion.
ADR-0064's later Customer isolation is preserved at every access boundary, including
for elevated administrators. Retirement still deletes every owned profile without
granting access to guest contents. The cascade test uses a Customer VM and the
Customer authorization regression now supplies a genuinely elevated administrator.
SSH deliberately receives no browser elevation; owners and shared users retain
ordinary rights. No changes to Lilly's execution protocol are required.

## Implementation review

- PostgreSQL challenge consumption and account locking serialize assertions across
  nodes. Receipts bind stored login, credential and account generation; client
  metadata alone cannot grant elevation. Read-only administration stays available.
- Upstream default credential routes are not exposed. Marshall invokes its
  registration API behind the account ceremony coordinator and uses Wax assertions.
- User retirement retains foreign keys, disables identity immediately and fences
  new owned work. Cleanup validates a durable deletion receipt and existing physical
  lifecycle outcomes; it does not fabricate an administrator or release capacity.
- Email retirement prevents reuse of earlier links; new same-email users receive
  new UUIDs. Existing sessions, grants and cleanup cannot follow that new identity.
- Migration up paths add schema only. No production migrations or deployment are
  performed by this change. Dependency fetching uses a refreshed fixed-output hash.

## Validation

Marshall's complete `mix precommit` passed in the pinned Elixir 1.20.4/OTP 29.0.6
shell on the integrated Customer-isolation tree: **717 checks (64 properties,
653 tests), two existing host/capacity exclusions**. This includes three independent
BEAM replicas racing passkey consumption and account retirement/admission, the
malformed-authenticator regression, real signed assertions, expiry/revocation,
Customer isolation with an elevated administrator, and cascading Customer cleanup.
Runtime/compiler, formatting, ADR/contracts, browser-state checks and forced
Dialyzer passed. Dialyzer reports zero errors and zero exclusions; the upgraded
Ash Authentication Phoenix types remove the obsolete upstream exclusion (ADRs
0002/0009). Contract discovery used the repository adapter, with manual review of
authentication, domain admission, lock ordering and ongoing access boundaries.

Chromium with a CTAP2 virtual authenticator passed real browser enrollment,
verification, naming, administrator last-key protection, lock-now, redirect and
explicit retry of role changes, user deletion and MFA on a fresh email session.
The probe uses a disposable test database; it does not establish physical-device
compatibility. The final integrated Nix Marshall release/source check passed,
including the packaged application and generated background workers.

No new physical NixOS/Firecracker destruction run is claimed. The deletion tests
exercise real Ash/PostgreSQL coordinators and protocol outcomes: held storage
persists until the exact cleanup receipt, shared-only machines survive, and
replicas resume durable cleanup while retirement fences new admission. They do
not prove physical erasure on an actual Lilly host. Existing lifecycle native
acceptance and physical-host failure scenarios remain separate.

## Rollout

Apply migrations before the new release. Quiesce older serving instances before
routing protected traffic to the new policy. Existing sessions have no elevation.
Confirm the deployed canonical HTTPS hostname before enrollment; changing the RP
identity invalidates access to credentials registered for a different RP.
Enrollment is required before an administrator can mutate anything. There is no
emergency reset command; total lockout requires manual database intervention.
