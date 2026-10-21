# ADR-0203: Guest reflection service

- ID: ADR-0203
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: protocol, Marshall, Audi, Lilly, Peach
- Supersedes: none
- Superseded by: none

## Context

Agents running inside a guest need a reliable description of their machine and
the private integrations available to that exact execution.

## Decision

Expose `reflection.internal` through the private-services network. Peach binds
requests to the current host and asks Marshall for a versioned, secret-free
projection containing guest resources, image and operating-system metadata,
current Lilly node, labels, comments, and eligible integration descriptors.
Only integration header names and kinds are returned; credentials and values
remain in the control plane. Stale, stopped, relocated, retired, or
unauthorized executions receive an unavailable response.

## Verification

Protocol property tests cover bounded metadata and rejection of secret-shaped
headers. Dedicated credential tests cover rotation, revocation, internal-only
reads and secret-free audit. Peach's suite drives its HTTP Plug against a
verified-TLS control stub, and the Galileo fleet machine test reads the
projection from a real guest. Hostname-verified production TLS awaits the
private leaf reissue, so the decision stays partial.

## Alternatives

Returning raw control-plane integration records would expose credentials and
break guest isolation, so the bounded projection is preferred.

## Consequences

Guests gain discoverability without configuration files. Peach adds a small
private service and must be deployed with the private frontend.

## Invariants and verification

Snapshots contain no secret values, are bounded, and are fenced to the current
execution. Protocol properties exercise bounded metadata. Peach refuses unknown
paths, methods, queries and foreign or duplicated bindings before any control
request, and never serves a projection after control admission fails or for a
guest other than the bound VM. Current/stale execution histories remain gaps.

## Implementation evidence

See [reflection protocol](../../../protocol/lib/overalls_protocol/reflection.ex),
[Marshall projection](../../../marshall/lib/marshall/reflection/snapshots.ex),
[Peach credential domain](../../../marshall/lib/marshall/peach.ex),
[credential lifecycle](../../../marshall/lib/marshall/peach/credentials.ex),
[secret-free audit migration](../../../marshall/priv/repo/migrations/20261018211500_add_peach_credential_versions.exs),
[credential tests](../../../marshall/test/marshall/peach/credentials_test.exs),
[Peach HTTP service](../../../peach/lib/peach/http.ex),
[Peach HTTP tests](../../../peach/test/http_test.exs),
[operator credential commands](../../../marshall/lib/marshall/operations/peach.ex),
[packaged NixOS module](../../../nix/domains/system/peach.nix) and the
[fleet guest journey](../../../nix/verification/tests/machines/fleet/scenarios/galileo.py).
See the [enablement review](../reviews/2026-10-20-peach-enablement.md) for recorded
runs and fleet rollout. Panterloons and Dungarees enable Peach; other hosts
may leave it disabled, and Audi permits that:
its optional backend socket is null and reflection refuses before requesting
guest execution authority. Configured sockets must be bounded canonical local
paths; Lilly, Ziggy and Galileo remain mandatory private-service dependencies.

## Open questions

Recorded property histories for current/stale execution and credential expiry,
host loss, and native same-host network isolation remain. The deployed private
leaf lacks the fixed `reflection.internal` SAN; offline leaf reissue and
hostname-verified production guest TLS remain before this decision is
implemented.

## Related decisions

None.
