# Legacy compatibility removal (2026-10-11)

Scope: [ADR-0159](../decisions/0159-remove-legacy-compatibility.md). Remove every
backward-compatibility and legacy path in ordered, converged pushes; export then
purge old-format data; remove rollout switches. Owner authorization (2026-10-11):
everything in scope, purge after export, delete machines and use privileged host
maintenance as needed.

## Preflight (Step 0, read-only, 2026-10-11)

Both hosts were healthy on `f4b0892c` (current main at the time);
`/run/current-system` matched `lastHealthySystem` on each.

### Host state

| Fact | dungarees | overalls |
|---|---|---|
| Stored commands / running `lilly-vm-*` units / VM datasets | 3 / 3 / 3 | 21 / 21 / 21 |
| Commands without `owner_id` | 0 | 0 |
| Live-file markers `"antithesis"`, `baseline_guid`, `"lilly-a"` | 0 | 0 |
| Pre-lifecycle actor journals, `.lifecycle-legacy` archives | 0 | 0 |
| v1 envelopes: actors / vms / deleted claims / transfers | 31 / 49 / 6 / 5 | 218 / 388 / 39 / 27 |
| v1 envelopes in templates, standbys, active claims, copies | 0 | 0 |
| `.lifecycle-v1` archives (unimported, all under imports) | 320 (13) | 525 (19) |
| Standby diagnostics entries | 256 | 256 |
| Manifest keys (resourcePolicy, diagnosticPreflight, consumers, socketUnits, transferStateDirectory) | present | present |
| `owner.json` pools carry `logical_budget_bytes` | yes | yes |
| Logging cursors (`journal-*.db`) quick_check | ok; legacy `journal.db` and `journal-1.db` present | same |
| Recorder checkpoints | all v3 | all v3 |
| Ziggy spool | empty, `.slo-checkpoint` present | same |
| Rebind receipts | `lilly-rebind{,-network}.json` (2026-09-22) | none |

### Marshall database (overalls, `BEGIN READ ONLY`)

| Query | Result |
|---|---|
| Migration files not applied | 0 |
| Retired archives | fleet_hosts 2, fleet_credentials 2 (+2 versions), fleet_buckets 5018, fleet_receipts 1408, telemetry_summaries 51286, ingress_issuances 0, compute_lifecycle_cursors 1611 |
| Lifecycle events by actor | provisioner 8260 (1592 with pool_id), system 6024, user 1784 |
| `protocol_version` | hosts: 2 at v4; host sessions: 46 at v4, 3161 at v3 |
| Job-history backfill gap | 0 |
| Relocations | 22, none unfinished |
| Inference rows legacy-shaped / total | 5 / 5 |
| Endpoints on port 4444; retired agent tools; open operations without owner | 0; 0; 0 |
| Non-archived VMs | 0 |
| Machine-name trigger | present |
| NOT VALID constraints | `compute_relocations.relocation_stop_requires_probe`, Oban's `oban_jobs.non_negative_priority` (kept) |
| Hosts without `machine_id` | 0 |

The host counts above were transient: a later read-only check the same day found
0 stored commands and 0 `lilly-vm-*` units on both hosts, matching Marshall's 0
non-archived VMs (418 archived). No orphaned placement exists.

## Pushes

Results are appended per push.

### Governance and updater strictness (`f636fa02`)

ADR-0159, superseded records, contracts and HLDD policy, plus the updater refusing
manifests without current fields and resource-policy introduction. Gates:
`auto-update-compatibility`, `host-planning`, `enrollment-preparation`, `hldd`,
Marshall precommit, both host evaluations. `auto-update-custody` fails identically
on the unmodified base (`unexpected unit pattern --no-legend`); that harness gap
predates this work. Both hosts reported healthy on `f636fa02`.

### Push 1a (Lilly, protocol, Nix and scripts dead code)

Console relay v1, dead events, resume-token argument, short host-lock frame,
retained `metrics.summary`, application-owned SLO exporters, legacy Nix options and
aliases, legacy deployment fixtures and fastpath campaign scripts. Gates: prek;
precommit in marshall, lilly, porsche, protocol and elixir/diagnostics; Nix
`hldd`, `module-configuration`, `otel-slo-rules`, `python-static`,
`nix-compact-configuration`, `host-planning`, `logging-transports`,
`auto-update-compatibility`; native `audi-service`, `galileo-service`,
`porsche-service`, `enrico-service`. otel-fleet native check passed on 2026-10-11 with
recorder-group exporters and 64 dashboard panels after its stale panel-index
assertions (failing on the unmodified base) were replaced by title selection.

Both hosts reported healthy on `c1b6d76f` (Push 1a); this was the first update
evaluated by the stricter updater.

### Push 1b (Marshall and services dead code)

