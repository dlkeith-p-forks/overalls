# ADR-0013: Capacity collection and durable Lilly receipt

- ID: ADR-0013
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Lilly Host, Lilly Control, Marshall Compute, shared protocol
- Supersedes: none
- Superseded by: ADR-0031

## Context

Superseded by [ADR-0031](0031-sparse-zfs-storage-and-capacity.md) for native sparse
ZFS support and backend-specific accounting. That record explicitly carries
forward the non-storage receipt, collection and ownership requirements. The
original rationale and ext4 implementation evidence below remain historical.

The authorized plan requires current CPU, memory, disk and I/O measurements,
effective constraints, no overcommit, durable commands and a provisioner that
recovers from process restarts. ADR-0012 supplied authenticated requests but no
automatic sampler, process ownership or durable local receipt. This record
specifies those implementation details within the existing authorization.

## Decision

Run an optional Lilly control runtime when `LILLY_CONFIG_FILE` names a validated
private configuration. The file must be a single-link regular file, mode 0600,
owned by the effective user. State directories are owned by that user, mode 0700,
with safe, non-symlink ancestors. Credentials stay outside diagnostics and
GenServer status; expose a small status map with host/session identity, phase,
sample time, receipt count and fixed error atoms.

Acquire an OS `flock` on the state directory before opening it. A port-owned
`flock --nonblock --no-fork ... cat` holds the lock; an echoed nonce confirms
acquisition. This was the initial receipt-only implementation. ADR-0015 replaces
`cat` with a non-setuid command/lock helper, retaining ownership through utility
termination even when the Elixir caller dies. Bind the state
directory permanently to its enrolled host ID. Another Lilly process using the
same directory cannot open a session. VM lifetime remains independent of this
runtime; the VM driver is still a separate obligation.

Use one-second OTP timer ticks, at most one collector task and one HTTP exchange
in flight. Retain only the newest sample and never queue old reports. Use a
monotonic clock for scheduling/rates/backoff and UTC for the shared freshness
contract. Collection failure sends null observations and lets Marshall's previous
capacity expire normally. Keep collection errors visible even while exchanges
succeed. Transport failures back off exponentially with jitter; retry an initial
open using the same nonce. A stale session, revoked credential or unsupported
version fences the loop until an operator restarts/reconfigures it. Do not
automatically compete to replace a newer session with another nonce.

Read physical CPU/memory inventory from procfs and all ancestor limits of the
configured **VM cgroup v2 subtree**. It must be the subtree that the eventual VM
supervisor actually uses, not an unrelated cgroup containing only Lilly. Require
v2 CPU, memory and cpuset controller visibility. Respect enabled-controller files,
effective cpusets and every ancestor CPU quota/memory maximum. Reject missing or
malformed required controls and threaded/escaped paths. Floor quota/period using
integer division, never floating point scheduling arithmetic. A known zero
effective capacity is a valid fresh observation; missing capacity is not zero.

Initially support plain local ext4 pools on whole block devices or partitions.
Use the filesystem ID plus device identity and sector extents to detect aliases,
overlapping partitions and a whole device counted alongside its partition.
Reject device-mapper, loop and other stacked devices; they need explicit capacity
semantics before support. This cannot establish the physical backing guarantees
of a hypervisor/cloud volume outside the host's kernel-visible topology.

Report usable filesystem total/free space while excluding kernel-reserved blocks
from schedulable capacity. Report raw total/free/reserved bytes separately. Scan
`vms/<uuid>/rootfs.ext4`; credit only same-filesystem, regular, single-link,
fully allocated files. Sparse/partial and unmatched files consume free space but
earn no speculative reservation credit. The VM driver must fully preallocate
disks, prevent guest-triggered host hole punching and serialize host disk
creation/deletion with these snapshots. Those physical mutation guarantees must
be implemented before VM execution is enabled.

Derive CPU usage without adding guest counters twice. Derive read/write IOPS,
bytes/second, average completed-I/O latency, average queue depth, current requests
in flight and busy percentage from Linux diskstats and monotonic elapsed time.
First samples, unavailable counters and decreases/resets yield null rates.
Latency is null when no operations completed. Kernel busy/queue statistics are
observations, not throughput guarantees. Maximum IOPS stays null unless an
operator supplies a configured/calibrated value and provenance. IOPS remains
monitor-only.

Persist the latest command per VM in private JSON files. Validate the complete
protocol and host/pool binding. Write a new file exclusively, set mode 0600 before
writing contents, sync file data, atomically rename, then sync the directory.
Only then acknowledge receipt. Duplicates preserve identity; older generations
cannot replace newer intent; equal-generation conflicts fence the loop. Retried
writes re-read disk state, so an uncertain rename cannot move generation backward.
Keep an in-process cache only after successful durable writes and verify stored
intent when receiving duplicates. Failures/corruption fence receipt processing.
This is a delivery cache of Marshall's Ash operations, not another authority for
VM lifecycle or capacity reservations.

Invoke a fixed allowlist of GNU/util-linux utilities with argv arrays and no
shell. Pin those utilities in devenv. Bound output and use a separate timeout
process for utility execution. Use ordinary documented Linux interfaces; no
sample-host internal endpoints are involved.

