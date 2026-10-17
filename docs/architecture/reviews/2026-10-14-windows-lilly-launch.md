# Windows Lilly launch review

## Scope and impact

[ADR-0170](../decisions/0170-lilly-firmware-guest-launch.md) turns the
firmware-booted Windows image of
[ADR-0169](../decisions/0169-firmware-booted-windows-guests.md) into a guest
Lilly can place: the shared protocol admits the eight-key version-5 manifest
and a version-2 firmware bundle beside the unchanged version-4 shapes; Lilly
names artifacts from the protocol, keeps `rootfs.ext4` as the pool-side root
slot, boots firmware bundles over virtio-pci with the boot identity seeded into
Firecracker's MMDS from a jail-local file, records trust as `skipped` and
provisioning as `unattested`, and refuses readiness, terminals, workspace
sources and Inception for guests without agents; the Windows image gains a
SYSTEM bootstrap task that applies the delivered `/32` from MMDS; Marshall
derives a `guest_agents_status`, hides and refuses Terminal, Agents, the
editor and SSH for such images, refuses Inception admission and measures only
the physical service level.

Boundaries preserved: ADR-0011/0068 (version-4 Linux images unchanged, pinned
by tests), ADR-0016/0098 (admission bounds; firmware ≤ 64 MiB, root ≤ 128 GiB),
ADR-0113/0154 (trust and readiness remain guest proofs; an agentless guest
never acquires either), ADR-0130 (templates and sealed copies carry both file
sets), ADR-0146 (no standby disks for the Windows image), ADR-0159 (an
additive shape change, converged before any placement). No database migration:
Marshall stores the manifest as an opaque map and derives the new status.

Also in this change: the spike branch merged `origin/main` (28 commits:
Antithesis rebuild, resize and storage hardening, native guest coding CLIs,
rewritten zfs-guest fixtures). Main had meanwhile assigned ADR-0163 to bounded
standby refill, so the spike decision was renumbered to ADR-0169 across the
repository; the HLDD coverage chapter was regenerated and all six review
receipts re-recorded for the merge.

## Findings and resolutions

- **The spike manifest carried a display name.** The Nix builder emitted a
  ninth key (`name`) that the planned shape never had; Marshall names images at
  registration. The builder drops it and the protocol admits exactly eight keys.
- **Identity delivery without a kernel command line.** Firecracker 1.16.1's
  `--metadata <file>` loads the MMDS store inside `VmResources::from_json`,
  before the guest runs, so the jail writes `metadata.json` next to
  `firecracker.json`; no API call after start and no race. The document carries
  what the kernel command line carries plus gateway, prefix length and MAC, and
  deliberately not the generation, which advances without a reboot.
- **No vsock for firmware bundles.** Windows has no virtio-vsock driver and
  every Lilly vsock consumer is refused for agentless guests; omitting the
  device makes accidental use fail closed.
- **A readiness phase that is honest about what is known.** Rather than
  fabricating `guest_ready` from a host-side probe, provisioning gains the
  terminal `unattested` phase (challenge, no boot UUID, no path to `ready`),
  trust gains the `skipped` state, and the executor reports `running` with no
  `guest_ready` fact. Marshall's service-level admission skips creation-to-ready
  for such operations instead of measuring a guaranteed failure.
- **The Firecracker NIC is a new adapter instance.** The recorded SAC boot
  showed an APIPA address although the installer disabled DHCP, so the guest
  bootstrap configures whatever adapter is up, uses a temporary link-local
  address to reach MMDS when none exists, and matches the delivered MAC against
  the adapter before applying anything.
- **Contract block adjacency.** The repository contract checker refused two
  adjacent `@cc` comment blocks in `Marshall.Compute.Images`; the new function
  moved below the existing one.

## Verification

Executed on 2026-10-14 (host with nested KVM, `system-features` includes
`nested-kvm`):

- `checks.x86_64-linux.windows-guest` (operator launcher, nested KVM) on the
  spike commit `66052b340`: passed; firmware banner after 252.9 s of guest time,
  `SAC>` 6.2 s later, 273.9 s in total
  (`/nix/store/kz6azps22rydza1vyywssxk97kwbdp2p-vm-test-run-overalls-windows-guest`).
  This is the first recorded execution of that check.
- `checks.x86_64-linux.ubuntu-guest` on the merge commit `4fe9033fc` (patched
  VMM, no Phase 2 code yet): the Ubuntu guest booted, delivered trust, survived
  the launching BEAM's loss and the simulated host crash (the first four
  subtests passed), then the new `post-import template identity retains strict
  fenced recovery` subtest failed in the fixture's `absent_mountpoint/1`
  (`template-post-import.exs:381`). A forced re-execution of the same check on
  untouched `origin/main` (`c3f8bfeaf`, `nix build --rebuild`) failed at the
  same line after the same four passing subtests, so the failure is
  pre-existing on main and independent of the VMM patches and of this change.
- `checks.x86_64-linux.zfs-guest` (NixOS guest, real Lilly, nested KVM) on the
  merge commit `4fe9033fc` with the patched VMM: passed, all fifteen subtests
  including the post-import template subtest, in 4446 s of script time
  (`/nix/store/bv5s38m3nvjdy1jk2zb4750h9m9q315s-vm-test-run-overalls-zfs-guest`).
