# Handbook scenario close-out

## Scope and architecture impact

Campaign improvement 073 is a review-only reconciliation of the `handbook`
scenario row in `marshall/priv/hldd/scenarios.json` with the merged 005
(handbook reader), 007 (subsequent MFA login and cross-replica revocation), 015
(standalone browser type gates) and 033 (configured Hegel evidence attribute)
records. Base: published main `c14ae27dc0fbbca400e73ae5c6f1567104ab9801`
(`docs: record verification 020 integration`).

Architecture impact: documentation only. No production code, runtime, domain,
protocol, authorization, persistence, dependency or deployment change. ADR-0121
remains superseded by ADR-0122 (accepted, implementation implemented); neither
status nor implementation changes. `scripts/check_adrs.exs` passes 124
decisions, confirming no decision-structure drift. No new native, Inception or
provider validation is claimed.

## Inspected evidence and consistency findings

Each `handbook` scenario-row claim was traced to current source:

- **machine, recorded** (`nix/verification/tests/machines/hldd/browser.py` stale-page sign-in
  assertion): current at browser.py:209-223 — `revoke_reader()` changes the
  actual stored token purpose; the mounted page's next navigation lands on
  `/sign-in` (browser.py:216-218) and a fresh deep link carrying the
  pre-revocation cookie is refused in a separate context (browser.py:219-222).
  The record ("Integrated native hldd-browser passed in 49.65 seconds") matches
  the 005 review's integrated validation with derivation
  `/nix/store/nrgwckjhvcranzjyqccsnbqd3pa32pyz-vm-test-run-overalls-hldd-browser.drv`.
  Consistent; retains its original single-instance source and scope.
