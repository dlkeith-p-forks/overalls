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
reads and secret-free audit. These tests are present; recorded native HTTP and
guest execution remain required before marking this decision implemented.

## Alternatives

Returning raw control-plane integration records would expose credentials and
break guest isolation, so the bounded projection is preferred.

## Consequences

Guests gain discoverability without configuration files. Peach adds a small
private service and must be deployed with the private frontend.

## Invariants and verification

Snapshots contain no secret values, are bounded, and are fenced to the current
execution. Protocol properties exercise bounded metadata. The Peach projection
fixture does not invoke its HTTP Plug; successful native guest projection and
current/stale execution histories remain acceptance gaps.

## Implementation evidence

See [reflection protocol](../../../protocol/lib/overalls_protocol/reflection.ex),
[Marshall projection](../../../marshall/lib/marshall/reflection/snapshots.ex),
[Peach credential domain](../../../marshall/lib/marshall/peach.ex),
[credential lifecycle](../../../marshall/lib/marshall/peach/credentials.ex),
[secret-free audit migration](../../../marshall/priv/repo/migrations/20261018211500_add_peach_credential_versions.exs),
[credential tests](../../../marshall/test/marshall/peach/credentials_test.exs),
[Peach HTTP service](../../../peach/lib/peach/http.ex) and
[packaged NixOS module](../../../nix/domains/system/peach.nix).
The package/module and test presence do not establish deployed fleet enablement
or a successful native HTTP projection. Audi permits Peach to remain disabled:
its optional backend socket is null and reflection refuses before requesting
guest execution authority. Configured sockets must be bounded canonical local
paths; Lilly, Ziggy and Galileo remain mandatory private-service dependencies.

## Open questions

Recorded property histories for current/stale execution and credential expiry,
successful packaged guest projection, host loss, and native same-host network
isolation remain. The declared fleet currently does not enable Peach; enabled
socket access and packaged credential lifetime still require review.

## Related decisions

None.