## Alternatives

Sampling the Lilly process cgroup can advertise the wrong limits for independently
supervised VMs. CPU idle percentage cannot replace reservation accounting.
Rounding floating point quota ratios can add an extra core at precision limits.
Crediting sparse files can double-count promised growth. File rename alone does
not guarantee receipt durability after a crash. An in-memory process name cannot
prevent another BEAM from using the same state directory. Automatic reconnection
with a new nonce after fencing could make duplicate agents fight indefinitely.

## Consequences

Collection cost grows with pools/managed disks. Slow collection does not queue
unbounded work but eventually makes the host ineligible through freshness expiry.
Measure realistic host loads before scale claims. The current protocol bounds
pool/allocation counts and total report size. Disk topology is deliberately
restricted; broader storage and hot-replacement identity rules need review.

V1 reports capacity and stores commands without launching VMs. ADRs 0015–0017
subsequently add the storage coordinator, driver, executable v2 actors and physical
outcomes. [ADR-0023](0023-retained-capacity-telemetry.md) adds retained telemetry
without changing Lilly's report format. Operator enrollment/file delivery
remains required. Accepted receipt must not be presented to
users as a running VM.

## Invariants and verification

- Ancestor quotas, memory limits and CPU sets cap advertised capacity, including
  sub-core quotas and integer values beyond floating point precision.
- Filesystem reserved blocks, aliases and overlapping extents cannot create
  additional schedulable bytes; sparse files earn no premature credit.
- Reset/first/unavailable rates remain distinct from measured zero activity.
- One process owns each state directory; committed generations never decrease
  through reordered delivery or process restart.
- A real authenticated loop sends capacity, receives/stores/acknowledges an Ash
  operation, recovers after restart and fences on revocation.
- Losing pool access stops freshness updates even when control requests succeed.
- Run normal gates in all projects and explicit Linux/ext4 host integration tests
  with `mix test --include host` in Marshall. These tests need no root or KVM.

## Implementation evidence

[Collector](../../../lilly/lib/lilly/host/collector.ex),
[cgroup limits](../../../lilly/lib/lilly/host/limits.ex),
[pool identity/accounting](../../../lilly/lib/lilly/host/pool.ex) and
[counter rates](../../../lilly/lib/lilly/host/counters.ex) implement measurements.
[Runtime](../../../lilly/lib/lilly/control/runtime.ex),
[configuration](../../../lilly/lib/lilly/control/config.ex),
[host lock](../../../lilly/lib/lilly/host/lock.ex) and
[store](../../../lilly/lib/lilly/control/store.ex) implement automatic exchange
and durable receipt. [Private files](../../../lilly/lib/lilly/host/private_files.ex)
and [bounded utilities](../../../lilly/lib/lilly/host/command.ex) define OS access.

[Limit properties](../../../lilly/test/host/limits_test.exs),
[counter tests](../../../lilly/test/host/counters_test.exs),
[pool tests](../../../lilly/test/host/pool_test.exs),
[store properties](../../../lilly/test/lilly/control/store_test.exs) and
[host integration tests](../../../nix/verification/tests/machines/fleet/default.nix)
cover the listed foundation invariants. The
[review](../reviews/2026-09-15-capacity-loop.md) records scope and remaining gaps.

[ADR-0015](0015-jailed-execution-and-host-networking.md) now implements a shared
[pool mutation lock](../../../lilly/lib/lilly/host/storage.ex), preallocated disks
and VM units in `lilly.slice`. Runtime configuration must select that actual
subtree; executable v2 now enforces it. V1 remains receipt-only.

The native ZFS extension in [ADR-0031](0031-sparse-zfs-storage-and-capacity.md)
uses [logical pool I/O](../../../lilly/lib/lilly/host/zfs_io.ex), separately from
this decision's ext4 block-device counters. It preserves explicit unknowns,
bounded collection, provenance and monitoring-only IOPS. The
[I/O review](../reviews/2026-09-16-native-zfs-io.md) records integration evidence.

## Open questions

[ADR-0016](0016-executable-generations-and-lifecycle.md) adds the explicit v2
client and server ledger. [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
adds global host ownership and durable VM execution actors/outcomes to v2.

Measure sampling time/report size at representative VM counts. ADR-0023 defines
aggregation boundaries and retention jobs. Cgroup placement, mutation serialization,
preallocation and physical reconciliation are now integrated under ADRs 0015–0017.
Specify hot-replacement device identification and operational key/
credential delivery before fleet rollout.

[ADR-0014](0014-image-and-address-admission.md) adds locally verified read-only
image availability to the collector, without changing v1 command receipts.

## Related decisions

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0012](0012-provisioner-control-transport.md).

Interface references: [cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html),
[Linux I/O statistics](https://www.kernel.org/doc/html/latest/admin-guide/iostats.html),
[GNU sync](https://www.gnu.org/s/coreutils/manual/html_node/sync-invocation.html),
[util-linux flock](https://www.man7.org/linux/man-pages/man1/flock.1.html).

The original ext4/v1 host-loop tests were retired by ADR-0035. Their current
ZFS/v2 capacity, image-availability, restart and revocation coverage lives in the
linked NixOS fleet suite; earlier test results above remain historical.
