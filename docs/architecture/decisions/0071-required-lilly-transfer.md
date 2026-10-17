# ADR-0071: Required Lilly transfer service

- ID: ADR-0071
- Date: 2026-09-18
- Status: accepted
- Implementation: partial
- Components: Lilly, NixOS, fleet enrollment
- Supersedes: none
- Superseded by: none

## Context

The Dungarees evacuation was accepted but all three workloads remained blocked
with `source_unavailable`. Both production hosts lacked the transfer listener
and an enrolled transfer endpoint. An optional deployment component allowed
otherwise healthy workers to be incapable of relocation.

## Decision

The user's explicit instruction that Lilly Transfer should always be enabled
authorizes making the restricted transfer service mandatory whenever Lilly is
enabled. Explicit disablement fails NixOS evaluation. The standalone export
module remains available for isolated endpoint tests.

Enabled Lilly defaults to transfer port 2223 and opens its firewall port.
Administrative SSH must use a different port. Fleet declarations carry the public
address, port and existing pinned Ed25519 identity; the installed port and
enrollment input share that declaration. Nix activation does not independently
mutate Marshall's durable host records. Existing hosts require endpoint enrollment
as well as service activation before relocation can run.

All existing permit checks, forced commands, private keys, bounded export workers
and execution fencing remain required by ADR-0037. Guest units remain independent.

## Alternatives

Keep transfer opt-in: rejected because it produced workers unable to evacuate.
Bypass source eligibility or patch relocation state: rejected because a missing
authenticated transfer channel cannot safely move storage or execution authority.

## Consequences

Every enabled Lilly requires a native ZFS pool and installs a restricted listener.
Configurations that disable transfer or reuse the administrative SSH port fail.
Firewall overrides remain possible for deployments using separately managed rules.
Enrollment and activation remain distinct operations; configuration alone does
not establish peer connectivity or successful evacuation.

## Invariants and verification

Evaluation must prove automatic enablement, explicit-disable rejection, distinct
ports and the declared fleet port being used by the installed listener.
Native transfer authentication and source fencing must remain unchanged.

## Implementation evidence

- [Lilly module](../../../nix/domains/system/lilly.nix) enables transfer and refuses disablement.
- [Transfer module](../../../nix/domains/system/transfer.nix) rejects administrative port collisions.
- [Host profile](../../../nix/platform/hosts/profile.nix) binds declared endpoint ports and identity.
- [Module checks](../../../nix/verification/tests/evaluation/module-configuration.nix) cover mandatory service and collision rejection.
- [Enrollment checks](../../../nix/verification/tests/evaluation/enrollment-configuration.nix) cover declaration binding.
- [Overalls](../../../fleet/hosts/overalls/host.json) and [Dungarees](../../../fleet/hosts/dungarees/host.json) declare endpoints.

Production activation, registration and evacuation acceptance remain pending.
Executed validation is recorded in the [review](../reviews/2026-09-18-required-lilly-transfer.md).

## Open questions

None.

## Related decisions

- [ADR-0037](0037-workload-placement-and-relocation.md): retained relocation and restricted transfer design.
- [ADR-0045](0045-declarative-lilly-enrollment.md): durable enrollment workflow.
- [ADR-0061](0061-maintenance-evacuation.md): maintenance campaigns.
