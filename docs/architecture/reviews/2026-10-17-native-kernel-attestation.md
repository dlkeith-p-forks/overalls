# Native kernel provenance and attestation review (2026-10-17)

## Scope

This review covers the follow-up to ADR-0180 that adds native FreeBSD and
illumos kernel provenance, a jail-local kernel probe, native agent daemon
packaging and Lilly's pre-credential kernel-attestation check. It inspects the
current `native-kernels` Nix inputs, version-6 manifests and version-3 bundles,
the Protocol and Lilly validators, Lyra's native daemons, and the focused tests.
The review uses the existing multi-OS image review for the earlier catalog and
firmware decisions; it does not convert structural evidence into boot evidence.

## Architecture impact

The change is architectural. Kernel bytes are now part of the native image
identity and a guest response is required before credentials or readiness. This
extends ADR-0180's explicit metadata boundary and preserves ADR-0113's
boot-bound trust model. The native daemons remain guest-local processes; they do
not create a new host service or Ash domain. No deployment topology or domain
ownership changes.

## Findings

### 1. Provenance is explicit and admission remains fail-closed — resolved with an implementation gap

Version-6 manifests and version-3 bundles carry a positive kernel byte count,
SHA-256 digest, full source revision, patch hash, configuration hash and
compiler identity. Protocol validation rejects incomplete or malformed
descriptors. `native-kernels/default.nix` pins FreeBSD, illumos and OmniOS
source inputs and emits a reviewable source receipt, but marks
`artifact.available = false` and uses a placeholder digest. The FreeBSD and
OmniOS image builders test the receipt before unpacking their disks, so a stock
kernel cannot be silently advertised as native support.

Evidence: `nix/packages/guest/native-kernels/default.nix`,
`nix/packages/guest/native.nix`,
`protocol/lib/overalls_protocol/image_manifest.ex`,
`protocol/lib/overalls_protocol/workload_bundle.ex` and their focused tests.

### 2. Kernel attestation is bound to the current execution — implemented in source, runtime unverified

Lilly's driver reads the validated native bundle and sends a bounded request over
the jail-local `/v.sock` to the fixed probe port. It compares OS, placement,
execution epoch, boot challenge and kernel digest before credentials and the
ordinary readiness exchange. Lyra's probe returns a boot ID and kernel digest;
malformed, stale, absent and oversized responses remain refusal/retry evidence.
The tests exercise framing and mismatch handling through local sockets only.
No native Firecracker guest has answered this probe, and no machine test records
the host-CID/vsock path or a real kernel digest.

Evidence: `protocol/lib/overalls_protocol/kernel_attestation.ex`,
`lilly/lib/lilly/vm/kernel_attestation.ex`,
`lilly/lib/lilly/vm/driver.ex`, `lyra/src/guest/kernel_probe.rs`,
`protocol/test/kernel_attestation_test.exs` and
`lilly/test/vm/kernel_attestation_test.exs`.

### 3. Native agent closure is named but not cross-built — open

The native agent package names kernel probe, agent, flush, readiness, trust,
workspace and SSH helper binaries for each libc family, and starts them through
FreeBSD `rc.d` or an illumos SMF manifest. The Rust targets, native filesystem
paths, trust roots and service ordering still need a successful FreeBSD and
illumos cross build. `terminald` remains the Linux static package; every native
capability row is therefore false and must stay fail-closed until native targets
and machine evidence exist.

Evidence: `nix/packages/guest/native-agents.nix`, `nix/packages/lyra.nix`,
`lyra/src/bin/overalls-native-*.rs` and `nix/packages/terminald.nix`.

### 4. Shared Lilly boundaries are preserved — resolved

The new check runs inside existing placement locking and boot-generation
fences. It uses the existing jailer, per-tap network guard, ZFS ownership and
readiness transaction. Native guests retain guest CID 3, host CID 2 and the
jail-local `/v.sock`; no listener or host placement is added. Credentials are
not delivered when kernel attestation fails.

## Verification boundary and follow-up

Protocol, Lilly and Rust unit tests plus Nix evaluation provide typed, bounded
source evidence. They do not prove a FreeBSD or illumos kernel build, CloudHv
boot, vsock transport, agent startup, terminald, trust, workspace, SSH,
isolation, storage growth, restart, relocation, recovery or fleet availability.

Before either family is staged, implement the OS-specific AF_VSOCK/virtio-vsock
kernel paths and cross toolchains, build a real kernel and signed image, add a
native `terminald` target, fix and record the probe's `attested` response in a
nested-KVM machine scenario, and then run Marshall-driven capability and
recovery journeys. Keep the current placeholder receipt and all capability
rows fail-closed until those results are recorded.

Checks for this review are `elixir scripts/check_adrs.exs`,
`elixir scripts/check_hldd.exs`, `elixir scripts/hldd_coverage.exs --check`,
`elixir scripts/hldd_views.exs --check`, the Protocol/Lilly focused tests and
the Lyra formatter/type/test gates. These checks do not add native runtime
evidence.
