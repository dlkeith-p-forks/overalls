# Configured Hegel evidence recognition

## Scope and architecture assessment

Improvement 033 begins at published `2d66e76d` in the dedicated
`verify/033-hldd-hegel-attributes` branch and integrates published `c12a73e6`
before its full gate. Improvement 028 exposed an HLDD
evidence rejection for real `#[hegel::test(test_cases = 8)]` and
`#[hegel::test(test_cases = 4)]` attributes in its guest-supervisor tests.
The checker previously recognized only the literal bare attribute.

No architecture impact: ADR-0122 carries forward ADR-0121's structural evidence
classification and reviewed execution boundaries. This repair changes lexical
runner recognition only; it introduces no application, authority, protocol,
persistence, dependency or deployment change. Existing native evidence retains
its original scope. No native or Inception validation is performed here.

## Repair and contract review

Reviewed the root, scripts, Marshall, test and documentation contracts, the
coverage validator and its callers, and the pinned Hegel 0.28.8 macro's
`SettingsAttrArgs` parser. Hegel accepts a bare or empty invocation, named
options, an initial settings expression, trailing commas and Rust whitespace.
The evidence check recognizes the exact `hegel::test` path and closed bare or
parenthesized attribute. Nested settings calls are permitted. Rust compilation
still validates option expressions and the annotated function; this checker is
not a Rust parser and does not establish an effective property assertion.

The new local contract preserves the exact macro boundary and the distinction
between lexical recognition, execution and native evidence. The validator's
local-path, assertion-text, recorded-result and machine-path requirements remain
unchanged. Existing ExUnit, proptest and Hypothesis markers remain recognized.
No contract is weakened. The handbook reference explains these limits; no user
scenario gains execution evidence or changes coverage status from this repair.

## Execution record

The regression uses disposable source files and scenario
rows, including configured and multiline attributes, macro-name near misses,
malformed delimiters, generated counts/whitespace and independent evidence
requirements. The unmodified validator fails the new fixed and generated tests
at seed `33001`: 10/12 pass, with one test and one property failure, in 1.9 seconds.
The corrected validator passes all 12 checks (4 properties, 8 tests), same seed,
in 1.4 seconds. These focused runs load the standalone validator with pinned
Elixir 1.20.4 and StreamData 1.4.0. Logs are
`/tmp/verify033-baseline-configured.log` and
`/tmp/verify033-focused-standalone.log`; sessions drained with exits 2 and 0.
Two earlier standalone bootstrap attempts lacked StreamData loading/configuration;
their logs remain separate and are not the defect reproduction.

The full Marshall suite on frozen tree
`c48f2bc3f10f46214c699703edfc04a946b6347f`, based on `c12a73e6`, passes
**1,170 checks (132 properties, 1,038 tests)**, with two exclusions,
seed `713483`, in 674.7 seconds (32.1 async, 642.6 sync). Distributed tests are
included. The 28 terminal browser-state checks, four dashboard checks and
workspace TypeScript gate also pass. Forced Dialyzer reports zero errors, skips
or unnecessary skips in 1m7.53s, after a 4m5.56s private PLT rebuild. Full
`mix precommit` exits zero and its session is drained. Log:
`/tmp/verify033-full-gate.log`.

The standalone coverage checker also passes direct Dialyzer with zero warnings
in 12.672808 seconds. Its exact compiled BEAM is analyzed against a private copy
of the pinned dependency PLT, so this source script is checked independently of
Marshall's application BEAM scan. Log: `/tmp/verify033-checker-types.log`;
session drained with exit zero. Frozen source SHA-256 values are:

- `scripts/hldd/coverage.ex`:
  `694d36d6d037f2d7d712c2f0443090487e0484caf4ab56d961f1ab61fee5e88b`.
- `marshall/test/architecture/hldd_test.exs`:
  `68f9bc20aa10d7fb194c2d7c5eb4a31a3c0f94e4b806fedbfd316be306afd2aa`.

All-file `prek` (including Ruff formatting/lint and ty), contract
format/discovery, ADR/HLDD and generated options/coverage/views pass. The frozen
Nix `hldd` and `python-static` checks pass in 23 seconds; the session drained with
exit zero. Log: `/tmp/verify033-static-gate.log`; compact archive:
`/home/ghuntley/.local/state/nix/build-logs/1790396398384-977823-0.jsonl`.

The isolated writable caches and fresh `marshall_testverify033` partition
preserve before/after inventories. Before execution, all public tables are empty
except the one seeded bootstrap row and 138 migration rows. The complete initial
table counts/digests and id-bearing row IDs/digests are retained in
`/tmp/verify033-before-full-audit.log`, SHA-256
`b75872ae013160a5ee1e45c314ed44970c053813750eb2b2430987bb25a2091e`.
The database did not exist before setup; no database reset or older campaign-row
deletion is used.

The final audit covers all 138 public tables. The bootstrap and migration rows
retain their complete digests; 128 other tables remain empty. The inherited
full-suite fixtures leave 63 rows each in `agent_audit_events`, `agent_roots`,
`agent_roots_versions`, `agent_threads` and `agent_threads_versions` (315 rows).
The expanded audit also observes 193 `admin_job_events`, 185
`admin_job_snapshots` and 468 `compute_lifecycle_events` rows (846 rows).
Earlier campaign audits covered a narrower table set; these additional retained
rows are not attributed to the checker repair. All 1,161 rows remain available
for the separate fixture-cleanup investigation. Exact IDs and row digests are
retained in `/tmp/verify033-after-full-audit.log`, SHA-256
`dfc4ddf685db353059b60071ce9407ef6cbe44bc12eb20f958d6c0ba9cde474c`.
No database connections or advisory locks remain after the gate.

Final contract and architecture review preserves ADR-0122's evidence boundaries;
no accepted decision or implementation status changes. Later result bookkeeping
does not change the frozen checker or regression source. This verifies structural
recognition, not the separate guest-supervisor recovery scenarios in 028.
