# Code contracts adoption review

## Scope and architectural impact

The user requested structured assumptions and requirements beside all existing
repository code, with parallel implementation/review. Three agents backfilled
Marshall domains, Lilly/shared protocol and Nix/Web/deployment boundaries; the
coordinating agent implemented tooling, scripts/tests and governance integration.

[ADR-0028](../decisions/0028-colocated-code-contracts.md) adds the development
verification contract. This extends ADR-0001 governance and ADR-0002/0009 assurance.
Source annotations preserve the product and architecture requirements recorded
in ADRs 0003–0027. They do not complete those decisions' remaining infrastructure,
multi-host or load acceptance obligations.

The initial repository was entirely untracked, so git diff was not sufficient.
A starting source snapshot was retained under /tmp for comparison. Of 355
pre-existing Elixir files, 349 have identical parsed ASTs after removing source
metadata. The three Mix changes add the contract gate. The other three changed
ASTs belong to concurrent database durability/fixture work, now recorded separately
under ADR-0029; that work was preserved. Contract backfill itself changes comments,
directory requirements, verification tooling and documentation.

## Contract evidence and review

The [guide](../../code-contracts.md) describes scope, syntax, ownership and limits.
The final structural inventory inspected 385 maintained source files, 42 directory
contract files, 306 native source notes and six files with supported documentation
contracts. The precommit runs preceded the concurrent addition of the database
recovery acceptance script and inspected 384 sources. The inventory includes
nonignored untracked source. Counts establish
discoverability and scoped coverage, not completeness of every possible invariant.

Source and critical callers were inspected for admission/reservation atomicity,
generation/outcome authority, sharing/Cedar/login freshness, terminal input and
output fencing, retained telemetry, encrypted email/credentials, privileged host
operations, independent guest lifetime, protocol bounds and Nix/service boundaries.
Directory rules cover generated components, migrations/snapshots, vendored assets,
tests and scripts without rewriting third-party implementation. Native notes
remain adjacent source requirements, not inferred AST-scoped declarations.

The concurrently added database recovery script received a separate read-only
review of its seven local contracts and inherited fixture requirements. No
concrete mismatch was found in promotion fencing, replication-before-traffic,
isolated restore or ownership-checked cleanup. Its real acceptance execution
belongs to ADR-0029 and was not performed by this contract-adoption task.

## Findings and disposition

1. **High — upstream language exclusions could silently omit most code — fixed.**
   Upstream 0.2.0 rejects Elixir/Nix/C/shell and JavaScript extensions. The
   [adapter](../../../scripts/check_contracts.mjs) projects native documentation
   into standard CONTRACTS and byte-identical JavaScript into TypeScript suffixes.
   Original paths/lines are retained. Actual terminal discovery finds all twelve
   JSDoc method contracts with their ancestor requirements. Native discovery was
   verified on Nix, Admission, Console.Gate and TerminalLive.
2. **Medium — structural false passes in the initial adapter — fixed.**
   Independent review reproduced string literals counted as coverage, skipped
   vendor contract directories, malformed later notes absorbed as prior prose,
   JS/TS projection filename collisions, incorrect opening-line C normalization
   and symlink traversal. The final adapter uses upstream document extraction,
   collision-free encoded projection paths, independent document checks plus
   file-local uniqueness, and preflight of every discovery route. Each case has
   a [regression test](../../../scripts/test/check_contracts_test.mjs).
3. **Medium — static contract document became a public asset — fixed.**
   A contract initially placed in priv/static was picked up by a concurrent asset
   build. It now lives in [priv/CONTRACTS](../../../marshall/priv/CONTRACTS).
   Only the task-created source/release static documents and their exact digest
   manifest entries were removed. Both generated static trees and manifests were
   checked for absence of those artifacts. Nonstatic priv contracts are inert
   files; existing consumers select migration, schema and policy filenames.
4. **Existing guidance discrepancy — surfaced, unchanged.**
   [The page layout](../../../marshall/lib/marshall_web/components/layouts/root.html.heex)
   contains an inline theme script, whereas Marshall AGENTS.md forbids inline
   scripts. This predates adoption and does not contradict the scoped terminal
   renderer contract. It remains an explicit guidance/implementation follow-up;
   the backfill does not silently bless or alter theme initialization behavior.
5. **Tooling guarantees are limited deliberately.**
   Native source-note extraction is lexical, not a parser or language server.
   Native listing gives every note in a file and ancestor CONTRACTS; authors must
   inspect declaration attachment and called symbols. The pinned internal
   upstream extraction interface is regression-tested and version-checked.
   Structural success never establishes semantic compliance or runtime safety.

## Verification performed

- `mix precommit` passes in protocol: 22 cases (11 properties, 11 tests), compiler,
  format, runtime, ADR and Dialyzer gates; zero analysis errors/exclusions.
- `mix precommit` passes in Lilly: 84 cases (19 properties, 65 tests), compiler,
  format, runtime, ADR and forced Dialyzer; zero analysis errors/exclusions.
- `mix precommit` passes in Marshall: 218 cases (23 properties, 195 tests), including
  three-node tests; four opt-in host cases excluded. Six browser-state tests pass.
  Forced Dialyzer retains exactly the documented upstream typespec exclusion,
  with no unused exclusions. `mix assets.build` passes.
- Each project runs the contract syntax/coverage check and all 19 checker
  regression tests through the shared [Mix bridge](../../../scripts/check_contracts.exs).
- All six Nix expressions parse. Shared Elixir formatting passes. Python acceptance
  scripts parse without execution. The ADR structural checker validates 29
  records and their local links, including concurrent ADR-0029.
- Native/C and JavaScript negative fixtures prove malformed inputs fail. Fixture
  checks prove original source remains unchanged; temporary projections are
  cleaned on success and failure. JavaScript and native file discovery include
  correct ancestor contracts and original source provenance.

No KVM, SMTP, fleet-load or production failure-domain acceptance was rerun for
this annotation/tooling change. Existing acceptance records retain their stated
scope. ADR-0028 is implemented for the selected local workflow; external review
notifications and hosted CI were not selected or installed.
