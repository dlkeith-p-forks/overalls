---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# Native database-recovery inventory — 2026-10-13

Source root: `/home/ghuntley/src/kittens-antithesis-reset` at HEAD `9fe1e493b2090d44bacd16089049cd12b316d58a`, with an existing reset working diff. Paths below are relative to that root. This is a read-only inventory of the six exported database client-loss checks. No repository edits, builds, native reruns, production credential reads or retired `antithesis/` harness reads were performed. Historical execution claims are attributed to committed documentation and retain their original captured scope; this inventory adds no runtime acceptance.

Architecture assessment before and after review: no architecture impact from the inventory itself. The substantive obligations are ADR-0126 (client-loss recovery), inherited ADR-0030/0033 machine and deployment verification, ADR-0029 database durability/quarantine, ADR-0048's qualified nonredundant deployment, and ADR-0070 host-recovery boundaries. An accepted/implemented ADR is separate from execution evidence. No repository/HLDD change is made by this out-of-repository report.

## Export and classification matrix

`flake.nix:24` selects `x86_64-linux`; `flake.nix:113–124` exports the `nix/tests` result as checks using stable `testPkgs` and source-built application `packages`. All six checks instantiate `pkgs.testers.runNixOSTest` at `nix/tests/machines/database-recovery/default.nix:24`; all are **native NixOS/QEMU machine execution checks**, neither evaluation-only nor package-only checks. Their use of `marshall eval` (`default.nix:17`) starts the real release Repo and dependencies inside a VM; it does not change that classification, nor does it establish whole serving-application recovery.

| Export under `checks.x86_64-linux` | Exact export | Holder/fault | Seed-126 waiter submission order | Recorded final native result |
| --- | --- | --- | --- | --- |
| `database-recovery` | `nix/tests/default.nix:54` | Idle in transaction / client VM crash | 1,3,2 | Passed, 71.92s test; 27.882s all-session reclamation |
| `database-recovery-active` | `nix/tests/default.nix:55` | Active / client VM crash | 2,3,1 | Passed, 62.08s test; 19.527s reclamation |
| `database-recovery-silent` | `nix/tests/default.nix:56` | Idle in transaction / bidirectional packet DROP | 2,1,3 | Passed, 73.38s test; 27.518s reclamation; outbound DROP 35 |
| `database-recovery-asymmetric` | `nix/tests/default.nix:57` | Idle in transaction / client-to-server packet DROP | 3,2,1 | Passed, 70.53s test; 27.747s reclamation; inbound DROP 25 |
| `database-recovery-active-silent` | `nix/tests/default.nix:58` | Active / bidirectional packet DROP | 1,2,3 | Passed, 62.63s test; 19.432s reclamation; outbound DROP 20 |
| `database-recovery-active-asymmetric` | `nix/tests/default.nix:59` | Active / client-to-server packet DROP | 3,1,2 | Passed, 62.70s test; 19.770s reclamation; inbound DROP 10 |

Submission orders are derived directly from `driver.py:81–88` using permutations and Python `random.Random(126)`. They are six fixed seeded submission schedules, not an established PostgreSQL queue order (`client.exs:82–85`, review `2026-10-02-database-loss-histories.md:16–18`). No Hegel/composed generated loss/reconnect property is attached to these exports. The final results all come from one recorded serial six-case capture, detailed below; they are not current-tree executions.

## Nodes, dependencies and budgets

