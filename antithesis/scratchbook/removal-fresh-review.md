---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# Fresh independent Antithesis removal review

Reviewed the staged removal-phase diff and the current working-tree validation update in `/home/ghuntley/src/kittens-antithesis-reset`, against baseline `9fe1e493b2090d44bacd16089049cd12b316d58a`. No blocking architecture, code-contract, or HLDD findings were identified.

The scope is retirement of the old `antithesis/` tree, preservation of ordinary Lilly generated tests through a fixture relocation, and accurate historical/current evidence descriptions. The review read root/component guidance, architecture-review, code-contracts and hldd-maintenance skills, ancestor contracts, the architecture overview and decision index, ADR-0017, the changed architecture records, lifecycle/reference chapters, scenario entries, and unchanged domain/topology boundaries. Old research, catalog and mutant contents were not inspected; historical target validation used `git cat-file -e` only.

Architecture impact is limited to test organization and the declared availability of the retired verification harness. No production code, Ash ownership, protocol, persistence format, authorization, execution fencing, isolation, capacity accounting or recovery authority changes. ADR-0017 remains accepted/partial, with its decision and rationale intact. The historical harness and local mutation records are distinguished from pending fresh hosted and mutation evidence. No new or replacement ADR is needed for this removal.

The fixture peer review compared the old and relocated implementations. Reconcile branches, validated state, persistence order, durable launch/attempt markers, stop/delete observation causality, pause handshake, typespecs and the launch-once contract are preserved. The module namespace changes and the old SDK assertion emission is intentionally removed. In an environment with old SDK capture enabled, JSONL telemetry and capture-write error side effects consequently differ; these retired harness effects are not part of the retained ordinary fixture guarantee. Lilly compiles `test/support` only in the test environment. The two consuming test modules now use the relocated fixture through ordinary compilation. Exhaustive namespace search found three direct reconcile calls, eleven reads and four executor-injection sites in those two modules, with two aliases; no maintained old fixture/SDK namespace or removed support-loading reference remains.

Independent source checks verified 18 architecture archive-link occurrences covering 15 distinct targets, all existing at the full captured baseline and using the repository's configured GitHub origin. External GitHub availability was not tested. The scenario ledger is byte-identical to baseline; all four actor and one fake-command property names match baseline, and all three retained scenario evidence entries resolve to exact current assertion and historical record text. Their controlled-executor scope and native/hosted gaps remain explicit. HLDD chapters 04 and 17 describe retirement accurately; unchanged ownership/topology/security boundaries require no new inventory or scenario claim.

Checks run during this fresh review passed: staged and unstaged `git diff --check`; archive existence and exact assertion/record comparisons; pinned contract format/discovery for the moved fixture and both consumers (127 CONTRACTS files, 2712 native notes, 264 parsed sources; 2751 maintained files); `elixir scripts/check_adrs.exs` (156 decisions, structural/local-link checks); and `elixir scripts/check_hldd.exs` (current review receipts/references). No repository edits or receipt refresh occurred during this review.

Lilly 559 passing cases and forced Dialyzer, root generated/static checks, 19 contract-tool regression checks, and Nix HLDD output `/nix/store/zkxmw9dh7wb9vyd1rs8h932kafh04z4i-overalls-hldd-check` are author-supplied current validation evidence, not suite reruns by this reviewer. Marshall's full precommit remained pending at review time and must pass and be recorded/restaged before the authorized removal commit. This review establishes no fresh Antithesis harness, hosted run, mutation verdict, native isolation, deployment or production acceptance.
