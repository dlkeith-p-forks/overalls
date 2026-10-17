---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Safety guarantees: independent system discovery

The repository claims conservative execution authority, bounded authority leases, idempotent durable intent and owned cleanup. These are claims to test, not established guarantees. Its strongest recurring distinction is between acceptance, attempted effect, physical evidence and acknowledgment: none may silently substitute for the next. This report identifies implementation mechanisms and feasible observations, without producing the final property catalog.

## Scope and evidence limits

Examined root/component instructions; architecture overview and decision index; relevant accepted decisions including ADR-0004/0017/0036/0037/0080/0123/0136/0149/0155/0158; ancestor and local contracts; primary admission/lifecycle/outcome, native guard, authority lease, cache, mirror, backup, secret publication and updater paths. Components covered are Marshall, Lilly, Audi, Brady, Enrico, Galileo, Porsche, Ziggy, protocol, shared diagnostics/accounting, Lyra, browser, guest terminal/editor helpers and Nix. Source examination is focused sampling of high-risk paths, not exhaustive semantic contract verification. Local git history confirms stopped-only relocation (`7a583604`) and shared typed diagnostics (`1de650d5`) are incoming primary implementations; their commit titles alone prove no runtime behavior.

Ran `node scripts/check_contracts.mjs format`: passed for 127 CONTRACTS files, 2,712 native notes, 264 parsed source files and 2,751 maintained source files. This is structural evidence only. No application, native or machine tests were executed during discovery. Historical ADR evidence retains its exact earlier scope; the index explicitly marks many capabilities partial. Retired `antithesis/` files were not read. This temporary report changes no implementation or accepted architecture.

## 1. Durable acknowledgment is conditional on the configured database

`marshall/lib/marshall/operations/CONTRACTS:1` claims production connections cannot inherit `synchronous_commit=off`. `operations/runtime_config.ex:138` installs `synchronous_commit: "on"` and primary-only connections; verified TLS is mandatory except explicit literal-loopback development. `compute/ledger.ex:21` wraps durable mutations in PostgreSQL transactions, and `:36` runs queued after-commit effects only when the outer successful scope is outside a transaction. Intended invariant: successful user acknowledgment follows the configured primary WAL boundary, and rolled-back business changes produce no committed-success diagnostic.

This does not establish synchronous standby durability or independent-host availability: standby selection belongs to the operator. A feasible oracle uses an actual PostgreSQL instance with role default `off`, inspects each pooled connection setting, records acknowledged mutations, kills the client or primary around commit/reply, and compares recovered rows. Reply loss must be modeled separately from transaction failure.

## 2. Admission cannot allocate partially or spend unknown headroom

`compute/admission.ex:34` claims one owner/idempotency key returns the original VM, including archived history, or rejects changed shape/source/name. `run/3` takes an advisory key lock before checking history. Allocation (`:153`) validates shape, profile, image and source capability; locks candidate hosts; requires normal maintenance mode, execution protocol v4, explicit execution readiness, fresh host/pool reports and image availability. VM, placement, reservation, address, provision operation and dispatched job belong to one transaction.

`compute/budget.ex:10` separates measured physical headroom from settled virtual promises. Missing capacity returns zero schedulable capacity; cross-pool startup compute holds are subtracted once, and pending disk growth gets only its own physical-materialization credit. Intended safety is bounded new admission under observed headroom, not a promise that total virtual allocations never exceed RAM. Oracle: independently compute expected startup charges from accepted requests and physical receipts, race admissions/reports, fail job insertion, and verify no partial allocation or duplicated owner/key VM survives.

## 3. New intent and physical history remain separately fenced

`compute/lifecycle.ex:22` claims authorization is rechecked after obtaining the VM lock. Its implementation acquires sorted host locks before reloading/locking the VM, rejects changed placement/epoch, then atomically advances generation, cancels superseded operations and inserts the replacement. Exact replay returns the same-kind operation without a second generation increment. Resize, clone and unresolved relocation have explicit exclusion checks.

