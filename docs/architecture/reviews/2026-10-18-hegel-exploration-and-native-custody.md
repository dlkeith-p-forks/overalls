# Hegel exploration, fixture ownership and native installation

## Scope and architectural impact

This review covers the uncommitted Hegel migration repair based on Overalls
`720b7e0a8b1fd11edc64f46d116118e2878ae3bd`, and upstream frontend
`b0dec2abf868c7036950c00256a2ebf5af2929e7`. It is an intermediate review:
application runs, final release qualification and integration with moving trunk
are pending. It does not certify the entire changed test inventory.

[ADR-0191](../decisions/0191-elixir-hegel-property-verification.md) remains
accepted and partially implemented. These changes enforce its generated-case
isolation, exploration and evidence boundaries without changing product domain
ownership, protocol contracts, PostgreSQL authority or deployment placement.
[ADR-0186](../decisions/0186-covenant-contract-verification.md) remains complementary;
Covenant results retain their own obligation and execution scope.

## Findings and repairs

1. **High: reduced exploration and ignored execution options.** Nested compatibility
   `check all` options did not control the outer runner. One- and two-case clamps
   further reduced successful exploration. Ordinary generated properties now use
   one runner with labelled draws and default 100 cases, preserving existing
   larger budgets. Upstream `093b819` rejects unsupported options and execution
   options inside nested checks. The complete Enrico mutation matrix is restored
   in [its boot property](../../../enrico/test/invalid_boot_property_test.exs).
   True finite exhaustive matrices, such as protocol
   [opening worker deaths](../../../protocol/test/control/opening_worker_property_test.exs),
   enumerate every value and retain their assertions as ordinary tests. Deliberate
   negative/replay controls remain distinct from successful exploration.
2. **High: fixtures survived generated-case boundaries.** ExUnit setup/teardown
   surrounds the whole test, so repeated generated cases accumulated children,
   socket state and database rows. The shared
   [fixture helper](../../../scripts/test/hegel_fixtures.exs) registers case cleanup
   and verifies original PID custody before stopping a reused child ID.
   [Regression tests](../../../audi/test/hegel_fixtures_test.exs) cover explicit
   teardown, replay and replacement ownership. Marshall's
   [sandbox helper](../../../marshall/test/support/data_case.ex) creates case-owned
   SQL owners for tagged local properties; committed and distributed fixtures
   retain explicit owned-row cleanup. Runtime completion of all consumers remains
   required before treating this repair as verified across the fleet.
3. **High: native installation could truncate a mapped library.** Astra's syscall
   inspection established that the old installer's `File.cp!` opened the loaded
   destination with `O_TRUNC`. A Ziggy test VM exited 139 during overlapping
   compilation. Upstream `b0dec2a` writes a sibling staging file and atomically
   renames it, preserving the inode mapped into another VM. The regression suite
   checks replacement inode/read-handle behavior and concurrent installs. Native
   engine 0.43.7 and ABI 2.17 are unchanged; this installer fix does not turn prior
   incomplete application runs into passing results.
4. **Medium: native flaky results hid original BEAM failures.** Upstream `1cfe362`
   retains discovered exceptions and original stacks in native error results;
   `check` raises with those failures rather than printing unstable replay data.
   Actual native flaky regression execution accompanies the change.
5. **Medium: aggregate timeouts confused exploration cost with operation failure.**
   Hundreds or thousands of fresh VM launches need measured aggregate budgets.
   Boot histories preserve full matrices and 100 cases with budgets up to three
   hours; each boot retains a 30-second operation deadline and five-second kill
   allowance. Ziggy's
   [reporter history](../../../ziggy/test/reporter_history_test.exs) retains its
   batch deadlines and uses same-sender suspend/release ordering instead of
   assuming a send trace implies target-mailbox delivery. Its revised aggregate
   timeout and ordering still require completed runtime evidence.

