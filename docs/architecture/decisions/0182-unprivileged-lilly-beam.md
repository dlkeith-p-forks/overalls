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
- hostd refuses socket requests for paths outside its socket roots and
  namespaces or devices that are not Lilly's. Correction (2026-10-17): these
  requests were never lease-gated; they are gated by peer authentication and
  that path and namespace policy.

## Implementation evidence

**Step 5 (ownership), first part.** [`Lilly.Host.Privilege`](../../../lilly/lib/lilly/host/privilege.ex) reports
a file owned by the configured service uid (`LILLY_SERVICE_UID`; unset
means none) as uid 0 (`service-uid-normalised-to-root`). The root gates in `Ownership`,
`Network.locked/3`, `Driver.locked_value/4`, `ZFSDataset.bind/1` and
`Backup.main/0`, and the Lilly-state ownership checks in templates,
datasets, disks, workload bundles, the driver and import cleanup, go
through it. They admit root or that user; an unconfigured non-root BEAM
still fails closed. System files (`/etc`, the Nix store, images) keep plain
`File.lstat/1`. With the variable unset nothing changes; Lilly mix test
550/551 (the remaining failure is on origin/main alone).

**Step 1 (introspection).** [`Observation`](../../../lilly/lib/lilly/vm/observation.ex)
compares the VMM's `/proc` root, network namespace and executable through one
hostd `stat -L` read (`vmm-identity-through-hostd`), always: the direct
root comparison was removed with root mode. `lilly-vm-watch` needs
no change: `pidfd_open` and `cgroup.events` need no privilege.

