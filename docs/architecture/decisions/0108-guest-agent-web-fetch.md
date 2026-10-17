# ADR-0108: Guest-executed agent web fetch

- ID: ADR-0108
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Lyra, Marshall, NixOS guest, Ubuntu guest
- Supersedes: none
- Superseded by: none

## Context

OpenCode's `webfetch` reads HTTP content as text, Markdown or HTML. Overalls
already has Marshall-owned `web_search`, but a fetch must reach services local
to the VM and obey its existing network ACL and Brady path. Marshall still owns
the durable agent turn, authority and audit history.

## Decision

Marshall advertises `web_fetch` to OSS, Standard and Inception agents and
validates its URL, format and timeout arguments under the existing profile
policy. A claimed fetch is delivered to the fenced Rust CLI executor in the VM.
The CLI reports `started` before network activity and sends one bounded result
through the existing transition RPC. It uses a Rust HTTP client, the guest's
native CA store, direct guest networking, verified TLS and at most five redirects.
HTTP is allowed for guest-local and ACL-permitted services.

The request defaults to Markdown and thirty seconds. `text`, `markdown` and
`html` are supported; the timeout is at most 120 seconds. Responses above five
MiB, nontext content and unsuccessful requests return closed errors. A completed
result includes content type, content and a truncation flag within the existing
12 KiB executor request limit. HTML is converted to readable text or basic
Markdown in Rust. Fetched content remains untrusted model context.

The CLI writes only closed fetch state events. Marshall's command audit receipts
and catalog events record transitions without URL, body, credentials or error
text. Fetch results remain in authorized private thread state.

## Alternatives

Marshall execution would lose the guest's loopback and network policy. Shelling
out to curl would move HTTP behavior outside the Rust tool boundary. Enlarging
the executor wire and model context for whole-page output is deferred.

## Consequences

Already-running old CLI versions may reject the new tool until the private
guest updater replaces them. No compatibility requirement was requested.
Redirects and local HTTP reachability remain subject to the VM's network policy.

## Invariants and verification

- Only the persisted profile and current executor fence authorize dispatch.
- Every request has bounded time, redirects, download bytes and serialized
  result bytes; a redirect cannot switch to a non-HTTP protocol.
- TLS verification uses the guest trust store and is never disabled.
- Tests cover argument policy, native local fetch, denial, TLS, truncation and
  absence of payloads in diagnostic and audit records.

## Implementation evidence

The [profile allowlist](../../../marshall/lib/marshall/agents/capabilities.ex),
[tool schema](../../../marshall/lib/marshall/agents/model_protocol.ex),
[Rust fetch executor](../../../lyra/src/agent/web_fetch.rs) and
[closed CLI events](../../../lyra/src/log.rs) implement the boundaries. The
[profile property tests](../../../marshall/test/marshall/agents/capabilities_test.exs)
and Rust unit tests exercise validation. Both NixOS and Ubuntu
[fleet machine scenarios](../../../nix/tests/machines/fleet/scenarios/agent.py)
passed the real guest local fetch and content-free audit checks. Production
rollout remains unverified.

## Open questions

None for this release.

## Related decisions

[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) owns durable tool
execution; [ADR-0103](0103-profile-scoped-agent-capabilities.md) owns profile
authorization; [ADR-0107](0107-marshall-owned-agent-web-search.md) retains the
separate server-owned search tool; [ADR-0069](0069-brady-egress-cache.md) owns
guest egress interception.
