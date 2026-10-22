# ADR-0256: Batched page authorization over one read-only snapshot

- ID: ADR-0256
- Date: 2026-10-22
- Status: accepted
- Implementation: partial
- Components: Marshall, PostgreSQL, overalls_diagnostics
- Supersedes: none
- Superseded by: none

## Context

`/overview`, `/machines` and `/machines/new` were slow. Code tracing found no
remote calls on any of them. All the time went to serial PostgreSQL round trips
inside one `Ledger.transaction`:

- **Per-machine authorization.** `Marshall.Compute.Views` checked read twice and
  manage three times for every machine.
- **Repeated actor reads.** Each `Authorization.allowed?/3` re-read the same
  data: the actor's user row, login token and elevation proof, the machine
  owner, and the machine's grant, thread and team rows.
- **Per-machine projection reads.** Each projected row also read its image,
  host, endpoint, pin, resize and owner one by one.
- **Catalog.** Headroom read reservations and pools separately for every host.

Measured in the test sandbox before this change, a machine page cost about
30 queries per listed machine. At 24 machines that was 724 queries and 758 ms.
Sessions with a bound login token pay more per decision (login presence and
elevation reads).

`/machines` scheduled its 1 s refresh before running it, so slow refreshes ran
back to back. `/overview` loaded everything on both the disconnected and the
connected mount. On `/machines/new`, every form `validate` patch reloaded the
catalog and team list.

Observability could not show any of this:

- The only Marshall web span covers the HTTP dead render, not LiveView mounts,
  refreshes or events.
- Ecto time was aggregated per minute, but the collector's gauge allowlist
  dropped it before it reached Prometheus.

The user required that the fix must not weaken security.

## Decision

Authorization for a page of machines runs as a **decision batch**:

- **Snapshot.** `Marshall.Authorization.DecisionSnapshot.transaction/1` opens the
  outermost transaction as `REPEATABLE READ, READ ONLY`. Every statement in the
  batch sees one PostgreSQL snapshot.
- **Memoized reads.** Inside the batch, reads that the snapshot makes identical
  are memoized for the rest of the batch: the Cedar principal (user,
  login-token presence, elevation), machine owners, grant/thread/team
  membership rows and VM entities, images, hosts, endpoints, pins and active
  resize requests.
- **Batched preloads.** A page may prime the same cache keys from batched
  `IN` reads with filters identical to the per-row reads.
- **Fresh evaluation.** Cedar still evaluates every decision. Only the
  persisted inputs are shared.
- **Scope and fallback.** The memo is process-local and dropped when the
  transaction ends. Nested inside another transaction, a batch does not
  memoize and every read runs fresh.

Time-dependent checks (token expiry, elevation window) are evaluated once, at
the batch's first principal read. They are not re-evaluated milliseconds later
for each row. Nothing is reused across refreshes, events, requests or
processes, so revocation, retirement, logout and demotion take effect on the
next refresh exactly as before.

**Page behaviour:**

- `/machines` schedules the next refresh only after the current one finishes.
- `/machines` reloads data on parameter changes only when the view changes
  (action, machine or cursor).
- `/overview` reads data only on the connected mount, and projects only the
  pinned machines it displays.

**Indexes:**

- `user_id`-leading partial indexes on current access grants, thread grants
  and team memberships.
- Owner and team keyset indexes on machines.
- A `host_id` index on reservations.

**List candidates.** `/machines` ANDs its exact authorization filter with a
superset of candidates: the actor's own machines, machines of the actor's
current teams, and machines named by the actor's current machine or thread
grants. The candidates come from indexed reads. They never admit a row on their
own, so the result is unchanged, but PostgreSQL can combine the owner, team and
primary-key indexes instead of walking every machine.

**Instrumentation** goes through `overalls_diagnostics`:

- Reviewed spans `marshall.live.refresh` (view label) and `marshall.views.read`
  (operation label).
- `Tracing.annotate/1` for end-of-span `query_count`/`row_count`.
- The registered `[:marshall, :live, :refresh]` metric.
- Per-view refresh count, duration and query totals in
  `marshall.runtime_metrics`.
- Database and per-view gauges admitted to Prometheus, with operations
  dashboard panels.

**Authorization source:** the user approved the implementation plan in this
session, with the constraint that security must not be weakened. The user later
approved two deviations from that plan:
- rejecting the catalog cache;
- keeping the fresh-read fallback for nested batches, instead of the planned
  `Cedar.with_principal` refusal.

## Alternatives

- **Cache permissions across requests or with a TTL.** Rejected: a revoked or
  demoted user would keep access until expiry.
- **Only deduplicate the six decisions per machine.** Safe, but it removes only
  about half of the reads. The repeated actor and grant reads remain.
- **Memoize under the default READ COMMITTED isolation.** Rejected: rows read
  later in the batch could legitimately differ from the memoized ones, so
  memoization would change decisions.
- **Cache the catalog for a few seconds.** Rejected: the batched catalog now
  costs a constant handful of reads, so a cache would save little. It would also
  show capacity older than the host freshness window (ADR-0023) and add a
  process to own the cache.
- **Rewrite the list query as a `UNION` of grant sources.** Rejected in favour
  of the candidate restriction. A `UNION` would restate the authorization
  predicates in a second form that could drift from the exact filter.

## Consequences

**Measured effect** (test sandbox, same probe before and after):

- **Owner list:** 34 → 14 queries at 1 machine, 364 → 25 at 12, and
  724 → 37 at 24 (758 ms → 73 ms).
- **Shared member list:** a constant 13 queries, down from 700 at 24 machines.
- **Catalog:** a constant 8 queries, down from 2H + 6.

