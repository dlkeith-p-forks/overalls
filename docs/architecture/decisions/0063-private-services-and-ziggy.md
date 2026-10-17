# ADR-0063: Private guest services and Ziggy inference

- ID: ADR-0063
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, Audi, Ziggy, protocol, NixOS guest
- Supersedes: none
- Superseded by: ADR-0064, ADR-0078, ADR-0099, ADR-0149

Customer eligibility is superseded by [ADR-0064](0064-customer-workspace-isolation.md):
Customer cannot reach private DNS/HTTPS or inference. The per-host
certificate issuance provisions are superseded by
[ADR-0078](0078-fleet-wildcard-certificate.md), which replaces runtime
issuance and renewal with one offline fleet wildcard certificate. Other
decisions and remaining acceptance obligations are carried forward.
The direct provider routing clause is superseded by
[ADR-0099](0099-marshall-owned-agent-threads.md) for enrolled hosts using
host-local Underclass.
Historical rationale follows.

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

The user authorized private services and Ziggy, without backwards compatibility,
in a new worktree. The canonical endpoint is `https://llm.internal`. The accepted
load target is 1,000 simultaneous streams per Lilly host for fifteen minutes.

## Decision

Every deployed Lilly host runs Ziggy and Audi's private frontend. The NixOS Ziggy
module defaults its enablement and node connection settings from Lilly and rejects
an explicit disable on a Lilly node; provider secrets remain mandatory. Lilly owns
caller identity before NAT and isolation; Audi owns authoritative internal DNS,
TLS and certificate custody; Ziggy calls providers directly. Marshall Ash and
PostgreSQL own authorization and accounting. No application shares a database
connection across these release boundaries.

Reserve 169.254.254.1 in the owned namespace, permitting only guest UDP/TCP 53
and TCP 443. This explicitly adds registered private services to the network
policy inherited from ADR-0015, preserving every other private/host/sibling
restriction. Split DNS routes only `.internal` to Audi; unknown internal names
must not leak to public resolvers. A trusted local connection context binds VM,
host, placement and execution epoch. Peer headers cannot manufacture identity.

Public CA roots are reproducible guest image inputs. Root, intermediate and individual host service
certificates expire after five calendar years, capped by issuer expiry. Keys are never generated during builds.
Audi retains individual host keys; no fleet-wide private key is shared. Public
VM certificates retain Audi ACME; private subjects use the private issuer.
Certificate readiness is not request authority. Destination internal-service
readiness precedes relocation; interrupted inference must never be replayed.

All provider keys use existing SOPS/SecretSpec/systemd credential delivery and
never enter Marshall, Audi, guests or logs. Nested development must not inherit
outer-host production secrets. Independent Ziggy authority binds its host.

Expose models, OpenAI Responses/chat and Anthropic Messages/token counting with
native streaming. Discovery refreshes every fifteen minutes with jitter and
pagination. All available models in these API families are usable; LLMDB enriches
metadata/prices but never gates new models. No automatic inference retry, content
capture, public inference, API translation or monetary quota is included.

Persist admission before provider effects and use bounded idempotent accounting.
Record VM owner, execution identities, provider/model, operation, request IDs,
timings, outcomes, bytes and reported token categories. Missing values are unknown;
cost estimates are labelled with pricing provenance. Details expire after ninety
days and daily totals after one year. Owners see their records; admins see the
fleet. Sharing a VM does not grant access to owner accounting. Thirty-second
request authority renews every ten seconds and fences active streams on expiry.

## Alternatives

A central proxy was rejected for direct access from each Lilly host. Private
PKI replaces public DNS/CA validation for private services. A second Ziggy ACME
stack duplicates Audi. Shared server keys spread compromise across the fleet.

## Consequences

New images and services move together. Existing writable disks are not silently
rewritten; root rotation uses overlapping roots and explicit guest updates.
Five-year certificate lifetimes require explicit rotation/revocation.
Native execution and capacity remain separate acceptance obligations.

## Invariants and verification

Property tests exercise streaming boundaries, accounting idempotency, lifecycle
fences and crash recovery. Nix checks verify trust and secret-free builds. Real
two-host Firecracker checks cover all profiles, relocation, spoofing, secrets and
isolation. Sustained real guest load must demonstrate the accepted capacity.

## Implementation evidence

