---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# Emulated real guest feasibility — 2026-10-13

Research root: `/home/ghuntley/src/kittens-antithesis-reset`. This is a fresh,
read-only SUT investigation. The work did not edit repository files, read
archived Antithesis content, build images, boot guests, or run native isolation
assertions. Repository instructions, ancestor contracts,
architecture overview/index and relevant guest ADRs were reviewed with the
architecture-review and code-contracts workflows. Package-input evaluation and
inspection of already-realized pinned kernel artifacts establish structural
feasibility only.

## Result

The proposed QEMU 11.1.0 TCG / vhost-device-vsock 0.3.0 path can reuse the real
NixOS guest kernel, apps and service protocols. A distinct guest image variant
must add virtio PCI modules and remove `pci=off`. A distinct emulator executor
must observe actual QEMU/backend processes and persistent disk effects; it
cannot satisfy the native Firecracker observer by naming QEMU `firecracker` or
fabricating API/ownership results. Software storage remains an explicit harness
substitution for native ZFS. Native NixOS/Firecracker/ZFS acceptance remains a
separate verification track.

Full data/terminal/editor journeys are feasible in principle, but a guest with
the actual private-service roots cannot become ready until real trust delivery,
private DNS, live execution/roster bootstrap and Audi HTTPS account authority
work. Serial completion markers alone do not unblock these prerequisites.

## Exact input and package evidence

`flake.nix:9` and `flake.lock:3-20` lock `buildNixpkgs` to
`cachix/devenv-nixpkgs@256551e45f6303e142ab4a98be1bf243feb77dc0`;
`flake.lock:119-134` locks its source to
`NixOS/nixpkgs@c8f90650c15282fa8656a041bfbbd2403997a9a7`.

The already-realized patched package tree is
`/nix/store/2b8v6ak9pilpzvx2k7wmiapnfbj3f8z6-devenv-nixpkgs-patched`.
Its only source patch is the locked devenv Poetry patch; the associated overlays
list is empty. Importing this tree directly was necessary for evaluation with
`allow-import-from-derivation=false`. The standard compatibility shim refuses
its patch derivation at that setting, even though its output is already present.
Calling `builtins.getFlake` on the working directory also attempted to copy a
local PostgreSQL Unix socket and failed with an unsupported-file-type error.
Neither limitation requires an image build; use a clean packaged source and the
same locked input for the eventual build.

Read-only `nix eval --impure --option allow-import-from-derivation false --json`
confirmed these exact attributes:

| Attribute in locked build package set | Version | Derivation |
| --- | --- | --- |
| `pkgs.qemu` | 11.1.0 | `/nix/store/1vx5yzk68biym600rjxvbasqfda8ikzf-qemu-11.1.0.drv` |
| `pkgs.vhost-device-vsock` | 0.3.0 | `/nix/store/vgfzyijip0xzz1adz12q22pa9a25r6ar-vhost-device-vsock-0.3.0.drv` |
| `pkgs.linuxPackages_6_12.kernel` | 6.12.104 | `/nix/store/r7smspybl5wmv2yw5ngkkzmq089i78y4-linux-6.12.104.drv` |

QEMU's pinned recipe is
`pkgs/by-name/qe/qemu/package.nix` in that package tree. It is a system emulator,
with tools/blobs enabled; it does not explicitly disable TCG or vhost-user.
The exact runtime device/options still need executable-help verification.
`pkgs.qemu_test` disables unnecessary test-runner GUI integrations and
`pkgs.qemu_kvm` means host-architecture-only compilation, not a guarantee that
KVM must be used; use explicit `-accel tcg,thread=single` regardless of package
name. For a smaller closure, evaluate
`pkgs.qemu.override { hostCpuOnly = true; nixosTestRunner = true; }` as a new,
explicit derivation rather than assuming it is the evaluated full-QEMU output.

`pkgs/by-name/vh/vhost-device-vsock/package.nix` pins tag
`vhost-device-vsock-v0.3.0`, source hash
`sha256-g+u6WBJtizIgQwC0kkWdAcTiYCM1zMI4YBLVRU4MOrs=` and Cargo hash
`sha256-mtORRCY/TNeIEgRCQ1ZbjpsykteRm2FHRveKaQxD/Pw=`.

Neither evaluated QEMU nor vhost-device-vsock output is realized here.
Absolute-path `--help`/`--version` probes failed with `No such file or directory`;
no substitute or build was attempted. Package existence is not runtime evidence.

