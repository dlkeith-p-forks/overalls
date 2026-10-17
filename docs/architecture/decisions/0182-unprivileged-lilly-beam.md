# ADR-0182: Run the Lilly BEAM unprivileged behind lilly-hostd

- ID: ADR-0182
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: Lilly, lilly-hostd, NixOS lilly module
- Supersedes: none
- Superseded by: none

## Context

[ADR-0176](0176-host-concurrency-single-writers-and-effects.md) sets the
security end state: `lilly-hostd` is the only root component and the BEAM
runs as an unprivileged `lilly` user. It also says the privilege drop needs
its own audit. Since ADR-0176's decision 4 stages shipped, every host
utility runs in hostd, and both units are hardened without namespaces.

An inventory of `lilly/lib` (2026-10-16) found the BEAM still depends on
root in six areas:

1. **Root gates.** `File.stat("/proc/self")` must report uid 0 in
   `Ownership`, `Network.locked/3`, `Driver.locked_value/4`,
   `ZFSDataset.bind/1` and `Backup.main/0`.
2. **Ownership model.** `PrivateFiles` requires every state directory to be
   0700 and owned by the current uid, and secrets to be owned by it. About
   25 `lstat` checks require root-owned files, among them templates,
   datasets, disks, workload bundles and import cleanup.
3. **Sockets.** Ingress opens sockets inside VM network namespaces
   (`{:netns, path}`, `SO_MARK`, `bind_to_device`), which needs
   `CAP_SYS_ADMIN` and `CAP_NET_ADMIN`. The BEAM also dials Firecracker's
   API and vsock sockets inside jails owned by per-VM uids.
4. **Process introspection.** `Observation` compares the VMM's
   `/proc/<pid>/root`, `ns/net` and `exe`, which needs ptrace-level access.
   `lilly-vm-watch` watches another uid's process and cgroup.
5. **Helpers spawned by the BEAM.** `lilly-transfer-stream` and
   `lilly-source-export` run `zfs send` and `zfs receive` (and `ssh`, `cmp`)
   from the BEAM.
6. **Files in root-owned locations.** Jails, templates, datasets, `/run`
   working directories, the Firecracker logging directory and the image
   digest cache are written, chmodded and removed directly.

## Decision

Accepted by the user on 2026-10-16 ("do all the work"). Move each
privileged capability behind a typed hostd effect, one area at a
time, while the BEAM still runs as root, and switch `User=lilly` last:

1. **Introspection and watch.** hostd answers a typed `ObserveVmm` (pid,
   root, net namespace and exe identity, cgroup limits) and runs
   `lilly-vm-watch` for the BEAM, streaming its events.
2. **Sockets by descriptor.** hostd opens namespace sockets (with mark and
   device binding) and Firecracker API and vsock connections, and passes
   the descriptors to the BEAM with `SCM_RIGHTS`.
3. **Helpers as jobs.** Transfer and export helpers become hostd jobs with
   their pipes passed by descriptor.
4. **Files.** hostd gains typed file effects (`openat2`
   `RESOLVE_BENEATH`, `O_TMPFILE`, `renameat2`) for jails, templates,
   datasets and `/run` work directories. BEAM-private state moves to
   `lilly`-owned directories.
5. **Ownership flip.** Root gates become "is the configured service user".
   `PrivateFiles` and the `lstat` checks accept the service uid for
   BEAM-owned state and root for hostd-owned state. Secrets are delivered
   with `LoadCredential`.
6. **`User=lilly`.** The unit runs as `lilly` with an empty capability set.
   hostd admits that uid in `lilly.service`.

Each step ships separately and is verified natively before the next.

## Alternatives

- **Keep root and harden.** The current state. It limits the damage only by
  the bounding set; a BEAM compromise is still a host compromise.
- **Ambient capabilities instead of hostd effects** (`CAP_SYS_ADMIN`,
  `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`). Rejected: those three are close to
  root, and the BEAM would keep them.

## Consequences

- The BEAM loses direct host authority. A compromise is bounded by hostd's
  closed command set.
- hostd grows a typed command surface and descriptor passing, which needs
  protocol tests and fuzzing.
