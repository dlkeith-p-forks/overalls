# ADR-0126: Bounded database recovery after client machine loss

- ID: ADR-0126
- Date: 2026-09-25
- Status: superseded
- Implementation: implemented
- Components: Marshall runtime configuration, PostgreSQL recovery, NixOS verification
- Supersedes: ADR-0053
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for the inherited `logical_budget_bytes` compatibility retention. ADR-0159 carries every other requirement of this record forward unchanged. ADR-0159 Push 11 dropped the retained `compute_storage_pools.logical_budget_bytes` column and made enrollment refuse a supplied budget.

## Context

The user authorized incremental verification improvements, corrections and
publication. The terminal workspace journey exposed a lost-client database lock
convoy beyond its existing 35-second connection-reclamation bound. A separate
two-machine fixture reproduced that failure with the real release Repo: one
holder and three observed lock waiters existed before the client machine stopped.

The inherited [ADR-0030](0030-nixos-deployment-and-tls.md) decision uses a
15-second idle-transaction timeout, TCP keepalives after 15 seconds with 5-second
intervals and three probes, and a 30-second TCP unacknowledged-data limit. The
idle-transaction timer starts when a statement returns to command-read state.
An active lock waiter can acquire the predecessor's released lock, then begin a
new idle period after its client has already disappeared. Successive periods
therefore extend total recovery beyond the nominal individual timeout.

One-second active disconnect polling alone failed the same bound. The kernel
reported disconnection after another waiter had already entered an idle period.
The combined one-second polling and 15-second TCP limit passed the unchanged
bound, while a healthy 20-second query completed. The
[execution review](../reviews/2026-09-25-terminal-workspace-verification.md)
preserves exact artifacts, earlier failures and comparison limits.

## Decision

Production Repo connections set `client_connection_check_interval=1s` and
`tcp_user_timeout=15s`. Preserve `idle_in_transaction_session_timeout=15s`,
`tcp_keepalives_idle=15s`, `tcp_keepalives_interval=5s` and
`tcp_keepalives_count=3`. Keep the existing verified PostgreSQL TLS, writable
primary requirement, synchronous commits and pool/notifier connection budget.

The TCP limit bounds tolerance of unacknowledged network traffic. It is not a
statement execution deadline: a healthy connection must support a query lasting
longer than 15 seconds. PostgreSQL polling observes a connection failure reported
by the kernel during active statements; its interval alone does not guarantee a
particular total recovery time.

Preserve the native fixture's independent 20-second holder and 35-second total
connection-reclamation assertions. Require the lock queue to be observed before
machine loss, then verify another connection can acquire the row. Never use
explicit backend termination, fixture-only server settings or relaxed deadlines
to pass that check. An uncertain commit still requires durable idempotency;
connection recovery does not authorize replay of terminal input or other effects.

This narrowly replaces the inherited database recovery settings under
[ADR-0053](0053-vm-disk-limit.md). Carry forward that record's 500 GiB VM disk
limit and every other inherited decision and rationale, including resize,
capacity, deployment, identity, transport, isolation and storage ownership.
No domain, wire protocol, authorization rule or physical-host acceptance changes.
The campaign's authorization and review of the measured correction establish
acceptance. Both full integrated terminal recovery journeys have passed the
implementation gate recorded below.

## Alternatives

- Keep the old settings: the observed convoy remained after 35 seconds and
  first disappeared in failure-only observation at 43.050 seconds.
- Enable polling alone: it still missed 35 seconds; the first empty sample
  occurred at 43.049 seconds.
- Increase the recovery deadline: this would leave the demonstrated interruption
  and weaken existing user-operation acceptance.
- Add a statement timeout: healthy long-running SQL is not the failed boundary.
- Terminate backends explicitly in the fixture: this would not establish
  recovery performed by the production configuration after client loss.

## Consequences

A network interruption that previously tolerated up to 30 seconds of
unacknowledged traffic can now fail earlier. Callers retain their existing
idempotency and reconnect rules. Active PostgreSQL statements incur periodic
connection checks; no production throughput claim is made from this fixture.
Healthy active and idle connections remain distinct from abandoned transactions.

Updated startup parameters apply to new database connections. Existing serving
connections retain their previous parameters until they reconnect through the
ordinary deployment/restart workflow. No live rollout is included in this change.

## Invariants and verification

- Read effective settings from the real PostgreSQL session, including both new
  settings and every preserved timeout/keepalive parameter.
- Complete a healthy 20-second active query before injecting failure.
- Observe one holder and three distinct active lock waiters before client loss;
  capture all ten Repo backends and preserve both reclamation deadlines.
- Reacquire the row after every captured backend disappears.
- Retain terminal host freshness, single writer, sharing, revocation, retained
  shell and refusal to replay uncertain input in both native guest journeys.

## Implementation evidence

[Runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex)
supplies the settings; the
[configuration regression](../../../marshall/test/marshall/operations/runtime_config_test.exs)
pins their complete production list. The
[two-machine fixture](../../../nix/verification/tests/machines/database-recovery/default.nix),
[release client](../../../nix/verification/tests/machines/database-recovery/client.exs) and
[driver](../../../nix/verification/tests/machines/database-recovery/driver.py) exercise verified
TLS PostgreSQL with the actual release Repo and observed lock queue.

The additional `database-recovery-active` check keeps the acquired holder lock
during a real ninety-second server statement and observes active state before
client-machine crash. It preserves the original holder and total reclamation
deadlines and production parameters. Its initial crash variant passed in
60.51 seconds, reclaiming all ten sessions in 19.518 seconds. The final six-case
matrix adds seeded submission orders and verified packet DROP directions. All
six cases passed capture `1790973915375-2537070-0.jsonl`, with all ten sessions
reclaimed in 19.432–27.882 seconds and subsequent row acquisition. Production
settings and both original bounds remain unchanged. See the
[history review](../reviews/2026-10-02-database-loss-histories.md) for exact scope,
direction counters and retained pre-injection fixture failures. Independent
surviving release contenders, reconnect histories and hosted faults remain open.

The captured combined candidate passed in 68.07 seconds and reclaimed all ten
connections in 27.719 seconds. Both earlier candidates failed the original bound;
their later observation did not convert either result into success. The healthy
20-second query and post-recovery row acquisition passed. The review identifies
the different full source bases and unchanged exercised Repo/startup inputs.
The adopted RuntimeConfig executable BEAM chunks match the captured candidate;
only line metadata differs. The Repo BEAM and recovery driver match, and helper
changes are comments only. The review records the wider release differences
without claiming complete binary identity.

Full Marshall precommit passed 1,092 checks, including 111 properties, and forced
Dialyzer reported zero findings. Complete integrated NixOS and Ubuntu terminal
journeys on captured tree `e710ef1e` separately passed browser recovery, retained
effects, sharing, writer refusal and revocation. Their VM-script timers were
702.42 and 683.84 seconds. These browser results provide the additional evidence
that the focused database fixture alone could not establish.

## Open questions

Physical fleet and managed-provider failure behavior, network stalls under
production load and rollout of existing connections require separate operational
acceptance. The earlier post-crash terminal-status failure is preserved in the
review; the complete current journeys pass that assertion, without isolating a
separate causal explanation for the earlier failure.

## Related decisions

- [ADR-0030: NixOS deployment and TLS](0030-nixos-deployment-and-tls.md)
- [ADR-0053: Maximum VM disk capacity](0053-vm-disk-limit.md)
- [ADR-0083: Terminal host stream and registry](0083-terminal-host-stream-and-registry.md)
- [ADR-0125: Fresh guest identities](0125-fresh-guest-identities.md)
