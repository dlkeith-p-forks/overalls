# ADR-0159: Remove legacy compatibility after convergence

- ID: ADR-0159
- Date: 2026-10-11
- Status: superseded
- Implementation: implemented
- Components: Marshall, Lilly, Protocol, Audi, Brady, Ziggy, Lyra, NixOS, auto-update, observability, deployment
- Supersedes: ADR-0087, ADR-0088, ADR-0105, ADR-0126, ADR-0136, ADR-0138, ADR-0149, ADR-0151, ADR-0155, ADR-0158
- Superseded by: ADR-0197

## Context

[ADR-0197](0197-memory-suspension-and-demand-wake.md) replaces only the
memory-migration/stopped-source and cross-host-relay prohibitions where this
record carries them, and extends owner pins with automatic-suspension prevention
and wake. Unrelated requirements and historical rationale remain in force.


Overalls is in development and has no external consumers. The owner directed on
2026-10-02 that replaced mechanisms leave no legacy paths, shims or deprecated
APIs, and on 2026-10-11 asked for every remaining backward-compatibility and
legacy path to be removed. A read-only inventory of `9fe1e493` found about 75
such mechanisms: Lilly importers for old durable journal formats and one-shot
deployed-state migrations; optional protocol fields and capability flags kept for
older peers; retired archives, columns and triggers in Marshall's database;
rollout switches whose off path is the previous mechanism; version-tolerant
updater and metrics readers; and scripts and fixtures for removed harnesses.

The owner decided on 2026-10-11 to purge old-format data after an encrypted
export instead of writing conversion code, to remove every rollout switch with
rollback by revert, and to include the riskier removals: the
`logical_budget_bytes` binding field, applied one-shot migration files and the
separate Underclass latency histogram. The owner also authorized deleting
machines and privileged host maintenance where the removal needs it.

Two hosts update independently from the branch tip. The updater runs Marshall
migrations while the previous release still serves, and a fast pair of pushes can
skip the intermediate revision on a host.

## Decision

Keep exactly one current format and path per mechanism. Compatibility with an
older peer, release or stored shape exists only as **push ordering**, never as
retained code:

1. A consumer first stops relying on a field, route, column or format and
   tolerates its absence. Both hosts converge on that revision.
2. The producer stops writing it. Both hosts converge.
3. The decoder becomes strict, or a hand-written migration drops the column or
   table, in a later push.

A push that depends on an earlier push waits until both hosts report healthy on
a revision descending from it. Every Marshall migration remains compatible with
the release serving while it runs; this restates the inherited ADR-0036/ADR-0126
migration rule as expand/contract ordering.

Old-format durable data is exported, encrypted to the documented recovery
recipient and the operator key, verified and recorded by digest, then purged.
No conversion code is written. Restoring a backup taken before a purge is
unsupported. Rollout switches whose off path is the previous mechanism are
removed; rollback is a revert. Positive capacity sizes remain configuration.

Applied migration files may lose one-shot data statements, purges and
compatibility triggers once every deployed database contains their effect,
provided the schema a fresh installation produces is unchanged and required seed
rows remain. Squashing into a new baseline is not adopted.

This record replaces only these clauses and carries every other requirement of
the superseded records forward unchanged:

| Record | Replaced clause |
|---|---|
| ADR-0087 | The preserved default-on legacy `overalls.nixCompact.enable` option and compatibility adapters |
| ADR-0088 | The whole decision: exact legacy VM journal import |
| ADR-0105 | Retaining historical per-VM issuance rows as a read-only archive |
| ADR-0126 | The inherited retention of `logical_budget_bytes` for enrollment compatibility; its migration rule is restated above |
| ADR-0136 | Upgrading version-one and version-two recorder checkpoints; application-owned SLO exporter units |
| ADR-0138 | The separate versioned Underclass latency histogram |
| ADR-0149 | v1 lifecycle envelope acceptance, archive import, the lost-legacy-ACK projection compare, retention of retired diagnostic archives, and the shard cursor migration |
| ADR-0151 | The whole decision: existing-state profile migration, which completed on both hosts |
| ADR-0155 | The transfer-journal migration and legacy lifecycle rebase |
| ADR-0158 | The inherited owner-less execution commands and owner metadata endpoint (ADR-0069), and version-one roster bindings (ADR-0115) |

