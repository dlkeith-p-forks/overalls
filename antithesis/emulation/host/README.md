# Measured Lilly host under QEMU TCG

`antithesis/nix/lilly-host.nix` builds a separate NixOS kernel, root image and
source-built Lilly release. Its compile selector uses production
`Lilly.Host.Collector`, `Lilly.Host.ZFSIO`, native pool validation and the
host-only guest emulator executor. The ordinary control-core container keeps
its unavailable controlled pool and cannot claim native capacity.

The outer `runner.py` accepts only `start`, `status` and `observe` with the
immutable eight-field config exported by `antithesis/nix/images.nix`. It checks
the root, kernel and initrd hashes before starting q35 QEMU with single-thread
TCG, two vCPUs, 6 GiB RAM, a retained root overlay, a sparse 8 GiB fixed-serial
ZFS data member, user-mode network, and separate secret, observation and fault
9p shares. The retained
root overlay, data member, image identity and QEMU process record live under
`/var/lib/lilly-hostvm/state`. A partial disk set or changed base image refuses
startup. The private secret share is `/run/overalls-secrets`; the sanitized
observation share is `/run/overalls-host-observation`.
The private fault share is `/run/overalls-fault-control`; only the operator and
host own it. An inner worker uses it for closed guest-process crash requests
bound to the recorded PID and start ticks.

At first boot, `bootstrap.py prepare` verifies that the fixed data member is
blank, creates `tank` and `tank/lilly`, records their actual GUIDs on the
retained root, and publishes `lilly-host-enrollment.json` in the private share.
Later boots import only the recorded GUID and verify the same member and mounted
dataset. The separate Marshall operator enrolls this measured request through
its real CLI and writes `lilly-host-credential.json`, `lilly-host-pool-id`, and
`ca.crt` into the private runtime share. `bootstrap.py activate` requires all
three, rechecks the GUIDs, and writes a mode-0600 Lilly v4 config with the
actual pool identity and 6 GiB logical budget. Lilly connects to
`https://marshall-a:5443` through QEMU user networking and the outer Compose
network. The inner fixture firewall is disabled for this closed Compose link;
its network policy is not native host isolation evidence. No credential enters
a Nix output or Compose environment value.

`private_bootstrap.py prepare` creates a separate synthetic private-service CA
and leaf in retained, root-owned `/var/lib/lilly-host` state. The public root is
`private-ca.crt`; the signing key remains in the inner host and is never added
to guest images or Audi's runtime credentials. Restarts verify file ownership,
permissions, certificate names, key matches and retained hashes before using
that identity. `private_bootstrap.py configure` binds private Audi, Ziggy and
Galileo configs to the issued **inner** Lilly host ID. It requires separate
inner-host Ziggy/Galileo tokens and synthetic provider keys in the private 9p
share, then installs service-owned copies under `/run/{audi-private,ziggy,galileo}`.
Ziggy's single selected OpenAI-compatible origin is the actual inner-loopback
fixture at `127.0.0.1:8080`; no external provider is contacted by this config.
Private Audi uses Lilly's local `/run/lilly-ingress/private.sock` and publishes its
own `/run/audi-private/status.sock`. These config files and certificates alone
do not establish DNS, TLS, connector or guest readiness; the actual inner
services and guest path must pass their live checks.

The inner guest emulator server runs under its own service and supplies Lilly's
closed control socket. Its retained qcow2 placement state is rooted at
`/pool/guest-emulator` on the measured parent ZFS dataset. This gives the
software guest real ZFS-backed file bytes, while the harness emulator does not
claim production per-placement child-dataset ownership. Its witness socket remains private to the inner host;
the host fixture does not claim that Unix socket is visible to an outer
workload. `bootstrap.py monitor` reads the actual Lilly status socket and
OpenZFS/cgroup values every three seconds. It writes a sanitized
`physical.json` to the dedicated observation share: `sampled_at_ns`, kernel
`boot_id`, measured ZFS GUIDs, dataset available/used/referenced bytes, pool
size/free bytes, Lilly slice memory current/limit and CPU quota/period, and
Control connected/execution-ready booleans. A failed source writes an explicit
unavailable record. Control loss clears those booleans while preserving a
successful physical sample. The outer `status` command succeeds only when QEMU's PID
identity is live and a fresh inner sample confirms an authenticated v4 Control
connection; `observe` returns the available inner sample with the outer QEMU
PID/start ticks and retained disk paths.

This is software-emulated Linux/OpenZFS evidence. Native KVM, Firecracker jail
and physical power-loss evidence remain in the repository's native machine
checks. A package evaluation or static check is not a VM boot or measured
capacity result.
