# Local QEMU TCG guest boot evidence

[The machine-readable record](guest-boot.json) binds this local result to the
built image, runner, tool configuration and source hashes. The image is
`/nix/store/4a0cplfxrav2r3z8p1c4gcq06gw931ah-overalls-antithesis-tcg-nixos-x86_64`
(derivation `v2p4dxc2q4zbkli73lnwngncj00mbvyr-overalls-antithesis-tcg-nixos-x86_64.drv`),
with manifest SHA-256
`5f49c664e763521174b997a4cd6e6195a7175101cdb0e3bb4a48f100038fd829`.
It contains the production NixOS guest services in a 3,276,800,000-byte rootfs
and declares a 2 GiB memory minimum. The manifest's workspace source capability
is null. The pinned tools were QEMU 11.1.0 and vhost-device-vsock 0.3.0.

The first image reached multi-user and answered the real port 1026 flush
protocol, but readiness failed: q35 named its PCI NIC `enp0s3`, while
`lilly-network.service` requires `eth0`. After adding `net.ifnames=0` to the
q35 image, a new boot returned exact port 1024 readiness. The runner also had
to recognize Nix QEMU's exact sibling `.qemu-system-x86_64-wrapped` executable
while retaining its PID and process-start-tick identity checks. The diagnostic
VM and each later boot were stopped before the next launch.

| Boot | Result | Time and memory |
| --- | --- | --- |
| Repaired image, epoch 3 | Exact port 1024 readiness and port 1026 flush succeeded; kernel boot UUID `7c76cc8f-b050-4229-aadf-83982d030886` | Guest startup profile 37.210 s; QEMU RSS 771,452 KiB; backend RSS 3,596 KiB |
| Same qcow2 overlay, epoch 4 | Exact readiness; new kernel boot UUID `40ed111d-72e7-433a-ac5c-2d91e67fad49` | 43,985 ms from QEMU start to verified readiness; guest startup profile 42.789 s; QEMU RSS 773,440 KiB; backend RSS 3,956 KiB |
| Final formatted runner, epoch 5 | Exact readiness; new kernel boot UUID `76e90f58-18a8-4828-b6c4-3dabd3e55830` | 38,523 ms from QEMU start to verified readiness; QEMU RSS 768,640 KiB; backend RSS 4,148 KiB |

The restarted guest reported the same machine identity as the first repaired
boot. After stopping it, `qemu-img check` found no errors. An offline conversion
of the retained qcow2 to temporary raw and a `debugfs` read of `/etc/machine-id`
confirmed that the **retained disk bytes** matched the first boot; the temporary
raw file was deleted. No raw machine identity or boot challenge is in this
report. The owned QEMU and backend processes are stopped, their TAP is absent,
and the persistent qcow2 remains in private local state for review.

The runner package derivation is
`/nix/store/hdzd5ny2df00gwlcgsv2371wad4p10d5-overalls-tcg-guest.drv` and its
output is `/nix/store/8bp13zki7z9p8s85fa5lrr3xqk0s76k0-overalls-tcg-guest`.
The immutable tool configuration is
`/nix/store/d6f478q9fgs3v8s2chbf9wbzy3qjx6jf-overalls-tcg-guest-tools.json`
(SHA-256 `8b12805166d9d5555bf1eafb759ee4b3ce7cd896fc79d1ab35ed9556fda56592`).
The exact current source SHA-256 values are in the JSON record. The worktree was
dirty during the run, so those paths and hashes, rather than a later flake
evaluation, identify the observed build.

This is local software-emulated boot and protocol evidence. The hosted Lilly
`GuestExecutor` remains fail-closed and is not wired to the runner, so no hosted
Antithesis guest baseline was established. The run did not verify workspace
delivery or native Firecracker, KVM, ZFS or host isolation. Its architecture
impact is limited to harness emulation; ADR-0017, ADR-0157 and ADR-0158 are
unchanged.
