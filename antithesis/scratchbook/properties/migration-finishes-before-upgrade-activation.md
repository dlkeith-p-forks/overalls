# migration-finishes-before-upgrade-activation

Priority: P1. Confidence: high for intended ordering and source; concurrent-host behavior requires real database exercise.

## Claim and assertion

A candidate serving closure must not be activated before its explicit, bounded Marshall migrator exits successfully; serving startup never implicitly migrates, and a failed health check never automatically reverses schema. Proposed missing `Always`: **`lifecycle.candidate_activation_follows_successful_explicit_migration`**. This is safety at the actual activation boundary. Proposed missing `Reachable`: **`lifecycle.concurrent_candidate_migrator_waits_for_advisory_owner`** after a second host actually waits on the migration advisory lock; this targets a useful rare branch outcome, not a violation.

## Evidence and failure history

`marshall/lib/marshall/application.ex:12-41` selects operator mode with Repo/Vault/Cedar/Oban insertion but no listeners or queue leadership, and contains no migration call. `nix/domains/system/auto-update/runtime.py:542-571` runs the candidate migrator as a fixed, collected `systemd-run` oneshot with 1,800 s service timeout and 1,810 s client bound. `:1013-1028` calls stage, preflight, migrate, activate, verify, record in that order; `:1030-1047` retains failure and candidate recovery state without schema rollback. `marshall/config/config.exs:42` configures Ecto `migration_lock: :pg_advisory_lock`. `docs/architecture/decisions/0036-automatic-host-updates.md:26-47,78-96` explicitly claims advisory-locked migration across hosts and no schema rollback. Source presence establishes the intended path, not all real migration concurrency behavior; the ADR records native evidence at lines 206-219.

Failure history: stop the first updater while its systemd migration unit survives, start a second host's candidate update, kill a migrator midway, and lose its stdout/response. A returned timeout is not a known failed migration; inspect the real migration unit and schema migration ledger before retry. Activating a candidate while schema is incompatible could break serving, and duplicate simultaneous migration could exhaust connections or race DDL.

## Independent oracle and workload

Use two real Marshall hosts against one PostgreSQL primary with actual candidate migration and systemd units. Watch `schema_migrations`, PostgreSQL advisory lock holder/waiter, candidate `systemd-run` unit state, `/run/current-system`, and role process revisions. Block or slow the first migration; start second, then interrupt updater clients. Require no candidate closure activation before the corresponding migration has committed and exited. After failed migration, require prior serving processes remain and no automatic downgrade of `schema_migrations`; retry after healing and require a successful candidate path. Start a plain serving release independently and check migration ledger unchanged until explicit migrator invocation.

Configured limit menu: 1,800 s migrator service deadline and 1,810 s updater command timeout (`runtime.py:562,:570`); one versus two concurrent updaters; success, explicit failure, and lost-client uncertain result; pre- versus post-schema commit interruption. Keep hosted one-database evidence separate from physical database HA.

## Branch/replay guidance and scope

SUT-side missing assertions around `migrate()` completion, `run()` transition into `activate`, and the advisory lock waiter/result should record candidate and migration version IDs, not DB credentials or SQL arguments. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`. No assertion should demand automatic schema rollback, because ADR-0036 explicitly disallows it.

Open questions: Which native fixture can fault the real migrator and observe advisory-lock custody across two Marshall hosts? `(partial: updater unit and fleet have pieces; no combined two-host migrator fault fixture was found)`

### Investigation Log

#### Which native fixture can fault the real migrator and observe advisory-lock custody across two Marshall hosts?

- Examined: `nix/domains/system/auto-update/runtime.py:542-571,942-1028`, `nix/verification/tests/machines/auto-update/default.nix` and `driver.py`, `nix/verification/tests/machines/auto-update/unit.py:467-505`, `nix/verification/tests/machines/fleet/default.nix:540-669`, `marshall/lib/marshall/application.ex:12-41`, `marshall/config/config.exs:39-42`.
- Found: the updater invokes a fixed collected `overalls-auto-update-migrate` oneshot and awaits it before activation. Marshall operator mode has persistence/Oban insertion but no listeners or queues; serving mode does not implicitly migrate. The updater native fixture exercises a real switch on one fixture host, and the fleet has multiple Marshall hosts with explicit migration during startup. A unit test checks the fixed unit name on rerun.
- Not found: a native test that runs two candidate migrators against one PostgreSQL primary, records `pg_locks` holder/waiter and `schema_migrations`, then kills a migrator/updater at the activation boundary. The unit-name check alone cannot establish advisory-lock custody.
- Conclusion: partial. Extend the source-built fleet fixture with two independently launched updater/migrator units, a deliberately blocking migration, DB lock/ledger probes and closure/role observations. A client timeout remains uncertain until the real unit and migration ledger are checked.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
