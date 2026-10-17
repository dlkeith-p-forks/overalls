# NixOS releases, service roles, TLS and secret custody

Date: 2026-09-16

Subsequent certificate-management implementation and regression results are
recorded in the [ACME review](2026-09-16-acme-publication.md). Later passing
host-recipient rotation and replacement recovery are recorded in the
[rotation review](2026-09-16-secret-host-rotation.md); the
[fleet review](2026-09-16-nixos-fleet.md) covers coordination and guest acceptance.
The remaining-work list below describes this earlier implementation checkpoint.

## Scope and architecture impact

Implementation checkpoint for ADRs 0030, 0032 and 0033, following the separate
[decision review](2026-09-16-nixos-and-sparse-zfs.md). The user authorized the
plan. Accepted decisions are unchanged; their implementation is now partial.
This review covers the source package graph, release export, independent service
modules, verified proxy TLS and initial secret delivery. ADR-0031 remains planned
and ADR-0034 remains proposed. No live production host was changed.

## Evidence

- The [flake](../../../flake.nix) pins stable NixOS 26.05 separately from the
  development package set and exports actual source packages and checks.
- [Release derivations](../../../nix/packages/default.nix) use fixed-output
  Mix/Cargo sources, a lock snapshot guard, offline native compilation and
  prefetched asset tools. Source filtering excludes local deps/builds and old
  digested assets. Cedar executes successfully in the packaged Marshall runtime.
- Both release checks passed with Elixir 1.20.4/OTP 29.0.6, matching packaged
  ERTS, independent consumers, no packaged cookie, and actual frontend manifests.
  Both [closure exports](../../../scripts/package_release.sh) completed using
  the source packages; Lilly retains its canonical host tools.
- [Module checks](../../../nix/tests/evaluation/module-configuration.nix) validate independent
  roles, type constraints, port/connection/memory budgets and rejection paths.
- The [role suite](../../../nix/tests/machines/service-roles/default.nix) passed on four QEMU machines;
  the initial run took 56 seconds and the extended proxy run took 72.53 seconds.
  Both Marshall fixtures required explicit
  migrations, authenticated TLS database connections and separate enforced
  instance identities. HTTPS rejects untrusted trust stores; no optional HTTP
  port is opened by a conflicting environment file. Marshall runs unprivileged
  and cannot read the original root-only TLS key. Lilly runs as root in
  `system.slice`, with host mount visibility and separate guest limits. Its
  durable ownership binding proves the actual inner-KVM probe succeeded.
  Daemon restart was exercised; this suite contains no Firecracker guests.
- The [proxy module](../../../nix/modules/proxy.nix) passed real backend
  loss/recovery, CA/name-verified TLS routing and wrong-name rejection. Request
  logs excluded a synthetic token-bearing URL. Lilly's managed uplink retained
  only its assigned IPv4 address, without host DHCP/IPv6 interference.
- The [secret module](../../../nix/modules/secrets/default.nix) uses actual pinned
  SecretSpec/SOPS and SSH-to-age tools. Its initial two-machine
  [custody test](../../../nix/tests/machines/secret-custody/default.nix) passed in 61.27 seconds, covering
  actual unprivileged Marshall startup, distinct host identities, wrong-host
  rejection, independent synthetic operator recovery and missing-value startup
  fencing with preservation of the previous bundle.
- The expanded custody suite passed in **111.50 seconds**, including selected
  group permissions, controlled application credential rotation, journal checks,
  and a switch to a second NixOS configuration preserving the SSH fingerprint
  and successful decryption. Marshall returned to readiness after the switch.
  This validates one application's environment rotation; it does not establish
  fleet signing/Cloak/database coordination, host recipient rotation or reboot.
- [Boundary properties](../../../nix/tests/machines/secret-custody/properties.py) passed actual
  systemd EnvironmentFile delivery for 40 generated examples of four Unicode
  values plus explicit quoting/control-character cases. SIGKILL before bundle
  publication preserved the prior files; cleanup removed abandoned staging
  without touching another bundle. Unsafe paths, oversized output and a timed-out
  resolver's process group were rejected or terminated. These are VM-local
  filesystem/process checks, not host power-loss persistence evidence.
- The public [operator recipient](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/nix/packages/operator-recipient/default.nix) built
  successfully after checking the supplied key's SSH fingerprint. No operator
  private key, production credential or live key lookup was used.
