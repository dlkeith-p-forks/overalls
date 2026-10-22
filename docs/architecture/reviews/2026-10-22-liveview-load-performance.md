# 2026-10-22: LiveView load performance and batched authorization

## Scope

This review covers the slow `/overview`, `/machines` and `/machines/new` page
loads and the change recorded in
[ADR-0256](../decisions/0256-batched-page-authorization-snapshots.md):

- batched authorization over one read-only snapshot;
- batched projection and catalog reads;
- LiveView refresh scheduling;
- list and catalog indexes;
- `overalls_diagnostics` spans and metrics, with operations dashboard panels.

Dimensions reviewed: access and data (Cedar inputs, revocation), coordination
(transaction boundaries, isolation), capacity (catalog headroom), operation
(observability) and verification.

## Findings

1. **High. Authorization was the cost, not missing indexes.**
   - Per machine, `Views` made six Cedar decisions.
   - Each decision re-read the actor's user row, login token, elevation proof,
     the owner, and the grant, thread and team rows.
   - Measured before: about 30 queries per machine, 724 queries and 758 ms for
     24 machines.
   - Resolution: decisions are batched over one `REPEATABLE READ, READ ONLY`
     snapshot. Cedar still evaluates every decision; only the persisted inputs
     are shared within the snapshot.
2. **High. Refreshes could run back to back.** `/machines` queued its next 1 s
   refresh before running the current one. Resolution: the next refresh is
   scheduled after the current one completes.
3. **Medium. Repeated page loads.**
   - `/overview` read all panels twice per page load.
   - `/overview` built views for up to 20 pinned machines and displayed six.
   - `/machines/new` reloaded the catalog and teams on every validation patch.

   All three are resolved.
4. **Medium. Catalog headroom read per host.** Reservations and pools were read
   once per host. Resolution: two batched reads, plus a `host_id` reservation
   index.
5. **Medium. Telemetry could not show the problem.**
   - LiveView work had no spans.
   - Ecto gauges were dropped by the collector's allowlist.
   - No panel showed request or query cost per page.

   Resolution: reviewed spans and annotations, per-view refresh metrics,
   admitted gauges and four new panels.
6. **Low, open. List query plan.** The list filter ORs `owner_id` with three
   correlated EXISTS clauses. User-leading indexes were added, but the plan has
   not been checked with `EXPLAIN` on production-sized data. A `UNION` rewrite
   stays open.

## Security assessment

Decisions are unchanged:

- **Same snapshot, same rows.** Inside one repeatable-read snapshot, a repeated
  read returns the row it returned the first time. The Hegel property in
  `marshall/test/marshall/compute/views_batched_reads_test.exs` compares batched
  pages with fresh per-row decisions across generated role assignments.
- **No reuse across requests.** Memoized values are dropped when the
  transaction ends, raises or rolls back. A revocation between reads hides the
  machine on the next read; the same test file covers this.
- **Nested batches stay fresh.** A batch nested inside another transaction never
  memoizes. A probe against a real connection showed `read committed` and no
  memo for the nested case, and `repeatable read` with `read only` for the
  outermost case.
- **One evaluation instant.** Token-expiry and elevation windows are evaluated
  once per batch, at its first principal read. Every row of a page therefore
  sees the same moment rather than drifting across rows.

## Checks run

- **Diagnostics library:** `mix test` in `elixir/diagnostics` passed 40 tests,
  including the new annotation test. The schema was regenerated with
  `generate_schema.exs`, and `mix schema.check` passed.
- **New Marshall tests:**
  `mix test test/marshall/compute/views_batched_reads_test.exs --include hegel`
  passed 4 tests.
- **Before and after query counts:** measured with the same probe on trunk
  `95616c01d` and on this change, as recorded in ADR-0256.
- **Pre-existing failures:** six `/machines/new` provisioning tests in
  `test/marshall_web/machines_live_test.exs` fail identically on unchanged
  trunk.

## Plan completion follow-up

These were added after the first commit to close items from the plan's
verification list.