Provisioner 426 catch-all (now the fleet listener's 404), retired `/api` prefixes
generalised, retired-route tests, never-emitted Marshall/Brady events, stale
terminal-v1 snapshots, Audi DNS entries without deadlines (snapshots refused
whole), atom-keyed inventory, FleetChart and echarts, modal compatibility
show/hide and dead terminal session actions. Gates: prek; precommit in marshall,
audi and brady; Nix `hldd`. Audi `private_guard_test` failed once under load with
a `noproc`/`killed` exit race in unchanged code and passed five consecutive reruns.

### Export E1 (before Push 4)

Full `pg_dump -Fc` of the Marshall database, encrypted to the recovery recipient
and operator key: 137,578,930 bytes, sha256
`431250f4809914dfc690058ae485b681f33574aec7b53e936abb19af9c225d92`; decrypting and
listing it shows 150 table-data entries.
### Push 3 (one-sided strictness)

Inception offers require exactly the 15 keys Marshall sends; roster and guest
host-certificate requests accept only six-field bindings (Marshall and Ziggy, with
refusal tests); the `unsupported` creation status, Lilly's guest error-5 mapping
and `guest_upgrade_required` are removed; Lyra no longer deletes legacy
`kittens-<username>` sudoers files; Marshall no longer parses
`MARSHALL_INCEPTION_PARENT` and the Inception guest no longer sets it. Gates:
protocol precommit; every precommit step in marshall, lilly, ziggy, audi, brady,
porsche and galileo; Nix `inception-runtime`. Enrico (`Enrico.GitTest` and six
`ManagerHistoryPropertyTest` properties) and Nix `lyra`
(`workspace_object_format.rs`) fail identically on the unmodified base; the
`kittens-ssh-authorize` tests pass. Startup-refusal property evidence (now 34
cases) is present but not yet recorded at this revision.
Native `ssh-roster-matrix-fleet` passed with six-field bindings only. Native
`terminal-fleet` failed at the browser "terminal boot log" stage; the unmodified
deployed base (`f6085b76`) fails at the same stage, so this predates Push 3.

### Push 4 (expand: Lilly tolerant, Marshall stops using retired objects)

Lilly accepts session pools with or without `logical_budget_bytes` and compares
pools by id, filesystem and storage only (owner.json unchanged); it starts the
terminal stream without the `terminal_stream` flag; OwnerCache, the owner refresh
and the `egress_owners` client are deleted, `owner_id` is required and immutable,
and clone transfers validate placement shape without an owner. Marshall deletes
the Fleet domain, the issuance archive resource (catalog sends a null
`certificate_id`; the decoder accepts 5 keys or a null sixth), LifecycleCursor,
provisioner lifecycle fields, host console and `protocol_version` attributes, the
job-history backfill, the port-4444 branch and retired agent tools, and requires
`machine_id`. Expand migrations drop the three orphan diagnostic tables, purge the
8260 provisioner lifecycle events (none carried a measurement outcome), drop the
`protocol_version` CHECKs and the machine-name trigger, cancel queued backfill
jobs, purge port-4444 endpoints and add CHECK `primary_port <> 4444`. A scratch
rehearsal applied them to the base schema; the base tree's full Marshall suite
then failed only the five tests asserting the removed objects.
Both hosts reported healthy on `f603be11` (Push 3).

Push 4 gates: prek; precommit in protocol, lilly, marshall (1446 passed), audi,
brady, galileo, porsche, ziggy and elixir/diagnostics; Nix `hldd`,
`module-configuration` and both host evaluations; native `relocation-fleet` and
`brady-fleet`. Enrico fails the same seven tests as the unmodified base.
`brady-fleet` first failed because its attribution check read catalogued fields
at the top level of the shared diagnostics format (also broken on main); after
reading the `metadata` object it passed, confirming resolved attribution with the
command-carried owner.

### Push 5 (contract: Marshall stops sending; first drops)

Marshall no longer sends `logical_budget_bytes`, `terminal_stream` or the catalog
`certificate_id`; the pool budget attribute is gone (column nullable, CHECK without
budget clauses); enrollment validates and discards a supplied budget; the
`egress_owners` route and `KittensProtocol.EgressOwners` are deleted. Migrations
drop `compute_lifecycle_cursors`, the host `console_*`/`protocol_version` columns,
the session `protocol_version` and lifecycle-event `pool_id` columns, set
`machine_id` NOT NULL, cancel queued backfill jobs again and recreate the job
capture function without its backfill parameter. The Fleet and issuance archive
tables are deferred to Push 6: the Push 4 release still sweeps their version
tables for retention while the Push 5 migration runs, so dropping them now would
break that job until both hosts converge. A scratch rehearsal applied the
migrations to the Push 4 schema; the Push 4 suite then failed only the two
storage-pool tests asserting the relaxed budget constraint.

### Window M1: Lilly host purge (2026-10-11 22:03–22:05 UTC)

Ran after `converged(e3ee8722)`. Order: dungarees, then overalls. On each host:
- Stopped the updater timer, `lilly.service`, `lilly-transfer-sshd` and `lilly-transfer-export.socket`.
- Planned the purge read-only, refusing to run if any live VM, untombstoned actor or current standby carried legacy state.
- Exported the plan with `tar` piped to `age` (recovery recipient plus operator key), and confirmed that every planned path is in the archive.
- Re-verified that the plan had not drifted, then deleted.
- Restarted the units, including `audi-private`.

Purged per host:
- tombstoned `vms/<id>` directories and their actor directories that held v1 envelopes;
- the `.lilly-zfs/{deleted,imports}` entries;
- retired transfer exports;
- the retired standby diagnostics;
- template `*.lifecycle-v1{,.imported}` archives;
- the stale `kittens-logging/journal.db` and `journal-1.db`;
- on dungarees only, the `lilly-rebind*.json` receipts.

| Host | Entries | Archive bytes | SHA-256 of `lilly-legacy.tar.age` |
|---|---|---|---|
| dungarees | 464 | 3,585,174 | `7bd3deec33155f6caccc9cf7e4802443f9fba5fde7b4f417b42e460916533ec6` |
| overalls | 1,113 | 8,604,006 | `5a7c5efb7985b9c0f63597bd3f71a561d880978d32ca006ea893e105a79bb106` |

Afterwards on both hosts:
- The inventory shows no non-v2 envelopes, archives or markers.
- `lilly.ownership_acquired` was logged.
- Marshall host reports are under 2 s old.
- The updater timers are active.

`pool.snapshot_withheld stage=usage_moving` continued at its rate from before the window, so it is not attributable to the purge.

### Push 6 (Lilly and shared-diagnostics state-format contraction)

Host legacy state was purged before this push, so Lilly reads only current
formats. Removed:

- ADR-0151 `Lilly.Control.ProfileRename` (`antithesis` to `standard`), its
  runtime startup call (the runtime now reads `Store.all/1` directly and still
  refuses an unreadable store with `:invalid_state_store`), the
  `lilly.profile_renamed` event and its tests. The applied Marshall migration
  and its test are unchanged.
- ADR-0155 `Lilly.Control.TransferJournalMigration`, `ImportJournal.legacy/1`
  and `rebase_legacy/2`, `SnapshotJournal.drop_legacy_slot/1` and its
  `.lifecycle-legacy` archive, `Lilly.Lifecycle.Journal.rebase_legacy/5`, the
  `lilly.transfer_journals_migrated` event and their tests. Journals in the
  pre-copy shape (`baseline_guid`, `lilly-a` slot) fail closed.
- ADR-0088 version-3 VM journal import in `Lilly.VM.Journal`; an unenveloped
  journal now fails closed without rewriting.
- ADR-0149 v1 lifecycle envelope acceptance and lazy v1-to-v2 migration with
  `.lifecycle-v1` archives; `Lilly.Lifecycle.Journal` accepts only v2 metadata.
- The `.lifecycle-v1` archive importer (`Lilly.Lifecycle.Diagnostics`, its
  supervisor child, `.imported` markers and bounded traversal),
  `Lilly.Lifecycle.LegacyEvent`, the standby terminal-archive custody branch
  (`retain_terminal/2` and `.lilly-standbys/diagnostics`; terminal records are
  now always removed from the private catalog) and
  `Observability.persist_transition/1`.
- Shared diagnostics `Kittens.Diagnostics.Custody.persist/3` and the processor
  and sampler `:persist` branches; only bounded `enqueue/3` remains. No other
  consumer (Marshall, Audi, Brady, Enrico, Galileo, Porsche, Ziggy) called it.
  The library contract now ties the durable-custody meaning to a successful
  spool export.
- The `relocation-fleet` subtest that rewrote a destination import journal into
  the pre-ADR-0155 shape and checked its startup migration.

Tests that only exercised removed paths were deleted; the v1/version-3 seeding
tests became fail-closed refusal tests, and the writer-before-spool test from the
deleted importer suite moved to `publication_diagnostics_test.exs`. About 2,350
net lines were removed across Lilly, the shared library and the relocation
scenario (1,036 net in production code).

Push 6 gates: Lilly precommit (530 checks: 102 properties, 428 tests; forced
Dialyzer zero errors); `elixir/diagnostics` precommit (24 tests, forced
Dialyzer zero errors, trace schema regenerated); every Marshall precommit step except
the shared HLDD receipt check (1467 checks: 237 properties, 1230 tests; forced
Dialyzer zero errors); `check_adrs`, HLDD coverage,
options and views checks. The reduced `relocation-fleet` scenario has not been
rerun natively.

Push 6 also makes the protocol ingress-catalog decoder require exactly five entry
keys (M5 step 3; a `certificate_id` key of any value now rejects the reply), and
drops `ingress_issuances*`, `fleet_credentials*` and `fleet_hosts` (C1 deferred
from Push 5) in `20261011190000_drop_fleet_and_issuance_archives`, without CASCADE.
The Nix side removes the receiver's v1/v2 checkpoint upgrade (N4: other versions
are refused unchanged, `slo_recorder.refused reason=version`) and replaces the
cursor migration with the read-only `check_cursors.py` shard preflight (N1).

