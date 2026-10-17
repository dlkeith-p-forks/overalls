---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Fresh property discovery briefing

Read `../sut-analysis.md` and `../existing-assertions.md` before proposing
properties. Read root guidance, relevant component guidance, ancestor CONTRACTS,
local source notes and current accepted ADR chains. The research skill's
`references/property-catalog.md`, `property-discovery.md` and
`validating-claims.md` govern output. User scope answer is verbatim
"Repository only (Recommended)", external references are empty. Official
Antithesis docs may ground product mechanics. Retired artifacts are not inputs.

Whole-repository scope includes eight apps, protocol/diagnostics/accounting,
native helpers, Lyra, guest terminal/editor, browser, backup/updater and Nix.
Keep real service, real TCG guest/storage and native machine scopes separate.
Accepted claims are properties to test, not established guarantees. A permanent
refusal or an uncertain effect is not automatically a SUT defect. Preserve real
supervision and physical custody in workloads.

Root assigns one independent focus. Do not spawn more agents: the session has
already created its authorized hundred threads and is reusing them. Produce
concrete source-grounded properties through your focus. Prefer a compact set of
high-value independent invariants over repetitions, while preserving unique
finds even when other focus coverage is likely. Include meaningful progress and
reach claims where appropriate, not just safety.

Own only `discovery/property-focus-NN.md` and
`discovery/property-candidates-NN/{slug}.md`. A candidate file is detailed
evidence: exact paths/functions/lines, failure history, independent oracle,
workload preconditions, configured-limit value menu, SUT branch/replay guidance,
environment and scope limits, priority, confidence and open questions. Every
planned Antithesis assertion is missing at present; explicitly reference the
fresh existing-assertions scan. Give literal unique proposed message and correct
Always/AlwaysOrUnreachable/Sometimes/Reachable/Unreachable rationale. Never use
Sometimes(true), a reach claim that asserts a violation, or an aggregate ExUnit
suite exit as the oracle. Do not write mutant patches before green baseline.

The focus report returns properties in the standard catalog table format, each
with canonical candidate slug, priority and confidence, evidence-relative link
and open questions mirrored from evidence. Source-resolvable questions should
remain visible until investigation; do not claim human input is needed without
an investigation log. Distinguish an unresolved hypothesis from a confirmed
defect. Record inspected breadth and material limits. Checkpoint output early.
Do not edit production files, shared catalog, handbook, governance receipts or
another agent's candidates. Root handles synthesis and deduplication.
