# Emulated Linux/ZFS/Brady storage router

`antithesis/nix/storage-router.nix` builds a separate locked NixOS system and
QCOW2 root image. It includes source-built Lilly and Brady releases, the
production Brady ZFS preparation/pressure helper, real Linux ZFS and nftables,
and fixture-only control/oracle code. The outer `runner.py` launches one QEMU
q35 machine with `tcg,thread=single`, one vCPU, 2 GiB RAM, a retained writable
root overlay and two fixed-serial sparse 1 GiB raw mirror members. The guest caps
ZFS ARC at 128 MiB. A local virtio-serial port carries versioned typed commands;
QMP is a separate root-only Unix socket. Both sockets stay inside the router-vmm
container.

The image directory must contain `root.qcow2`, `kernel`, `initrd`, and
`manifest.json` with this exact shape and hashes of the three files:

```json
{"version":1,"root":{"bytes":1,"sha256":"..."},"kernel":{"bytes":1,"sha256":"..."},"initrd":{"bytes":1,"sha256":"..."},"toplevel":"/nix/store/...-nixos-system"}
```

The trusted outer runner configuration has exactly `image_dir`, `state_dir`,
`runtime_dir`, `qemu`, and `qemu_img` absolute paths. It retains
`state_dir/{root.qcow2,mirror-a.raw,mirror-b.raw,image.json,qemu.json}` across
ordinary QEMU/container restart; none is recreated if only part of the set
survives. The state volume and immutable image directory must survive container
recreation together, because the overlay records its backing file path. Start
with `runner.py --config /etc/routervm/config.json start`. Use `observe` for a
fresh guest oracle or `qmp-reboot` for an acknowledged QMP `system_reset`. A
`request` reads one closed JSON command from stdin and returns a correlated
reply. The outer process owner lock prevents two runner operations racing; a
single router-vmm process must own the same state volume.

`smoke.py --config /etc/routervm/config.json` is the bounded first-boot check.
It waits for fresh observations, confirms production preparation plus fixture
quota readback, makes a real intercepted HTTP request, checks independent nft
and origin effects, writes a fsynced marker, issues QMP reset, then checks a new
boot ID with the same GUIDs, marker bytes and re-applied fixture quota. A timeout
or malformed observation fails the check; it never counts as absence.

Guest bootstrap verifies both serials and sizes before first pool creation. It
requires blank disks and creates a `tank` mirror and `tank/lilly` with a 256 MiB
quota, recording pool and dataset GUIDs on the retained root. On later boot it
imports the recorded GUID and checks the members; it never runs forced create.
The unchanged Brady preparer then creates or verifies sibling `tank/brady` and
sets its capacity-derived quota. The fixture records that value, explicitly
sets `quota=refquota=64 MiB`, reads both properties back, and only then starts
pressure sampling and Brady. This ordering repeats on reboot.

The Lilly release generates nftables/router/guard policy. The bounded veth
topology has `guest`, `guest2`, `customer`, and `origin` namespaces. Brady runs as
UID 991 in the Lilly namespace with `CAP_NET_RAW` only, runtime synthetic
credentials, and a separate native pressure sampler. Bootstrap generates a new
Erlang release cookie each boot in a root-only `/run/router-release-cookie` file;
Brady's systemd unit reads that volatile file after bootstrap. The fixture topology uses
loose reverse-path filtering, as the repository's existing Brady router fixture
does. It does not establish the production strict source-validation setting.

Guest commands are `observe`, `write_marker`, `service_start/stop` for Brady,
origin or pressure, `link` up/down for one fixed peer, bounded `quota` change,
`disk_offline/online` for one fixed mirror member, and `probe` for fixed HTTP/TLS
routes. Public probes use one validated 16-hex fixture key so repeated runs have
distinct cache identities; no caller-supplied URL is accepted. There is no
shell, path, arbitrary QMP or nft program field. `observe`
reads current boot ID, ZFS GUIDs/quotas/mounts, fsynced marker bytes, complete
cache body hashes, Brady metrics/pressure, nft counters and the origin's own
fsynced effect counts. Failed/malformed/timed-out sources return `unavailable`;
no zero or absence is inferred from a missing source. A cache hit after origin
stop requires a complete body and unchanged independent origin effect count.

The witness scope is **software-emulated kernel integration**. QMP reset plus
post-import fsynced marker read is guest/process-crash evidence. It is not
physical power-loss durability, Firecracker ownership, real guest attribution,
strict production source validation, independent host recovery, or performance
calibration. The KVM-only native machine gates remain separate. The recorded
local TCG boot and its exact limits are in
[`storage-boot.md`](../../verification/storage-boot.md).