Push 6 native checks:
- Passed: `relocation-fleet` (the reduced scenario), `image-template`, `lilly-observability-recovery`, `trace-spool-native`, `audi-service`, `logging` and `otel-request-recorder`.
- Failed identically on the parent `e3ee8722`, so they predate this push:
  - `zfs-transfer`: the adoption fault-latch subtest times out.
  - `lilly-native-actor-recovery`: the fixture asserts that the guest image's minimum disk is under 4 GiB.
  - `guest-backups`: the test driver fails `ty` with 8 diagnostics.

### Push 7: relocation history purge (D1, D2)

- **Export:** `20261011T220514Z-marshall-pre-push7/marshall-full.dump.age`, 43,067,538 bytes, SHA-256 `5fde1bb64110967b9148deb08b145de79717354a0e92e9e6ea0c592f1ea8fb9a`. Taken after Push 5 converged; the relocation rows have not changed since.
- **Rehearsal:** I restored that export into the scratch Postgres. Of the 22 relocations, 18 violate `relocation_stop_requires_probe`; they cover 12 VMs, all archived. A row-level walk of the foreign-key graph found this dependent closure:
  - 54 operations and 79 physical outcomes;
  - 36 transfer slots and 36 source permits;
  - 18 readiness requests and 18 cleanup requests;
  - 13 SSH requests, 9 service-level attempts and 2 workflow attempts.
- **What the migration does:** one statement of data-modifying CTEs deletes exactly that closure. Both `VALIDATE CONSTRAINT` statements then succeed, after which no constraint is `NOT VALID`.
- **Guard:** `20261011200000_purge_pre_copy_relocations` raises unless 0 or exactly 18 violating rows exist, and raises if any of them belongs to a live VM. It also validates Oban's `non_negative_priority` (0 negative rows).

### Push 8 (switches)

Lilly's provisioning rollout switches are removed with their off paths (items
L11, L12 and the Lilly part of N12). The Nix module and the Lilly runtime
configuration change in the same host closure, so this is a single push.

- **Readiness:** `services.lilly.provisioningReadiness` and the execution
  `provisioning_readiness` key are gone. The provisioning journal is always
  written; the legacy `after_trust` clauses (inception and resize/clone
  `Driver.ready` without a journal), the fixed 120 s trust timeout and the
  missing-boot-state exception in `preserve_running_boot` are deleted. A running
  boot without a durable boot identity is now refused. `awaiting_trust` still
  begins a journal for a running boot whose logical generation advanced.
- **Block copies:** `services.lilly.blockCloneCopies` and `block_clone_copies`
  are gone. Every same-host, same-pool clone block-copies; the import-history
  check that kept a pre-switch receive going is removed. Same-host clones across
  pools keep the local stream receive.
- **Templates:** `services.lilly.imageTemplates.enable` is gone.
  `imageTemplates.budgetBytes` is a positive size (1 B..1 TiB, default 32 GiB);
  the budget-0 clauses in `ImageTemplate` and the `> 0` pool filters in prewarm,
  sweep and standby refill are deleted. Oversized images still take the verified
  uncached path.
- **Standbys:** `standbyDisks.perImage` is 1..128 (default 1); `refill/3`
  guards the positive range. Retiring every standby of an image now happens only
  when the image is deconfigured.
- **Hosts and fixtures:** both host declarations keep a 32 GiB budget and 128
  standbys. Fleet fixtures run templates with `perImage = 1` and keep their
  16 GiB ZFS fixtures (32 GiB for clone variants). Measured on the NixOS fleet
  image, the template and standby take about 1.4 GB of pool space before any
  guest. The capacity race needs fresh headroom for two 4 GiB startup
  reservations but not three; an unmeasured 8 GiB increase broke that. The zfs-guest family now runs with readiness and
  templates on. `zfs-guest-clone` runs only in block-copy mode and discards a
  copied clone on every run. `image-template` replaces its two
  `STANDBY_PER_IMAGE=0` refills with a deconfigured-image refill.
- **Benchmark:** `scripts/provisioning_benchmark.py` no longer reads the removed
  readiness key. Its baseline mode can now only measure a historical
  templates-off deployment.

