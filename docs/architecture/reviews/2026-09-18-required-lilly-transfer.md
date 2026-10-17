# Required Lilly transfer service

## Scope and findings

The production evacuation accepted at 18:00:21 UTC on September 18 remained
active with three `source_unavailable` items and no relocation records. Read-only
PostgreSQL queries showed NULL transfer endpoints on both workers. SSH inspection
confirmed three running guest units on Dungarees and no transfer service on either
host. The scheduler correctly refused admission without a pinned endpoint.

High severity deployment gap: optional transfer configuration made healthy
production workers incapable of evacuation. ADR-0071 makes the service mandatory
for enabled Lilly while retaining ADR-0037's authenticated export and execution
fencing and ADR-0061's distinction between acceptance and physical readiness.

## Change and architecture assessment

Lilly enables transfer automatically, rejects disablement and defaults to port
2223 with a firewall rule. The listener rejects administrative SSH port collisions.
Fleet declarations supply both production endpoint identities and the profile
checks their port and declared key. The existing ADR-0045 preparation code sends
these declarations during enrollment. Domain authority and wire protocols are
unchanged. No guest execution or production database mutation is part of this diff.

## Validation and remaining gaps

Passed `module-configuration`, `enrollment-configuration`, `ziggy-configuration`,
`audi-configuration` and `brady-configuration` Nix checks. Evaluated both actual
production host configurations: transfer enabled, port 2223, firewall rule present,
and no failed assertions. ADR structure/link validation and code-contract syntax
and coverage checks passed in `devenv shell`; these are structural checks.

The enrollment fixture needed its existing route and mandatory fleet-monitor
declaration brought up to date. Service-only fixtures now explicitly declare
synthetic storage; this does not establish physical storage readiness.

The ZFS guest and Ziggy service machine drivers also evaluate successfully.
Broader machine-driver evaluation encountered an existing missing
`services.ziggy.secretsFile` in the shared role fixture, affecting service-roles,
application-metrics, Audi service and enrollment-operator. Inception driver
evaluation was stopped after it triggered an unrelated guest-image rebuild.
No native machine test execution is claimed. Production activation, endpoint
registration and a completed evacuation remain unverified. Nix configuration does
not backfill existing database rows. No production success is claimed from
evaluation tests. No Elixir application code or governance tooling changed.
