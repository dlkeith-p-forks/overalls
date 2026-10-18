# ADR-0198: Guest reflection service

- ID: ADR-0198
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
headers. Packaged NixOS machine coverage remains required before marking this
decision implemented.

## Alternatives

Returning raw control-plane integration records would expose credentials and
break guest isolation, so the bounded projection is preferred.

## Consequences

Guests gain discoverability without configuration files. Peach adds a small
private service and must be deployed with the private frontend.

## Invariants and verification

Snapshots contain no secret values, are bounded, and are fenced to the current
execution. Protocol property tests and a packaged NixOS guest journey verify
these invariants.

## Implementation evidence

See [reflection protocol](../../../protocol/lib/overalls_protocol/reflection.ex),
[Marshall projection](../../../marshall/lib/marshall/reflection/snapshots.ex),
and [Peach HTTP service](../../../peach/lib/peach/http.ex). Packaged deployment
and NixOS execution remain open.

## Open questions

Dedicated Peach host credential persistence and packaged service wiring remain.

## Related decisions

None.
