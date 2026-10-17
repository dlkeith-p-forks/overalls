# transient-observation-is-not-absence

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
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

Open questions:

- Which hosted probe faults preserve real production observation? `(partial: hosted adapter cannot establish production systemd/ZFS observation)`

Next probe: Hosted Linux can exercise real flock contention and transport interruption, but TCG-only VMM/storage adapters do not run the production systemd/ZFS observer stack. Probe production Unit.status, Network and ZFS observation faults in a native machine while preserving a separately witnessed guest boot; hosted results must be labeled to the actual implementation reached.

### Investigation Log

#### Which hosted probe faults preserve real production observation?

- Examined: `lilly/lib/lilly/vm/executor.ex:134-218,247-266,315-318; lilly/lib/lilly/vm/driver.ex:1397-1435; antithesis/scratchbook/emulated-storage-feasibility.md`.
- Found: Hosted Linux can exercise real flock contention and transport interruption, but TCG-only VMM/storage adapters do not run the production systemd/ZFS observer stack. Probe production Unit.status, Network and ZFS observation faults in a native machine while preserving a separately witnessed guest boot; hosted results must be labeled to the actual implementation reached.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain partial production-observer feasibility; do not infer physical absence from hosted adapter errors.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