**Step 2 (sockets by descriptor).** hostd gains `OpenUnix` (only `api.sock`
or `v.sock`, without symbolic links, beneath `--socket-root` pool paths;
`hostd-unix-socket-confined`) and `OpenNetnsTcp` (a dedicated thread enters
only the VM namespace, binds the tap device, sets the mark and the optional
source, connects within the timeout; `hostd-netns-connect`), and replies with
the descriptor as `SCM_RIGHTS`
([`descriptors.rs`](../../../lilly/native/hostd/src/descriptors.rs)).
[`Lilly.Host.Sockets`](../../../lilly/lib/lilly/host/sockets.ex) adopts it with
`gen_tcp.fdopen/2` whenever a direct connect is refused for lack of
privilege (`sockets-through-hostd`); as `lilly` every jail socket and VM
namespace connection takes that path, while a caller with access (a root
tool, a unit test's own socket) connects directly. Every jail socket dial
(API, terminal vsock, credentials, workspace source, inception exchange,
flush, readiness, guest trust) and ingress go through it.
[ADR-0184](0184-lilly-owns-every-socket.md) replaces this mechanism: the BEAM
never closes a descriptor it did not create, so every passed socket leaked
and Firecracker's API stopped answering. hostd now connects a socket Lilly
created (`ConnectUnix`) or bridges it to the namespace connection through
`lilly-ingress-bridge` (`BridgeNetnsTcp`), and sends no descriptor.

**Step 3 (helpers), replaced.** The first build used ZFS delegation
instead of hostd jobs: each pool dataset allowed the `lilly` user
`send,receive,create,mount,snapshot,hold,release,userprop`. That build was
never shipped. A delegated receive silently drops every non-user property,
and the delegation let any `lilly` process receive a setuid- or
device-bearing dataset. [ADR-0183](0183-guest-dataset-streams-in-hostd.md)
replaces this step. Every guest dataset stream now runs in hostd from typed
fields, and `lilly` holds no ZFS permission.

**Step 6 (the switch).** The [Lilly module](../../../nix/domains/system/lilly.nix)
runs the BEAM as `lilly` (uid and gid 377, below the dynamic system range) with an empty capability set and `NoNewPrivileges`, sets
`LILLY_SERVICE_UID`, admits that uid in hostd, and runs `lilly-ownership`
first, which hands Lilly's state, runtime and pool metadata trees to `lilly`
and revokes any ZFS delegation an earlier build granted (`lilly-unprivileged-mode`).

**Step 4 (files), as built.** An inventory of every BEAM file effect found
that almost all of them already go through
[`PrivateFiles`](../../../lilly/lib/lilly/host/private_files.ex), which
works for whichever uid owns the directory, and that every chown to a jail
uid already runs in hostd. What needs root is narrower than this decision
assumed, and is routed through hostd's closed utility table instead of a
new typed file executor:
- `chmod` of files the BEAM does not own (hostd image-copy outputs and
  jail-owned drives) uses the new `chmod` utility (index 27) only after
  `File.chmod/2` fails with EPERM (`chmod-through-hostd-when-not-owner`);
- jail trees, which the jailer populates as root and the jail uid, and
  backup metadata copies are removed by hostd's `rm -rf --one-file-system`
  when `File.rm_rf/1` cannot finish (`remove-tree-through-hostd-when-not-owner`);
- dataset and template roots that hostd creates are handed to the service
  uid before the BEAM writes their metadata (`claimed-directory-owned-by-service`).
All three are in [`Lilly.Host.Privilege`](../../../lilly/lib/lilly/host/privilege.ex)
and are identical to the previous code as root. The general typed file
executor (`openat2`, `O_TMPFILE`, `renameat2`) stays open under
[ADR-0176](0176-host-concurrency-single-writers-and-effects.md) decision 4;
unprivileged operation does not depend on it.

**Step 5 (secrets).** `lilly.service` receives the
credential and Inception SMTP files with `LoadCredential`, the published
configuration names `/run/credentials/lilly.service/…`, and `read_secret`
accepts systemd's owner-only 0400 as well as 0600.

**Ownership hand-over.** `lilly-ownership` hands Lilly's state trees,
including the transfer state directory, and its `.lilly-*` pool metadata to
`lilly`, but only the jail directories
themselves (never their contents, which belong to per-VM uids). It also
hands over each pool's `vms`, `standbys` and `templates` mountpoint parents
and the root directory alone of every template a root Lilly sealed,
remounting the template and restoring `readonly` after that one `chown`;
sealed files stay root-owned and read-only. Without this, the first
unprivileged release on 2026-10-16 could not traverse `templates` and
failed every template read and retirement on both hosts. The remount
exposed one more fault: sealed identities recorded the device number, which
Linux ZFS reassigns on every mount, so any remounted template (also after a
reboot) was quarantined. Seal checks now ignore only that field while the
caller still pins the dataset GUID and mountpoint. hostd's
control socket is owned by the admitted peer uid (`hostd-socket-owned-by-peer`)
in a 0711 runtime directory.

**Boundary, with residual risks.** hostd no longer takes a caller argv
it does not understand: the VM unit is a typed `LaunchVm`; file effects,
jail mounts and ZFS snapshot mounts are performed natively on descriptors
resolved beneath fixed roots; every remaining utility must match the
argument shapes Lilly uses (ZFS names beneath the pool datasets, `ip` and
`sysctl` on Lilly's devices and namespaces, `netns exec` only for hostd's
own `ip`/`nft`/`sysctl`/flow labeller, `systemctl` on `lilly-vm-*` units),
and host-namespace `nft` rules may only define Lilly's own tables (see
ADR-0176 decision 4). Residual risks: Lilly's own nftables tables can drop
or redirect host traffic (it is the network policy author),
namespace-local rule files are not inspected, and the peer-supplied
transfer resume token is checked only by hostd's grammar and
`lilly-resume-token`'s parser. Lilly's private-services readiness check
needs two supplementary groups: `audi-private-status` (private Audi's
read-only status socket alone) and `ziggy-proxy`. The second admits Lilly to
Ziggy's whole proxy socket, not only its health route, which is the access
root Lilly and private Audi already had; a health-only Ziggy socket would
remove it. The fleet machine test found these groups missing: every new
guest start on a private-services host was deferred. Private Audi's guest
lookup and Brady's egress attribution also authenticated Lilly as uid 0, so
the switch left every guest without its SSH host certificate (readiness timed
out) and every egress flow unattributed. They and the Audi gateway's ingress
connector now take Lilly's uid from configuration (`users.users.lilly.uid`).
The control-plane CA is
a systemd credential, so its source path may be root-only. Guest dataset
`send` and `receive` are typed
hostd streams with no ZFS delegation ([ADR-0183](0183-guest-dataset-streams-in-hostd.md)).