`compute/provisioner_control.ex:101` authenticates the physical machine and rejects consumed old session nonces; `:166` fences current session/epoch before atomically ingesting outcomes, capacity and receipts. `compute/outcomes.ex:44` permits an outcome replay only if full encoded observation and host match. Recording validates immutable operation placement/epoch/kind and rejects future generations or reused placement sequences. Stale valid history is retained without rewriting current VM intent. Oracle: replay/mutate outcome IDs across sessions and generations, compare append-only history with current state, and require batch rollback on conflict. A provisioner receipt alone cannot count as physical completion.

## 4. Released capacity requires matching physical proof

`compute/outcomes.ex:166` explicitly retains allocations for unknown effects. Matching current stopped/deleted evidence controls release; failed start can free compute while retaining disk/address. Relocation cleanup holds remain independent. `Outcomes.record!/3` checks the current placement, execution epoch, generation and newer sequence before applying the result; a source-cleanup receipt may finish its own immutable operation without replacing destination state.

An independent oracle should reconstruct held commitments from admitted operations and confirmed cleanup, not call production Budget arithmetic to decide truth. Inject lost replies and stale proofs; verify a disk/address or unresolved copy remains charged until its exact physical obligation is reclaimed. Fake executors can establish ledger decisions, but cannot establish actual cgroup emptiness or native disk disappearance.

## 5. A logical generation cannot launch twice or outrun its native fence

ADR-0017 claims attempts precede effects and asynchronous results retain their original revision. `lilly/lib/lilly/vm/actor.ex:272` calls `Journal.attempt` before starting the executor task; result handling (`:222`) reloads command intent and discards superseded work. `vm/journal.ex:69` maintains monotonic epoch/generation; `:95` persists validated stable-ID physical outcomes; `:145` clears only the current acknowledged outcome. `vm/driver.ex:336` persists the separate launch-attempt marker before systemd submission.

`vm/intent.ex:25` refuses decreased revisions, same-revision state conflicts and resurrection from deleted intent. `native/launch-guard/src/lib.rs:169` acquires the stable shared lock before reading the exact 53-byte intent, compares placement/epoch/generation/running state, and retains its descriptor across jailer exec. Oracle: kill the actor before/after each marker and systemd submission, count native launch identities, and race a waiting guard against stop/fence intent. A marker without a launch may conservatively require explicit new intent; it is not guaranteed successful processing.

## 6. Ownership outlives the BEAM owner and every relevant utility descendant

Lilly contracts require independent VM lifetime and stable lock inodes (`lilly/CONTRACTS:1`, `lib/lilly/host/CONTRACTS:7`); restarting Lilly must not kill Firecracker or guest PTYs. Native host-lock uses subreaper custody and `terminate` (`native/host-lock/src/lib.rs:282`) signals the unreaped group leader, then waits for all adopted descendants before returning completion. Enrico’s git-owner (`enrico/native/git-owner/src/main.rs:138`) similarly waits across escaped sessions; unresolved cleanup reports failure rather than confirmed release. Source-export and transfer-stream contracts require revocation/deadline/failure to reap senders and receivers before exit.

Oracle: launch children that change session/process group while holding inherited locks, kill callers, and contend with a successor. Success must follow actual child retirement, not disappearance of one leader PID. This needs real Linux processes; no mock establishes custody. Physical VM independence additionally needs systemd/cgroup/Firecracker execution.

## 7. Relocation never grants both copies execution authority

ADR-0155 replaces live pre-copy with one stopped full copy while carrying forward ADR-0037 fencing. `compute/relocation_admission.ex:16` rechecks manage permission under sorted endpoint host locks and VM lock; cancellation (`relocation_cancellation.ex:12`) rejects committed handoff. Durable relocation constraints bind source/destination epochs and activation/stop operations. `relocation_readiness_state.ex:102` requires exact matching activation operation and physical evidence; `relocation_readiness.ex:26` fences the destination session, treats conflicting boot IDs as errors and cannot revive expired readiness.

