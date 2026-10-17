# Committed admission with a lost caller response

## Scope and architecture impact

Integrated main includes `31f133d8`; the recorded focused run predates that
terminal-only batch and uses baseline `e3598d11be20498968fc21da993a5459f4b96890`. Reviewed the admission
action, history replay, committed inventory/cleanup fixtures and three-peer
setup. ADR-0010's retained idempotency requirement is carried forward by accepted
ADR-0050; ADR-0014's linked image/address allocation remains part of the commit
set. This batch adds test-only worker and generated history code. It preserves
production APIs, transaction order, resource ownership and accepted rationale.

The existing fixed three-node same-key test already covers nine simultaneous
requests returning one ID, reservation and operation. The local generated
archived replay test covers delivered results. The new property addresses the
missing combination of lost result, concurrent cross-node retries and complete
committed allocation inventory.

## Workload and independent oracle

The test-only worker invokes the real authorized provision action on one of
three independent Marshall nodes. After the action returns, it publishes a
separate committed-ID observation and waits for response release. The parent
independently queries the committed VM/reservation/operation, requires no caller
result, kills that exact worker and observes its `:killed` monitor result before
retrying. A gate timeout or worker failure is not accepted as the intended fault.

Each generated draw varies origin node, one to three retry rounds and one of
three changed shape fields. Fixed live and archived witnesses run every draw.
Both worker loss and whole-origin BEAM loss run for each archival state. The
whole-node history starts an owned fourth Marshall with an independent committed
Repo pool before creating database fixtures; three original peers survive for
retry. `peer_down: :crash` exposes the requested abrupt exit status137, which
must be observed before retry or cleanup. A worker disconnection alone cannot
prove this fault. The owned controller never restarts.
Nine same-key requests race across the three nodes per round; every result must
return the original ID. The complete public-table row inventory must remain
unchanged after every round and every changed-shape refusal. Worker retirement
precedes normal fixture deletion. On body failure, the established cleanup
wrapper stops and observes every peer before deleting owned rows; independent
suite teardown checks preserve preexisting inventory and images.

## Verification status and limits

The first run failed because the local observer was not a named node, preventing
remote worker messages and monitors from reaching it. The tagged setup now starts
and connects an owned named observer when required, and stops only that observer
at teardown. No cookie values enter diagnostics. Destructive histories disable
shrinking because failure cleanup retires the shared peers; retaining the first
failure avoids masking it with later no-process errors. Generated inputs and
fixed worker/node-loss and live/archived witnesses remain enabled.


Pinned Elixir formatting parsed both changed files; `git diff --check` passes.
The standalone contract checker does not support Elixir files, so native
annotations and directory obligations were reviewed manually. Compilation and distributed-file execution passed: 43 checks (2 properties,
41 tests), seed837340,108.4seconds, exit0. Log
`/tmp/overalls-admission-uncertain-focused2.log`. Selection combined `--only
uncertain_admission` with `--include distributed`; include semantics selected
the entire distributed admission file. Forced Dialyzer, handbook and complete
project gates were pending at that focused stage. Integrated main `31f133d8`
full Marshall precommit now passed:1452checks (238properties,1214tests),
two exclusions, seed617270,1693.2seconds, exit0. Forced Dialyzer passed in
46.37seconds with zero errors, skips or unnecessary skips; its PLT update took
2m40.05s. Log `/tmp/overalls-admission-uncertain-main31-precommit.log`.
The final source review traced the committed inventory oracle and peer-before-row
cleanup obligations; no contract mismatch was found in that inspected scope.
Final all-file publication hooks passed, including Python typing. Evaluated
handbook check passed26seconds,exit0, archive `1791201804147-176444-0.jsonl`;
log `/tmp/overalls-admission-uncertain-publication-hooks.log`.

These faults kill the originating caller process or owned BEAM after commit. The observer's
committed-ID witness is deliberately separate from the withheld result; this
does not establish HTTP response loss, rollback ambiguity before
commit, native dispatch/VM execution or hosted faults. Those histories remain
valuable follow-up work rather than being declared covered by this seam.

The standalone pinned peer probe verified that default controller shutdown
reports `:normal`, while explicit `peer_down: :crash` exposes `{:exit_status,137}`
for `:erlang.halt(137)`. Log `/tmp/overalls-admission-owned-peer-exit-probe3.log`.
That platform probe is not execution evidence for the application property.
