# Administrative job retry and retained history verification

## Scope and architecture impact

Campaign 019 uses its own `verify/019-job-history` worktree. Initial investigation
and reproduction used published `f4de549a`; implementation now includes published
`7f7ee2cb`. All fixtures are disposable. No production service is deployed.

This preserves ADR-0059's transactional redacted history and audited retry,
carried through ADR-0119 and ADR-0123. All signed-in accounts retain bounded
reads; current elevated administrators alone retry eligible raw jobs. No resource,
schema, protocol, permission or deployment decision changes. Updated serving
replicas are required before relying on the stronger serialization guarantee.

## Existing coverage and reproduced mismatch

Existing [domain tests](../../../marshall/test/marshall/administration/jobs_test.exs)
cover eight Oban states, redaction, pruning, rollback, retry idempotence, refused
states, expiry, paging and backfill. Existing
[LiveView tests](../../../marshall/test/marshall_web/admin_jobs_live_test.exs)
cover displayed-job binding, filters, archived history, demotion and revocation.
The Control room native journey visited jobs without retrying an actual worker.

Baseline `f4de549a` ran eight new three-Marshall schedules before production
edits: seed `19001`, **6/8 passed**, 5.1 seconds. Both `Security.lock` overlaps
failed. With retry paused before its actual Oban update, a second Marshall
committed elevation lock and a third observed lost elevation; retry could still
commit using its preceding permission check. With elevation lock paused at its
actual verification update while holding User, retry committed without waiting.
Demotion and raw prune/completion schedules passed both orders. This demonstrates
missing ordering of overlapping operations, not acceptance of a request begun
after completed revocation. Log: `/tmp/verify019-baseline.log`.

## Repair and lock review

[Jobs.retry](../../../marshall/lib/marshall/administration/jobs.ex) now takes
`Security.lock_user!` after the installation latch and before fresh Cedar. It
holds installation → actor User → raw Oban through retry and audit commit.
Retry first makes revocation wait; revocation first makes retry wait and refuse
without changing job/history/audit state. Receipt replay still requires authority.

Reviewed callers are the Administration action and Jobs LiveView. Security and
ordinary sign-out hold User; roles/global revocation hold installation before
User. Capture/backfill lock raw jobs without acquiring User. Oban Basic commits
fetch before worker execution, and acknowledges after `perform` returns; the
reviewed execution path does not hold raw-job locks while acquiring account
locks. Existing scheduling, projections and post-commit diagnostics are unchanged.
Contracts reviewed include repository privacy/evidence, durable authority, Ash
boundaries, administrative allowlists, fixed elevation, ordered sign-out, audited
retry and isolated three-independent-BEAM verification. No conflict was found.

## Verification design and execution

[Generated histories](../../../marshall/test/marshall/administration/job_history_test.exs)
compare independent event/permission models with actual Administration actions.
Capture histories generate raw state/attempt/error transitions, prune and expire;
these fixture writes establish capture consistency, not worker execution.
Authority histories use signed passkey verification, elevation locks, real role
actions, token revocation, two jobs, multiple request keys and exact receipts.
Refusals and replays preserve complete job/history/audit snapshots.

[Distributed schedules](../../../marshall/test/marshall/administration/job_history_distributed_test.exs)
start three Marshall BEAMs with independent pools; the parent is not counted.
Actual write gates pause retry, Security.lock, ordinary AuthController.sign_out,
demotion, completion or pruning. A third peer checks committed state and the
PostgreSQL blocking relation. Five competitors run both orders with independent
expected event sequences and receipt counts. All peers observe identical results.
[Peer-side completion envelopes](../../../marshall/test/support/job_history_fixture.ex)
distinguish completion from RPC transport failure. Unknown outcomes stop the
peer before cleanup. Failed assertions release gates/drain calls; cleanup deletes
only fixture rows and trigger functions.