| Item | Source and exact configuration |
| --- | --- |
| Nodes | `default.nix:27–40`: `db` and `m1`, each explicitly `virtualisation.memorySize = 1024` MiB; 2048 MiB total configured guest RAM. The fixture does not explicitly set vCPU counts, disk sizes or additional disks. Framework defaults were not evaluated in this inventory. |
| Overall timeout | `default.nix:26`: `globalTimeout = 300` seconds for every variant. |
| DB | `default.nix:31–35`: shared `fleet-database.nix`, `generationService = recovery-credentials`, `maxConnections = 32`, fixture network `192.168.1.0/24`. |
| DB implementation | `nix/tests/support/fleet-database.nix:22–40`: PostgreSQL 18, TCP enabled, Marshall DB/user, `hostssl` plus SCRAM, TLS certificate/key paths, maximum connections, SQL/error-statement logging suppressed. Port 5432 opened (`:42`); credential fixture service and initialization precede PostgreSQL (`:10–20`, `:43–49`). No fixture server timeout override is present in this support module. |
| Client | `default.nix:5–18`: actual `${packages.marshall}/bin/marshall eval`, production Repo startup environment, `PHX_SERVER=false`, no release distribution, instance `recovery-client`, one planned replica, connection budget 21 and pool size 10, verified DB TLS and fixture CA. Erlang scheduler setting is `+S 2:2` (`:14`), distinct from an explicitly configured VM CPU count. |
| Client processes | `client.exs:21–27`: diagnostics suppressed, `ash_postgres` started, then `Marshall.Repo` plus a Task.Supervisor. It does not start three Marshall serving nodes, a proxy, workers or a surviving release contender. |
| Runtime startup timeouts | Actual production source has `connect_timeout: 3000`, `handshake_timeout: 3000`, writable-primary targeting and sensitive connection errors disabled (`marshall/lib/marshall/operations/runtime_config.ex:154–157`). |
| KVM scope | ADR-0033 `:62–78` requires standard KVM/NixOS-test capability and separates independent physical-host/load acceptance. This fixture has no explicit nested-KVM feature and creates no Firecracker guest. No builder capability was checked or native execution attempted here. |

## Exact executable assertions and controls

Unless otherwise specified, paths in the following table are under `nix/tests/machines/database-recovery/`.