The application package set comes from `import ./nix/packages { inherit pkgs; }`.
The real guest inputs are `terminald`, `lyraLinux`, `vscodeWeb` and
`vscodeWebBroker`, also reachable through
`legacyPackages.x86_64-linux`. `packages.x86_64-linux.guest` is the generic image
with no private-service roots. Although it contains the editor packages, it
does not enable the private trust/roster/editor units required for these
journeys. Import the guest builder with explicit public fixture roots, as
`nix/tests/machines/fleet/default.nix:153-175` already does for native journeys.

## Guest variant and successful evaluation

`nix/packages/guest/configuration.nix:13-38` uses Linux 6.12, a lean initrd with
`virtio_mmio`, `virtio_blk`, `virtio_net`, `ext4`, and `pci=off`.
`boot.initrd.includeDefaultModules=false` prevents a q35 guest from acquiring
PCI support implicitly. The original bare ext4 `/dev/vda` root and ordinary
guest services remain suitable after transport adaptation.

A read-only evaluation of the existing builder succeeded with the following
additional module and with the real package inputs, fixture certificate
`nix/tests/fixtures/ubuntu/ca.crt`, image name
`overalls-antithesis-tcg-nixos-x86_64`, and 2 GiB minimum memory:

```nix
{ lib, ... }: {
  boot.initrd.availableKernelModules = lib.mkForce [
    "virtio_pci" "virtio_blk" "virtio_net"
    "vmw_vsock_virtio_transport" "ext4"
  ];
  boot.kernelParams = lib.mkForce [
    "console=ttyS0" "reboot=k" "panic=1" "systemd.getty_auto=0"
    "printk.time=1" "quiet" "systemd.show_status=error"
  ];
}
```

`mkForce` removes the original `pci=off` while retaining the current quiet boot,
no-serial-login policy. Native images should retain their MMIO configuration.
The initrd module closure adds dependencies through Nix's `makeModulesClosure`;
it is not necessary to guess transitive module names. Read-only derivation
inspection confirmed the adapted shrink derivation root modules are exactly
`ext4 virtio_blk virtio_net virtio_pci vmw_vsock_virtio_transport`.

Evaluated outputs for this precise research expression (not built):

| Artifact | Path |
| --- | --- |
| Image derivation | `/nix/store/n7f5371gndyk2l5xzfrp61dn0hiqv4bf-overalls-antithesis-tcg-nixos-x86_64.drv` |
| Image output | `/nix/store/y2yjim64kkahly4gqpp8pr3pxmz8k9dk-overalls-antithesis-tcg-nixos-x86_64` |
| Rootfs derivation | `/nix/store/jkw99ni8k9951gz3axrd773i2csyfpa3-ext4-fs.img.drv` |
| Rootfs output | `/nix/store/i4jhh932by2xxs8fzhifcxglxvssz5aj-ext4-fs.img` |
| Matching initrd output | `/nix/store/a7gpg654xwfk8xwasi7b777fz9sm2wlz-initrd-linux-6.12.104` |
| Stripped kernel output | `/nix/store/6726ffisr4dp992h9h3yvv3sxi1xjf8p-lilly-guest-kernel-6.12.104` |
| System closure output | `/nix/store/lcw3rzrypdc4lsl8cgk0aqlbgq5hdlcz-nixos-system-lilly-guest-26.11pre-git` |

Evaluation returned `workspaceSourceEnabled=true`, `editorEnabled=true`, manifest
version 4, workspace source protocol 2, minimum memory 2147483648, and editor
protocol 1 / commit `2a59476c9bfcb90b3ddc372c36762471b7dfad1c` / release
`7d2415fecdd209b1cad571f2fd95a22fa4829f5fa4ed50e8688bd08d25f2d9a6`.
The final rootfs byte count/digests remain build-time outputs. Editor disk floor
is `(rootfs_bytes + 2 GiB)` rounded upward to a whole GiB
(`nix/packages/guest/default.nix:214-232`), rather than a guessed 2 GiB disk.

The realized kernel configuration explicitly has `CONFIG_PCI=y`,
`CONFIG_VIRTIO_PCI=m`, `CONFIG_VIRTIO_VSOCKETS=m`, `CONFIG_EXT4_FS=m` and
`CONFIG_XEN_PVH=y`. `readelf -n` on both the realized original kernel and stripped
guest kernel found Xen note type 18 (`XEN_ELFNOTE_PHYS32_ENTRY`) with address
`0x01000b40`. Therefore the uncompressed ELF has a structural PVH entry compatible
with the proposed QEMU x86 direct-loading route. It is not evidence that QEMU
11.1 has loaded this exact kernel/initrd successfully. Do not replace it with a
different kernel silently. The stripped kernel output's recorded NAR closure
size is 66090056 bytes; this is not the rootfs or whole harness closure size.