## Alternatives

Keeping the compatibility layers leaves duplicate paths and anti-patterns alive
with no consumer to protect. Conversion migrations would add code whose only
purpose is old data that can be exported instead. Squashing migration history
would require rewriting production `schema_migrations` and proving fresh and
upgraded schemas identical at once. A single coordinated push cannot remove a
field both hosts exchange without a window in which one host refuses the other.
Editing accepted records in place would silently rewrite their rationale.

## Consequences

Each mechanism has one code path and one test surface. Removals that cross the
Marshall/Lilly/Audi/Ziggy boundary take two or three converged pushes. Retired
archives, the pre-copy relocation history and legacy-shaped inference rows exist
only in encrypted exports. `logical_budget_bytes` removal changes the Lilly
installation binding; the updater refuses that change by design, so each host
receives a recorded root cutover of `owner.json` and an explicit switch to the
refused closure. Metric continuity for the Underclass latency histogram resets.

## Invariants and verification

- No production code accepts a format, field or route that no current producer
  emits; repository greps for removed identifiers return only historical records.
- No constraint remains `NOT VALID`, including Oban's own; a fresh database and
  an upgraded database have identical schemas.
- Every purge has an export with recorded digest before deletion.
- Each push is verified on both hosts before a dependent push.

## Implementation evidence

Execution commands require their owner in the
[execution codec](../../../protocol/lib/overalls_protocol/execution.ex). Lilly no
longer carries `logical_budget_bytes`: [the pool model](../../../lilly/lib/lilly/host/pool.ex)
rejects the option and records a budget-free ownership identity, the
[control client](../../../lilly/lib/lilly/control/client.ex) accepts only four-key
session pools, and [runtime configuration](../../../lilly/lib/lilly/control/config.ex)
and the [transfer endpoint](../../../lilly/lib/lilly/transfer/endpoint.ex) refuse a
pool that carries one, with refusal tests in
[session pools](../../../lilly/test/lilly/control/session_pools_test.exs) and the
[endpoint suite](../../../lilly/test/transfer/endpoint_test.exs). The
[Lilly module](../../../nix/domains/system/lilly.nix) has no budget option, the updater's
[Lilly owner descriptor](../../../nix/domains/system/auto-update/default.nix) and both
fleet `host.json` declarations omit it, and the
[host tool](../../../nix/domains/artifacts/host/preparation.py) neither sends a budget nor
bounds headroom by one. [Marshall enrollment](../../../marshall/lib/marshall/compute/enrollment_request.ex)
accepts only the three-key pool shape and refuses a supplied budget, with refusal
tests in the [request parser suite](../../../marshall/test/marshall/compute/enrollment_request_test.exs)
and the [enrollment suite](../../../marshall/test/marshall/compute/enrollment_test.exs);
[the drop migration](../../../marshall/priv/repo/migrations/20261012090000_drop_storage_pool_logical_budget.exs)
removes the column, which the [ZFS pool suite](../../../marshall/test/marshall/compute/zfs_pools_test.exs)
confirms is absent. The expand migrations
under [Marshall migrations](../../../marshall/priv/repo/migrations) drop orphan
tables, purge retired rows and refuse port 4444 while the serving release still
maps the remaining objects. Ziggy always maintains its durable SLO checkpoint
in [the spool](../../../ziggy/lib/ziggy/spool.ex); Marshall compares inference
completions exactly in [the request ledger](../../../marshall/lib/marshall/inference/requests.ex)
and the purge migration (`marshall/priv/repo/migrations/20261011210000_purge_legacy_inference_completions.exs` at overalls revision `033c8eef`, repository deleted)
deleted legacy-shaped rows before adding the
[exact-shape CHECK](../../../marshall/priv/repo/migrations/20261011210000_inference_completion_exact_shape.exs). Lilly has no
provisioning rollout switches: readiness is unconditional in
[the executor](../../../lilly/lib/lilly/vm/executor.ex), same-pool clones always
block-copy in [clone effects](../../../lilly/lib/lilly/clone/effects.ex), and
template budget and standby count are positive sizes in
[the Nix module](../../../nix/domains/system/lilly.nix). Remaining pushes
are listed in the plan record.

