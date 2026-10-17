# Real NixOS guest under QEMU TCG

`antithesis/nix/guest.nix` imports the production NixOS guest builder. Its only
boot adaptation replaces the Firecracker `virtio_mmio` initrd set with q35
virtio PCI modules, removes `pci=off`, retains `eth0` with `net.ifnames=0`, and selects the profile DNS address
`169.254.254.1`. The result remains a version-4 guest
image with the production kernel, initrd, ext4 template, manifest, readiness,
flush and optional private-service units. The expression returns `image`,
`qemu` (locked 11.1.0), `vsockBackend` (locked 0.3.0), a Python 3.13 `runner`
executable and `toolConfig` JSON containing the immutable image and tool paths.

`runner.py` has a closed JSON configuration and four commands:

```text
python3 runner.py reconcile --config /run/overalls-tcg/guest.json
python3 runner.py observe --config /run/overalls-tcg/guest.json
python3 runner.py readiness --config /run/overalls-tcg/guest.json --timeout 120
python3 runner.py stop --config /run/overalls-tcg/guest.json
```

The configuration has exactly these fields, with no extra keys:

```json
{
  "image_dir": "/nix/store/IMAGE-overalls-antithesis-tcg-nixos-x86_64",
  "state_dir": "/state/placements/11111111-1111-4111-8111-111111111111",
  "socket_dir": "/run/ktcg/11111111",
  "placement_id": "11111111-1111-4111-8111-111111111111",
  "execution_epoch": 1,
  "generation": 1,
  "boot_challenge": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "address": "10.20.0.2",
  "tap": "lvbd7662a5eeb4",
  "mac": "02:fc:0a:14:00:02",
  "disk_bytes": 4294967296,
  "qemu": "/nix/store/037j0xk9zyspzrd5s7y3k846qhjxvi0v-qemu-11.1.0/bin/qemu-system-x86_64",
  "qemu_img": "/nix/store/037j0xk9zyspzrd5s7y3k846qhjxvi0v-qemu-11.1.0/bin/qemu-img",
  "backend": "/nix/store/awgx9cabs5c2phckm5pc5ypyzqsi2b24-vhost-device-vsock-0.3.0/bin/vhost-device-vsock",
  "ip": "/nix/store/PINNED-IPROUTE2/bin/ip"
}
```

The TAP name is `lv` followed by the first twelve lowercase hex characters of
SHA-256 of the placement UUID. The address is `10.<profile>.<slot high>.<slot low>`
for Customer (10), Standard (20), OSS (30), or Inception (40), with slots
2–65534. The MAC is `02:fc:0a:<profile hex>:<slot high hex>:<slot low hex>`.
The runner checks all three against the placement before host effects and
configures the matching `10.<profile>.0.1/32` gateway and guest route.
Inception also receives its paired `10.41` route. The socket directory must stay below the
Linux AF_UNIX path limit. Runtime inputs should come from the same pinned Nix
package set as the image; the concrete tool paths above identify the already
realized feasibility inputs and are not installation instructions. Select
`disk_bytes` from the built manifest's `minimum_disk_bytes` or higher; the
illustrative 4 GiB value is not a measured image minimum.

The guest-vmm service runs `server.py`, which loads the five immutable paths
(`image_dir`, `qemu`, `qemu_img`, `backend`, `ip`) from the Nix-produced
`toolConfig`. Lilly's harness-only `GuestExecutor` derives the remaining inputs
from its validated placement, durable private boot record, and command
generation. It calls `/run/overalls-guest-vmm/control.sock` with exactly
`operation`, `placement_id`, `execution_epoch`, `generation`, `boot_challenge`,
`address`, `tap`, `mac`, and `disk_bytes` for `reconcile`, `observe`, `readiness`,
`stop`, or read-only `process_proof`. The control socket also accepts operation-only `identity`,
`inventory`, and `health`. No Control payload may select a tool or boot
challenge. `health` validates the image and inventory and fsyncs a state-root
probe; uncertain or degraded inventory fails health.
The response includes the canonical `state_root` path so the integrated host
can require its ZFS-backed placement root.

