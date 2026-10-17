# ADR-0064: Customer workspace isolation

- ID: ADR-0064
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: protocol, Marshall Access, Marshall Ingress, Lilly networking, Lilly ingress, NixOS tests
- Supersedes: ADR-0049, ADR-0054, ADR-0058, ADR-0063
- Superseded by: ADR-0069

[ADR-0069](0069-brady-egress-cache.md) retains Customer isolation and adds Brady
interception for profiles already permitted public egress.

## Context

Customer workspaces contain customer material. The user explicitly requires blocked
egress, no sharing or service exposure, and authenticated owner SSH. The existing
policy allowed all profiles public egress and marked web ingress. This is an
authorized policy replacement, not correction of an accidental implementation.
The user authorized incompatible changes and coordinated delivery without a
backward compatibility requirement.

## Decision

Carry forward ADR-0049, ADR-0054, ADR-0058 and ADR-0063 and their inherited decisions except Customer
network access and sharing. Administrators do not bypass owner-only Customer
workspace access; separate fleet inventory, maintenance and security revocation
remain available. Customer retains its 10.10.0.0/16 allocation identity.
It permits only authenticated workspace-owner SSH through Audi/Lilly on port 22
and owner serial-terminal access. All guest-initiated network connections and all
platform web exposure are forbidden. This includes host-local private DNS/HTTPS
and Ziggy inference: Customer has no private-service egress exception. SSH reply packets on admitted connections
and gateway ARP remain permitted; this is not general established-flow permission.

A closed shared profile capability policy governs the control plane and provisioner.
Unknown capabilities/profiles fail closed. Other declared profiles retain their
capabilities. Profile identity is immutable, including across clone and relocation.

Marshall applies owner-only authorization with Cedar, ignores Customer grants,
and rejects grant creation/replacement and endpoint configuration. Revocation
remains possible. Web login and stream admission/renewal reject Customer before
public-access or credential exceptions. Shared discovery needed for SSH remains;
DNS and certificate presence do not authorize guest web connections.

Lilly checks the durable profile at actor admission/renewal and socket creation.
Private-service identity, inference admission and renewal also require egress
capability; old inference records confer no authority. The namespace firewall removes Customer from forwarding/NAT and web exceptions,
and drops forbidden Customer flows before generic conntrack acceptance. Only
SSH-marked local port-22 connections and their replies are permitted. Existing
anti-spoofing, family restrictions and host/peer isolation remain required.
Atomic owned-table setup must succeed before execution readiness, including when
Lilly restarts around independently surviving VMMs.

## Alternatives

UI-only restrictions, Marshall-only authorization, and removing NAT alone leave
bypass paths. Disabling the guest NIC would prevent the requested owner SSH.
Allowing established traffic without service-specific checks would preserve old
forbidden connections. All are rejected.

## Consequences

Customer guests cannot fetch packages, resolve external DNS or contact services.
Their required tools must be in images or transferred by the owner. Owner SSH and
serial sessions can carry arbitrary bytes: preventing owner-mediated copying or
relaying is outside this boundary. The platform must never claim otherwise.
Coordinated upgrades are required; no mixed-version safety or production deployment
is established by a source commit. No destructive grant/history migration is needed:
stored records cannot override current profile authorization.

## Invariants and verification

- Customer egress fails for TCP, UDP/DNS and ICMP; IPv6 and spoofing remain denied.
- Only the owner can open/renew Customer SSH or terminal authority.
- All Customer web ports, including web-marked port 22, fail at both application
  and kernel boundaries. Public endpoints and stale grants cannot bypass denial.
- Other profiles supply reachable positive controls in isolated network tests.
- Test real namespace filtering and two-Lilly Firecracker isolation, restart,
  relocation and policy replacement; mocks do not establish packet isolation.
- Run all three application precommit gates and structural ADR validation.

## Implementation evidence

[Profile capabilities](../../../protocol/lib/overalls_protocol/profile_policy.ex),
[authorization](../../../marshall/lib/marshall/access/authorization.ex),
[web admission](../../../marshall/lib/marshall/ingress/execution.ex),
[actor](../../../lilly/lib/lilly/vm/actor.ex) and
[firewall](../../../lilly/lib/lilly/network/policy.ex) implement layered checks.
[Namespace fixture](../../../nix/tests/machines/audi-ingress/driver.py) and
[Firecracker matrix](../../../nix/tests/machines/fleet/network.exs) exercise
kernel and guest paths respectively. The dedicated
[Customer fleet setup](../../../nix/tests/machines/fleet/scenarios/customer-setup.py)
places all three tested profiles on both Lilly hosts;
[restart probes](../../../nix/tests/machines/fleet/scenarios/customer-recovery.py)
repeat isolation checks after Customer stop/start. Execution results and remaining acceptance
are recorded in the [review](../reviews/2026-09-18-customer-isolation.md).

## Open questions

Native first-move isolation is verified, including completed source cleanup and
destination egress denial. The broader return-move run timed out in its final
transfer before activation, so return and stopped-move acceptance remain open
for the relocation subsystem. The latest two-host rerun passed network/update
stages but failed its stop/start setup before post-restart probes; earlier
stop/start acceptance is historical. Namespace, owner-SSH and two-host recovery results
are recorded in the review. Deployment verification and inherited partial
requirements remain separate; no unresolved product-policy decisions remain.

## Related decisions

[ADR-0049](0049-organizational-email-registration.md),
[ADR-0054](0054-inception-development-profile.md),
[ADR-0052](0052-fenced-local-guest-ingress.md),
[ADR-0058](0058-administrative-authority.md),
[ADR-0063](0063-private-services-and-ziggy.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md).
