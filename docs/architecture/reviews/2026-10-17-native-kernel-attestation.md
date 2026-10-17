# Native kernel provenance and attestation review (2026-10-17)

## Scope

This review covers ADR-0188, the replacement for ADR-0180 that adds native FreeBSD and
illumos kernel provenance, a jail-local kernel probe, native agent daemon
packaging and Lilly's pre-credential kernel-attestation check. It inspects the
current `native-kernels` Nix inputs, version-6 manifests and version-3 bundles,
the Protocol and Lilly validators, Lyra's native daemons, and the focused tests.
The review uses the existing multi-OS image review for the earlier catalog and
firmware decisions; it does not convert structural evidence into boot evidence.

## Architecture impact

The change is architectural. Kernel bytes are now part of the native image
identity and a guest response is required before credentials or readiness. This
replaces ADR-0180's advertised native capabilities with unavailable rows and
kernel-provenance gates, while preserving ADR-0113's
boot-bound trust model. The native daemons remain guest-local processes; they do
not create a new host service or Ash domain. No deployment topology or domain
ownership changes.

[ADR-0188](../decisions/0188-native-kernel-provenance-and-admission.md) is accepted
under the custom native-kernel plan. It preserves the foreign Linux and native
metadata choices; [ADR-0180](../decisions/0180-multi-os-guest-image-contract.md)
retains the superseded rationale and historical evidence.

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

Evidence: `nix/domains/artifacts/guest/native-kernels/default.nix`,
`nix/domains/artifacts/guest/native.nix`,
`protocol/lib/overalls_protocol/image_manifest.ex`,
`protocol/lib/overalls_protocol/workload_bundle.ex` and their focused tests.

### 2. Kernel attestation is bound to the current execution — implemented in source, runtime unverified

Lilly's driver reads the validated native bundle and opens a bounded exchange over
the jail-local `/v.sock` to the fixed probe port. It compares OS, placement,
execution epoch, boot challenge and kernel digest before credentials and the
ordinary readiness exchange. Lyra's probe returns a boot ID and the digest of
the configured kernel file; this is file identity rather than proof that the
file is the running kernel. A native boot scenario must establish that link.
Malformed, stale, absent and oversized responses remain refusal/retry evidence.
Lilly also requires the subsequent readiness response to use the kernel
response's boot ID, preventing the two exchanges from naming different boots.
The tests exercise framing and mismatch handling through local sockets only.
No native Firecracker guest has answered this probe, and no machine test records
the host-CID/vsock path or a real kernel digest.

Evidence: `protocol/lib/overalls_protocol/kernel_attestation.ex`,
`lilly/lib/lilly/vm/kernel_attestation.ex`,
`lilly/lib/lilly/vm/driver.ex`, `lyra/src/guest/kernel_probe.rs`,
`protocol/test/kernel_attestation_test.exs` and
`lilly/test/vm/kernel_attestation_test.exs`.

### 3. Native agent targets type-check, but linked closure remains absent — open

The native agent package names kernel probe, agent, flush, readiness, trust,
workspace and SSH helper binaries for each libc family, and defines FreeBSD
`rc.d` and illumos SMF supervision separately from the blocked image builders.
The supervisor starts the six local listeners before bounded SSH bootstrap
retries, allowing trust installation to unblock the HTTPS roster/certificate
requests. It withholds the live sshd PID marker until that bootstrap succeeds;
readiness therefore remains unavailable during the bootstrap.
Fresh FreeBSD and illumos library/native-binary target type checks passed.
Upstream `fs2` 0.4.3 omitted illumos from its Solaris allocation fallback; the
pinned vendored copy adds only that target condition, preserving locking code.
The vendor provenance records the upstream archive digest and exact change.
These checks emit Rust metadata rather than linked installable binaries.
Native filesystem paths, trust roots, SSH configuration and service ordering
still need complete target-native image and machine evidence. `terminald`
remains the Linux static package; every native capability row remains false.

Evidence: `nix/domains/artifacts/guest/native-agents.nix`,
`nix/domains/artifacts/infrastructure/lyra.nix`,
`lyra/src/bin/overalls-native-*.rs` and
`nix/domains/artifacts/infrastructure/terminald.nix`, plus the dependency
provenance in [`lyra/vendor/fs2/OVERALLS.md`](../../../lyra/vendor/fs2/OVERALLS.md).

The native socket adapters describe proposed custom-kernel ABIs: FreeBSD uses
family 45 with BSD length/family bytes, and illumos uses an unregistered family
40 with a 16-bit family. Both 16-byte layouts retain port/CID offsets 4/8.
Compile-time layout checks against pinned OS headers establish that bounded
shape only; neither socket-family registration nor transport exists yet.

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
native `terminald` target, record the probe's `attested` response in a
nested-KVM machine scenario, and then run Marshall-driven capability and
recovery journeys. Keep the current placeholder receipt and all capability
rows fail-closed until those results are recorded.

Checks for this review are `elixir scripts/check_adrs.exs`,
`elixir scripts/check_hldd.exs`, `elixir scripts/hldd_coverage.exs --check`,
`elixir scripts/hldd_views.exs --check`, the Protocol/Lilly focused tests and
the Lyra formatter/type/test gates. These checks do not add native runtime
evidence.
