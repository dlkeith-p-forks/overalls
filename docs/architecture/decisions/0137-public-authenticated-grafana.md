# ADR-0137: Public authenticated Grafana

- ID: ADR-0137
- Date: 2026-10-03
- Status: accepted
- Implementation: partial
- Components: NixOS, Overalls, Grafana, HAProxy, fleet firewall
- Supersedes: none
- Superseded by: none

## Context

ADR-0132 retained operator-only loopback Grafana. The user now requests public
HTTPS access on Overalls through a NixOS option and a firewall grant, and selected
port 3443. Public reachability must preserve Grafana authentication and separate
telemetry listeners from VM/control-plane authority.

## Decision

The user's October 3 instruction and approved implementation plan authorize this
amendment to ADR-0132. Add default-off `services.overallsOtelFleet.publicGrafana.enable`
and typed `port` (default 3443). Overalls opts in at `https://ghuntley.dev:3443/`.
Require the central telemetry role and the existing Marshall proxy, with an
explicit IPv4 address and a distinct port. Append a dedicated HAProxy frontend
using that proxy's hostname and validated runtime certificate. Certificate
issuance/publication/reload stays under its existing owner.

Grafana's backend stays on loopback port 3000. Public requests require the correct
Host; the proxy replaces forwarded identity headers. Grafana's external URL and
secure cookies reflect HTTPS. Anonymous access and sign-up remain disabled;
private generated operator credentials remain outside the store. This does not
introduce Marshall single sign-on or make dashboards anonymous.

Admit only the selected TCP port at the explicit destination through ADR-0091's
registry. When the fleet perimeter is disabled, use the existing address-scoped
listener firewall helper. Grafana traffic has its own frontend and never enters
Marshall's ingress SLI. Prometheus, Tempo and collector listeners stay private.

## Alternatives

Exposing the loopback backend directly would require new certificate custody and
listener changes. A new reverse proxy would duplicate existing certificate and
reload ownership. Anonymous dashboards would expose telemetry without the
requested operator authentication boundary.

## Consequences

Operators can reach Grafana without an SSH tunnel. Its login endpoint becomes
internet reachable and Grafana remains responsible for account authentication.
The public path shares HAProxy and certificate availability with Marshall, while
its backend and frontend are independently named. No SLO target, source custody,
guest authority or notification destination changes.

## Invariants and verification

- Disabled configuration creates no public Grafana listener or firewall grant.
- Worker/disabled telemetry, missing proxy, wildcard bind and conflicting ports
  refuse evaluation; both firewall backends scope the grant to one destination.
- Native HTTPS verifies the certificate and hostname; anonymous/wrong credentials
  cannot read operator data, and wrong Host requests receive 421.
- Untrusted clients cannot reach Grafana's backend, Prometheus or Tempo directly.
- Reload retains the public HTTPS path. Generated port configurations preserve
  authentication and address-scoped access.

## Implementation evidence

The [public Grafana module](../../../nix/domains/system/otel-fleet/public-grafana.nix)
implements opt-in configuration, forwarding and firewall composition. The
[Overalls configuration](../../../fleet/hosts/overalls/configuration.nix) enables
it. [Configuration checks](../../../nix/verification/tests/evaluation/public-grafana.nix) and
[native test](../../../nix/verification/tests/machines/public-grafana/default.nix) are present;
passing execution and production activation are recorded separately in the
[review](../reviews/2026-10-03-public-grafana.md).

## Open questions

Production activation and external reachability remain to be verified.

## Related decisions

Amends [ADR-0132](0132-seven-day-provisional-fleet-objectives.md)'s private Grafana
access boundary and extends [ADR-0091](0091-fleet-perimeter-public-listeners.md)'s
reviewed public registry. Preserves [ADR-0075](0075-fleet-overlay-and-source-access.md)
and [ADR-0030](0030-nixos-deployment-and-tls.md). Durable request custody remains
[ADR-0136](0136-durable-application-request-accounting.md).