`process_proof` binds the exact boot tuple and challenge to the retained launch
record, pinned process executables, image manifest and disk shape. Its closed
response has `state`, `placement_id`, `execution_epoch`, `generation`,
`qemu_pid`, `qemu_start_ticks`, `backend_pid`, and `backend_start_ticks`.
`state: running` requires both recorded processes live. `state: qemu_exited`
requires positive `/proc` evidence that the recorded QEMU PID is absent,
zombie, or has different start ticks. Backend identity fields are null only
after positive backend exit evidence. An unexpected executable, unreadable
process state, or boot mismatch returns an error rather than a crash claim.
The caller must independently recheck its process and cgroup evidence before
classifying a crash or attaching a watcher.

The enrollment operator alone mounts the separate read-only
`/run/overalls-guest-witness/witness.sock`. It accepts operation-only `identity`,
or `witness` and `terminal_witness` requests naming only the canonical
`placement_id`, positive `execution_epoch`, and positive `generation`.
`terminal_input_stall` adds one positive `session_id`. The server derives the
private boot challenge from retained boot state; it never sends that value
to the witness socket's caller. `witness` returns process identities, readiness,
boot-challenge digest, manifest digest, and a bounded overlay digest only after
the guest is stopped. `stop` fsyncs a private `stopped.json` with the exact boot
tuple, challenge, exited process identities, image manifest digest and disk
shape before deleting the live launch record. A stopped witness verifies that
record and retained qcow2 metadata; an unknown or mismatched tuple fails.
The terminal operations require a live, ready boot and
authenticate to fixed guest vsock port 1076. Their replies contain only
session/process IDs, daemon PID/start ticks, counters, ring and viewer
measurements, input-stall timing,
and fixed-width ledger digests. The control socket refuses these witness
operations; the witness socket refuses mutations and health/inventory.

These adapters establish a closed local protocol, not a hosted baseline. Unit
tests exercise request closure and binary parsing without launching a VM.
Guest readiness and terminal evidence require a running guest and independent
observations in the selected Antithesis workload. Native Firecracker isolation
and ZFS evidence remain separate.

`reconcile` validates the image manifest and exact artifact hashes before it
creates a placement-local qcow2 overlay with a raw backing file. It writes a
durable launch attempt and effect journal, creates the TAP with the fixed
`10.10.0.1/32` gateway and guest route, then starts one backend and one QEMU
process. QEMU uses one vCPU, single-thread TCG, 2 GiB shared memfd RAM,
virtio block/network/vsock PCI, and a persistent writeback overlay. A retained
placement reuses the same overlay. The runner never launches a second guest
when process state or a prior launch attempt is uncertain.

`observe` checks `/proc` process identity and RSS. `readiness` additionally
polls the backend application Unix socket with `CONNECT 1024\n`, validates the
`OK` handshake and the guest's closed JSON response, and returns `ready: true`
only for the exact placement, execution epoch, challenge and canonical kernel
boot UUID. Each response contains `state`, `placement_id`, `execution_epoch`,
`generation`, `boot_id`, `qemu_pid`, `backend_pid`, `ready`, `qemu_rss_kib`,
`backend_rss_kib` and `error`. The boot ID is null until a real readiness
response succeeds. Errors exit nonzero with `{"state":"error","error":"..."}`.

`stop` terminates both recorded processes and confirms their exit before
removing TAP and socket state. It retains `rootfs.qcow2`. The runner deliberately
offers no shell, QMP or arbitrary guest-command operation. The serial log is
diagnostic only and must be size-bounded when collected; it is never readiness proof. This
software emulator exercises actual guest boot and protocols, while native
Firecracker jail, KVM, ZFS and host isolation acceptance remains separate.