Corrected source on `f4de549a` passed **12 checks (2 properties, 10 distributed
tests)**, seed `19003`, 20.2 seconds. Removing only User lock reproduced four
lock/sign-out ordering failures: **6/10 passed, four failed**, seed `19003`,
6.1 seconds; demotion/prune/completion passed. The fix was restored. Logs:
`/tmp/verify019-focused-2.log`, `/tmp/verify019-mutant.log`. An earlier fixture
adaptation left two direct peer calls; that run safely stopped peers and provides
no corrected-runtime evidence.

The [native browser journey](../../../nix/verification/tests/machines/job-history/default.nix)
passed at the captured revision below. It uses packaged Marshall/Oban, PostgreSQL,
verified browser TLS, virtual WebAuthn, the real DeliverAuthEmail worker and the
existing isolated TLS/authenticated SMTP fixture. Public magic-link requests
create ID-only jobs and encrypted outbox payloads. Only after observing actual
retryable attempt one does the fixture defer automatic scheduling. A browser
retry must record one actor/job receipt, reset scheduling via Oban and complete
attempt two with SMTP acceptance/erased outbox. A second failed job stays unchanged
through reader, locked and demoted refusals. Pruning retains read-only history;
real global revocation removes mounted and fresh reader access.

### Captured application gate and first native attempt

Staged tree `ec2e6b0f4705a699f57189bdda0db5e1228e832b`, based on
published `38edcbea`, passed full Marshall `mix precommit`: **1,068 passed
(107 properties, 961 tests), two excluded**, seed `864589`, 467.4 seconds.
JavaScript and workspace type checks passed. Forced `MIX_ENV=test` Dialyzer
reported **zero errors, zero skips and zero unnecessary skips**, 52.12 seconds
after its PLT update. Log: `/tmp/verify019-full-gates-2.log`. The earlier refined
focused run on this base passed 12 checks, seed `19004`, 16.9 seconds.

The corresponding strict native driver built successfully in 94 seconds. Runtime
`/nix/store/xa3c1ibsjkh255qfjcmz752ain22pgbs-vm-test-run-overalls-job-history-browser.drv`
failed at the first public request feedback assertion. At VM time 32.4 seconds
the real SMTP relay returned 451 and the packaged worker reported failure; five
seconds later the fixture timed out waiting for application `#flash-info`.
Source review found the public Ash Authentication flash renders `role="alert"`
without that ID. The fixture now selects that real feedback element. Failure
diagnostics expose only a reviewed stage, exception class and helper source
coordinate, never exception values or token-bearing URLs. Cleanup took 0.41
seconds; the Nix owner, driver and QEMU processes were independently absent.
Log: `/tmp/verify019-native.log`. This failed run provides no completed native
journey acceptance. The corrected helper's separate passing run follows.

### Corrected native execution

Captured tree `5a24fd04bf8439bf9bc9df7ee4cb10d0b125488e`, based on published
`7b8e4afe`, passed the complete native journey in **65.85 seconds**, including
36.22 seconds in the browser helper. Strict driver construction passed in 222
seconds, including pinned typing of the actual standalone helper with its
Python/Playwright closure. These artifacts identify the executed source:

- Runtime: `/nix/store/rfimmkwyd7x827pspyq3fl990954v68y-vm-test-run-overalls-job-history-browser.drv`.
- Result: `/nix/store/30q0zh3416kps6v3dm4rcx3c7d9jr9nq-vm-test-run-overalls-job-history-browser`.
- Driver: `/nix/store/1mjx77qa5lfx04927vfr5cnd5ky5h95y-nixos-test-driver-overalls-job-history-browser.drv`.
- Typed helper: `/nix/store/mbg7ylb6laddcbqs3cl5y6xfbw5chbpw-job-history-browser-typed/browser.py`.
- Log: `/tmp/verify019-native-retry.log`; the immutable runtime retains its Nix log.