Gates: Lilly `mix precommit` passed (560 checks, 108 properties; Dialyzer 0
errors). Marshall passed every precommit step except `hldd.check` (see below):
1467 checks (237 properties), 4 excluded, and Dialyzer reported 0 errors. prek
passed every hook except `hldd-review`. Nix `module-configuration`,
`storage-configuration`, `enrollment-configuration`, `python-static` and
`conflict-markers` passed; `hldd` failed only on stale receipts. Both host
`toplevel.drvPath` evaluations succeeded, and so did the native test
derivations for `zfs-guest`, `zfs-guest-clone`, `image-template`,
`lilly-native-actor-recovery`, `cloning-fleet`, `fleet-guest-trust` and
`user-ssh-journey-fleet`. `check_adrs`, `hldd_coverage --check`,
`hldd_options --check` and `hldd_views --check` passed. HLDD review receipts were
not refreshed and remain stale for the owner's review. Native VM checks were not
run: `zfs-guest`, `ubuntu-guest`, `zfs-guest-clone`, `image-template`,
`lilly-native-actor-recovery`, `guest-backups`, `zfs-namespace-cleanup`,
`guest-boot-profile`, `inception`, `zfs-transfer`, `cloning-fleet`,
`user-ssh-journey-fleet`, `fleet-guest-trust` and the clone fault fleets
(`clone-cancellation`, `clone-destination-loss`, `clone-marshall-restart`) are
outstanding.

**Native follow-up (2026-10-12).** Serial native runs on this tree, compared
with detached base `d98ba27a`:
- **Fixture size:** the unmeasured 8 GiB growth broke the `fleet` capacity race,
  which needs fresh headroom for two 4 GiB startup reservations but not three.
  Measured at 16 GiB, base reports 13.47 GB free before the first guest and this
  tree 12.10 GB, so the template and standby cost about 1.4 GB. Fixtures return
  to 16 GiB (32 GiB for clone variants).
- **Startup-bound oracle:** `fleet-startup-bound-from-raw-rows` counted a
  pending disk's own materialized bytes twice: once in reduced free bytes and
  again in its full startup charge. Cheap template materialization made it
  fail. It now nets each hold's reported allocation, as admission does
  (`physical-disk-pending-growth`).
- **Adopted block copy discard:** with block copies unconditional,
  `clone-cancellation` reached a discard of a copy that Lilly had adopted but
  Marshall never published. The copy journal refused to retire it and retried
  `clone_copy_state_unconfirmed` forever. ADR-0145 now records the correction
  that allows `adopted` to `retiring`, matching an adopted import.
- **Pre-existing on base:** `fleet-guest-trust`'s probe still called
  `Driver.verify_boot/4`, removed in `9193176a`; it now uses `boot_proof/4`. The
  clone permutation fleets had never run natively. Their cross-host
  precondition rested on CPU noise, because a two-vCPU copy fits beside its
  source's restart hold. They now use three-vCPU sources, and the fixture
  operator accepts that shape. `clone-destination-loss` also expected abandoned
  copy/adopt effects to be receipted, the permanent import tombstone to vanish,
  and a refused retry to raise something other than the driver's
  `AssertionError` subclass. Each of these oracles now matches the contract it
  checks.

Results: `fleet-guest-trust`, `clone-cancellation`, `clone-destination-loss`,
`clone-marshall-restart` and `cloning-fleet` pass. `fleet` passes every subtest through the credential
update and then fails the terminal browser at "terminal boot log", as an
earlier base `terminal-fleet` run did; the base `fleet` run failed earlier, at
profile egress. Base `clone-cancellation` does not build because its
report-instrument hash is stale.

### Push 8 (Ziggy/inference)

Ziggy's durable SLO rollout switch and Marshall's lost-legacy-ACK projection are
removed (items M18, M19 and the Ziggy part of N12). Preflight: both Ziggy spools
held only `.slo-checkpoint`, and all 5 of 5 `inference_requests` rows carried a
legacy-shaped completion; Export E1 contains them:
`20261012T055802Z-marshall-pre-push8/marshall-full.dump.age`, 43,668,573 bytes,
SHA-256 `0a970798be68c771ddf4c9fa24d0373f97b2f192594008ad3306c3b9daccbfba`
(`pg_restore --list` lists 141 table-data entries).

- **Ziggy:** `services.ziggy.durableSloCounters`, `ZIGGY_DURABLE_SLO`, the
  `durable_slo` spool option and its reader-only path (contract
  `ziggy-checkpoint-reader-first`) are gone. The spool always loads, fsyncs and
  maintains the checkpoint; an ACK requires the completion to be counted. The
  host declarations and the `ziggy-service` fixture drop the switch, and the
  `ziggy-configuration` evaluation asserts it is absent. That evaluation also no
  longer sets the fleet-exporter `controlPlane`/`credentialFile` options removed
  in `4d3c651d`, which had broken it on main.
- **Inference:** `KittensProtocol.Inference.accounting_projection/1` (contract
  `inference-accounting-projection`) is deleted. Ziggy keeps its local-to-wire
  field selection as `Ziggy.Completion.wire/1`. Marshall acknowledges a replay
  only when it equals the stored completion exactly.
  `20261011210000_purge_legacy_inference_completions` aborts unless 0 or exactly
  5 rows are legacy-shaped. It then deletes their PaperTrail versions (no foreign
  key references `inference_requests`) and the rows, and adds CHECK
  `inference_completion_exact_shape`: a stored completion must be NULL or an
  object with `outcome`, `tokens` and `completeness`, plus an optional
  `cost_estimate`. The serving release already validates that exact key set
  before writing, so it stays compatible while the migration runs. Daily totals
  are kept. A Ziggy receipt for a purged request would be refused, but both
  spools are empty.
- **Rehearsal:** the migration's SQL, run against a minimal scratch table,
  purged 5 legacy rows and their versions while keeping NULL and exact rows,
  was a no-op with 0, aborted with 3, and added the CHECK in the first two cases.

Gates: Ziggy `mix precommit` passed (68: 16 properties, 52 tests; Dialyzer 0
errors). Protocol `mix precommit` passed (252: 96 properties, 156 tests; Dialyzer
0 errors). Marshall: every precommit step except `hldd.check` (stale receipts),
plus `ash.codegen --check`: tests 1467 passed (237 properties, 1230 tests), and
`dialyzer --force-check` found 0 errors.
prek passed every hook except `hldd-review`. Nix `module-configuration` and
`ziggy-configuration` passed, and both host `toplevel.drvPath` evaluations
succeeded. `check_adrs`, `hldd_coverage --check`, `hldd_options --check` and
`hldd_views --check` passed. HLDD receipts were not refreshed. Native checks not
yet run: `ziggy-service`, `ziggy-underclass`, `agent-fleet`, `agent-cli-journey`,
`otel-guest-native`, `audi-service`, `galileo-service` and `inception`, which
start Ziggy with checkpoint creation now always on.

