# ADR-0181: Public HTTP-01 ingress for the Marshall proxy

- ID: ADR-0181
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: NixOS fleet firewall, Marshall proxy, ACME HTTP-01 ingress
- Supersedes: none
- Superseded by: none

## Context

[ADR-0075](0075-fleet-overlay-and-source-access.md) made public HTTP-01
intentionally unavailable: only reviewed sources reach the proxy address.
The Overalls proxy certificate for `overalls.dev` predated that perimeter and
was never reissued under it. On 2026-10-16 the public hostname moved to
`ghuntley.dev` after `overalls.dev` lapsed. Let's Encrypt then reported
`Timeout during connect (likely firewall problem)` for
`http://ghuntley.dev/.well-known/acme-challenge/…`. With no valid certificate,
the publication validator kept HAProxy stopped, and the browser origin was
unavailable. [ADR-0091](0091-fleet-perimeter-public-listeners.md) left the
proxy's issuance method as an open operator decision.

## Decision

The user authorized this on 2026-10-16 by choosing to open `.55:80` publicly
over DNS-01 through Cloudflare or a temporary opening. Under that
authorization, the HTTP-01 ingress (`marshall-acme-http`) on the proxy's
explicit address is admitted from any IPv4 source on TCP 80 only, through the
typed `publicServices` registry. The ingress serves only ACME challenges for
the configured public host and permanent HTTPS redirects. It carries no
certificate key and no Marshall route.

Admission is an explicit per-host opt-in
(`services.marshallProxy.acme.http01.publicIngress`). Overalls enables it. The
proxy's public listeners share one destination entry (`marshall-proxy`), so
ADR-0091's unique-address invariant still holds while public Grafana
([ADR-0137](0137-public-authenticated-grafana.md)) and HTTP-01 coexist. Port
443 and every other proxy listener remain reachable only from reviewed sources.

This amends ADR-0075's consequence that public HTTP-01 is unavailable, and it
resolves ADR-0091's open question for the Overalls proxy.

## Alternatives

DNS-01 through Cloudflare would keep port 80 closed. It needs a new
challenge provider (the module supports Route 53 only) and a new
zone-write credential. Opening port 80 only during issuance would require a
manual step every renewal (about 60 days) and would fail silently when that
step is missed. Moving the apex into Audi's zone would break ADR-0090's
strict-subzone rule.

## Consequences

Renewal becomes unattended again. Anonymous clients can reach a minimal
HAProxy that answers challenge lookups and redirects; request handling is
bounded by its existing connection limits and timeouts. Exposing the
challenge path reveals nothing beyond the public token flow.

## Invariants and verification

- Without `publicIngress`, no public entry is contributed for port 80.
- With it, the only addition is `tcp dport 80` on the proxy's explicit address
  under the shared `marshall-proxy` entry. Wildcard and duplicate-address
  entries still fail evaluation.
- Live check: Let's Encrypt issues a certificate for the public host,
  `marshall-certificate` publishes it, and HAProxy serves it on 443 to
  reviewed sources.

## Implementation evidence

[`nix/domains/system/acme/http.nix`](../../../nix/domains/system/acme/http.nix) declares the
opt-in and the shared entry, and
[`public-grafana.nix`](../../../nix/domains/system/otel-fleet/public-grafana.nix)
joins it. The [Overalls services](../../../fleet/hosts/overalls/services.nix)
enable it. The [public Grafana evaluation check](../../../nix/verification/tests/evaluation/public-grafana.nix)
asserts the shared entry and adds HTTP-01 cases (merged with Grafana, default
off, opt-in alone); the check built successfully on 2026-10-16. Live: after
activation on Overalls, Let's Encrypt issued `ghuntley.dev` (expiring
2027-01-14), `marshall-certificate` published it and HAProxy served it with a
verified chain. Implementation stays partial until a NixOS machine test
exercises public port 80 through the perimeter.

## Open questions

Whether Dungarees or future proxies should opt in is decided per host.

## Related decisions

[ADR-0075](0075-fleet-overlay-and-source-access.md),
[ADR-0091](0091-fleet-perimeter-public-listeners.md),
[ADR-0038](0038-http01-validation-and-peer-routing.md),
[ADR-0137](0137-public-authenticated-grafana.md).
