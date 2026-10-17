# migration-finishes-before-upgrade-activation

Priority: P1. Confidence: high for intended ordering and source; concurrent-host behavior requires real database exercise.

## Claim and assertion

A candidate serving closure must not be activated before its explicit, bounded Marshall migrator exits successfully; serving startup never implicitly migrates, and a failed health check never automatically reverses schema. Proposed missing `Always`: **`lifecycle.candidate_activation_follows_successful_explicit_migration`**. This is safety at the actual activation boundary. Proposed missing `Reachable`: **`lifecycle.concurrent_candidate_migrator_waits_for_advisory_owner`** after a second host actually waits on the migration advisory lock; this targets a useful rare branch outcome, not a violation.

## Evidence and failure history

`marshall/lib/marshall/application.ex:12-41` selects operator mode with Repo/Vault/Cedar/Oban insertion but no listeners or queue leadership, and contains no migration call. `nix/modules/auto-update/runtime.py:542-571` runs the candidate migrator as a fixed, collected `systemd-run` oneshot with 1,800 s service timeout and 1,810 s client bound. `:1013-1028` calls stage, preflight, migrate, activate, verify, record in that order; `:1030-1047` retains failure and candidate recovery state without schema rollback. `marshall/config/config.exs:42` configures Ecto `migration_lock: :pg_advisory_lock`. `docs/architecture/decisions/0036-automatic-host-updates.md:26-47,78-96` explicitly claims advisory-locked migration across hosts and no schema rollback. Source presence establishes the intended path, not all real migration concurrency behavior; the ADR records native evidence at lines 206-219.

Failure history: stop the first updater while its systemd migration unit survives, start a second host's candidate update, kill a migrator midway, and lose its stdout/response. A returned timeout is not a known failed migration; inspect the real migration unit and schema migration ledger before retry. Activating a candidate while schema is incompatible could break serving, and duplicate simultaneous migration could exhaust connections or race DDL.

## Independent oracle and workload

Use two real Marshall hosts against one PostgreSQL primary with actual candidate migration and systemd units. Watch `schema_migrations`, PostgreSQL advisory lock holder/waiter, candidate `systemd-run` unit state, `/run/current-system`, and role process revisions. Block or slow the first migration; start second, then interrupt updater clients. Require no candidate closure activation before the corresponding migration has committed and exited. After failed migration, require prior serving processes remain and no automatic downgrade of `schema_migrations`; retry after healing and require a successful candidate path. Start a plain serving release independently and check migration ledger unchanged until explicit migrator invocation.

Configured limit menu: 1,800 s migrator service deadline and 1,810 s updater command timeout (`runtime.py:562,:570`); one versus two concurrent updaters; success, explicit failure, and lost-client uncertain result; pre- versus post-schema commit interruption. Keep hosted one-database evidence separate from physical database HA.

## Branch/replay guidance and scope

SUT-side missing assertions around `migrate()` completion, `run()` transition into `activate`, and the advisory lock waiter/result should record candidate and migration version IDs, not DB credentials or SQL arguments. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`. No assertion should demand automatic schema rollback, because ADR-0036 explicitly disallows it.

Open questions: None after the source inspection above.