- **Real-connection isolation:**
  `test/marshall/authorization/decision_snapshot_isolation_test.exs` runs on an
  unboxed connection.
  - It asserts that the outermost batch reports repeatable read and read-only
    and refuses an UPDATE.
  - It asserts that a batch nested in a read-committed transaction does not
    memoize.
  - The real-connection isolation test passed.
  - Replacing the `SET TRANSACTION` with `READ COMMITTED` makes it fail.
- **Form edits:** editing the `/machines/new` form does not refresh page data,
  but a tick refreshes it exactly once. The form-edit refresh test passed.
  Forcing a reload on every patch makes it fail on `refute_received`.
- **Relocation reads:**
  - Relocation status is now primed as `nil` for machines without any
    relocation, from one batched read.
  - Relocated machines keep the unchanged per-row read.
  - The owner-list budget now asserts equal query counts for four and twelve
    machines.
  - A new test compares listed relocation status with a fresh per-row read.
- **Catalog budget:** a new test asserts equal catalog query counts for two and
  six hosts. A per-host read mutant fails it with 10 versus 14 queries.
- **Catalog TTL cache:** rejected, with user approval; see ADR-0256
  Alternatives. The user also approved keeping the nested fresh-read fallback
  instead of the planned refusal.
- **Unattributed failures:** sharing surfaces, lifecycle history, suspension,
  clone history and relocation sources also fail on `95616c01d`, the commit
  before this change. Suspension outcomes vary between runs.
- **Fleet-sized `EXPLAIN`:**
  - **Setup.** A rolled-back probe used 40,002 machines, 2,012 users and
    19,961 grants.
  - **Before.** The OR-of-EXISTS list query walked the primary key and
    filtered 40,001 rows, taking 17–23 ms with or without the new indexes.
  - **Change.** Adding an indexed candidate superset produced a BitmapOr plan
    of 0.065–0.084 ms, which needs the owner and team indexes.
  - **Equivalence.** Equivalence, revocation, budget and relocation checks
    pass: `views_batched_reads_test.exs` passed 7 tests.
  - **Related tests.** `threads_machine_access_test.exs` passes.
  - **Pre-existing failure.** A `teams_resource_history_test.exs` timeout in
    `host_fixture` also fails with trunk's `views.ex`.
- **Results:** `views_batched_reads_test.exs` passed 7 tests together with the
  relocation settings LiveView test. The machines LiveView file still has only
  the six provisioning failures above. They fail identically on `95616c01d`,
  the commit before this change.

## Live deployment check (2026-10-22)

The user asked for measurement on this host, so this check ran read-only on
`panterloons`.

- **Data:** 2 users, 19 machines; all six indexes deployed.
- **List query:** a rolled-back `READ ONLY` `EXPLAIN (ANALYZE, BUFFERS)` took
  0.248 ms for the OR-of-EXISTS shape and 0.085 ms with candidates. A
  sequential scan is correct at this size.
- **SLIs:** six anonymous page loads gave six `marshall_live` successes. In
  Grafana, the completion and within-1 s SLIs read 1 and p95 read 38 ms.
- **Diagnostics:** the callback panels showed a 6.3 ms mean mount, and Tempo
  holds `marshall.live.callback` spans.
- **Gauge delay:** the `liveview_*` gauges reached Prometheus about a minute
  after the first callbacks, at the next 60 s log-to-metric flush and 30 s
  scrape.

## Relocation batching

`RelocationStatus.latest_many/1` batches the latest relocation, readiness
request, stop operation and outcome for managed rows.
`relocation_status_batch_test.exs` compares relocated, cancelled and
never-relocated machines with `latest/1`, and also through `list_vms`.
Returning nil from the batch makes that test fail. The affected suites pass:
66 tests, including views, relocation capacity, evacuations, thread access,
overview, pins and the relocation LiveView test.

## Follow-up

- Repeat the `EXPLAIN` on production data.
- Consider PubSub-driven refresh for `/machines`.
- Watch the new panels with live fleet data.
