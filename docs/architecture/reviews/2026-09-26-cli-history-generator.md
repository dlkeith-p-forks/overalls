# CLI lifetime history generator repair

## Scope and architecture assessment

Improvement 031 began at published `08ae4faa087abfd6707c69713f03c470577f1f73`
and incorporates published `8a5750608530a3f82460116ceec5cce1037df30e` before
the final gate. Its dedicated branch is `verify/031-cli-history-generator`.

No architecture impact: this corrects generation of the existing CLI lifetime
property. ADR-0009/0042's property-test requirement and ADR-0100/0101's current
account, VM and per-invocation authority remain unchanged. No production code,
schema, permission, dependency, protocol or deployment changes. ADR-0101 remains
accepted and partial. The earlier native captures retain their exact revisions
and limits; no new native or Inception verification is performed.

## Reproduced defect and repair

Improvement 025's full Marshall gate at seed `605897` exposed
`StreamData.TooManyDuplicatesError` in the inherited
[CLI history test](../../../marshall/test/marshall_web/agent_cli_history_test.exs).
The lifetime generator requested all three members of a finite set using
`uniq_list_of(member_of(...), length: 3)`. Ten consecutive duplicate draws
exhaust its retry budget before the lifetime checks run. The failing output
contains only `:expiry` and `:retire`; this is a verification defect, not an
observed product-authority failure.

The unchanged published baseline reproduces with
`mix test test/marshall_web/agent_cli_history_test.exs:140 --seed 605897`:
**0/1 passed, two excluded**, the same duplicate exhaustion, in 1.6 seconds.
Log: `/tmp/verify031-baseline.log`; its owner drained with exit 2.

The repair uses the already pinned StreamData 1.4.0 `shuffle/1`. Its implementation
maps bounded lists of index swaps over the original three-element array.
Generation and shrinking both apply swaps to that complete array; neither
removes nor repeats a boundary. Every permutation is reachable, including the
original order. Shrinking tends toward the original order while retaining
`:expiry`, `:delete` and `:retire`. The generated expiry age is unchanged. Each
property execution still generates four permutations, each exercising all three
boundaries in fresh fixtures: twelve boundary fixtures total. Increasing
duplicate retry limits would retain the same probabilistic failure and is
unnecessary.

## Contract review

Reviewed repository, Marshall, test and documentation ancestor contracts; all
three local CLI history contracts; actual CLIAccess, API and browser approval
contracts; and StreamData's shuffle and shrinking implementation. The existing
`cli-browser-and-session-lifetimes` obligation now explicitly requires complete
generation and shrinking without rejection exhaustion. Its single property
consumer still calls the unchanged typed `lifetime_boundary/2` for each value.
No contract is weakened. The authority oracle, full refusal inventory and SQL
sandbox lifetime remain unchanged. No new wrapper or mirrored library test is
needed to establish the permutation invariant.

## Execution record

The repaired focused run on integrated `8a575060` passed **8 checks (3 properties,
5 tests)** at the exact failing seed `605897`, in 41.2 seconds. This runs both
the history file and the existing CLI API/approval file. The test file SHA-256 is
`6204388ef3ff3ea9d1d333827b8344036ec25266a27b1f308a0cd7fc8e66970c`.
Log: `/tmp/verify031-focused.log`; its owner drained with exit zero.

Full Marshall `mix precommit` passed on frozen staged tree
`69c760c78ceaede4e8390b6974ffa2070fc4a932`, integrated base `8a575060`:
**1,138 checks (123 properties, 1,015 tests)**, two excluded, seed `327583`,
529.5 seconds. Browser checks passed 28 tests, dashboard checks four, and
workspace TypeScript passed. Forced test Dialyzer reported zero errors, skipped
findings or unnecessary skips, in 67.77 seconds after a 3m23.06s private PLT
rebuild. Log: `/tmp/verify031-precommit.log`; its owner drained with exit zero.
The final source test has the same SHA-256 as the focused run.

The dedicated database partition is `marshall_testverify031`, with isolated
writable build/dependency caches. Before/after focused audits and the pre-full
audit have identical complete row digests and zero rows in all 31 audited tables.
The full suite subsequently retains 64 rows in each of `agent_audit_events`,
`agent_roots`, `agent_roots_versions`, `agent_threads` and
`agent_threads_versions`: 320 rows from inherited committed fixtures. The other
26 audited agent, terminal, user/token, host/VM, reservation, placement,
operation and access tables remain empty. The full audit SHA-256 is
`9c71952948893c7e849f73043fd654695742b08f3ecd548e7722a6ea28d4eaa3`.
Exact retained IDs, row digests and insertion times are preserved privately in
`/tmp/verify031-residue.log`, SHA-256
`05f9a3cbf4b45fc2c527642aa6a59acda2ddb57aaf66e32f0f6c2da2040e08ca`.
No retained rows are deleted and no database reset is used. Separate improvement 029
must attribute and repair the inherited fixture teardown. All worktree BEAMs,
database connections and advisory locks are absent after the gate.

ADR/HLDD/options/coverage/views, contract format/discovery/coverage and all-file
`prek` (including Ruff, formatting and ty) passed. Nix `hldd` passed in seven
seconds on the frozen tree; its owner drained with exit zero. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790393297215-211477-0.jsonl`.
Final changes after that capture record these outcomes and clarify permutation
counts only. Final diff review found no violation of the inspected contracts and
no architecture impact; ADR-0100/0101 authority and partial acceptance remain.

This scope exercises real HTTP/LiveView and SQL-backed authority with the existing
synthetic capacity/execution fixtures. It does not establish native guest work,
TLS transport, provider availability, independent physical hosts or production
load. Existing native executor interruption and rollout gaps remain in the
[023 review](2026-09-25-agent-cli-verification.md).

## Coordinator integration scope

The implementation is integrated with independently published `951630ee` clone
restart recovery. That upstream change leaves Marshall application modules and
the CLI history/API tests unchanged. The generator file is byte-identical to
tested tree `69c760c7`; the full 1,138-check result retains its captured `8a575060`
base. Upstream Lilly and cloning evidence remains in its own recovery review.
No combined native execution or new Inception validation is claimed.