| Boundary | Exact source assertions/control |
| --- | --- |
| Finite modes/defaults | `default.nix:1–2`: defaults `expectedConnectionCheckMs=1000`, `expectedTcpUserTimeoutMs=15000`, idle holder and crash; `faultMode` restricted to crash/silent/asymmetric. Constants/state/fault are composed before driver text (`:43–47`). |
| Healthy active SQL | `client.exs:29–33`: validate fixture ID and complete actual `SELECT pg_sleep(20)` with one result. This positive control is longer than the 15-second TCP unacknowledged-data limit. |
| Effective production settings | `client.exs:35–50`: read PostgreSQL session GUCs; require idle transaction 15000ms, keepalive idle 15s, interval 5s, count 3; check/payload timeout values must be nonnegative integers. `driver.py:103–108` requires the settings object to equal exactly connection check 1000ms, TCP user timeout 15000ms and `healthy_query=True` for exported defaults. Startup production list is independently visible at `runtime_config.ex:144–152`; the configuration regression pins it at `marshall/test/marshall/operations/runtime_config_test.exs:109–115`, whose mere presence is not counted as a new passing result here. |
| Owner-only rendezvous | `client.exs:129–135`: write `.pending` exclusively, chmod 0600, rename into place. `driver.py:71–79` copies fixture environment/CA through a mode-0700 temporary directory with files chmod 0600; no credential content was read for this inventory. Client systemd unit has UMask 0077 (`driver.py:90–96`). |
| Holder acquired first | `client.exs:62–69`: start holder transaction and require `{:locked,0}` within 10000ms before submitting waiters. `transaction/3` takes a real row lock at `:110` and announces acquisition at `:111`. |
| Valid submission permutations | `driver.py:81–88` selects one of all six orders, seed 126; `:87` asserts sorted indices `[1,2,3]`. `client.exs:86–96` accepts exactly the six distinct-index permutations and rejects other external input before waiter start. |
| Distinct native backends | `driver.py:109–117`: each of four rendezvous PIDs must be an actual positive integer; four PIDs must be distinct. Settings wait is 30s (`:99`), each backend rendezvous wait 15s (`:112`). |
| Three observed queued statements | `driver.py:122–138`: DB observer requires exactly three captured waiters in active state with `wait_event_type='Lock'`, nonempty blockers drawn only from the four captured transaction PIDs, and queries active for at least two seconds. `eventually(queued,8)` must succeed before fault injection. This observes queue participation independently of submission order. Poll cadence is 0.2s (`:30–36`). |
| Correct holder state | `driver.py:139`: observed holder state must equal `idle in transaction` or `active`, as selected by export. Active holder executes real `pg_sleep(90)` while holding its acquired row (`client.exs:99–113`). Idle transactions hold until loss/expiry; fixture receive watchdog is 90000ms (`:115–119`), transaction/query timeout 95000ms (`:121`, `:125–127`). These long helper limits do not replace the 20/35-second driver acceptance bounds. |
| Full release pool captured | `driver.py:140–146`: capture server PIDs for `application_name='marshall:recovery-client'`; four transaction PIDs must be a subset and exactly ten total positive Repo PIDs must exist before fault. This is the Repo pool, not the whole runtime's notifier/migration budget. |
| Crash injection | `driver.py:148–149`: abrupt `m1.crash()` after the queue/state/pool observations. |
| Link loss preserves live sockets | `driver.py:151–159`: validate peer obtained from `host(client_addr)` for the captured holder PID as IPv4, then freeze the client systemd unit. Userspace is frozen while kernel sockets stay present, avoiding application retries and explicit TCP resets. |
| Real DROP direction | `driver.py:160–170`: install an nftables input hook at priority -100 dropping the holder's client-to-server TCP/5432 traffic; silent mode also has output hook dropping server-to-client TCP/5432 traffic. These are `counter drop` rules, not reject/reset actions. They are scoped to the validated fixture peer. |
| Holder 20-second bound | `driver.py:171–188`: after injection set `lost_at`; require captured holder PID absent within 20s. Failure diagnostics only inspect captured IDs/closed server state and cannot extend the bound. Assertion text at `:188`: `Abandoned holder exceeded its existing 20-second bound`. |
| All connections 35-second bound | `driver.py:191–195` checks all ten captured PIDs absent using only the remaining time to original `lost_at+35`; `:217` asserts `Lost release Repo connections exceeded the existing 35-second bound`. |
| Failure-only tail retains failure | `driver.py:196–216`: if the 35s probe fails, observe only until `lost_at+75`, sampling each second. `passed` is never reset by that tail; `:217` still fails the original bound even if later samples become empty. |
| Observed exercised DROP | `driver.py:43–65`: parse/validate nft JSON, chain names and nonnegative integer counters, require both inbound/outbound counter keys for silent and only inbound for asymmetric. `:219–222` asserts **outbound >0 for bidirectional silent**, **inbound >0 for asymmetric**. The fixture does not separately require positive inbound in silent mode, despite both installed DROP chains; this inventory does not inflate that assertion into independently observed positive loss in both directions. |
| Another connection reacquires row | `driver.py:224`: DB-local SQL observer executes `SELECT true FROM overalls_fleet_fixture FOR UPDATE` and requires `t` after all original sessions disappear. This proves row-lock availability to that observer, not an independent Marshall contender's pool recovery/admission. |

The fixture contains no explicit backend termination and does not change production startup timeouts to make the acceptance test pass. These controls correspond to the local contracts listed next; this is source observation, not runtime confirmation.

## Contracts and architecture obligations reviewed

Read root `CONTRACTS`, `nix/CONTRACTS`, `nix/tests/CONTRACTS`, and support's `nix/tests/support/CONTRACTS`; no intervening CONTRACTS exists under `nix/tests/machines/database-recovery/`. Root rules expressly separate acceptance from accepted ADRs/structural checks and forbid secret diagnostics. Nix/test contracts require pinned input, real source-built release/packages and isolated bounded fixtures. Shared support requires retaining TLS/authentication/resource/failure boundaries and composed driver static checks.