- Local reproduction of Lilly's firmware launch on bare KVM (patched
  Firecracker with `--enable-pci --metadata`, the rebuilt image
  `/nix/store/za61xzjas5kymm80fbdx64yrgfwkvhx7-lilly-windows-server-2025-x86_64`,
  MMDS V2 seeded with placement, challenge, `10.10.0.203/32`, gateway
  `10.10.0.1` and the guest MAC, a tap carrying the gateway): the SAC `i`
  listing showed `Ip=10.10.0.203 Subnet=255.255.255.255 Gateway=10.10.0.1`,
  the host answered `ping` (0.2 ms) and found TCP 22 open, Firecracker's MMDS
  counter recorded nine accepted frames, and the bootstrap log read back from
  the EFI system partition with mtools (no login) recorded: adapter found with
  a tentative APIPA address (DHCP had re-enabled itself on the new adapter
  instance, as inferred), identity fetched, network applied, complete in 14 s,
  about two minutes after power-on. The first image (without log publication)
  behaved the same except that its log could only be inferred from the MMDS
  counters and the SAC listing.
- `checks.x86_64-linux.windows-lilly-guest` (real Lilly driver, nested KVM): a
  first run on the first rebuilt image passed the Inception refusal and the
  placement subtest (firmware bundle on the dataset, sparse usage, skipped
  trust, `unattested` provisioning, `SAC>` in the boot log) and timed out
  after 900 s waiting for the host-side ping, before the guest-side evidence
  above existed. Windows under nested KVM runs an order of magnitude slower
  than on bare KVM (the firmware banner alone took 253 s in the launcher test),
  so the test now waits up to 2400 s and prints the MMDS counters.
  A second run with the re-entrant `unattested` commit timed out on the
  reachability wait for the real reason: Lilly's host policy
  (`inet lilly_filter`, `input` and `output` chains) drops every unmarked
  packet between the host and a Customer guest by design, so a plain ping from
  the namespace can never succeed; the guest itself was fine. The test now
  reads the guest's bootstrap log from the live disk and probes through a
  test-only accept for the one `/32`, with the tap guard untouched.
  Final execution on the committed tree (2026-10-14, 2688 s of script time,
  `/nix/store/nrpkvzk1g85bvj0a4594pi7dyap8w2j4-vm-test-run-overalls-windows-lilly-guest`):
  passed. Inception refused before any dataset (306 s, dominated by hashing the
  32 GiB sparse image); placement 791 s (two digest passes over the sparse
  template plus the copy); `boot-bundle.json`, `firmware` and `rootfs.ext4` on
  the dataset with well under 12 GiB of pool usage; trust `skipped` and
  provisioning `unattested` in the journals; `SAC>` on the boot log within
  seconds of launch; the published bootstrap log showed `network applied` and
  the applied identity carried the delivered `/32` 80 s later; ICMP and TCP 22
  answered through the probe allowance;
  the tap guard counted nine accepted IPv4 frames from the assigned MAC,
  dropped eight ARP probes from other sources (Windows' link-local
  duplicate-address detection) and two ARP
  frames not aimed at the gateway, and kept its spoofed-MAC counters at zero;
  the guest then stopped, restarted from the portable bundle without the image
  and answered again, and the dataset was deleted.
- Protocol `mix test`: 267 passed (100 properties) with the version-5 manifest,
  pinned independent identity vectors for both versions and the version-2
  bundle. Protocol `mix precommit` (toolchain, ADR, contracts, format, tests,
  Dialyzer with zero errors): passed. Lilly `mix precommit`: passed, 547 tests
  (106 properties), Dialyzer with zero errors, after two fixture corrections
  found by the full run (a read-only test file rewritten without a chmod, and
  the `unattested` guard that at first also refused the trust step's idempotent
  re-entry).
- Lilly unit tests for the touched modules (jail, unit arguments, image loading
  of a firmware directory, bundle refusal logging, provisioning and trust
  lifecycles including `unattested` and `skipped`, image template identities):
  passed under `devenv shell`.
- Marshall tests for the touched modules (image admission including the
  firmware image, guest-agents capability property, editor workspace rendering
  with hidden controls, SSH command wire views, service levels, terminal
  authority, admission, machines live): passed under `devenv shell`. A full
  `mix precommit` run finished 1480 of 1481 tests with one failure in
  `Marshall.Compute.CloneHistoryTest` (a generated grant/submit/cancel/advance
  history reached `CloneCoordinator.settle_cleanup!` without a host id), code
  this change does not touch and last modified by main's clone commits; the
  property passed three consecutive isolated reruns, so it is recorded here as
  an intermittent generated case for the clone owners, not as acceptance.
  Final full `mix precommit` on the committed tree: passed, 1481 tests
  (240 properties), Dialyzer with zero errors.
- `checks.x86_64-linux.windows-guest-unit` (evaluation: eight-key manifest,
  bootstrap task registration and script rules) and `firecracker-vmm`: passed.
- The Windows image rebuilt with the bootstrap task and the eight-key manifest
  (`/nix/store/p3jy4hqjrimk902lhdq7a6dnc2nclqc1-lilly-windows-server-2025-x86_64`).
- Repository gates on the committed tree: `elixir scripts/check_adrs.exs`
  (167 decisions), HLDD receipts (`check_hldd.exs`), Ash and deployment views
  (`hldd_views.exs --check`), the regenerated coverage chapter
  (`hldd_coverage.exs --check`), merge-conflict markers, the Nix `hldd`,
  `windows-guest-unit`, `firecracker-vmm` and `conflict-markers` checks: passed.

## Acceptance limits

The Lilly-mode machine test proves the launch path under the jailer and
network guard, the agentless journals, host-side reachability of the delivered
`/32` and the SAC prompt. It does not prove Windows readiness (none exists),
trust installation, terminals, workspace delivery, DNS, timekeeping under load,
`C:` growth beyond a bootable guest, or fleet distribution of the 32 GiB
template with standby disks or a template budget. Unit tests cannot establish
native isolation. Nothing has been merged, pushed or deployed; the rollout
ordering in ADR-0170 applies before any Windows placement.