## Emulator plumbing

The pinned upstream vhost-device-vsock v0.3.0 application UDS backend provides
the existing Firecracker socket protocol. Its README documents separate
`--socket` (vhost-user transport) and `--uds-path` (application interface),
`--guest-cid=3`, and QEMU `memory-backend-memfd` plus
`vhost-user-vsock-pci`. Source inspection in the parallel protocol investigation
confirmed `VSOCK_HOST_CID=2` in `src/vhu_vsock.rs:47`, UDS host connections use that
CID in `src/vhu_vsock_thread.rs:478-500`, requests parse `CONNECT <port>\n` at
`:539`, and responses emit `OK <peer_port>\n` in `src/vsock_conn.rs:237`.
This external package inspection concerns the emulator adapter; Overalls SUT
findings use repository source only. No kernel `/dev/vhost-vsock` is needed for
this UDS backend. Use one backend process per placement and private sockets;
do not assume default backend forwarding groups reproduce native sibling fences.

The following is the intended future argv shape, pending help and boot smoke:

```sh
vhost-device-vsock --guest-cid=3 \
  --socket=/run/overalls-tcg/PLACEMENT/vhost.sock \
  --uds-path=/run/overalls-tcg/PLACEMENT/v.sock

qemu-system-x86_64 \
  -machine q35,memory-backend=guestmem \
  -accel tcg,thread=single -cpu max -smp 1 -m 2048 \
  -object memory-backend-memfd,id=guestmem,size=2147483648,share=on \
  -kernel IMAGE/kernel -initrd IMAGE/initrd \
  -append 'MANIFEST_BOOT_ARGS lilly.ipv4=10.10.0.2 lilly.placement=PLACEMENT lilly.execution_epoch=EPOCH lilly.boot_challenge=CHALLENGE' \
  -drive if=none,id=root,file=PLACEMENT/rootfs.qcow2,format=qcow2,cache=writeback,aio=threads,discard=ignore \
  -device virtio-blk-pci,drive=root \
  -netdev tap,id=net0,ifname=PLACEMENT_TAP,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=DERIVED_MAC \
  -chardev socket,id=vsock,path=/run/overalls-tcg/PLACEMENT/vhost.sock \
  -device vhost-user-vsock-pci,chardev=vsock \
  -qmp unix:/run/overalls-tcg/PLACEMENT/qmp.sock,server=on,wait=off \
  -serial file:PLACEMENT/boot.log -display none -monitor none -no-reboot
```

The adapter must build an argument vector from validated typed configuration,
not interpolate caller data into a shell. The quoted command above is a
specification with placeholders, not an executed launch script. Use short socket
paths below Linux's 108-byte sockaddr limit. QEMU must see shared memfd memory;
the backend maps it through the vhost-user FD exchange. TCG single-thread means
one CPU translation thread, not that QEMU/backend/I/O uses only one OS thread,
nor proof of deterministic execution.

TAP networking needs `/dev/net/tun` and `CAP_NET_ADMIN` in the emulator host
container/network namespace. Put `10.10.0.1` on its routed guest interface and
route each guest `10.10.0.2/32` through its TAP. The real guest `network.py` adds
its `/32`, link gateway route and default route itself. Default SLIRP settings
(`10.0.2.*`) are incompatible. If a future rootless network adapter replaces TAP,
it must preserve these observed guest/source addresses, private-service routing
and incoming editor source gateway; that is separate unverified work.

Serve Audi private DNS at `169.254.254.1` and route its actual private HTTPS
service. `lilly-private-dns` sends only `~internal` there and disables default
route for that resolver (`private-services.nix:128-161`). Personal guest accounts
use the fixed verified origin `https://ssh.integration.internal/ssh/v1/`
(`lyra/src/bin/overalls-ssh-authorize.rs:17`). Public repository fixtures must
preserve supported provider hostnames and TLS: `WorkspaceSource` accepts a
closed provider set, not arbitrary localhost URLs.

