# ADR-0038: HTTP-01 validation and peer routing

- ID: ADR-0038
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: NixOS deployment, ACME, HAProxy, certificate custody
- Supersedes: ADR-0036
- Superseded by: ADR-0043

## Context

[ADR-0043](0043-declarative-host-provisioning.md) replaces generic host deployment
and inventory boundaries while carrying forward the other decisions below.
This record preserves the historical rationale and evidence.

The user requested HTTP-01 as the default verification method, selected permanent
HTTP-to-HTTPS redirects only in HTTP mode, and required three machines behind
rotating DNS to validate regardless of the receiving frontend. The machines have
stable private connectivity. Backwards compatibility is explicitly unnecessary.
The approved implementation plan authorizes this decision.

ADR-0036 carries forward ADR-0030's Route 53-only certificate decision. Independent
HTTP solvers would fail whenever DNS directs validation to another machine.
HAProxy retries avoid only the last server, not all previously visited servers;
increasing a retry count does not establish complete multi-peer lookup.

## Decision

Replace the inherited DNS-only choice with default HTTP-01 and explicit Route 53
DNS-01. Carry forward all other ADR-0036 requirements, including automatic update,
migration, service-role, custody, TLS, installation and recovery boundaries.
Group HTTP and Route 53 settings under `http01` and `route53`, without legacy
aliases or implicit provider selection. Never fall back between methods.

In HTTP mode, an independent unprivileged HAProxy service listens on port 80,
accepts only the configured public hostname, forwards challenge GETs to a local
Unix-socket lookup service and redirects ordinary requests with HTTP 308 to the
configured HTTPS origin, retaining path and query. It must start without an
issued certificate or a working HTTPS proxy. HTTPS still requires a validated
certificate. DNS mode does not enable the HTTP listener or redirects.

Every frontend declares its own private Lego responder and every other issuer
for that hostname. Each machine retains its own account, certificate and private
keys. A Python/aiohttp lookup process queries the fixed local and peer responders
once each, concurrently, returning the first matching key authorization and
cancelling outstanding requests. Peer requests never traverse public listeners,
follow redirects, inherit environment proxies or select caller-provided hosts.
Use the supplied pinned Nixpkgs aiohttp package, not a runtime installation.

Use a three-second total deadline, two-second endpoint timeout, 1 KiB response
bound and sixteen active lookups. Reject overload with 503. Return 404 only if
all responders report a missing token; otherwise an unsuccessful lookup is 503.
Do not cache responses. The lookup and HTTP services cannot read TLS private keys
or DNS credentials. Diagnostics omit URLs, headers, tokens and raw client errors.

Peer mode uses explicit, unique RFC1918 or IPv6 ULA addresses of one family on a
trusted private network. All peers are trusted validation delegates for the
shared hostname. Firewall management opens public port 80 but allows the private
responder port only from configured peer IPs to the declared local address.
Firewall opt-out makes these rules the operator's responsibility. Publicly
reachable or untrusted peer networks require a different reviewed transport.

Preserve verified ACME endpoint trust, strictly selected DNS credentials and the
existing certificate chain/name/lifetime/key validation, atomic persistent
publication, independent publication retries and graceful HTTPS reloads. HTTP
mode requires no DNS credentials. Route 53 still exports its scoped IAM policy;
cloud provisioning and inter-host DNS TXT update coordination remain separate.

## Alternatives

A single shared validation server introduces a new availability dependency.
Shared filesystems or PostgreSQL token storage add custody and deployment
requirements to a standalone proxy role. Blind load-balancer retries do not
cover all peers deterministically. A two-server special case unnecessarily
limits the requested three-machine topology. Direct bounded peer lookup preserves
independent issuance without distributing private keys.

## Consequences

The peer list must describe every possible issuer before DNS starts routing to
new frontends. Each lookup can contact every configured peer, so three-machine
functional acceptance is not a large-fleet throughput guarantee. Unreachable
public frontends must be removed from DNS. Unavailable validation must not replace
a working certificate. The private network and configured peers are part of the
hostname-validation trust boundary. aiohttp is a new pinned host-side dependency;
application releases and shared protocol types remain unchanged.

## Invariants and verification

- Bootstrap with no valid certificate and no AWS credentials in HTTP mode.
- Validate every issuer through another frontend, including concurrent renewals.
- Exercise all nine combinations of owner and receiving frontend independently
  of probabilistic DNS routing.
- Reject arbitrary destinations, redirects, malformed or oversized responses,
  duplicate/self peers, mixed families and listener port collisions.
- Bound deadlines, active work and cancellation; a slow peer must not delay a
  valid response from another peer.
- Retain WebSockets during renewal and previous certificates after failure.
- Test source-restricted private firewall access and independent standalone mode.
- Retain the signed Route 53 fixture and publication/recovery regression suite.

## Implementation evidence

The [ACME module](../../../nix/modules/acme/default.nix) selects the challenge
method and conditional credentials. The
[HTTP module](../../../nix/modules/acme/http.nix) defines independent ingress,
private responders, firewall rules and assertions. The
[lookup service](../../../nix/modules/acme/lookup.py) bounds direct requests and
validates key authorizations without accessing certificates.
[Configuration checks](../../../nix/tests/evaluation/module-configuration.nix)
and [lookup checks](../../../nix/tests/evaluation/acme-lookup.py) pass locally.
The [HTTP machine suite](../../../nix/tests/machines/acme-http01/default.nix)
and [DNS regression suite](../../../nix/tests/machines/acme-route53/default.nix)
passed locally, along with the service-role regression. Exact execution results
and production acceptance limits are tracked in the
[review](../reviews/2026-09-17-http01-validation.md).
The [deployment guide](../../nixos.md) documents inputs,
limits and standalone/three-machine configurations.

## Open questions

Real CA/provider acceptance, production network configuration, independent
physical failure domains and larger-fleet load validation remain deployment work.

## Related decisions

[ADR-0036](0036-automatic-host-updates.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md).
