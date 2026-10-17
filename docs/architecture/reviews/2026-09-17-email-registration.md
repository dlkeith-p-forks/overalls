# Organizational registration review

Date: 2026-09-17

## Scope and decisions

ADR-0049 replaces ADR-0008's open registration requirement at the operator's
request, preserving its remaining access/terminal decisions. Account request and
verified-token actions enforce exact case-insensitive domain matching. The public
form gives identical request feedback without revealing registration or provider
state. A subsequent operator instruction removes all visible organization/domain
requirements while retaining server-side enforcement. No schema or stored-session mutation is introduced.

## Verification

Fourteen focused account/outbox/SMTP and real LiveView tests passed, covering
first registration, verified token consumption, single use, case-insensitive
identity, rejected external/suffix/subdomain identities and identical public
feedback. Initial attempts were blocked by concurrent uncommitted code; the final
ordinary Marshall precommit gate passed with 397 successful cases (37 properties,
360 tests), distributed checks and forced Dialyzer (one documented upstream
exclusion, no unused exclusions). Contract and 49-decision structure/link checks
also passed.

The UI test exposed a framework error interpolating Regex validation metadata.
The domain validation now returns fixed field-error text without Regex values or
recipient data. Revision fe30e45b0f5af9067340d5b2f78c3ed5e73425d1 deployed through
the normal updater and passed physical service health. The live sign-in form was
checked for the absence of organization/domain requirement text. Backend domain
rejection and eligible automatic registration are covered by the action and real
LiveView tests.

## SMTP incident

The existing sign-in request was queued but upstream SMTP connections from overalls
timed out on port 465. Authentication from the development machine had previously
passed and did not establish production connectivity. From overalls, port 587
negotiated verified STARTTLS and authenticated successfully using the encrypted
credentials. The host configuration now selects mandatory STARTTLS on port 587.
The committed port-587 configuration deployed through the normal updater. The
temporary runtime service override was removed after verifying the installed Nix
unit uses mandatory STARTTLS. Retrying the existing queued message succeeded:
its outbox state is delivered (SMTP acceptance). No private message
or token is exposed by these diagnostics; provider acceptance and inbox delivery
remain distinct.