The independent service review also found an inherited Brady mutation-list clamp
from `9243a32d4`/`ccb9cf3ad`: only one to three schema mutations were sampled per
case. The restored shuffled matrix contains all 41 mutations, retaining 100 cases
(4,100 fresh boots). Its focused run is pending, so the earlier 92-test pass below
does not qualify that later restoration. Per-case directory cleanup and synchronous
supervisor retirement were added in Ziggy/Brady, and Galileo/Brady counters now
start fresh per case. These later fixture edits also require their own reruns.

## Recorded execution at this checkpoint

These are scoped intermediate results, not a final all-application pass. Log
paths identify local execution artifacts; they are not permanent repository
artifacts. Later source changes require their own qualification.

| Scope | Frontend/source scope | Observed result | Local log |
| --- | --- | --- | --- |
| Upstream full native-backed suite | `b0dec2a` | 14 EUnit and 22 Elixir tests passed, plus Erlang/Elixir/Gleam examples | `/tmp/hegel-atomic-install-tests.log` |
| Brady full ExUnit suite | `b0dec2a` | 92 passed in 208.9 seconds; forced Dialyzer zero errors/skips | `/tmp/overalls-brady-b0-precommit.log` |
| Diagnostics precommit | `b0dec2a` | 32 passed; forced Dialyzer zero errors/skips | `/tmp/overalls-hegel-diagnostics-b0-precommit.log` |
| Request accounting precommit | `b0dec2a` | 30 passed; forced Dialyzer zero errors/skips | `/tmp/overalls-hegel-accounting-b0-precommit.log` |
| Antithesis SDK precommit | Separate unchanged SDK scope | 13 passed | `/tmp/overalls-hegel-sdk-precommit.log` |

The final-pin native probe in `/tmp/overalls-hegel-b0-native-probe.log` records
engine 0.43.7, 100 actual draws and successful deliberate-failure replay with
`HEGEL_NIF_PATH` unset. The process mapped the installed application-build library
`elixir/diagnostics/_build/test/lib/hegel/priv/hegel_nif.so`. This establishes local
Mix native loading. All eight final-pin Nix release checks passed in 545 seconds
(`/tmp/overalls-hegel-b0-releases.log`). These are production builds, where Hegel
remains test-only; they do not substitute for the native-backed test run. All eight realized
Nix dependency outputs have matching normalized locks and configured hashes in
`/tmp/overalls-hegel-b0-fod-receipt.json`; it is dependency custody, not release
execution or a reproducibility claim.

The earlier Ziggy reporter attempt exited 139 and is incomplete. Runs compiled
before subsequent timeout or fixture edits require focused reruns. Galileo
upstream-history aggregate timeouts remain under diagnosis. No pending run,
structural checker, source inspection or dependency hash substitutes for a
completed native-backed application run.

## Remaining verification and evidence boundaries

Complete every Elixir application suite except known-broken Inception, including
Marshall distributed/host/capacity tags. Finish relevant compiler, contract,
formatting and forced Dialyzer gates. Recheck lock/hash custody if integration changes dependencies; build the final releases
and exercise packaged native loading without a developer override. Integrate
current trunk and rerun checks affected by integration before recording final
completion.

The inspected changes preserve test oracles and product contracts; this review
samples fixture, SQL, boot and finite-matrix transformations and does not assert
an exhaustive semantic review of every changed property. Native KVM isolation,
physical recovery, public transport, production rollout and independent-host
availability retain their existing machine/native acceptance requirements.
Scenario ledger historical records are preserved without upgrades. Finite-matrix
entries now identify ordinary exhaustive tests and explicitly qualify their
historical generated execution. Lilly's per-mutation boot entry binds the current
assertion. The coverage scanner now recognizes parenthesized `property(...)`
syntax while rejecting prefixed names and unrelated modules; a regression extends
Marshall's governance suite. Standalone ADR, scenario, Ash/deployment-view and
configuration-reference checks passed; the governance runtime regression remains
pending. The handbook
Reference explains current runner/cleanup semantics and clearly separates older
clamped-count results from the current repair.