### Push 9: unified Underclass histogram (N5)

The owner chose to unify the Underclass histograms rather than keep ADR-0138's
separate versioned one. This push replaces only that clause (ADR-0138 carries a
carry-forward note; ADR-0159 lists the evidence).

- **Underclass journal:** `nix/domains/artifacts/underclass/slo.rs` keeps one totals record
  whose single histogram has the fifteen bounds through 86,400 seconds (16 buckets).
  It persists in a new file, `slo-totals.sqlite`, with only `slo_totals` and
  `slo_pending`. The `slo_latency_v2` table, the startup migration, the
  `latency_v2` snapshot key and the old seven-bound totals are gone. No code reads
  or deletes the retired `slo.sqlite`; it stays on disk until window M2. Source
  lifetime and incarnation restart with the new journal, so the Underclass
  candidate is withheld for its usual five-minute warmup after deploy.
- **Receiver:** `DurationSample` carries per-service bounds as vectors;
  `service_bounds` fixes exactly one bound set per configured source (lifecycle,
  browser, Underclass or default). The bucket count must be bounds + 1, and it
  cannot change within one incarnation. The `Latency` type, the `latency_v2` field
  and validation, and the four `kittens.outer.underclass_proxy.latency_v2.*`
  metrics are deleted.
- **Rules:** `rules.nix` and `diagnostics.nix` read
  `kittens_outer_underclass_proxy_duration_seconds` and `_requests_total` like
  every other source. The `latency_v2_start_time` and `latency_v2_sample_time`
  gates are removed. The ordinary source-start, sample-clock and coverage gates
  already withhold the window after the journal restart.
- **Tests:**
  - The underclass-slo native subtest that dropped the v2 table became a
    single-journal check: the table set, no `slo.sqlite`, no `latency` keys, 15
    bounds and 16 buckets, and the 12-second response in bucket 7.
  - `telemetry-diagnostics` uses the source clock and adds an overflow case
    (status 9).
  - `otel-slo-rules` adds seven Underclass p95 cases (`underclass-unified-p95-rule`):
    - visible 29 s and 83,160 s results;
    - withheld for overflow, partial samples, a missing 86400 bucket, warmup and a
      missing replica.
  - A mutation of the overflow and partial cases to expect 29 failed as intended.

Push 9 gates:

- **Underclass Rust tests:** the Underclass package has `doCheck = false`, so Nix
  never runs these tests. Run them by hand on the patched source:
  1. Copy the pinned `fetchFromGitHub` source.
  2. Apply `instrumentation.patch`.
  3. Copy in `slo.rs`.
  4. Run `cargo test --lib slo::` (rustc 1.97.1).

  For this push, `cargo test slo::` on the patched Underclass source passed 11 tests
  (0 failed, 67 filtered out), with no compiler warnings and `rustfmt --check`
  clean.
- **Receiver:** the receiver package build ran its Rust suite: 44 passed, 3 ignored,
  plus 3 integration tests. This includes `underclass_exports_one_fifteen_bound_histogram`.
- **Rule checks:** `otel-slo-rules` passed with seven Underclass p95 cases.
  `telemetry-diagnostics` also passed (257 rules).
- **underclass-slo native check:** the first native run failed in the new subtest.
  It waited for the cumulative `le="30"` bucket to equal 1, but the unified
  histogram counts all four measured requests, so that bucket reads 4. The fixed
  driver waits for `le="30"` = 4 and then checks `le="10"` = 3. With that fix, the
  underclass-slo native check passed (test script finished in 99.72s).
- **Other Push 9 native checks:** these were run one after another on the final
  tree. `underclass-service` passed (591.68s), `ziggy-underclass` passed (29.35s)
  and `otel-fleet` passed (455.07s).
- **Remaining gap:** production verification after deploy is still open. That
  means the candidate p95 reappearing after the five-minute warmup on both hosts,
  and window M2 deleting `slo.sqlite`.
- **Production (2026-10-12).** `c2ab7ad8` converged on both hosts at 07:12 UTC.
  Each host's Underclass writes a fresh `slo-totals.sqlite`; the retired
  `slo.sqlite` was last written at 06:28, before activation. Prometheus shows the
  Underclass duration histogram with exactly 16 `le` values (8 before) and no
  `latency_v2` series, and the p95 recording rule is healthy. The p95 has no value
  because Underclass served no requests since activation (nor in the same hour the
  previous day), so its return awaits real traffic. Window M2 may delete
  `slo.sqlite`, `slo.sqlite-shm`, `slo.sqlite-wal` and `slo.lock` under
  `/var/lib/private/underclass` after 2026-10-13 07:12 UTC.

### Push 10: contract `logical_budget_bytes` (M31) and Window M3

Depends on Push 5 having converged: Marshall no longer sends the budget and
enrollment accepts pools without it.

**Changes**
- **Lilly is strict.** `Lilly.Host.Pool` has no budget field and `new/4` refuses
  any unbound option. `session_identity/1` is exactly `id`, `filesystem_id` and
  `storage`. The control client accepts only four-key session pools (`id`, `name`,
  `filesystem_id`, `storage`). Runtime configuration pools may carry only the bound
  keys, so a budget fails startup. The transfer endpoint configuration requires
  exactly four pool keys, and backup no longer passes a budget. The Push 4
  tolerant branches and the `session-pool-budget-tolerant` contract are gone.
- **Ownership fails closed.** Lilly compares `/var/lib/lilly/owner.json` to its
  expected binding by exact decoded equality. An owner record that still carries
  a budget therefore refuses startup with `host_identity_mismatch`; it is neither
  ignored nor rewritten. Per-pool `.lilly-zfs/owner.json` never carried a budget
  and is unchanged.
- **Nix and fleet.** `services.lilly.pools.*.logical_budget_bytes` is removed, so
  it also leaves the updater's Lilly `binding.pools`, the `owner.pools` descriptor,
  `/etc/lilly-transfer.json` and the backup configuration. Host profiles require
  exactly the `guestCpuCores`, `guestMemoryMiB` and `arcMaxMiB` budgets, and
  binding pools with exactly `id`, `name`, `filesystem_id` and `storage`. Both
  `host.json` files drop `budgets.logicalBytes` and the binding pool budget.
