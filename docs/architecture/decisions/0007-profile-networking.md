# ADR-0007: Profile networking and isolation

- ID: ADR-0007
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Lilly networking, Firecracker guests
- Supersedes: none
- Superseded by: ADR-0052

## Context

Historical profile labels are normalized to the Standard spelling selected by
[ADR-0147](0147-standard-profile-name.md); addressing and isolation rationale remain.

[ADR-0052](0052-fenced-local-guest-ingress.md) carries forward these isolation and
addressing requirements while replacing the first-release ingress prohibition
with Audi's authenticated, execution-fenced local connector. The rationale and
evidence below describe the earlier policy.

Three profiles select guest networking and future profile behavior. Guests need
outbound public Internet access and must not communicate directly with each
other, including across physical hosts.

## Decision

Canonicalize the profile name as Standard (alongside Customer and OSS). Use
these address pools, interpreting the specified address ranges as /16 networks:

| Profile | Pool |
| --- | --- |
| Customer | 10.10.0.0/16 |
| Standard | 10.20.0.0/16 |
| OSS | 10.30.0.0/16 |

Provide outbound NAT and return traffic for established outbound connections;
provide no public guest ingress in the first release. Enforce direct VM-to-VM
isolation within and across profiles and hosts. A profile subnet is an address
pool, not permission for guest-to-guest forwarding. Keep allocation identities
coordinated across hosts and retain an address while its VM is stopped.

## Alternatives

Shared bridged subnets without per-VM filtering permit lateral access. Separate
profile networks alone do not isolate VMs in the same profile. Routed public
guest ingress adds exposure outside the selected first-release access model.

## Consequences

Lilly needs explicit host firewall, forwarding, NAT and anti-spoofing behavior.
Network cleanup and address reuse must follow confirmed lifecycle cleanup.
Isolation must account for hairpin/host paths and protocol families, not just
TCP between two guests on one host.

## Invariants and verification

- A guest can reach public Internet destinations and receive reply traffic.
- Direct guest-to-guest traffic fails for same host/different host and same
  profile/different profile combinations, including via host forwarding/NAT paths.
- Spoofed sources, unintended IPv6 paths and host/control-service access cannot
  bypass the reviewed isolation policy.
- Stopped VMs keep addresses; a reused address cannot route to an old guest.
- Verify the connectivity matrix on two real KVM hosts.

## Implementation evidence

[Address allocation](../../../marshall/lib/marshall/compute/address_allocation.ex)
and [address resource](../../../marshall/lib/marshall/compute/network_address.ex)
now reserve unique profile identities atomically with VM admission. Slot bounds,
exhaustion and three-node/two-host-record races are tested under
[ADR-0014](0014-image-and-address-admission.md). [ADR-0015](0015-jailed-execution-and-host-networking.md) now adds
[owned TAP/routing setup](../../../lilly/lib/lilly/network.ex), NAT, anti-spoofing
and nftables filtering. The [KVM smoke](../../../lilly/scripts/smoke_jailed.exs)
checks real same-host guests, Internet access and denial paths. The
[NixOS fleet](../../../nix/verification/tests/machines/fleet/default.nix) now verifies remote execution and
cross-host isolation across two nested-KVM provisioners in one physical failure
domain. Independent physical-host acceptance remains open.

## Open questions

ADR-0015 selects IPv4/public DNS, denies IPv6 and host/private access, and reserves
a host transit range. The [fleet matrix](../../../nix/verification/tests/machines/fleet/network.exs)
now passes actual egress, all directed peer denials across two Lilly machines,
protected-address denial and spoofing checks under ADR-0033. Supply the real
deployment's protected public infrastructure addresses and verify independent
physical-host routing. Public Internet
access cannot by itself prevent guests communicating through an external relay;
this decision's enforceable boundary is direct network isolation. Additional
profile functionality remains undefined.

## Related decisions

[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0008](0008-identity-sharing-and-terminal.md).
