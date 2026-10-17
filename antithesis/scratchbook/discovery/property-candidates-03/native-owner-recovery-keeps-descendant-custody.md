# native-owner-recovery-keeps-descendant-custody

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(successor_mutation_or_release_reply implies prior utility descendants retired)`;
message **"Native ownership recovery retains custody until every utility descendant retires"**.

Evidence: `lilly/native/host-lock/src/lib.rs:223-258` (`acquire`) stable private
lock and inherited descriptor; `:282-303` (`terminate`) signals before reaping;
`:305-319` parent-death setup; `:331-367` (`execute`) subreaper and inherited
custody; `:412-448` caller EOF cleanup. `lilly/lib/lilly/host/lock.ex:90` release
waits real helper exit, not merely port close. Directory CONTRACTS prohibit
unlinking owner.lock. ADR-0017 gives physical ownership authority.

History: owned utility forks descendant, descendant creates another session and
retains lock FD, then caller/helper dies or output limit/timeout fires. Successor
tries same inode while descendant can still mutate a tagged resource. Exercise
separate process groups, parent-death before/after exec, paused helper and direct
leader exit. Do not replace the owned helper by a dummy lock in this history.

Independent oracle: kernel lock contention on original inode, PID/start-time
and pidfd descendant identity, outside-observed mutation sequence on a harmless
owned test file. A reaped leader alone is insufficient; release failure is allowed
while custody is uncertain. After confirmed retirement a successor acquires and
mutates, rather than using an unlinked replacement inode.

Guidance: `Reachable` **"Native owner retired a descendant that escaped the utility process group"**
after reaping independently witnessed session escape; instrument cleanup reason,
remaining child count and original inode identity, never argv. Replay anchors at
caller EOF, timeout, group signal and final reap before acknowledgment.

Values: 0/1/2/4 descendants, ordinary/session escape, EOF/timeout/output overflow,
limits just below/equal/above configured output cap, owner paused 0/1/2 ticks.
Hosted real Linux Rust helpers may cover this directly if subreaping works and
the observer can use pidfds; native machine testing remains necessary for
cgroup/VMM confinement.

Open questions: Does the selected hosted environment support the helper's
subreaper and inherited-descriptor semantics, plus observer pidfds for an
independent descendant witness?