Both public requests produced genuine failed attempt one before scheduling was
deferred. Ordinary read/filter/redaction assertions and forged retry refusal
passed. Actual virtual-WebAuthn elevation admitted the displayed first job's
manual retry with its exact actor/job receipt. Attempt two completed with the
same Message-ID and erased encrypted outbox. The second job's complete private
snapshot remained unchanged through ordinary, locked and demoted refusals.
Browser role demotion, raw pruning with retained read-only history, global
revocation of mounted/fresh reader access and decoded-token/SMTP-password absence
all passed. SMTP acceptance is not inbox delivery or exactly-once mail delivery.

Cleanup took **0.53 seconds**. Session 52560 drained with exit zero; Nix PID
1558264, driver 1558717 and QEMU 1559117 were independently confirmed absent
before releasing the campaign's native slot.

### Integration and final review

After integrating published `7b8e4afe`, seed `19005` passed **3 properties** in
15.2 seconds and **16 distributed schedules** in 8.5 seconds across the job and
Git-mirror histories. Forced test-environment Dialyzer reported zero errors,
zero skips and zero unnecessary skips in 48.68 seconds. Final contract review
extended peer completion envelopes to the post-race refusal probes as well;
the ten job schedules passed seed `19006` in 5.3 seconds and forced test-environment
Dialyzer again reported zero findings in 52.14 seconds. Logs:
`/tmp/verify019-integrated.log`, `/tmp/verify019-completion-gate.log`.

Published `7f7ee2cb` subsequently integrated the guest-identity improvement.
Review of its sorted User → GuestAccount → namespace acquisition found no
bootstrap or existing raw-Oban acquisition and no reverse job-retry path.
Its source changes do not alter the job coordinator, mail worker, SMTP fixture
or browser helper. The full gate and native result above retain their earlier
captured revisions. Combined job/guest-identity checks passed seed `19007`:
**16 ordinary checks (5 properties, 11 tests)** in 12.9 seconds and **15 distributed
schedules** in 10.0 seconds. Forced test-environment Dialyzer reported zero errors,
zero skips and zero unnecessary skips in 47.45 seconds. Log:
`/tmp/verify019-integrated-018.log`. The integrated Nix test script and standalone
browser helper compare byte-for-byte with their executed artifacts; the captured
package revision remains distinct from later guest-identity source.

Final review strengthened application refusal snapshots from eight selected raw
columns to the complete typed `Oban.Job` record, retaining typed Ash snapshots,
events and audit records. The same exact comparison now observes every stored
raw-job field. On integrated `7f7ee2cb`, **12 checks (2 properties, 10 distributed
tests)** passed seed `19008` in 14.5 seconds. Forced test-environment Dialyzer
reported zero errors, zero skips and zero unnecessary skips in 48.28 seconds.
Log: `/tmp/verify019-final-snapshot.log`. The independent coordinator reviewed
the final source, calls, generated/concurrent oracles and native helper and found
no remaining source or contract blocker. No new decision or production dependency
is introduced. The typed fixture change does not enter the release allowlist.

The final pinned Nix Python gate passed at
`/nix/store/jh71bh2yskhhgdbmy7kgsy7zyp5gm3l1-overalls-python-static`.

All-file `prek`, ADR structure/links, HLDD receipts/references, generated options,
scenario coverage, Ash/deployment views, contract syntax/coverage and its nineteen
regressions passed on the integrated source. Nix `hldd` also passed. Logs:
`/tmp/verify019-final-static-2.log`, `/tmp/verify019-final-hldd-2.log`.
Earlier final gate attempts correctly rejected stale receipts after fixture and
evidence edits; review confirmed the existing chapters already described their
scope, and specific no-impact receipts resolved them. Property/distributed
execution anchors now point to corrected seed `19008`; mutation failures remain
separate evidence. Final database audit found zero users and zero job-history,
Git-mirror or guest-identity fixture gate functions.

## Remaining acceptance

Finite functional histories do not establish capture overhead, database throughput,
independent-host availability, VM completion, hardware authenticators, inbox
delivery or exactly-once SMTP effects across uncertain commit. Mixed old/new
replicas and production rollout remain separate. ADR-0059's historical partial
status is retained.
