# ADR-0139: Private SLO burn notification delivery

- ID: ADR-0139
- Date: 2026-10-03
- Status: accepted
- Implementation: partial
- Components: NixOS, Prometheus, Alertmanager
- Supersedes: none
- Superseded by: none

## Context

Prometheus evaluates forty seven-day provisional burn warnings, but the deployed
fleet has no notification receiver. The user authorized implementing remaining
SLOs, burn alerts and deployment. A destination and its approved runtime secret
reference have not yet been supplied.

## Decision

Provide optional NixOS-managed upstream Alertmanager on the central telemetry
host. Enable delivery only with an explicit runtime HTTPS webhook file, optionally
with a runtime bearer credential. Systemd loads private credentials; neither
secret value enters evaluated Nix configuration. Listen only on IPv4 loopback,
disable clustering, and open no firewall port.

Derive forty exact routes from the objective roster. Each route requires matching
alert name, objective, fast/slow window, provisional status and warning severity.
The default receiver has no integration. Notify firing and resolved states;
disable redirects. Preserve ADR-0132 targets, coverage guards and provisional
policy. Retention remains ninety days under ADR-0138.

Suppress upstream stdout/stderr because delivery errors can contain destination
URLs. Scrape the local Alertmanager metrics for notification health and failures.
Keep upstream build-time schema validation enabled; its parser accepts private
file references without reading their contents. Also validate HTTPS and the
completed configuration at service startup, when private credentials exist.

## Alternatives

Grafana-managed notification policies would introduce a second source of alert
evaluation and routing. A custom Rust sender would duplicate upstream retry,
grouping and resolved-notification behavior. Email requires additional destination
and SMTP configuration; the destination remains an explicit operator choice.

## Consequences

Delivery is optional and remains disabled in production until destination and
credentials are supplied. Central host failure interrupts notification delivery;
this does not establish independent monitoring availability. Local metrics and
service status replace potentially secret-bearing upstream logs. Repeat delivery
and receiver-side deduplication must be expected.

## Invariants and verification

- Unrelated or mismatched alerts must not reach the destination.
- Credentials must remain private runtime files outside the Nix store.
- HTTP destinations must refuse startup; HTTPS must verify system trust.
- Receiver outage must produce retries without being reported as successful.
- Native restart must recover firing and resolved notification delivery.
- Disposable fixture alerts prove transport only, not seven-day compliance.

## Implementation evidence

The [delivery module](../../../nix/domains/system/otel-fleet/burn-delivery.nix) configures
the sender, routes, custody and private listener. The
[NixOS test](../../../nix/verification/tests/machines/otel-burn-delivery/default.nix) uses actual
Prometheus and Alertmanager with a
[Rust fixture](../../../nix/verification/tests/machines/otel-burn-delivery/receiver.rs) behind
verified TLS. Its [driver](../../../nix/verification/tests/machines/otel-burn-delivery/driver.py)
contains refusal, retry and restart assertions. The
[review](../reviews/2026-10-03-private-burn-delivery.md) records the complete
final native check passing in 97.55 seconds, including eighty generated route histories.
This establishes the disposable transport scope; production external receipt
remains untested.

## Open questions

The approved destination, credential provisioning reference and external receipt
remain required before production enablement. Independent notification failure
monitoring and receiver-side handling are not established by this capability.

## Related decisions

- [ADR-0132](0132-seven-day-provisional-fleet-objectives.md)
- [ADR-0138](0138-telemetry-retention-and-measurement-diagnostics.md)