Intended invariant: transfer/adoption alone grants no launch right; handoff moves authoritative placement/epoch atomically; cancellation and commit choose one outcome; source deletion waits for destination readiness. Oracle: observe physical execution identities on both hosts plus the database authority tuple while racing cancellation, late receipt, activation failure and cleanup. Do not equate a completed byte stream with durable import, guest boot, source restoration or resource release.

## 8. Current persisted user/account authority governs sensitive operations

`authorization/cedar.ex:48` returns true only for typed principals and an explicit allow with zero evaluation errors. The Ash authorizer’s resource/action allowlist (`:418`) denies unlisted actions, including internal ones. Access contracts require current unarchived grants and immutable profile restrictions; Customer admits only its owner. Stored login-token presence/expiry, current administrator elevation, revoked SSH keys and per-operation permissions cannot be replaced by cached roles or an old JWT.

`editor/authority.ex:207` binds renewal to the current stored login, permanent GuestAccount UUID/UID, gateway generation, host session, execution and immutable image descriptor; expired/closed leases cannot migrate or resurrect. ADR-0158 makes Linux account identity independent of email. Oracle: revoke login/key/grant while a request waits on locks, retire accounts, change email, and try renewal or reauthentication using the old proof. Denials should remain classified by authentication, permission and execution rather than blanket retryable availability.

## 9. Satellite authority is bounded and DNS confers no access

Audi owns no Marshall database authority. `audi/authority/stream_guard.ex:11` requires a dedicated process owning its sockets; denial, changed binding or expiry kills that owner even if it traps exits. An independent watchdog covers guard death/suspension. Its Lease uses request-start time, so delayed responses cannot acquire a fresh full lifetime at receipt. `dns/directory.ex:85` rejects regressed/conflicting/expired snapshots; route deadlines (`:109`) expire independently, producing SERVFAIL rather than stale addresses.

A concrete contract mismatch needs reconciliation before selecting a numerical oracle: `audi/lib/audi/authority/lease.ex:8` says every grant expires at most five seconds after request start, while `new/4` accepts TTLs through 30,000 ms; current editor authority emits 30,000 ms (`marshall/lib/marshall/editor/authority.ex:13`) through this same HTTP guard. This establishes stale/inconsistent specification, not unauthorized access. Preserve request-start anchoring, and derive the intended service-specific maximum from current authority.

Galileo authorizes before upstream effect (`galileo/http.ex:105`) and `upstream.ex:35` enforces fixed verified-TLS origins, injected-header precedence, no redirect/retry and a renewable lease covering connect/upload/download. Ziggy uses a direct owner kill timer (`ziggy/lease.ex:51`) and rejects late renewal. Oracle: block upstream/downstream and suspend renewal/guard work; count origin attempts and forwarded bytes after lease expiry. DNS answer success alone must never permit SSH, editor or private integration effects.

## 10. Inference/tool uncertainty must not cause repeated external effects

Ziggy’s `spool.ex:87` fsyncs metadata and reserved completion capacity before admission returns. Full/failed persistence prevents provider work; immutable completions are retired only after exact acknowledgment. Inference contracts preserve missing usage as unknown and durable request-ID attribution. `agents/model_calls.ex:10` claims durable single provider attempt, and claimed timeout (`:491`) becomes uncertain rather than queued again. Executor-loss contracts apply the same rule to issued tools.

Porsche submits validated closed requests without implicit retries (`porsche/client.ex:103`) and opens sessions only from live proof (`connection.ex:34`). Lyra reports tool `started` before side effects (`lyra/src/agent.rs:135`) and propagates failed transition RPCs. Oracle: count synthetic provider/tool effects independently of completion receipts, cut after effect but before result acknowledgment, restart all owners, and require uncertainty instead of a second effect. The exact revocation guarantee during a currently executing Lyra tool needs separate investigation; checks surrounding tools are not proof of continuous in-tool fencing.

## 11. Shared caches and source mirrors cannot elevate untrusted requests

