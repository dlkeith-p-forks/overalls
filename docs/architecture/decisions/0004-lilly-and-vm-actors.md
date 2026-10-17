# ADR-0004: Lilly and VM actors

- ID: ADR-0004
- Date: 2026-09-15
- Status: accepted
- Implementation: partial
- Components: Lilly, Firecracker, host supervision
- Supersedes: none
- Superseded by: none

## Context

Provisioners run on dedicated physical hosts with root-equivalent permissions.
They can reach the Marshall API even when hosted separately. Multiple hosts and
multiple VMs per host are required. Each VM exposes a readable/writable TTY.

## Decision

Implement Lilly as a separate Elixir release on dedicated hosts. Represent each
VM with an OTP actor, while supervising the actual Firecracker process and its
console independently of the Lilly application so a Lilly restart does not stop
running VMs. Reconcile existing host state when Lilly reconnects or restarts.

Use Firecracker with KVM and an initially x86-64, reproducible minimal NixOS guest.
Keep architecture explicit in commands and inventory for future support. The
privileged host interface must be authenticated and narrowly scoped even though
Lilly itself holds broad host permissions. These are the selected platform
requirements, not a claim that the exact host/transport protocol is decided.

## Alternatives

Launching VMs as children whose lifetime ends with Lilly violates the restart
requirement. A Rust/Go provisioner was not selected. Running privileged Lilly on
shared, unrelated service hosts expands the isolation boundary beyond the chosen
dedicated-host model.

## Consequences

Actors must recover durable process/disk identity and reconcile reality rather
than assume a fresh host. Host supervision and console buffering need explicit
limits. The local exe.dev VM exposes KVM to root: API version 12 and creation of an
empty KVM VM were verified on 2026-09-15. This permits local execution tests;
a second independent host is still needed for the required cross-host tests.

## Invariants and verification

- Restarting Lilly preserves guest execution, disk and usable console access.
- Repeated commands do not launch duplicate VM processes or attach the wrong disk.
- Only authenticated/authorized Marshall commands can cause privileged actions.
- A disconnected host is unreachable, not automatically dead or free of VMs.
- Verify on two x86-64 KVM hosts, including process and connection failures.

## Implementation evidence

[Lilly's application](../../../lilly/lib/lilly/application.ex) and
[Mix project](../../../lilly/mix.exs) establish a separate OTP application/release
with the shared runtime and validation gates. A typed
[inventory API](../../../lilly/lib/lilly/host/inventory.ex) starts the host-side
implementation. Release and gate verification is tracked in the
[foundation review](../reviews/2026-09-15-toolchain.md).

[Guest image](../../../nix/packages/guest/default.nix)
and [KVM smoke harness](../../../lilly/scripts/smoke_guest.exs) proved local
NixOS boot, root console reattachment and disk persistence across VMM restart.
See [ADR-0011](0011-nixos-guest-and-console.md) and its execution review.

The local [jailed driver](../../../lilly/lib/lilly/vm/driver.ex) and
[independent-process smoke](../../../lilly/scripts/smoke_jailed.exs) now supply
systemd/jailer/manifest primitives under
[ADR-0015](0015-jailed-execution-and-host-networking.md). [ADR-0017](0017-durable-vm-actors-and-host-ownership.md) adds the executable
[runtime](../../../lilly/lib/lilly/control/runtime.ex), durable
[actors](../../../lilly/lib/lilly/vm/actor.ex) and host ownership. Its real TLS/KVM
harness exercises process restart and physical outcomes. Cross-host acceptance
and remote terminal access remain required.

## Open questions

[ADR-0016](0016-executable-generations-and-lifecycle.md) implements the v2
client/server contract and local native launch fence. ADR-0017 integrates global
host ownership, durable VM actors/outcomes and runtime reconciliation.

ADR-0012 selects encrypted/revocable credentials and outbound HTTPS; ADR-0013
implements automatic reporting and durable receipt; ADR-0014 supplies image and
address admission prerequisites. ADR-0015 selects local supervision, manifests
and networking. Protected enrollment and host drains now have implementation
under ADRs 0025/0026; shared terminal integration is implemented under ADRs
0018–0022. The [NixOS fleet](../../../nix/tests/machines/fleet/default.nix) verifies two distinct
nested-KVM Lilly machines and three Marshall machines. Independent physical
failure domains and deployment-specific replacement operations remain required.

## Related decisions

[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0007](0007-profile-networking.md),
[ADR-0008](0008-identity-sharing-and-terminal.md).
