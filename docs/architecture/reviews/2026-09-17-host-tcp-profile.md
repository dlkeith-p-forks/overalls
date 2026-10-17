# Opt-in host TCP profile review

Date: 2026-09-17

## Scope and architecture impact

[ADR-0039](../decisions/0039-opt-in-host-tcp-profile.md) adds explicitly selected
host congestion control and packet scheduling. [ADR-0007](../decisions/0007-profile-networking.md)
isolation and [ADR-0033](../decisions/0033-nixos-machine-verification.md)
verification requirements remain applicable; ADR-0034's storage proposal is
unchanged. No existing host or guest image opts in and no compatibility layer is
introduced. Existing unrelated working-tree work is outside this review.

## Findings and resolution

- Copying the upstream numbers would lower current inotify-instance, PID and
  send-buffer limits; receive/watch limits are redundant. The profile inherits
  all resource limits, omits the global file cap and BSD-only kern.maxproc, and
  supplies only BBR/fq defaults with explicit kernel module loading.
- Host default queue scheduling also handles forwarded traffic, but no firewall,
  forwarding or guest supervision settings change. The profile does not select
  guest TCP congestion control.
- NixOS activation does not recreate every existing socket or interface queue,
  and removing sysctl definitions does not reset their live values. The guide
  documents explicit restoration and maintenance reboot; no disruptive automatic
  queue replacement or reboot is introduced.
- Contracts require explicit opt-in and native operator overrides. Evaluation
  checks cover these obligations and inherited policy; actual TCP probes and
  queue inspection are required for runtime claims.

## Validation

Initial checks used a temporary source snapshot containing tracked and nonignored
untracked files. Before committing, a second snapshot contained only the staged
sysctl change on top of the committed tree, excluding unrelated relocation work.

- Module evaluation passed, including all six new sysctl cases:
  `/nix/store/f39lqz6b5fz1apmij3bf79jbcq2w6zfc-overalls-module-configuration-check.json.drv`.
- The two-node KVM suite passed in 62 seconds, checking BBR on outgoing and
  accepted IPv4 TCP sockets, fq on eth1, inherited file/inotify/PID/buffer and
  forwarding values, disabled configuration, and retained policy after reboot:
  `/nix/store/2vaymfh06rjbvf07i8vl2682x2gl9jwd-vm-test-run-overalls-sysctl.drv`.
- Full `nix flake check --no-build` passed. This evaluates the other suites;
  it does not execute them.
- `devenv shell` ADR and contract format/discovery checks passed (39 ADRs,
  including structural links and the new module's local contracts).
- The four-node service-role regression passed with the real source-built
  Marshall/Lilly packages, checking independent roles, effective service limits,
  restarts and proxy TLS/failover:
  `/nix/store/x0gymycjr1jmivavrgkhpvqrn2a5q9l0-vm-test-run-overalls-service-roles.drv`.
- The isolated staged tree also passed module-configuration, sysctl and
  service-role checks, reusing successful immutable results where unchanged.
  Its ADR gate passed with 38 decisions and its contract gate passed with
  50 CONTRACTS files; the larger initial snapshot included unrelated work.

The normal Nix build user lacked KVM access. The successful run used the local
root builder with an empty build-users-group override and KVM features for that
invocation; no device permissions or daemon settings changed. An initial runtime
attempt passed first-boot assertions but exposed the driver's default QEMU exit
on reboot. The final driver waits for that exit and restarts with the same disk
before repeating all effective-policy and connection assertions. The framework's
Python lint/type checks remained enabled. No KVM execution was skipped.

## Remaining gaps

No implementation or verification work remains for this profile. Live activation,
custom kernels and representative performance measurements are outside this
change. All VM checks share one physical host; no performance or independent-host
claim is made. Final diff review found no change to ADR-0007 isolation, service
budgets or guest lifetimes. ADR-0039 is accepted and implemented; ADR-0033's wider
deployment obligations retain their existing status.