- **Host tool.** Enrollment requests carry no budget, and the stored binding pool
  is Marshall's four-key descriptor. The storage-headroom upper bound was
  `budgets.logicalBytes - 1`. It only kept Marshall's `overhead < budget` check
  satisfiable and never related headroom to real capacity. Marshall subtracts
  headroom from observed free bytes (`max(0, F - H - P - T)`). Headroom at or
  above the physical guest capacity would therefore enroll a pool that can never
  admit a disk. The new bound is strictly below the reviewed physical guest
  capacity: the Hetzner guest dataset quota, or the summed raw size of the
  declared EC2 local NVMe guest disks. The contract is
  `enrollment-storage-headroom-below-capacity`.
- **Fixtures, documents and HLDD.** Lilly tests, evaluation checks, machine-test
  drivers and probes, and the smoke scripts are updated. The storage, enrollment,
  transport, NixOS and host-provisioning guides are updated, and the HLDD storage
  and guest chapters and the generated option reference are updated.
- **Out of scope.** Marshall still validates and discards a supplied budget in
  enrollment, and the nullable column remains. Push 11 removes both.

**`owner.json` shape change** (`/var/lib/lilly/owner.json`, root-owned, mode 0600,
single link)

The record must be published atomically. Only `pools[].logical_budget_bytes` is
removed:

```json
{"version": 1, "machine_id": "sha256:…", "host_id": "…",
 "state_dir": "…", "vm_state_dir": "…", "network_state_dir": "…",
 "pools": [{"id": "…", "path": "/var/lib/lilly/pool", "filesystem_id": "zfs:…:…",
            "storage": {"backend": "zfs", "zpool_guid": "…", "dataset_guid": "…", "dataset": "zroot/lilly"}}]}
```

Pools stay sorted by `id`. Key order inside objects is irrelevant because Lilly
and the updater compare decoded values.

**Cutover (Window M3, per host: dungarees, then overalls)**
1. The updater refuses the push with `lilly_binding_change` at preflight. Stop the updater timer.
2. Diff the live and candidate manifests. Only the Lilly `binding.pools[].logical_budget_bytes` and `owner.pools[].logical_budget_bytes` may differ.
3. Back up `owner.json`.
4. Stop Lilly.
5. Atomically rewrite `owner.json` without budgets, keeping it root-owned, mode 0600 and single-link.
6. Point the system profile at `$B/system` (`nix-env -p /nix/var/nix/profiles/system --set`) and run its `switch-to-configuration switch`, where `$B` is the updater's already-built `/var/lib/kittens-auto-update/candidate`.
7. Start Lilly. Confirm `lilly.ownership_acquired` and that the Marshall host is ready.
8. Restart the updater timer. The identical-closure verify path should then mark the host healthy.

**Rollback:** restore `owner.json`, switch back to the previous system, then revert.

**Push 10 gates**
- **Precommit.** Lilly passed: 531 checks (102 properties, 429 tests) and forced Dialyzer with zero errors. Every Marshall precommit step except the shared HLDD receipt check passed: 1467 checks (237 properties, 1230 tests) and forced Dialyzer with zero errors.
- **Repository checks.** `prek` passes every hook except the HLDD review receipts. `check_adrs`, the HLDD views check and the HLDD options check pass. The trace schema was regenerated.
- **Nix checks passed:** `module-configuration`, `storage-configuration`, `enrollment-configuration`, `enrollment-preparation`, `host-planning`, `python-static`, `audi-configuration` and `fleet-guest-trust-configuration`. Both host `toplevel.drvPath` evaluations also succeed.
- **Pre-existing failures.** `brady-configuration` fails identically on the unmodified base `d98ba27a`, with `services.kittensFleetExporter.controlPlane` not existing (Push 8 repaired `ziggy-configuration`).
- **After merging Push 8.** Lilly and Marshall precommit, `prek`, the HLDD check, the configuration, enrollment, host-planning and `python-static` checks and both host evaluations passed again; the trace schema was unchanged.
- **Native checks (serial).** Passed: `auto-update-compatibility`, `auto-update`, `native-zfs`, `image-template`, `export-endpoint`, `backup-recovery`, `fleet-guest-trust`, `galileo-service`, `ziggy-service`, `clone-cancellation`, `cloning-fleet` and `maintenance-evacuation`. `native-zfs` first failed on a fixture that `e6195a0d` left stale: the updater now requires the `enrollment.json` receipt to carry `revision`, and `native_resources.py` wrote only `storage`. The fixture now writes and re-asserts the revision.
- **Native failures that are identical on base `0b23aa9e`:** `enrollment-operator` (`galileo.secretsFile` has no value at evaluation), `host-enrollment` (the harness cannot open its SSH connection), `zfs-io` (22 type-check diagnostics in its driver), `zfs-lifecycle` and `source-export` (probe match errors), `zfs-transfer`, `guest-backups`, `executor-loss` (owner-withdrawal retry assertion), `host-replacement` (live Ziggy identity) and `account-lifecycle` (browser invitation).
- **`team-resources`** first timed out twice waiting for a guest's known-hosts route (404). Cause: the route needs the fleet wildcard certificate to be active and installed, and the certificate advances on one-minute AshOban ticks, so whether it finished within the per-guest 30-second readiness wait depended on the minute boundary after Marshall started (base passed with about 15 s to spare; roughly half of all runs would fail). The driver now waits for the active certificate and its installation on every provisioner after Audi enrollment, as the other fleet scenarios do. It then passes the provisioning subtest and fails at the pre-existing base assertion "SSH refusal lacked a fresh closed forbidden control response".

### Push 11: drop the pool budget column (H2) and strict enrollment

Depends on Push 10 having converged on both hosts: no producer (Lilly, Nix, the
host tool) sends `logical_budget_bytes`, and the serving Marshall neither maps nor
writes the column (Push 5).