The [Ziggy application](../../../ziggy/lib/ziggy/application.ex),
[Marshall inference domain](../../../marshall/lib/marshall/inference.ex),
[Audi private frontend](../../../audi/lib/audi/private/front.ex), and
[Lilly binding connector](../../../lilly/lib/lilly/private/server.ex) implement
separate authority and execution boundaries. The
[Ziggy control client](../../../ziggy/lib/ziggy/control.ex) now classifies a
Marshall HTTP 426 separately from transient unavailability. Generated
[version-refusal histories](../../../ziggy/test/version_refusal_test.exs)
exercise the reporter and agent poller against real durable spool entries and
check that automatic retries stop without acknowledging retained receipts.
Marshall's [Ziggy control service](../../../marshall/lib/marshall/control/services/ziggy.ex)
answers an explicit wrong body version with `unsupported_version` (426 before
ADR-0142 moved Ziggy onto the control WebSocket); generated
[op tests](../../../marshall/test/marshall/control/satellite_version_test.exs)
check the closed refusal. These local histories do not establish hosted
version-skew behavior. The
[guest module](../../../nix/domains/artifacts/guest/private-services.nix) supplies explicit
public trust and split DNS; [service configuration](../../../nix/domains/system/ziggy.nix)
uses existing SOPS bundles and systemd credentials.

The existing [fleet collector](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/runtime.py)
and [Lilly admin page](../../../marshall/lib/marshall_web/live/admin/lilly_nodes_live.ex)
now expose content-free proxy observations and retained service charts, preserving
ADRs 0060/0062's separate monitoring authority and freshness rules.

The [kernel integration test](../../../nix/verification/tests/machines/private-services/default.nix)
boots real Audi and Lilly packages and exercises DNS/TLS and nftables isolation.
The [ledger](../../services/ziggy.md) distinguishes executed checks from missing native
Firecracker, production provisioning and sustained-load acceptance.

[ADR-0167](0167-native-guest-coding-clis.md) adds native-configured guest Codex
and Claude Code without changing private inference authority or provider policy.
The [route validator](../../../ziggy/lib/ziggy/route.ex) accepts exactly
`beta=true` for Anthropic Messages and token-counting POST requests, with or
without the matching provider prefix. The
[upstream transport](../../../ziggy/lib/ziggy/upstream.ex) preserves this validated
query while retaining the native path for accounting. This completes the native
SDK URL contract without permitting arbitrary queries or API translation.
[Route properties](../../../ziggy/test/route_test.exs) and
[provider-selection refusals](../../../ziggy/test/provider_selection_test.exs)
cover the closed allowance and disabled-provider refusal before effects. Current
execution scope is recorded in the
[coding CLI review](../reviews/2026-10-13-native-guest-coding-clis.md); production
Anthropic remains disabled and historical acceptance retains its original scope.

The [Dungarees deployment review](../reviews/2026-09-18-dungarees-provisioning.md)
records native worker enrollment, OpenAI discovery and guest acceptance. The
Audi frontend explicitly sets the canonical upstream Host over its Unix socket;
a native comparison demonstrated denial with the socket pool default and success
with `llm.internal`. Transport-derived binding and Marshall authorization remain
mandatory. This evidence does not establish sustained-load acceptance.

## Open questions

The private [SLO checkpoint](../../../ziggy/lib/ziggy/slo_checkpoint.ex)
preserves numeric aggregates and bounded completion replay identities through
ACK removal and process restart without executing inference again. The
[durability review](../reviews/2026-10-02-ziggy-durable-slo.md) records generated
and packaged SIGKILL evidence and the required compatible-reader-first rollout.
That rollout completed on both hosts; under [ADR-0159](0159-remove-legacy-compatibility.md)
the `durableSloCounters` switch and its reader-only path are removed, so the
[spool](../../../ziggy/lib/ziggy/spool.ex) always creates and maintains the checkpoint.
This extends accounting evidence, not native guest or sustained-load acceptance.

The production CA and overalls service authority have been provisioned. Provider
selection is explicit and defaults to both providers. Overalls and dungarees
select OpenAI while retaining an inactive Anthropic placeholder. The
[configuration parser](../../../ziggy/lib/ziggy/config.ex) loads only selected
providers, and [provider selection tests](../../../ziggy/test/provider_selection_test.exs)
cover default compatibility, invalid selections and rejection before effects.
Readiness still requires every selected catalog and authenticated host authority;
a disabled provider is never represented as ready. Synthetic test roots never
become production defaults.

## Related decisions

- [ADR-0015](0015-jailed-execution-and-host-networking.md): inherited isolation.
- [ADR-0047](0047-audi-ingress-and-authoritative-dns.md): Audi DNS/TLS custody.
- [ADR-0044](0044-recovery-only-secret-documents.md): root recovery custody.
- [ADR-0042](0042-host-observability.md): diagnostic privacy.