Local source contracts:

| Contract | Source |
| --- | --- |
| `database-recovery-real-release` | `default.nix:20–23`: real release Repo and PostgreSQL on two machines, three observed waiters before loss, no timeout overrides/backend termination |
| `database-recovery-observed-lock-convoy` | `client.exs:14–18`: distinct connections, unchanged production parameters, private rendezvous/redacted diagnostic fields, locks retained until loss/expiry |
| `database-recovery-waiter-permutation` | `client.exs:82–85`: each index once, reject malformed input, no queue-order inference |
| `database-recovery-active-holder` | `client.exs:99–102`: real active statement holding row, original timeouts, active state observed before loss |
| `database-recovery-drop-observed` | `driver.py:39–42`: actual positive directional counters rather than installation-only loss claims |

Marshall guidance and applicable root/Marshall/library/operations contracts were additionally read for the referenced RuntimeConfig settings. RuntimeConfig recovery notes are `abandoned-transaction-server-deadline` at `:110–114`, `lost-client-connections-are-reclaimed` at `:116–120`, and `lost-active-database-clients-are-observed` at `:122–126`. All three require preserving idempotency/healthy SQL and native deadlines.

`node scripts/check_contracts.mjs list` completed successfully for all three fixture files, confirming native file-level inventory and ancestors. This does not prove declaration attachment or semantic compliance. Targeted `format <path>` invocations were rejected because the repository adapter's format mode takes no path; no format pass is claimed. A whole-repository scan would have exceeded this inventory's exclusion of the retired harness. No type check, project gate, Nix evaluation or build was run.

ADR-0126 `:36–53` specifies 1s polling/15s TCP limit while retaining keepalives and 20/35s bounds, no explicit termination/server overrides, and no authority to replay uncertain effects. ADR-0033 `:26–38`, `:62–78`, `:98–106` requires actual NixOS machines, bounded waits and separate failures/completed executions/physical claims; it is superseded by ADR-0043, which carries forward those requirements (`0043-declarative-host-provisioning.md:25–30`). ADR-0029 `:27–55` requires acknowledged history, synchronous durability/fencing and isolated historical restore with reconciliation; `:116–130` preserves production HA/provider/reconciliation gaps. ADR-0048 `:31–53` permits explicit nonredundancy without claiming machine-loss availability and carries forward durability/fencing/quarantine. ADR-0070 `:86–102` supplements database backup drills without replacing replication/physical-manifest/fencing obligations, and requires explicit node replacement reconciliation; `:145–147` rejects unit-only recoverability claims. None of those broader restore/HA/host-replacement requirements is established by this six-case client-loss fixture.

## Historical execution evidence, preserving failures

### Final six-case runtime pass

`docs/architecture/reviews/2026-10-02-database-loss-histories.md:78–98` records terminal success/shell exit zero for capture **`1790973915375-2537070-0.jsonl`**, with `nix build --max-jobs 1 --keep-going --no-link` over all six exports. It records the **`ad999a42` base plus this verification expansion**, not current-tree native execution. The six table rows are at `:85–90`; their figures appear in the export matrix above. Lines `:80–81` explicitly retain both independent bounds and subsequent row reacquisition. No final-matrix store path is provided in that detailed review. ADR-0126 `:110–121` and HLDD `marshall/priv/hldd/16-recovery.md:246–262` carry forward the same exact historical result.

### Earlier successful cases and setup failures