Editor traffic must originate at the derived gateway `10.10.0.1` and reach guest
TCP 4444. The actual Lilly connector binds the TAP, namespace and ingress mark,
then sends the length-framed `EditorConnect` preface and waits for ready
(`lilly/lib/lilly/network/ingress.ex:6-98`). An emulator connector may substitute
the network device mechanics, but must preserve current execution/account/image
bindings and actual broker admission. Browser origins remain Audi's authenticated
HTTPS hostnames, including release-bound webview assets.

## Protocols and bootstrap evidence

| Actual service | Port | Necessary proof |
| --- | ---: | --- |
| Readiness | AF_VSOCK 1024 | JSON line, exact placement/epoch/challenge/kernel boot UUID; live units/network/root fsync |
| Backup flush | AF_VSOCK 1026 | JSON line with exact boot and 64-hex nonce; `flushed` only after fixed `sync` completes |
| Trust | AF_VSOCK 1030 | 4-byte big-endian frame, ≤1 MiB; exact boot/nonce/root digest; installed receipt after durable installation |
| Workspace | AF_VSOCK 1031 | request JSON line ≤4096 bytes, response ≤512; delivery envelope v1, nested source v2 |
| Terminald | AF_VSOCK 1075 | fresh boot-bound HMAC hello on each connection, then account/session attachment proof |
| Editor broker | TCP 4444 | gateway source plus closed current execution/account/package/origin preface |

All five guest vsock listeners reject observed peers other than CID 2. Existing
Lilly clients first dial a private UDS, send `CONNECT <port>\n`, and validate an
`OK <u32>\n` response; readiness and terminal implementations are
`lilly/lib/lilly/vm/readiness.ex:67-99` and
`lilly/lib/lilly/terminal/vsock.ex:365-380`.

`nix/packages/guest/readiness.py:28-64` requires exactly one canonical lowercase
UUID placement, positive canonical signed64-bounded epoch, 64 lowercase hex
challenge, and a `10.{10,20,30,40}` address in slots 2..65534. At readiness it
checks actual active `multi-user.target`, `lilly-network.service`, optional
required units, `/32` eth0 address, link/default gateway routes, and root write
plus fsync (`:135-169`). Private-root images also require `sshd.service`.

Boot ordering is actual `overalls-trustd` receipt/notify → networking → private
DNS → account roster/certificate sync → SSH listener. Trust timeout remains
180 seconds in the guest module. Do not make that TCG timing guarantee until
measured; a slow emulator may expose the existing deadline. Roster startup
needs current boot proof before it can issue personal account authority, so
the emulated executor must publish actual current-boot evidence through the
same authoritative actor/view boundary.

`lilly-guest boot complete`, `lilly-boot-report: ` lines, and
`/run/overalls-ssh-ready` are useful diagnostic milestones; none substitutes for
the full boot-bound readiness response. Boot logs must stay bounded and must
exclude terminal bytes and credentials. ADR-0154 already records a report
timeout-budget discrepancy; do not reinterpret its diagnostic timeout as
readiness or liveness proof.

## Executor and persistent storage boundary

`Lilly.VM.Executor` exposes callbacks for reconcile, terminal options, ingress,
boot proof and watch target (`lilly/lib/lilly/vm/executor.ex:17-37`). Actors accept
an executor tuple, but `Lilly.Control.Runtime.ensure_actor` hardcodes
`{Executor, state.config}` at `runtime.ex:1118`. Thus the full hosted-Lilly
journey requires an explicit harness-only injection seam or dedicated harness
startup composition; there is no existing production runtime configuration
switch that selects QEMU. Source-built release inputs must contain the actual
adapter, not runtime binary/module replacement hidden from build provenance.

Native `Observation.vmm` verifies Firecracker comm/executable/API, jail inode,
network namespace, UID/GID, zero capabilities, no-new-privileges, seccomp,
PID namespace and cgroup limits (`observation.ex:15-65`). The existing native
executor's `boot_proof`, `watch_target`, `terminal_options` and `open_ingress`
reuse those native boundaries. An emulated executor must implement its own
actual process/current-boot evidence and present explicitly scoped emulator
observations. It must not weaken native observer contracts or label QEMU as
native Firecracker/ZFS acceptance. Roster/private grants depend on the booted
execution row (`runtime.ex:111-137`); a canned roster or always-ready callback
would bypass the very journey being researched.