**Changes**
- **H2 migration.** [`20261012090000_drop_storage_pool_logical_budget`](../../../marshall/priv/repo/migrations/20261012090000_drop_storage_pool_logical_budget.exs)
  runs `SET LOCAL lock_timeout = '5s'` and
  `ALTER TABLE compute_storage_pools DROP COLUMN logical_budget_bytes`, without
  `CASCADE` or `IF EXISTS`; `down` raises. On a database migrated to
  `20261011210000`, PostgreSQL records no dependent object on the column: Push 5's
  `storage_backend_identity` CHECK already omits it, no index references it, no
  function body names it and `compute_storage_pools` has no PaperTrail version
  table. The latest resource snapshot (`20261011185240`, Push 5) already lacks
  the attribute, so no snapshot changes and `mix ash.codegen --check` passes.
  Historical migrations and snapshots are unchanged.
- **Strict enrollment.** The [request parser](../../../marshall/lib/marshall/compute/enrollment_request.ex)
  accepts only the three-key pool (`name`, `storage`, `overhead_bytes`). A pool
  carrying `logical_budget_bytes`, whatever its value, or any other unknown key
  returns `invalid_enrollment_request`, as unknown top-level keys already did.
  The discard branch is removed and the `zfs-enrollment-logical-budget` contract
  is replaced by `zfs-enrollment-pool-shape`. Refusal tests: the parser property,
  a file-enrollment test asserting no host or credential file is created, and a
  ZFS pool test asserting the column is absent (`undefined_column`).
- **Fixtures.** Enrollment requests in the enrollment, enrollment-history,
  distributed enrollment and distributed admission suites and the budget suite's
  pool maps drop the budget. The guest-identity migration test keeps it: it
  inserts a pool at migration `20261010013000`, where the column is still
  required.
- **Unfreeze.** The host enrollment and credential rotation freeze imposed from
  Push 5 is lifted with this push.

**Export.** There is no new production data shape to preserve beyond the column
itself. Export: `20261012T110631Z-marshall-pre-push11/marshall-full.dump.age`,
44,154,498 bytes, SHA-256
`d32900fa088a4c56c03063fb1661536f8f4df504f33fca2a3fe1828f8b6f2145`
(`pg_restore --list` lists 141 table-data entries). At export both production
pools carried `logical_budget_bytes = 1503238553600`; no pool had a NULL budget.

**Compatibility.** The Push 10 tree's enrollment, ZFS pool, budget, host report,
distributed enrollment and enrollment history suites pass against a schema that
includes this migration (51 checks, 9 properties).

**Push 11 gates**
- **Marshall.** Every precommit step except the shared HLDD receipt check passed:
  1469 checks (237 properties, 1232 tests), four excluded, seed 640186, and forced
  Dialyzer with zero errors. `mix ash.codegen --check` passes. The migration
  applies to a database migrated to `20261011210000`, and a fresh
  drop/create/migrate succeeds.
- **Repository checks.** `prek` passes every hook except the HLDD review
  receipts. `check_adrs`, the HLDD views, options and coverage checks pass; the
  trace schema is unchanged.
- **Nix checks passed:** `enrollment-configuration` and `python-static`. The Nix
  `hldd` check fails only on the review receipts. Both host `toplevel.drvPath`
  evaluations succeed.
- **Native checks** (`enrollment-operator`, `enrollment-preparation`,
  `host-enrollment`, `native-zfs`, `auto-update-compatibility`) are not yet run.

### Push 12: prune applied one-shot migrations (M13)

**Precondition.** Overalls `schema_migrations` held exactly the 174 versions present
at `033c8eef`; every file was applied and none was missing.

**Deleted** (applied one-shot data, or a net-zero pair):
- `20261009120000_retire_monitor_credentials` (credential revocation and job cancellation; the tables are dropped);
- `20261010013000_rename_antithesis_profile` (data rename; its drop and re-add of `valid_address_profile` reproduces the inception-profile definition);
- `20260925172905_guest_identity_localpart` with the `email_localpart` removal in `20261010110000` (the column was added and removed);
- `20261011170100`, `170400`, `170500` and `180400` purge or cancel files (data only);
- `20261011170300_drop_machine_name_trigger`, with the trigger, function and backfill in `20260917092357_machine_names`.

**Renamed, DDL kept under the same version:**
- `20261011200000_validate_oban_priority` keeps only Oban's `non_negative_priority` validation;
- `20261011210000_inference_completion_exact_shape` keeps only the CHECK.

**Edited to remove data statements:** `20260915182941` (reservation memory rewrite, up and down), `20260916032917` (initiator backfill), `20260917131050` (provisioning sizes backfill), `20260917140201` (command snapshot backfill), `20261009000100` (host protocol reset), `20261010000100` (source conversion and image disable), `20261010110000` (username canonicalization, retirement, editor lease close and the index drop/recreate that only served them; the `u<uid>` CHECK stays) and `20261010120000` (descriptor rewrites). `relocation_stop_requires_probe` is now created valid instead of `NOT VALID` and then validated in Push 7.

**Contracts.** Deleted with their code: `retire-monitor-preserve-archives`, `deployed-profile-rename-scope`, `legacy-guest-source-backfill`, `durable-guest-identity-cutover`, `provisioner-cut-preserves-history`, `source-cutover-preserves-execution-identity`, `machine-name-trigger-retired`, the four purge contracts, `pre-copy-relocation-purge`, `legacy-inference-completion-purge`, and the test contracts of the four removed migration tests. `stopped-only-cut-keeps-history-readable` keeps only its DDL clauses. New: `no-unvalidated-constraints` and `inference-completion-exact-shape`.

**Tests and scenarios.** The four migration tests and `Marshall.MigrationScratchRepo` are deleted. The `retained-profile-migration-custody` scenario and the canonical-migration evidence of `durable-guest-identity` are removed and the coverage chapter regenerated.

**Schema equality.** Two fresh scratch databases were migrated, one with the `033c8eef` files (174 versions) and one with the pruned set (166 versions). `pg_dump -s --no-owner --no-privileges` output is byte-identical (7,604 lines each), and neither has a constraint with `convalidated = false`. Data-only dumps excluding `schema_migrations` differ only in the generated UUIDs and `now()` timestamps of the seven `compute_service_level_totals` seed rows; `account_admin_bootstrap` is identical.

**Upgrade path.** Ecto selects pending migrations as files whose version is not recorded, so production rows for deleted versions are ignored (`mix ecto.migrations` lists them as `** FILE NOT FOUND **`). Marshall health requires the highest file version to be recorded; after Push 11 that is `20261012090000`, recorded in production since Push 11 converged.

### Push 13: final sweep leftovers

