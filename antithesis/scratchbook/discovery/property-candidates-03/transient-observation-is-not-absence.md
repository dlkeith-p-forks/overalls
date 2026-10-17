# transient-observation-is-not-absence

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(retryable_unavailability cannot replace durable physical outcome or release allocation)`;
message **"Lilly temporary observation failure never fabricates physical absence"**.

Evidence: `lilly/lib/lilly/vm/executor.ex:134-218` (`reconcile/3`) classifies
execution/network/storage contention as retry; `:247-266` (`adoption_failure/1`)
preserves known running VMM on transient ownership contention; `:315-318` defers
inconclusive unit state. `actor.ex:423-443` retry leaves durable journal unchanged.
Confirmed cleanup failures remain unknown; `executor.ex:517-549` requires proven
same-revision running history before labelling a crash. ADR-0017/0013 separate
absence, authority and observed availability.

History: keep guest running and preserve independently observed VMM identity;
hold pool/VM/network lock, interrupt systemd/ZFS probe or Control DB access,
restart actor/runtime and sample during it. Release the obstruction and verify
same boot adoption. Separately stop actual unit or invalidate custody identity
to exercise real negative proof; these are different semantic outcomes.

Oracle: pre/post journal hash and decoded pending outcome, PostgreSQL held
reservations, independent guest heartbeat/data read and actual process custody.
An observer failing to read the guest cannot infer guest death. Check no fabricated
stopped/deleted/disk-absent outcome and no released hold specifically due to
temporary failed inspection. A definite security/identity fence is not required
to keep granting execution access.

Guidance: `Reachable` **"Lilly running adoption deferred under real lock contention"**
on retry plus independent running witness; **"Lilly unknown cleanup retained allocation"**
on genuine cleanup uncertainty and held reservation. Instrument closed reason and
revision at executor/actor branches; errors alone are not lifecycle proof.

Values: 0/1/2-second lock contention, sampler ticks missed 1/4/16, 1/2/4 neighbors,
running/stopped/transitional unit observation, available/unavailable/read-only
storage. Hosted real owner helpers cover kernel flock; TCG supplies guest witness;
native systemd/ZFS/Firecracker required for production adoption and pool proof.

Open questions: Which probe failures are feasible in hosted TCG without replacing
the production observation implementation?