The [request recorder checkpoint](../../../nix/domains/system/otel-guest/receiver/src/durable_slo.rs)
accepts only version 3 and refuses any other version unchanged, with a regression
test for versions 1, 2 and 4. The logging collector's
[cursor preflight](../../../nix/domains/system/logging/check_cursors.py) only verifies
existing shard cursors; the [health evaluation](../../../nix/verification/tests/evaluation/logging-health.py)
exercises fresh, valid, corrupt and unsafe-custody cursors and confirms a retired
`journal.db` is neither read nor converted.

Underclass keeps one totals record with a single fifteen-bound duration histogram
in a fresh `slo-totals.sqlite` journal
([accounting](../../../nix/domains/artifacts/underclass/slo.rs)); no code reads the retired
`slo.sqlite`, which Window M2 exported and deleted on both hosts; `slo.lock`
remains the current journal's process lock. The
[exporter](../../../nix/domains/system/otel-guest/receiver/src/slo.rs) validates one
per-service bound set and has no `latency_v2` metrics; the
[recording rules](../../../nix/domains/system/otel-fleet/rules.nix) and
[diagnostics](../../../nix/domains/system/otel-fleet/diagnostics.nix) read the ordinary
histogram, exercised by the [rule fixtures](../../../nix/verification/tests/evaluation/otel-slo-rules.nix)
and the [native Underclass check](../../../nix/verification/tests/machines/underclass-slo/driver.py).

Applied one-shot data migrations are pruned under the policy above: the
monitor-credential retirement, profile rename, guest local-part pair and every
purge file are deleted, and backfills, data rewrites, the machine-name trigger
and the `NOT VALID` probe constraint are edited out of the remaining
[Marshall migrations](../../../marshall/priv/repo/migrations). Their DDL stays:
the exact-shape CHECK keeps its version, and
[Oban's priority validation](../../../marshall/priv/repo/migrations/20261011200000_validate_oban_priority.exs)
keeps the Push 7 version. A schema-only `pg_dump` of a fresh database migrated
before and after the pruning is identical; production `schema_migrations` keeps
the rows of deleted versions, which Ecto ignores.

Complete on 2026-10-13: fourteen ordered pushes and host windows M1–M3
converged on both hosts, every export is recorded with digests, and the final
sweep found no remaining compatibility path. See the
[removal review](../reviews/2026-10-11-legacy-compatibility-removal.md) for
preflight facts, exports, per-push results and the known issues outside this
decision. Repository policy is recorded in
[the root contracts](../../../CONTRACTS) and
[migration contracts](../../../marshall/priv/repo/CONTRACTS).

## Open questions

None.

## Related decisions

[ADR-0036](0036-automatic-host-updates.md), [ADR-0069](0069-brady-egress-cache.md),
[ADR-0115](0115-ssh-roster-boot-authority.md), [ADR-0130](0130-verified-provisioning-fastpath.md),
[ADR-0142](0142-overallsprotocol-control-websocket.md),
[ADR-0145](0145-same-pool-block-cloned-clones.md), [ADR-0146](0146-standby-guest-disks.md),
[ADR-0147](0147-standard-profile-name.md).