A read-only sweep of `5c843eab` for removed identifiers and live legacy wording
found ten genuine leftovers; this push removes them.

- **Code.** `marshall/scripts/smoke_execution.exs` no longer reads the host
  `protocol_version` attribute removed in Push 5. Lilly's session decoder
  (`Lilly.Control.Client.open/2`) requires exactly the six keys Marshall sends,
  so a `terminal_stream` key is refused like any unknown key (the Push 4 expand
  tolerance is gone; tests assert refusal). A Ziggy comment now names
  `Ziggy.Completion.wire/1`, and a Lilly lock test no longer calls permission
  tightening "legacy".
- **Docs.** The architecture overview no longer describes the removed v1
  envelope migration or the ADR-0088 importer as current. HLDD 07 describes v4
  manifests only, HLDD 16 the current readiness-journal supersession,
  `docs/history/ledgers/provisioning-fastpath.md` marks its rollout-switch section historical, and
  `docs/history/ledgers/terminal-v2-completion.md` closes its stale probe row.
- **Known gap (pre-existing).** The `console` action of `smoke_execution.exs`
  still calls `Lilly.Console.Dtach` and `Lilly.VM.Unit.console/2`, removed with
  terminal v1 in `4e4ad9ea`, so that manual root/KVM harness cannot complete its
  in-guest checks. No automated check runs it; porting it to terminal v2 is new
  work outside this program.

### Window M2: retired Underclass journal

Run at the owner's direction on 2026-10-13 02:47 UTC, about 20 hours after
`c2ab7ad8` converged rather than the planned 24. The export keeps rollback
possible. On both hosts no process held `slo.sqlite`, `slo.sqlite-shm` or
`slo.sqlite-wal` open, and their last writes (2026-10-12 06:28) predate Push 9
activation. Each host's three files were streamed with `tar` into `age` (recovery
recipient and operator key) to
`~/kittens-legacy-exports/20261013T024744Z-underclass-m2/`, decrypted, extracted
and compared byte-for-byte with host-side SHA-256 digests, then deleted.

| Host | File | SHA-256 |
|---|---|---|
| dungarees | `slo.sqlite` | `da63a52bdf62b3fc863995d79f497584be3ba97c1de4c55d1d301afbafab6cfc` |
| dungarees | `slo.sqlite-shm` | `0ad28c2f1cdb3f364f047f51e245ea3684a793dc7ff670b97fef04c5c6be70dc` |
| dungarees | `slo.sqlite-wal` | `7c24216a1d36f648eb71e6db600b52c1c3f48a432c6927d7e12069bc291ae6c3` |
| overalls | `slo.sqlite` | `396e5322e4dfe661149778c93200431b0f600bebf33fc8b21688b6fce38e8a05` |
| overalls | `slo.sqlite-shm` | `1180fb9b4874ff72a8bf293efab3a19332086a06a84a01de7f53dbe43f5d594e` |
| overalls | `slo.sqlite-wal` | `278f57f7ab2ee111917a1c88b0093ce8240ea3569d967ef05a6be120a3ac862c` |

Archive digests: dungarees `5b0c73ff…9f0c53`, overalls `6f6b9529…ad92`.

**Correction to the plan.** `slo.lock` is not retired: the current journal still
takes its process lock on it ([accounting](../../../nix/domains/artifacts/underclass/slo.rs)).
Deleting it while Underclass holds the lock would let a second process lock a new
inode and recover the same journal, so it was kept. Underclass stayed active on
both hosts and served requests after the deletion.

### Push 14: collector socket custody on Overalls

Verifying the Underclass p95 found that Overalls had never exported Underclass
proxy metrics. Overalls' collector had accepted no points from any per-source
socket; only Brady, which uses the shared `kittens-otel-app` socket, reached
Prometheus. Dungarees was unaffected. The cause is outside this program: the
browser probes (`0c730c9e`, 2026-10-10, enabled only on Overalls) added two more
`ExecStartPost` commands to the collector. systemd re-applies `RuntimeDirectory`
ownership (the collector user and `kittens-otel-app`) whenever it spawns a unit
command. So the first custody command reset every socket directory the main post-start
step had just regrouped, and only the last browser socket kept its group.
Change times on Overalls show this order: post-start regrouping, then one bulk
reset at 14:03:37.081–.089, then `code-nixos` reset at .220 and `code-ubuntu`
regrouped at .313. Exporters retry silently, so every Overalls application SLO
other than Brady read unknown.

- **Fix.** [Browser probe custody](../../../nix/domains/system/otel-fleet/browser-probes.nix)
  now joins the collector's single `postStart`, ahead of the base block that ends
  in `exit 0`. A `collector-socket-custody` assertion in the
  [fleet module](../../../nix/domains/system/otel-fleet/default.nix) refuses any second
  `ExecStartPost`. The assertion fails when evaluating Overalls on `8aa4911e`
  and passes with the fix.
- **Durability.** Exporters read cumulative durable journals, so totals resume
  at the next export. Ratios over windows that include the outage stay incomplete.
- **Correction to the Push 9 production note.** The Underclass p95 was not only
  waiting for traffic. Its source-readiness clause requires exactly one
  `underclass_proxy` source on each host, so with Overalls' series missing the
  rule could never return a value. After `057aca28` converged (03:12 UTC), both
  Overalls collector sockets regained their groups and every per-source
  receiver accepted points. Prometheus shows both hosts' Underclass histograms
  with 16 `le` values and no `latency_v2` series, and Overalls carries 290
  application series (Brady's 16 before).
- **Underclass p95 verified.** With both replicas exporting, the first natural
  Underclass traffic after warmup produced
  `kittens:underclass_proxy_candidate_duration:p95_5m` = 9.75 s at 2026-10-13
  04:47 UTC. This closes the Push 9 production check.

### Closure

ADR-0159 is implemented. Fourteen pushes and windows M1–M3 converged on both
hosts. Every purge has a recorded encrypted export, and no retired table,
`NOT VALID` constraint, old-format host file or rollout switch remains. The
final sweep found no compatibility path outside the keep-list.

Known issues outside this decision:

- **Smoke harness console checks.** `smoke_execution.exs` still uses the
  terminal v1 console API that `4e4ad9ea` removed before this program. Porting its
  in-guest checks to terminal v2 is new verification work.
- **Base-identical native failures.** The native checks listed under earlier
  pushes fail identically on their base revisions and remain separate work.