**Plan on fleet-sized data.** A rolled-back sandbox probe used 2,012 users,
40,002 machines and 19,961 grants, with `ANALYZE` and
`EXPLAIN (ANALYZE, BUFFERS)` on the exact SQL `list_vms` sends:

| List query | Member, 1 grant | Owner of 20 |
|---|---|---|
| OR-of-EXISTS only (primary-key walk, 40,001 rows filtered) | 21.4 ms | 17.2 ms |
| Same, without the six new indexes | 18.5 ms | 23.0 ms |
| With candidates (BitmapOr of owner, team and primary-key indexes) | 0.065 ms | 0.084 ms |
| With candidates, without the six new indexes (walk returns) | 14.9 ms | 16.0 ms |

The grant index alone cut the grant subplan from 1.4 ms to 0.01 ms but left the
walk. The owner and team indexes matter only together with the candidates. The
candidates add three small indexed reads, 17 queries per page in all, still
constant in machine count.

Relocation status is read per row only for machines that have a relocation.
Machines without one are primed as `nil` from a single batched read.

**Costs and risks:**

- Long read-only snapshots are bounded by one page refresh.
- `SET TRANSACTION` must be the first statement of its transaction. This was
  verified on a real connection: outermost batches report `repeatable read`
  and `read only`, and nested batches stay `read committed` without
  memoization.
- The SQL sandbox cannot change isolation, so tests run the memoization
  without `REPEATABLE READ` (`decision_snapshot_isolation: false`).

**Page behaviour changes:**

- The overview's first, disconnected HTML shows empty panels marked
  `aria-busy`. The connected mount fills them.
- The pinned action gains a `limit` argument and returns `ids`, the readable
  pins in order. Existing callers keep their results.

## Invariants and verification

- **Decision equivalence.** A batched page lists exactly the machines that a
  fresh per-row read decision allows, with identical read/write/manage
  permissions, for any combination of grant roles.
  `marshall/test/marshall/compute/views_batched_reads_test.exs` checks this as
  a Hegel property.
- **No reuse across reads.** A revocation between two page reads hides the
  machine on the next read. Memoized values never survive their batch. The
  same file covers both.
- **Query budget.** Page queries do not grow with machines that have no
  relocation, and catalog queries do not grow with eligible hosts. The same
  file asserts both, and that listed relocation status equals a fresh per-row
  read.
- **Isolation.** The outermost batch is repeatable-read and read-only, refuses
  writes, and a nested batch keeps its transaction's isolation without
  memoizing.
  [`decision_snapshot_isolation_test.exs`](../../../marshall/test/marshall/authorization/decision_snapshot_isolation_test.exs)
  checks this on an unboxed real connection.
- **Form edits.** Editing the `/machines/new` form does not reload page data;
  a refresh tick reloads it once.
  [`machines_live_test.exs`](../../../marshall/test/marshall_web/machines_live_test.exs).
- **Bounded telemetry.** Annotation adds only reviewed schema attributes and
  never raises. `elixir/diagnostics/test/sdk_test.exs` checks this.

## Implementation evidence

| Component | Files |
|---|---|
| Snapshot and memo | [`decision_snapshot.ex`](../../../marshall/lib/marshall/authorization/decision_snapshot.ex) |
| Cedar principal memo | [`cedar.ex`](../../../marshall/lib/marshall/authorization/cedar.ex) |
| VM entity, grant and team batching | [`authorization.ex`](../../../marshall/lib/marshall/access/authorization.ex) |
| Thread binding batching | [`authorization.ex`](../../../marshall/lib/marshall/threads/authorization.ex) |
| Page prefetch, permissions computed once per row, batched catalog, spans | [`views.ex`](../../../marshall/lib/marshall/compute/views.ex) |
| Refresh scheduling and params handling | [`machines_live.ex`](../../../marshall/lib/marshall_web/live/machines_live.ex) |
| Connected-only overview load and pinned limit | [`overview_live.ex`](../../../marshall/lib/marshall_web/live/overview_live.ex) |
| Indexes | [`20261022091921_liveview_load_indexes.exs`](../../../marshall/priv/repo/migrations/20261022091921_liveview_load_indexes.exs) |
| Refresh measurement and query counting | [`observability.ex`](../../../marshall/lib/marshall/observability.ex) |
| Library spans, annotation and metric | [`tracing.ex`](../../../elixir/diagnostics/lib/overalls/diagnostics/tracing.ex), [`metrics.ex`](../../../elixir/diagnostics/lib/overalls/diagnostics/metrics.ex) |
| Dashboard and gauges | [`operations-dashboard.nix`](../../../nix/domains/system/otel-fleet/operations-dashboard.nix), [`default.nix`](../../../nix/domains/system/otel-fleet/default.nix), [`default.nix`](../../../nix/domains/system/logging/default.nix) |

Remaining gaps:

- The plan was measured on synthetic fleet-sized data (cloned rows, empty
  thread and team tables), not on production data.
- An owner of very many machines sorts all of them before the limit. That is
  cheaper than the old walk, but not keyset-bounded.
- Relocation status is still read per row for machines that have a relocation.
- The dashboard panels have not been observed with live fleet data.

## Open questions

- Should `/machines` move from 1 s polling to PubSub-driven refresh?

## Related decisions

- [ADR-0003](0003-control-plane-coordination.md): PostgreSQL authority and
  transaction boundaries.
- [ADR-0077](0077-teams-and-shared-resources.md): team and shared-machine
  authority.
- [ADR-0175](0175-thread-sharing-and-bound-machine-authority.md): thread-bound
  machine authority.
- [ADR-0160](0160-privileged-administrator-step-up.md): elevation freshness.
- [ADR-0149](0149-independent-observability.md) and
  [ADR-0042](0042-host-observability.md): observability.
- [Review 2026-10-22](../reviews/2026-10-22-liveview-load-performance.md).