| Record | Exact documented outcome and boundary |
| --- | --- |
| Initial active/crash, `1790971761080-1137410-0.jsonl` | Review `2026-10-02-database-loss-histories.md:22–28`: passed 60.51s, all ten reclaimed 19.518s, row reacquired. Predates final formatting, failure-only holder diagnostics, DROP counters and seeded orders; proves initial active-crash variant only. |
| First silent capture, `1790972141045-1389243-0.jsonl` | `:37–48`: observer-address bug/empty-address validation stopped before packet injection. No recovery outcome established. |
| First corrected address matrix, `1790972547094-1655251-0.jsonl` | `:50–60`: inet-to-text produced `192.168.1.2/32`; bare-address validator rejected it before injection. All four link cases terminal failed at this fixture format mismatch, not reclamation. Driver changed to `host(client_addr)`. |
| Nft syntax matrix, `1790973269234-2111001-0.jsonl` | `:62–74`: all four link cases stopped pre-injection due missing nft chain separator. Active/crash passed 64.32s/reclaimed 19.405s; idle/crash passed 69.51s/reclaimed 27.866s; original holder bounds and row reacquisition held. Newline repair then passed isolated nftables `--check`; this static validation does not establish link-loss runtime acceptance. |

The earlier chronological statements that matrix results were pending are superseded by that same review's final execution section, not erased. The separate reviews index remains stale: `docs/architecture/reviews/README.md:111` says silent/asymmetric verification is pending, while the detailed result and ADR/HLDD record all six passed. This is documentation drift surfaced read-only, not an unresolved runtime failure.

### Original baseline and correction evidence

`docs/architecture/reviews/2026-09-25-terminal-workspace-verification.md:297–303` introduces the explicit native convoy and immutable 20/35s bounds; `:308–314` records two pre-Repo failures (runtime closure/PATH), establishing no recovery result. Source provenance at `:316–327` distinguishes baseline `daa8491d` plus graphics fix from polling-only candidate `38edcbea` plus graphics fix/overlay: exercised inputs were compared, but complete releases were not binary identical.

| Case | Exact artifact and recorded result |
| --- | --- |
| Old settings baseline | `:329–340`: `/nix/store/vlzh77215zr73kd8jb3x19yb00ifcpal-vm-test-run-overalls-database-recovery.drv`. Holder passed 20s; total failed at 35.183s with two captured backends still present. First empty failure-only sample at 43.050s did not convert failure to pass. Healthy query then lasted **2s**, unlike the final 20s control. Both QEMUs confirmed absent after 0.12s cleanup. |
| Polling-only candidate | `:342–350`: `/nix/store/hmndpwb4x3dc48xixddbngcv7j5z59ck-vm-test-run-overalls-database-recovery.drv`. Real 1s polling/effective existing settings and lock schedule passed; 35s bound still failed; first empty failure-only sample 43.049s. Both QEMUs absent after 0.12s cleanup. |
| Combined 1s polling + 15s TCP candidate | `:352–369`: `/nix/store/53mi80rgxpwnxd86rs02ky0ic4m7ma11-vm-test-run-overalls-database-recovery.drv`, release `/nix/store/g5nw67wgxng6ch3hm00pyphx39da0w3y-overalls-marshall-0.1.0`. Passed 68.07s; holder within 20s; all ten reclaimed 27.719s; actual healthy 20s SQL, settings/queue and row reacquisition passed. QEMUs absent after 0.12s cleanup. |

That review's `:458–473` explicitly retains the combined capture's original source scope rather than relabeling it integrated execution. Recovery driver/executable RuntimeConfig chunks/Repo and startup inputs were compared; whole release binary identity was not claimed. The review also records separate later browser acceptance, but those broader terminal journeys are not executions of these six exports and are not included as matrix results.

## What remains unproven

The detailed final review `2026-10-02-database-loss-histories.md:100–105` expressly leaves an independent surviving release contender, repeated generated loss/reconnect histories, uncertain commit replay and hosted Antithesis execution separate. A local SQL observer reacquiring a row cannot establish application-pool reconnection or admission completion. ADR-0126 `:84–86` says settings apply on new connections and includes no live rollout; `:142–146` leaves physical fleet, managed-provider behavior, stalls under production load and existing-connection rollout to separate operational acceptance. No such claim is inferred from final matrix passing, source test presence, an accepted ADR or a build/type/structural gate.
