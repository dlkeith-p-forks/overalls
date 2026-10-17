# native-utility-descendant-custody

P0; high source confidence; safety `Always`, message **"Native utility descendant custody blocks a second mutation until retirement"**. SDK assertion missing per [scan](../existing-assertions.md). On the original stable lock inode, a second exclusive mutation or successful release cannot occur while any first utility descendant can still mutate. Caller death, direct child exit or port close alone is not retirement proof.

## Evidence and fault history

`lilly/lib/lilly/host/lock.ex:41-113` waits for helper nonce/exit, while `lilly/native/host-lock/src/lib.rs:223-448` owns stable flock, inherited descriptors, subreaper and descendant cleanup on EOF/timeout/overflow. `lilly/native/source-export/src/lib.rs:209-210,415-441` applies equivalent transfer custody. Have a controlled utility fork a new-session descendant retaining the lock FD; kill BEAM caller/helper or let the leader exit, then race a second real mutator. This combines [focus 02](../discovery/property-candidates-02/native-utility-descendant-custody.md)'s overlapping-mutation witness and [focus 03](../discovery/property-candidates-03/native-owner-recovery-keeps-descendant-custody.md)'s successor-release/caller-loss history. A process-group-only kill would be too weak.

## Oracle, environment, and instrumentation

Record original lock device/inode, descendant PID/start-time/pidfd and tagged harmless file mutation in a workload-owned ledger. Direct flock probes and effect ordering independently establish overlap; do not unlink/recreate the lock path. After confirmed descendant retirement, a successor should acquire normally. Vary ordinary/escaped descendants, 0/1/2/4 children, EOF/timeout/output overflow, same/different inode. Hosted real Linux helpers may cover subreaping; Firecracker/cgroup custody needs native machine execution. A `Reachable` marker at reaping an escaped-session descendant helps search.

## Open questions

- Does hosted Linux preserve subreaper and inherited-descriptor behavior with stable pidfd/inode evidence after helper death? `(partial: helper uses subreaper; hosted namespace behavior unproven)`

Next probe: The helper explicitly sets itself as Linux child subreaper, inherits the lock descriptor across utility exec, and reaps adopted descendants after direct-child wait. Hosted Linux can run these kernel primitives, but source alone cannot establish the exact hosted container pid namespace/capabilities or stable pidfd observation after helper death. Probe a forked setsid descendant holding the original inode, kill caller/helper, and observe flock denial until confirmed descendant exit; distinguish direct-child exit from descendant retirement.

### Investigation Log

#### Does hosted Linux preserve subreaper and inherited-descriptor behavior with stable pidfd/inode evidence after helper death?

- Examined: `lilly/native/host-lock/src/lib.rs:223-295,342-378; lilly/native/source-export/src/lib.rs:209-210,415-441; lilly/lib/lilly/host/lock.ex:41-113`.
- Found: The helper explicitly sets itself as Linux child subreaper, inherits the lock descriptor across utility exec, and reaps adopted descendants after direct-child wait. Hosted Linux can run these kernel primitives, but source alone cannot establish the exact hosted container pid namespace/capabilities or stable pidfd observation after helper death. Probe a forked setsid descendant holding the original inode, kill caller/helper, and observe flock denial until confirmed descendant exit; distinguish direct-child exit from descendant retirement.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain hosted environment probe; explicitly reject direct child exit as retirement proof.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. hosted-tcg-zfs-limited; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