Brady permits only anonymous eligible GETs with complete explicitly public responses or its reviewed commit-pinned archive exception (`brady/cache/policy.ex:25`). Credentials, cookies, signed/query URLs, ambiguous policy and unsupported variants bypass storage/reuse. Cache keys bind origin/port/path/variants. Budget (`cache/budget.ex:25`) refuses unknown pressure and includes committed plus inflight bytes; unconfirmed deletion cannot reclaim budget. Oracle: concurrent unknown-length uploads, truncated responses, origin/variant changes and storage failure must preserve proxy safety without cross-user cache reuse or direct guest bypass.

Enrico constructs only validated GitHub URLs and fixed argv (`enrico/git.ex:47`), uses atomic Git fetch and retained published heads, and single-flights refresh ownership (`manager.ex:70`). Only the retained current attempt generation settles (`:174`). Oracle: interruption/owner death must leave the previously published tree readable, stale completion cannot overwrite the active attempt, and foreign paths/hosts refuse before any utility effect.

## 12. Guest, browser, diagnostics and operational custody preserve their boundaries

Guest terminald authenticates host CID 2 plus boot-bound HMAC before control, applies checked passwd credentials, preserves byte fidelity with backpressure and explicit replay gaps (`nix/domains/artifacts/terminald/CONTRACTS`). Lilly input sequences drop duplicate delivery; editor broker validates closed account/boot/package prefaces (`vscode-web-broker/src/lib.rs:311`) and kernel peer UID before worker reuse. Lyra outer SSH pins the exact currently fetched gateway key (`lyra/src/proxy.rs:202`). Browser transmission follows explicit toolbar click, exact provider validation and configured destination (`marvin/common/extension.mjs:63`). Oracles should count guest input effects, mutate boot proofs/accounts and record extension requests without retaining real payloads.

Diagnostics catalogs admit only reviewed non-string metadata (`elixir/diagnostics/lib/overalls/diagnostics/events/catalog.ex:15`); trace spool acknowledgment follows SQLite FULL WAL commit (`native/spool/src/lib.rs:483`). Routine observer failure must leave lifecycle authority unchanged under ADR-0149. Accounting independently preserves `requests = successes + failures` and histogram conservation (`request_accounting/aggregate.ex:122`), with missing observations remaining unmeasured. Synthetic secrets can test every diagnostic projection, while an independent recorder ledger tests conservation/reply-loss.

Backups journal cleanup before snapshots, preserve every retained completed manifest’s components, and never destroy foreign snapshots. `nix/domains/system/backups/host.py:108` checks dataset GUID, local nonce, snapshot GUID and mount source before deletion; `journal.py:158` refuses terminal state before confirmed cleanup. Secrets preparation validates the whole bundle and fsyncs atomic publication (`secrets/prepare.py:219`). Updater `runtime.py:990` stages even identical closures, then preflights/migrates/activates/verifies before advancing `lastHealthy`; binding changes and incomplete role health refuse. Native oracles track owned/foreign GUIDs, retained manifest reachability, bundle readers and exact active candidate identity through process/storage failures.

## Assumptions and open questions

These claims depend on reliable native flock/inode identity, filesystem/SQLite/PostgreSQL durability semantics, dedicated Lilly UID/GID and cgroup ranges, protected infrastructure CIDRs, verified peer trust and operator-controlled executable paths. Public infrastructure protection and external identity-service exclusivity are operator obligations, not automatically discovered facts. Readiness reports are authenticated provisioner claims, not hardware attestation. Host-local monotonic leases and shared database clock deadlines have different scopes and must not be compared as interchangeable timestamps.

A rebuild needs independently observed native execution/cleanup, externally counted attempts, version-skew refusals, explicit unknown-state modeling, and current-baseline machine evidence. Review older ADR version/range language against superseding decisions before using it as an oracle. Preferred NixOS/property tests are present across these boundaries, but neither their presence nor this structural pass establishes execution on this baseline; native isolation, production journeys, restore reconciliation and full source-fault acceptance remain open where the ADR index records them.