- The migration touches about 40 Lilly modules and the ownership of
  existing state, and needs a one-time `chown` of BEAM-owned state at the
  switch.

## Invariants and verification

- Before step 6, every privileged path in the inventory has a hostd effect
  with a refusal test, and a NixOS machine test runs Lilly as `lilly` with
  guest create, terminal, ingress, transfer, backup and delete.
- hostd refuses descriptor requests for namespaces and jails the session's
  leases do not cover.

## Implementation evidence

**Step 5 (ownership), first part.** [`Lilly.Host.Privilege`](../../../lilly/lib/lilly/host/privilege.ex) reports
a file owned by the configured service uid (`LILLY_SERVICE_UID`, default 0)
as uid 0 (`service-uid-normalised-to-root`). The root gates in `Ownership`,
`Network.locked/3`, `Driver.locked_value/4`, `ZFSDataset.bind/1` and
`Backup.main/0`, and the Lilly-state ownership checks in templates,
datasets, disks, workload bundles, the driver and import cleanup, go
through it. They admit root or that user; an unconfigured non-root BEAM
still fails closed. System files (`/etc`, the Nix store, images) keep plain
`File.lstat/1`. With the variable unset nothing changes; Lilly mix test
550/551 (the remaining failure is on origin/main alone).

**Step 1 (introspection).** [`Observation`](../../../lilly/lib/lilly/vm/observation.ex)
compares the VMM's `/proc` root, network namespace and executable through one
hostd `stat -L` read (`vmm-identity-through-hostd`). `lilly-vm-watch` needs
no change: `pidfd_open` and `cgroup.events` need no privilege.

**Step 2 (sockets by descriptor).** hostd gains `OpenUnix` (only `api.sock`
or `v.sock`, without symbolic links, beneath `--socket-root` pool paths;
`hostd-unix-socket-confined`) and `OpenNetnsTcp` (a dedicated thread enters
only the VM namespace, binds the tap device, sets the mark and the optional
source, connects within the timeout; `hostd-netns-connect`), and replies with
the descriptor as `SCM_RIGHTS`
([`descriptors.rs`](../../../lilly/native/hostd/src/descriptors.rs)).
[`Lilly.Host.Sockets`](../../../lilly/lib/lilly/host/sockets.ex) adopts it with
`gen_tcp`'s `fd` option when Lilly runs unprivileged and connects directly as
root (`sockets-through-hostd-when-unprivileged`). Every jail socket dial
(API, terminal vsock, credentials, workspace source, inception exchange,
flush, readiness, guest trust) and ingress go through it.

**Step 3 (helpers).** Instead of hostd jobs, the transfer and export
helpers' `zfs send` and `zfs receive` use ZFS delegation: in unprivileged mode
each pool dataset allows the `lilly` user `send,receive,snapshot,hold,release,userprop`
only. Mounting received datasets stays in hostd.

**Step 6 (the switch).** The [Lilly module](../../../nix/modules/lilly.nix)
option `services.lilly.unprivileged` (default off) runs the BEAM as `lilly`
(uid 977) with an empty capability set and `NoNewPrivileges`, sets
`LILLY_SERVICE_UID`, admits that uid in hostd, and runs `lilly-ownership`
first, which hands Lilly's state, runtime and pool metadata trees to `lilly`
and applies the ZFS delegation (`lilly-unprivileged-mode`).

**Not verified.** None of steps 1–6 has run natively in unprivileged mode,
and step 4 (typed file effects) is not built: the BEAM still writes jails,
templates and dataset metadata directly, which works only where `lilly`
owns them. The option stays off until a NixOS machine test runs the full
guest lifecycle as `lilly`.

## Open questions

- Whether OTP `:socket` can adopt a descriptor received with `SCM_RIGHTS`
  without a NIF (`socket:open/1` on an inherited descriptor is the
  candidate).
- Where the boot log and terminal state live once jails stay root-owned.

## Related decisions

- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): sets the
  security end state this ADR plans.
- [ADR-0144](0144-nix-builds-exclude-guest-datasets.md): private pool
  propagation, which rules out mount namespaces for both units.
