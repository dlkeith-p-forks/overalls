# ADR-0039: Opt-in host TCP profile

- ID: ADR-0039
- Date: 2026-09-17
- Status: accepted
- Implementation: implemented
- Components: NixOS host networking, deployment verification
- Supersedes: none
- Superseded by: none

## Context

The user requested incorporating [Loom's sysctl module](https://github.com/ghuntley/loom/blob/trunk/infra/nixos-modules/sysctl.nix).
After inspecting the pinned NixOS input, the user selected explicit opt-in,
adaptation to current defaults, and fq pacing alongside BBR. The implementation
request authorizes this decision without backward-compatibility requirements.

The pinned NixOS input already sets both inotify limits to 524288 and pid_max to
4194304. Linux 6.18 already sets receive/send buffer maxima to 4 MiB. Loom's
watch/receive limits are redundant, while its instance/PID/send limits are lower.
Its global file cap would constrain all services together, and kern.maxproc is
a BSD setting. These settings do not supply useful increased limits here.

## Decision

Export `nixosModules.sysctl`, also imported by the default module, with
`overalls.sysctl.enable = false`. Enabling it loads tcp_bbr and sch_fq and provides
`lib.mkDefault` values of bbr for net.ipv4.tcp_congestion_control and fq for
net.core.default_qdisc. Ordinary native NixOS assignments override either value.
No role or existing machine/guest composition opts in automatically.

Inherit resource limits and preserve service-level limits, forwarding, firewall
ownership and independently supervised guest lifetimes. The importing host's
TCP stack uses the profile; separately booted guests keep their own TCP defaults.
Host scheduling can also affect forwarded traffic but grants no new connectivity.
Do not add a kernel replacement, external dependency, legacy alias or migration.

Use normal NixOS activation. Do not automatically reboot, replace live queues or
unload modules. Existing sockets/listeners and interface queues can retain their
policy after a live switch. Removing configuration does not undo live sysctls;
operators restore desired values explicitly or disable and reboot through normal
maintenance. Document these limits, including the need to recreate queues and
sockets for full policy convergence.

## Alternatives

Copying all upstream settings would introduce an unsupported key and reduce
several existing limits. Automatic service-role enablement was not selected.
Retaining the current scheduler works with BBR's internal pacing, but fq was
selected for packet pacing. No physical performance claim follows from that
choice or from functional VM tests.

## Consequences

Operators can enable a small, overridable profile without changing resource
admission or guest configuration. The selected kernel must support BBR and fq.
Changes affect host networking and require runtime verification, not just module
evaluation. Live rollout and representative performance measurements remain
deployment-specific work.

## Invariants and verification

- Disabled profiles contribute no sysctls or kernel modules.
- Enabled profiles preserve inherited resource and forwarding policy.
- Plain native sysctl definitions override the profile defaults.
- Standalone and default-module imports expose the same opt-in behavior.
- Real VM tests inspect BBR on connected sockets, fq on an actual interface,
  inherited limits, and persistence after reboot without manually setting them.
- Functional tests do not establish fleet throughput or physical-host acceptance.

## Implementation evidence

The [module](../../../nix/modules/sysctl.nix) and [flake](../../../flake.nix)
provide the opt-in interface. The [evaluation checks](../../../nix/tests/evaluation/module-configuration.nix)
cover defaults, overrides and service composition. The [machine suite](../../../nix/tests/machines/sysctl/default.nix)
uses actual pinned kernels, [socket probes](../../../nix/tests/machines/sysctl/probe.py)
and [runtime/reboot assertions](../../../nix/tests/machines/sysctl/driver.py).
Evaluation and the two-node KVM suite pass, including connected IPv4 sockets and
reboot persistence. The [review](../reviews/2026-09-17-host-tcp-profile.md) records
the exact derivations and passing service-role regression. The [guide](../../nixos.md#opt-in-host-tcp-profile)
documents activation and restoration semantics.

## Open questions

No implementation decisions remain open. Production deployment and measured
workload benefits are not established by this profile.

## Related decisions

[ADR-0007](0007-profile-networking.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0034](0034-mixed-workload-storage-tuning.md).

References: [pinned NixOS sysctl defaults](https://github.com/NixOS/nixpkgs/blob/c3eea5b2156db11c7eeeada3dc737711255b253e/nixos/modules/config/sysctl.nix),
[Linux 6.18 socket defaults](https://github.com/torvalds/linux/blob/v6.18/net/core/sock.c),
[BBR pacing](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_bbr.c).