Before spawning, durably persist placement/epoch/generation authority and the
fresh physical-launch challenge. Preserve current challenge when adopting the
same live guest; rotate it for a new guest boot. Native `Boot.prepare` and
`Driver.start` provide evidence for the ordering and one-attempt rule
(`boot.ex:13-27,64-85`; `driver.ex:336-419`). Record actual backend/QEMU PID
identities and retain them outside Lilly's application lifetime. A timeout or
lost QMP/UDS connection must not be treated as proof of stopped compute.

For each newly created placement, validate the immutable raw image's manifest,
then create a qcow2 overlay with an explicit raw backing format and admitted
logical size:

```sh
qemu-img create -f qcow2 -F raw -b /images/IMAGE/rootfs.ext4 \
  /state/placements/PLACEMENT/rootfs.qcow2 DISK_BYTES
qemu-img info --output=json /state/placements/PLACEMENT/rootfs.qcow2
qemu-img check /state/placements/PLACEMENT/rootfs.qcow2
```

The raw template is immutable and one persistent overlay belongs to one
placement. Starting a retained placement must reuse that overlay; missing
previously ready data is an error, not permission to rematerialize. Expose the
admitted virtual size and preserve guest fsync/flush through QEMU writeback
cache; do not select an unsafe no-flush mode. Deletion must prove actual
QEMU/backend exit before deleting overlays or freeing modeled capacity.
Clone/relocation software copy/snapshot semantics require their own typed
adapter, durable fencing and data assertions; qcow2 alone does not implement
ZFS GUID/stream/resume/accounting semantics.

Use standard/OSS profiles first. Inception's accepted additional drive is
256 GiB (`protocol/lib/overalls_protocol/disk_layout.ex:4-27`) and its image
minimum memory is 32 GiB (`nix/packages/default.nix:193-199`); a 2 GiB TCG guest
does not establish nested platform behavior.

## Journeys and decisive assertions

1. **Boot/trust:** deliver exact roots over 1030 before network startup; validate
   trust receipt and 1024 readiness for the current kernel boot. Repeat with
   rotated roots and assert retired roots fail verification. Existing native
   evidence: `nix/tests/machines/zfs-guest/boot-profile.py` and
   `nix/tests/machines/fleet-guest-trust/guest.exs`.
2. **Data:** write a unique synthetic marker and fsync it through a real guest
   tool; request 1026 flush; stop, prove QEMU/backend exit, restart the same
   overlay with a new boot challenge, and read the old marker before any
   rewriting. Add abrupt process-loss histories with carefully scoped ext4/
   qcow2 persistence expectations.
3. **Repository:** deliver source v2 through 1031 to real `overalls-workspaced` and
   a local verified-TLS provider fixture. Assert HEAD and `.launch-probe`
   survive stop/start. Keep `/var/lib/overalls-workspace/source.json`, `done` and
   `/workspace/REPO` on the overlay; unfinished deliveries resume, identical
   sources are idempotent and conflicting sources reject. Workspace delivery
   remains outside readiness. Evidence: `lyra/src/workspace_receiver.rs:198`,
   `nix/tests/machines/repository-launch/driver.py:273-277`.
4. **Terminal:** enter via Marshall's authenticated current grant and Lilly's
   actual 1075 socket; establish HMAC hello and a personal roster-backed PTY.
   Disconnect/reconnect transport and restart Lilly while the independent
   QEMU/backend retain the same PTY. Guest/terminald restart ends that PTY;
   do not promise terminal survival across those faults. Test stale challenge,
   stale generation and duplicate input refusals. A root administrative PTY
   is a bounded bootstrap fixture, not personal-terminal acceptance.
5. **Editor:** authenticate through actual Marshall→Audi→emulated Lilly→guest
   broker 4444, verify personal UID, release/origin and webview asset identity,
   save a unique file, restart broker/worker or stop/start guest as appropriate,
   and read saved content immediately before editing it again. Existing
   recovery browser flow rewrites before readback, which is insufficient for
   a pre-fault persistence oracle. Refuse mismatched account, gateway, epoch,
   package and origin; revoke/sign out and require stream closure. Evidence:
   `nix/tests/machines/vscode-web/default.nix:414-438`,
   `nix/tests/machines/vscode-web/guest.exs:155,337`.

The workspace clone command currently runs without a process timeout
(`lyra/src/workspace_receiver.rs:335`); this is an explicit liveness limit to
observe, not grounds to claim all clone attempts settle within a bound.
Existing native NixOS/fleet tests declare mandatory KVM and actual Firecracker/
ZFS (`nix/tests/support/role-node.nix:8-11`, fleet bootstrap contract). They are
sources for scenarios, not tests that can silently be renamed as TCG acceptance.

