# lilly-hostd core review (2026-10-16)

## Scope

[ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md)
decision 4, first stage: replace one `lilly-host-lock` helper process per held
lock with one host-effects daemon, `lilly-hostd`. This review covers the
authorization, isolation, recovery and deployment boundaries the change
moves.

## Findings

| Area | Before | After | Risk and mitigation |
|---|---|---|---|
| Lock holding | Each held lock was a helper process holding one `flock`. Its stdin was the lock's lifetime. | hostd holds every lease's `flock` on the same inodes. | Other processes still contend on those inodes, so mixed old and new holders stay mutually exclusive during a rollout. |
| Waiting | Callers polled a non-blocking `flock` every 10–30 ms, spawning a helper each try. | Waiters queue per inode inside hostd and are granted in arrival order. The pool section waits once (`Lock.await/2`). | Property `lease-fifo-property`; lock test `waiters-granted-in-arrival-order`. |
| Executables | The BEAM passed an absolute executable path in every frame. | Lilly sends an index into a closed table; hostd resolves executables from its own PATH and clears the environment. | Arguments are still Lilly's. Typed commands come with the native effects stage. |
| Custody | The helper reaped its one command's process tree, then released. | Each production command runs in its own child of hostd's delegated cgroup; a reply, release or session end follows `cgroup.kill` and a confirmed empty cgroup. The utility inherits the lease descriptor. | Unit tests cover process-group custody only; cgroup custody runs under the module in machine tests. |
| Caller death | The helper's stdin closed with its holder, killing the command. | The session process releases a dead holder's leases, which kills their commands first; a Lilly crash closes the session and hostd fences the same way. | Lock test `holder-death-kills-leased-command`; hostd test `session-death-fences`. |
| Authentication | A helper trusted its parent. | Root-only socket; SO_PEERCRED uid 0, peer in `/system.slice/lilly.service`, exact protocol version. | `/proc/<pid>/cgroup` is read after connect, not through a pidfd. |
| Loss of hostd | Not applicable. | Lilly `BindsTo` hostd and stops with it; hostd's cgroup is killed by systemd; a surviving utility still holds its inherited lock. VMMs are transient units outside hostd's cgroup. | A hostd restart restarts Lilly's components. |
| Tooling BEAMs | Probes and evaluation tools spawned helpers themselves. | Without `LILLY_HOSTD_SOCKET` a BEAM starts a private hostd that inherits its environment, so PATH fault injection still applies. | The private daemon uses process-group custody. |

## Evidence

- `cargo test` passed 12 hostd tests: Hegel properties for Run and Acquire
  decoding against independent models, reply round-trips and lease grant
  order, plus real-utility session tests (output chunking, output limit,
  timeout, busy lease, release cancellation, session death, version check)
  and inode refusals. `cargo fmt --check` and `clippy -D warnings` passed,
  and the Nix package build reran all of them in the sandbox.
- Lilly mix test passed 550 tests (105 properties) against real daemons, including the
  new lock tests `holder-death-kills-leased-command` and
  `waiters-granted-in-arrival-order`.
- Both fleet hosts evaluate with `lilly-hostd.service`, the expected roots and
  `lilly.service` bound to it.

## Machine-test findings

The `zfs-guest` and `lilly-native-actor-recovery` tests enable the Lilly
module, so they run `lilly-hostd.service`. Their probe BEAM now uses that
unit's socket (`hostd.peerCgroups = [ ]` for the test), so creates exercise
cgroup custody and the unit's PATH. Two defects were found and fixed:

- hostd opened every root at startup and exited with status 71 when the pool
  path did not exist yet; these tests create the pool after boot. Roots are
  now opened at each acquisition, and setup failures have distinct exit
  codes.
- The roots omitted `/var/lib/lilly` itself, so a lock directory outside the
  listed state directories was refused. The module now includes it.

`zfs-guest` fails at baseline `87826bb3a` (before this change) on the same
`coding-clis` guest console step, so it is not evidence either way; the
actor-recovery variant passed at baseline in 840 s, and
checks.lilly-native-actor-recovery passed in 893 s with this change, after
both fixes.

## Remaining gaps

- Lease-less reads moved into hostd in the follow-up change; Lilly no longer
  spawns host utilities itself.
- Rank-ordered explicit leases, the outcome ledger, generation fencing and
  typed native effects are later stages of decision 4.
- No dedicated machine test yet for wrong-peer refusal, BEAM SIGKILL
  mid-command or escaped descendants under cgroup custody.