**The only mode (2026-10-16).** At the user's direction the switch first
became the fleet default and then the only mode: the
`services.lilly.unprivileged` option, and every root-mode branch in Lilly
(`Privilege.unprivileged?/0`, mode-selected socket connects, the root VMM identity
comparison, the root-only branches of the chmod/remove fallbacks), were
deleted, completing
step 6's migration. Boot-time tmpfiles rules give Lilly's state directories
and its socket directories (`/run/lilly-ingress`, `/run/lilly-brady`,
setgid to the peer's group) to the service user. Root Lilly tools (backups,
transfer workers, operator `lilly eval`, machine-test probes) are not the
service: they keep root but always set `LILLY_SERVICE_UID` (the module
exports it system-wide) so they trust the state the service wrote. Every
machine test now runs `lilly.service` as `lilly`; the zfs-guest probe BEAM
also runs as `lilly`.

**Machine evidence (2026-10-16).** `lilly-unprivileged-enrollment` (now
`enrollment-operator`: the real `lilly.service` as `lilly`, credentials via
`LoadCredential`, enrolled with Marshall and ready) passed.
`lilly-unprivileged-guest` (now `zfs-guest`) boots, observes, writes to, stops, deletes,
snapshots, exports and restarts a confined guest as `lilly`, and recovers
from a simulated host loss; runs found and fixed: hostd's root-only socket,
gen_tcp adoption of passed descriptors (`fdopen`, not a second connect),
systemd credential files (root-owned, ACL-readable), the Firecracker log
collector's manifest owner, transfer state ownership and root workers'
trust, transfer key ownership, and `lilly-ownership` handing hostd's
`owner.lock` inodes to `lilly` (now excluded). A complete passing run of
the unprivileged guest journey is not yet recorded; `zfs-guest`'s
`coding-clis` step also fails on main.

**Verification.** The `zfs-guest` machine test runs the full guest journey
with the probe BEAM as `lilly`, no capabilities and
`NoNewPrivileges`. Its first runs found the root-owned socket and the
fixture's boot-time pool ownership; its result is recorded below. The
`lilly.service` paths (credentials, the unit's capability set) are not
covered by that test, which drives Lilly from a probe.

Correction (2026-10-17): the hand-over omitted the transfer state
directory. Its `transfers/` keys and `exports/` permits stayed root-owned
on both production hosts, so the unprivileged BEAM refused its own transfer
tree and the first production clone failed at `invalid_transfer_identity`.
The [module](../../../nix/domains/system/lilly.nix) now hands it over
recursively, and the zfs-guest hand-over subtest seeds a root-era transfer
tree and asserts that nothing but lock inodes stays root-owned.

## Open questions

- Answered by [ADR-0184](0184-lilly-owns-every-socket.md): OTP adopts a
  received descriptor without a NIF but never closes it, so hostd no longer
  sends descriptors.
- Answered for the boot log (2026-10-17): it stays at
  `<state_dir>/<placement>/boot.log`. The root boot-log writer creates or
  verifies it as a single-link 0600 file and, given `--reader-uid`, hands it
  to the service uid through the same descriptor, as the launch guard
  accepts the service uid's `intent.bin` (`boot-log-private-to-its-reader`,
  `vm-launch-argv-derived-by-hostd`). Before this, the unprivileged BEAM
  could not open the root-owned log and the terminal's boot-log pane stayed
  empty. Where terminal state lives remains open.

## Related decisions

- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): sets the
  security end state this ADR plans.
- [ADR-0183](0183-guest-dataset-streams-in-hostd.md): replaces step 3's
  ZFS delegation with typed hostd streams.
- [ADR-0144](0144-nix-builds-exclude-guest-datasets.md): private pool
  propagation, which rules out mount namespaces for both units.
- [ADR-0184](0184-lilly-owns-every-socket.md): replaces step 2's descriptor
  passing.
