# Jailed execution and networking review — 2026-09-15

## Scope and evidence

Reviewed Lilly's new local VM driver, systemd/PID/jailer process tree, persistent
ext4 materialization, API readiness/shutdown, network namespace/TAP ownership,
nftables programs, NixOS routing and root KVM harness. Reviewed actual new source
and the existing staged relocation/unstaged user work. Architecture impact:
ADR-0015 refines local execution details in ADR-0004/0005/0007/0011/0013/0014.
Acceptance uses the existing full implementation authorization.

## Findings and decisions

- **High, fixed command-lifetime defect:** fault injection proved a utility could
  survive the Elixir caller while its separate `flock ... cat` owner exited.
  The new non-setuid C lock helper owns utility execution, kills/reaps work on
  pipe EOF, and keeps the lock inherited by children with a parent-death signal.
  Tests kill both caller and helper, then verify a successor cannot own the lock
  while the prior utility still executes. Binary argv properties and output/
  timeout tests cover its bounded protocol. Asynchronous systemd effects still
  require reconciliation; killing a D-Bus client does not undo an accepted start.

- **High, fixed local execution defect:** the inherited shell selected GNU
  Firecracker, which the jailer does not support. A pinned static musl output and
  an ELF interpreter/architecture check now select the matching pair explicitly.
- **High, fixed packet-policy defect:** an initial private-destination rule also
  matched return traffic to guests. Scope that denial to TAP ingress and accept
  only replies to established outbound connections in the opposite direction.
- **Medium, fixed recovery defects:** empty `ip netns list` is not JSON; veth
  creation did not persist the requested alias; Linux rejected routes while
  interfaces were down. Query namespaces as bounded text, explicitly set/verify
  aliases, install filtering before link activation and add routes afterwards.
- **High, fixed disk-loss risk:** a missing previously ready disk must not be
  treated as an incomplete first copy. Persist a readiness marker before launch
  and reject later absence. Disk deletion is preceded by a VM tombstone.
- **Medium, fixed stop-observation defects:** a successful Firecracker 204 action
  response may omit Content-Length, and systemd collects finished transient
  units. Recognize bodyless 204 responses and confirm unit/cgroup absence; wait
  through the short asynchronous unit removal window after a successful stop.
- **Medium, fixed cleanup defect:** kernel tunnel modules create inactive fallback
  devices in every namespace. Cleanup now recognizes only named, typed, inactive,
  unconfigured fallback devices; active/unexpected links and retained TAPs prevent
  namespace destruction. Cleanup retries preserve ownership rather than deleting
  unrecognized resources.
- **High, documented integration requirement:** v1 receipts remain non-executable.
  Complete generations, durable physical outcomes, VM actors, bounded recovery,
  release/archival and terminal authorization before exposing provisioning.
- **High, documented integration requirement:** VM units now cap guest RAM plus
  64 MiB, but Marshall currently reserves guest RAM. Admission must reserve that
  overhead before the driver is connected. Collection must use `lilly.slice`.
- **High, documented deployment requirement:** per-directory locks are not global
  physical-host fencing. Complete enrollment/UID-range ownership, singleton host
  identity and protected public infrastructure address distribution before
  automatic execution. Trusted root host administration remains in the boundary.
- **High, acceptance evidence pending:** three real guests on one host cannot
  prove the two-host connectivity/failure matrix. The second independent KVM host
  and workload targets remain required. No 100-control-plane throughput claim.
- **Medium, operational boundary:** dtach/unshare remain privileged helpers in
  the trusted host process tree. Their code and pinned versions belong in host
  hardening/upgrade review. No terminal bytes or credentials are diagnostic output.

No requirement was narrowed. Sharing/terminal writer revocation, telemetry
rollups/retention, enrollment, deployment/failover and scale validation remain
part of the active implementation objective.

## Verification

Initial real root/KVM probes verified three x86-64 NixOS guests under static
Firecracker/jailer 1.16.1 and systemd 255.4, independent launcher BEAM exit,
root consoles, public DNS/HTTPS, six directed same/cross-profile TCP denials,
known host-listener/private/link-local denials, source IP/MAC spoofing, VLAN and
IPv6 ingress drop counters, cgroup/jail/PID/UID/seccomp readiness, persistent
stop/start, full preallocation credit and deletion tombstones. Final cleanup
initially retained its namespace on unexpected kernel fallback devices; that
case was inspected, corrected and explicitly cleaned through the ownership API.

The repeatable [KVM harness](../../../lilly/scripts/smoke_jailed.exs) passed with
OS lock ownership, partial TAP alias recovery, refusal to destroy a namespace
with retained TAPs, missing-ready-disk rejection, independent launching BEAMs,
all listed packet/confinement/persistence paths and full idempotent cleanup.
No VM unit, owned namespace or nftables table remained. The temporary empty
`lilly.slice` was returned to its original inactive state.

Final verification:

- Lilly: 34 tests and 12 properties; compiler and Dialyzer pass without exclusions.
- Marshall: 63 tests and six properties, including three BEAM nodes; compiler and
  Dialyzer pass with the one unchanged precise upstream typespec exclusion.
- Protocol: five tests and five properties; compiler and Dialyzer pass.
- Four additional Linux/ext4/TLS capacity-loop host tests pass with the new helper.
- Total: 129 test/property cases, plus the real three-guest KVM harness.
- The C helper builds with `-Wall -Wextra -Werror`. Fault tests cover caller/helper
  kill, lock handoff, output bounds, timeouts and private legacy lock permissions.
- An API test cleanup race was fixed by stopping the supervised child through
  its supervisor instead of checking liveness before stopping a disappearing PID.
- The independent production Lilly release builds and verifies image hashes and
  a locked host utility with the packaged helper on its trusted PATH.
- The 15-ADR structural/link gate and `git diff --check` pass. Original-file hash
  comparison found no missing files and only the previously intended source
  changes plus `devenv.nix`; 46 staged relocations remain unchanged.

The KVM run used the helper before the final permission-migration change; its
0600 lock-file behavior is unchanged. The final helper's migration and command
ownership guard are covered by the final unprivileged and host checks.

Pinned outputs built successfully:

- Static VMM: `/nix/store/zq3l7qzb2i13my6hckqfgyyk6hwx84m1-firecracker-static-x86_64-unknown-linux-musl-1.16.1`.
- Guest: `/nix/store/n78q5nr2swks88iv93pmn3qn2aw2lzx0-lilly-nixos-x86_64`.
- Host utilities: `/nix/store/y829b4ma6bja5862gcs11i3plqq15jfc-lilly-host-tools`.
- Nix `--realise --check` reproduced the changed guest rootfs
  `giiw17fqcsaydv8ynnsryf87w5kyjjzk-ext4-fs.img` byte for byte.

## Follow-up

Wire the local execution specification to a reviewed command revision and
physical outcome protocol. Integrate admission overhead, host fencing, VM actors,
stop/start/delete and bounded crash recovery. Continue the full platform plan;
this local driver milestone does not finish user provisioning or fleet readiness.