- **property, recorded** (`marshall/test/marshall_web/hldd_live_test.exs`
  "ordinary reader chapter histories lose revoked expired and deleted login
  authority"): current at hldd_live_test.exs:84-117 — ordinary non-administrator
  readers (:95-96), generated chapter sequences (:88-93) followed by each of
  revoke/expire/delete invalidation (:94, :119-135), with mounted navigation and
  fresh-request refusal assertions (:110-114). The scouting prompt cited a
  `live/` subdirectory; the ledger path
  `marshall/test/marshall_web/hldd_live_test.exs` is the actual location and is
  already correct. Matches the 005 record ("Generated reader-authority property
  passed with seed 55005").
- **property, present**: exact assertion texts verified at
  `marshall/test/architecture/hldd_test.exs:31` (receipt invalidation),
  `marshall/test/marshall/handbook_test.exs:17` (unknown identifiers fail
  closed), and `marshall/test/architecture/hldd_views_test.exs:22,59` (domain/
  ownership and evaluated topology snapshot invalidation).
- **machine, recorded** (Source code link): current at browser.py:56-66 under
  contract `handbook-source-code-navigation` — HLDD adjacency, exact repository
  href, ordinary href navigation and no GitHub request.
- Delivery-boundary contracts are declared at source:
  `handbook-contents-metadata` (marshall/lib/marshall/handbook.ex:37-41),
  `handbook-current-reader` and `handbook-section-payload`
  (marshall/lib/marshall_web/live/hldd_live.ex:7-9, 16-19, 23-43), including the
  unknown-identifier redirect at hldd_live.ex:37-39. The index-body and
  navigation-hook assertions at hldd_live_test.exs:22-23 and :51 match those
  contracts. The 22 chapter files are consistent with the native bound
  `len(sections) >= 22` (browser.py:151) and the diagram bound at
  browser.py:159.
- **015 typed helper**: `checkedBrowser` (nix/verification/tests/machines/hldd/default.nix:4-13)
  type-checks the executed copied bytes and runs in the actual native subtest
  command (:45); the catalog export is at nix/verification/tests/catalog.nix:39. Rebuilding
  `.#checks.x86_64-linux.hldd-browser.checkedBrowser` on this tree reuses
  `/nix/store/k1pml4qqwx0pk806v7ab5wmg2mnnndpf-hldd-browser-typed`, byte-identical
  to the artifact recorded in
  [2026-09-25-browser-type-gates](2026-09-25-browser-type-gates.md). Consistent.
- **033 validator change**: lexical Hegel attribute recognition only; no
  scenario row gained or lost evidence. No impact on this row.

## Corrections made

- `scenarios.json` `handbook` gaps wording was stale: "cross-replica revocation
  and the revocation administration UI are separate" pre-dated improvement 007.
  It now states that three-replica revocation delivered through the
  administration UI is recorded for the `login` journey in
  [2026-09-25-mfa-login-verification](2026-09-25-mfa-login-verification.md)
  (machine evidence `nix/verification/tests/machines/mfa-login/browser.py`,
  "final mfa-login-browser passed", 57.20 seconds on its captured source) and
  belongs to that scenario. The handbook native journey remains honestly
  single-instance; the `preferred_gap` text already assigned multi-replica and
  hardware-authenticator acceptance to the login journey and is unchanged.
- `19-coverage.md` regenerated with `scripts/hldd_coverage.exs --write`; the
  diff is confined to that one gaps sentence.
- Remaining boundaries retained unchanged: GitHub live availability is excluded
  (link metadata only, no external request); per-client heap profiling stays out
  of scope; physical authenticators are not exercised; the fixture login-error
  custody check is not exhaustive production authentication-diagnostic
  acceptance; handbook prose semantic correctness is not proven. Status stays
  `partial` (four evidence entries remain `present`, not recorded).

## Validation performed on this tree

Pinned devenv Elixir 1.20.4/OTP 29.0.6; `ERL_FLAGS='+S 4:4'`,
`MIX_TEST_PARTITION=verify073`, `PGHOST=/run/user/1000/devenv-0e19ff2/postgres`,
`TMPDIR=/tmp/overalls-verify073`:

- `mix test test/marshall_web/hldd_live_test.exs --seed 0`: **8 passed
  (1 property, 7 tests)** in 2.6 seconds.
- `mix test test/architecture/hldd_test.exs
  test/architecture/hldd_views_test.exs test/marshall/handbook_test.exs
  --seed 0`: **22 passed (7 properties, 15 tests)** in 1.7 seconds.
- `nix build .#checks.x86_64-linux.hldd-browser.checkedBrowser`: passed,
  reusing the 015 store path above; pinned `ty` against packaged Python
  3.13/Playwright; no QEMU or native run.
- `mix contracts.check` (102 CONTRACTS files, 1,814 native notes, 125 parsed
  sources) and `mix logging.check` (marshall OK, 147 catalogued events) pass;
  structural checks only.
- `mix compile --warnings-as-errors` and `mix format` leave the tree without
  drift beyond the two intended documentation files.
- `mix test --include distributed --warnings-as-errors`: **1,187 passed
  (138 properties, 1,049 tests), two excluded**, seed `404113`, in 674.8
  seconds.
- `mix terminal.check`, `mix dashboard.check`, `mix workspace.check` pass
  (browser terminal, dashboard and workspace project checks).
- `mix dialyzer --force-check`: **0 errors, 0 skipped, 0 unnecessary skips**
  in 51.14 seconds.
- `elixir scripts/check_adrs.exs` passes (124 decisions; structure and local
  links only). `hldd_options.exs --check`, `hldd_coverage.exs --check` and
  `hldd_views.exs --check` pass on the edited tree.

Logs: `/tmp/overalls-verify073/heavy-gate.log` plus focused-suite output.
Review receipts (`marshall` updated; `lilly`, `services` and `deployment`
no-impact; `governance` updated for this record, the index and the ledger row)
are recorded after all documentation edits; `check_hldd.exs`, all-file `prek`
and the Nix `hldd` check are rerun on the recorded tree as final gates. These
confirm receipts and rendering, not a native rerun.

## Remaining limits

No new application, native or external evidence is produced by this close-out.
The 005 native record (49.65 seconds on its integrated source) and the 007
native record (57.20 seconds on its captured source) retain their exact
revisions and scopes. GitHub live availability, per-client heap measurement,
physical hardware authenticators, exhaustive production authentication
diagnostics and handbook prose semantic proof remain unverified as documented
in the row. Production deployment is outside the campaign.