- Framework Python type/lint checks passed. Final structural checks passed for
  34 ADRs and 406 maintained source files with 46 directory contract files;
  they do not prove runtime security or full
  deployment acceptance. No application source changed in this checkpoint;
  existing project property/Dialyzer gates remain required for subsequent domain
  changes.

## Findings resolved during implementation

1. The Mix fixed-output fetch strips Git internals. Asset aliases therefore
   needed the builder's authenticated dependency-loading path before invoking
   compile again. Hash checking and the exact lock snapshot guard remain active.
2. NixOS creates PostgreSQL roles in `postgresql-setup.service`; the fixture's
   password installation now follows that step. Fixture SQL error statements
   are suppressed so generated credentials cannot appear in PostgreSQL logs.
3. Lilly requires its fixed `/var/lib/lilly` ownership directory to be 0700;
   leaf-only tmpfiles declarations created that parent as 0755. The module now
   declares the fixed parent explicitly.
4. Private database CA files were inaccessible to dynamic Marshall users. They
   now pass through systemd credentials alongside backend TLS material.
5. A self-signed leaf was an inadequate OTP TLS fixture. The suite now generates
   an actual CA and signed server certificate while retaining peer/name checks.
6. The framework initially fell back to TCG because build users could not access
   KVM. Those runs failed or were interrupted and do not establish acceptance.
   The suite now forces acceleration and declares `nested-kvm`. The successful
   run used a local Nix store build with those features after a temporary build
   group ACL and an actual KVM API/VM-creation probe. No permanent daemon
   configuration was changed. The temporary ACL was removed after verification;
   `/dev/kvm` returned to root/kvm 0660 and no test QEMU process remained.
   Builder feature labels alone are insufficient.
7. HAProxy 3.3 verifies the SNI hostname when one is supplied; `verifyhost` is
   its fallback. The negative fixture now changes the module's one logical
   `serverName` across request SNI, health-check SNI and fallback verification.
   Backend verification remains enabled in both traffic and health checks.
8. Host network managers tried to configure Lilly's managed link. The module
   now excludes the exact host-derived uplink from dhcpcd, NetworkManager and
   networkd; it does not disable management of unrelated interfaces.
9. Resolver output initially had only an after-capture size check. The
   [preparer](../../../nix/modules/secrets/prepare.py) now reads with a fixed memory bound
   and deadline, killing the complete subprocess group on failure. Environment
   output rejects characters forbidden by systemd before publication.
10. Interrupted staging needs cleanup beyond Python's `finally` block. The
    preparer and systemd stop/failure cleanup remove bundle-specific abandoned
    staging, while retaining the previously published directory. The process
    termination fixture handles `/proc` disappearing during its observation.
11. `Requires`/`After` can propagate a preparation restart to running consumers.
    The [runbook](../../nixos.md) uses explicit consumer stop, preparation,
   consumer start and readiness checks. Changing ciphertext alone cannot update
   an existing process environment. Fleet-wide key coordination remains open.
12. The NixOS test framework omits the configuration-switch program by default.
    The custody fixture explicitly enables it and builds a second configuration
    through a specialisation. Its successful switch checks actual changed
    configuration, rather than inferring rebuild behavior from service restart.

## Remaining accepted work

- **High — deployment incomplete (ADR-0030):** Route 53 ACME, WebSocket proxy
  acceptance, external PostgreSQL deployment inputs, reference host,
  disko/UEFI installation and ISO/QEMU artifacts are still missing.
- **High — secret acceptance incomplete (ADR-0032):** host recipient replacement,
  reboot/image identity verification, coordinated fleet signing/Cloak/database
  rotation and deployment-specific encrypted documents remain required.
- **High — storage unchanged (ADR-0031):** Lilly still supports the preallocated
  ext4 path only. Native sparse ZFS and the logical/physical accounting changes
  must be implemented before accepting ZFS hosts.
- **High — acceptance incomplete (ADR-0033):** three-machine coordination,
  guest lifecycle/isolation on two Lilly nodes, complete secret/TLS rotation, ZFS failure
  recovery and mirrored UEFI boot suites remain required. Four QEMU machines
  share one physical failure domain and do not establish production HA.
- **Open — performance proposal (ADR-0034):** no storage tuning measurements or
  100-instance load acceptance were performed.

## Next work

Implement ACME publication and reference host/storage integration
and the remaining machine suites. Keep documentation and local contracts aligned
with each implemented boundary. Retain the independent physical-host and
provider acceptance requirements.