## Proposed implementation files and commands

These are future file responsibilities, not files created by this research:

| Future path | Responsibility |
| --- | --- |
| `antithesis/images/emulated-guest.nix` | Import existing real guest package with fixture public roots and PCI boot module; export exact manifest/kernel/initrd/raw template |
| `antithesis/images/runtime.nix` | Package source-built releases plus pinned QEMU/vsock/native helpers into a complete offline runtime closure |
| `antithesis/support/emulated_executor.ex` | Typed Executor callbacks; command-driven real spawn/adopt/stop/delete, fresh boot proofs, actual UDS/ingress paths, modeled storage accounting |
| `antithesis/support/emulated_storage.ex` | Typed overlay identity/materialization/restart/clone model; honest qcow2 backing and logical/physical observations |
| `antithesis/support/guest_runtime.py` or a Rust helper | Validated fixed argv launch, QMP and waitpid/PID custody, backend sockets, bounded observations and process-loss fault points |
| `antithesis/config/guest-network.*` | Typed/schema-checked TAP routing and fixed private DNS/TLS fixture endpoints |
| `antithesis/test/v1/guest/*` | Actual boot/trust/data/repository/personal-terminal/editor workloads and stateful properties |

Runtime injection may need an explicit local startup option in
`lilly/lib/lilly/control/runtime.ex`; host enrollment/capacity/private-service
readiness and release provenance must be reviewed with the complete plan.
Keep this explicitly out of ordinary production configuration and deployment.

After those concrete files exist, build the pinned closure once outside the
testing environment and export all references. Future commands should follow
this shape (not run here):

```sh
nix build --no-link .#antithesis-guest .#antithesis-runtime
nix path-info --recursive --json .#antithesis-runtime .#antithesis-guest
nix path-info --closure-size .#antithesis-runtime .#antithesis-guest
nix copy --to local?root=/tmp/overalls-antithesis-closure .#antithesis-runtime .#antithesis-guest
```

The proposed attributes must be exported deliberately; they do not exist in
the current flake. Include all release/kernel/initrd/rootfs/QEMU/backend
references rather than copying only `/bin` directories. Build-time registrations
and manifest hashes come from the existing builders. Measure realized template
size, closure size and overlay growth before selecting container volume budgets.

Before boot smoke, run realized `qemu-system-x86_64 --version`, `-accel help`,
`-machine q35,help`, `-device vhost-user-vsock-pci,help`, `qemu-img --version`, and
`vhost-device-vsock --help`. Then prove ELF loading, PCI root mount, observed
host CID 2, trust notification and 1024 readiness. No broad property campaign
should report guest coverage until that bootstrap is recorded passing.

Resource floor is 2 GiB guest RAM plus measured QEMU/vsock/release/container
overhead and the minimum writable disk size derived from the actual manifest.
Production's 64 MiB VMM allowance is not an estimate for QEMU. Begin with one
1-vCPU guest per emulated host; add concurrent guests only after observed
memory/thread/CPU/disk-growth and bounded fault-recovery measurements. One
single-thread TCG CPU may run substantially slower than the native deadlines.
No exact duration, whole-closure size or successful boot is established here.

## Architecture impact and remaining blockers

This research changes no repository behavior/configuration/architecture;
the `/tmp` findings do not need an HLDD receipt refresh. Implementation will
change verification/deployment topology and add an explicit execution/storage
substitution, so architecture, contracts and HLDD updates belong in that same
implementation change. Preserve ADR-0011 artifact rationale, ADR-0017 ownership
and recovery, ADR-0082 terminal lifetime/fencing, ADR-0113 trust ordering,
ADR-0153 editor binding and ADR-0154 boot-profile evidence. Do not turn software
qcow2 into evidence for native ZFS capacity/identity or guest networking into
evidence for Firecracker/native sibling isolation.

Concrete uncompleted checks are emulator realization/help; exact ELF/PVH TCG
boot; complete PCI initrd build; TAP/container device privilege; actual private
DNS/TLS/roster bootstrap; executor injection and observation contracts; persistent
QEMU/backend lifetime across Lilly restart; emulated storage/relocation semantics;
real browser/editor operation; measured resources/deadlines; and property
instrumentation/coverage. Contract discovery was manual because `cc-check` was
not on PATH, and no semantic verification claim is made for future adapter code.
