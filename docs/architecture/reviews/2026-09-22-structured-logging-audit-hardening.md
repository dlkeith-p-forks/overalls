# Structured logging and audit hardening

Date: 2026-09-22

## Scope and evidence

This review covered the preceding seven days of Git history and every tracked Rust
and Elixir source file. It concentrated on diagnostic closure, actor attribution,
durable authority receipts, privacy and bounded retention. The implementation
evidence is the Marshall/Lilly event catalogs, `Compute.Ledger`, all thirty current
PaperTrail resources, the retention worker, the team and Galileo coordinators,
inference admission/completion, Lilly workload bundles, terminald and the shared
logging gate.

Affected decisions are ADR-0028, ADR-0042, ADR-0074, ADR-0077 and ADR-0082. The
changes implement their accepted rationale; they do not change a domain boundary,
protocol, authorization rule, retention duration or diagnostic destination.

## Findings and resolutions

- High: PaperTrail had no uniform initiating-actor metadata and its default could
  display sensitive attributes. Every current version resource now declares
  nullable `actor_kind`/`actor_id` metadata and `sensitive_attributes :ignore`.
  Ledger propagates user, system, provisioner or operator attribution separately
  from its internal `SystemActor`. The additive migration leaves historical rows
  unattributed rather than inventing provenance.
- High: the retention allowlist omitted team, Galileo, terminal and environment
  version tables. The complete current inventory plus retained legacy writer
  history is now bounded by the existing global 1000-row/90-day policy, with an
  introspection regression test for metadata, privacy and inventory coverage.
  Removed writer history is optional on fresh installations but still expired
  when present after an upgrade; current version tables remain mandatory.
- High: team and secret-bearing Galileo authority mutations had diagnostics but
  no transactional business receipt. They now append payload-free `AdminEvent`
  rows in the same transaction. Rollback therefore removes mutation and receipt.
- Medium: inference admission/completion and Lilly workload bundle publication
  lacked catalogued outcomes. They now emit success/refusal events only after the
  operation returns, using safe IDs and closed reasons. Renewal remains quiet.
- Medium: terminal attachment, team transfer and Galileo diagnostics lacked actor
  or session correlation. The reviewed catalogs and call sites now include it.
- Medium: SSH's trusted `SystemActor` was being passed through as if it were an
  audit identity. SSH now keeps it solely as the authorization principal and
  classifies operator configuration, system runtime and real user transactions
  independently for nested audit writes.
- High: terminald accepted arbitrary event names, keys and string values. A closed
  Rust enum now fixes names, levels, messages and typed fields, adds placement and
  execution correlation, and retains the no-terminal-bytes contract. Crate Clippy
  denies prevent print/debug macro bypasses.
- Medium: the structural Elixir gate ignored runtime `.exs` files and did not
  recognize the newly audited mutation names. It now scans application config and
  runtime sources while continuing to exclude script protocol stdout.

Porsche remains identity-minimal as accepted by ADR-0042. Token minters and
internal issuance helpers retain their documented exemptions because duplicate
secret-adjacent diagnostics would weaken rather than improve the reviewed surface.

## Verification performed

The additive Ash migration and thirty resource snapshots were generated with the
pinned Elixir/OTP environment; `mix ash_postgres.generate_migrations --check`
reports no drift. Marshall and Lilly compile with warnings as errors. Focused
Marshall suites passed for PaperTrail policy, inference, teams, Galileo,
lifecycle/terminal retention, SSH authority, gateway transport and administrator
receipts. The focused Lilly workload-bundle test passed.

All seven structural logging checks passed (Marshall 125, Lilly 69, Audi 34,
Brady 8, Ziggy 15, Galileo 5 and Porsche 7 catalogued events). The ADR checker
passed 90 decisions. Code-contract format/coverage passed 92 `CONTRACTS` files,
1,445 native notes and 1,791 maintained files; its 19 regression tests passed.
Marshall and Lilly forced Dialyzer runs completed with zero findings. Both
Marshall browser suites passed. The terminald Nix check passed, including Rust
formatting, Clippy and tests. `git diff --check` passed.

The full Marshall test phase reached 840/849 passing. Five failures were stale
administrator-test assumptions that the expanded shared authority log contained
only administrator receipts; those assertions were narrowed and their nine-test
suite then passed on a fresh database. The remaining four failures require native
helpers unavailable in the sample-host shell (`openssl`, the ingress connector,
transfer SSH key preparation and export-permit confirmation). Lilly's full
precommit test phase similarly hit 187 host-lock/native-helper failures, while
its focused changed test and forced Dialyzer passed. `prek run --all-files` could
not run because the repository has neither `prek.toml` nor
`.pre-commit-config.yaml`, including when `prek` was fetched directly with Nix.

## Remaining gaps

Live log-provider delivery, provider-side retention/search and fleet runtime
acceptance remain deployment evidence, not properties established by unit tests.
Historical PaperTrail rows intentionally remain unattributed. The lexical logging
gate still cannot prove semantic event sufficiency; runtime tests and review remain
required.
