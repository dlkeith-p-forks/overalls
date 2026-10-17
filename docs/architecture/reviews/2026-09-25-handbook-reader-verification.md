# Handbook reader authority verification

## Scope and architecture impact

Improvement 005 repairs the authority represented by the native handbook fixture
and extends verification of ADR-0122's current-reader boundary. ADR-0121 remains
superseded; its maintenance and evidence requirements remain inherited. The
current-login requirements inherited through ADR-0022 → ADR-0084 → ADR-0117 and
ADR-0028's colocated contracts remain unchanged. No production
authorization, persistence, protocol, deployment or dependency change is needed.

## Findings and resolution

- **Medium — verification defect:** the old seed created an ordinary user but left
  `AdminBootstrap.completed` false. The first magic-link upsert then promoted that
  reader through `BootstrapAdministrator`. A seed flag did not establish the role
  held during browser operations. The fixture now seeds a distinct unused
  administrator, completes the installation latch, and queries the actual reader's
  persisted role immediately after login and at journey completion.
- **Medium — verification gap:** the old browser's sign-in redirect assertion tested only
  anonymous entry. Application tests covered revoked navigation, but native runs
  did not. The browser now changes exactly its one stored login to revocation,
  clicks another section on the existing connected page, and requires sign-in with
  no handbook content. A separate context retains the pre-revocation cookie and
  must also refuse a fresh section request. This is controlled token invalidation,
  not acceptance of an administrator's revocation UI or cross-replica delivery.
- The original three handbook reviews now explicitly withdraw the native
  ordinary-role inference and preserve their actual renderer/navigation results.
  Historical deployment observations are not reruns of this improvement.
- Generated chapter histories exercise actual LiveViews for ordinary users and
  deterministically cover each of token revocation, expiry and deletion. An
  independent expectation requires one selected body before invalidation and
  refusal of both mounted navigation and a fresh request afterwards. These tests
  use SQL sandbox isolation and do not establish native TLS or kernel behavior.
- **Medium — fixture diagnostic defect:** unguarded Playwright sign-in failures
  could include the bearer URL in their exception call log. The complete login
  navigation and interaction now fail with a fixed diagnostic and suppressed
  exception context. A real aborted request proves that formatted failure output
  contains neither the token nor login URL; unexpected success and unredacted
  errors remain fatal. This is fixture custody evidence, not an exhaustive review
  of application authentication diagnostics.

Source review traced `HLDDLive` through `LiveUserAuth` parameter hooks and
`Login.token_present`: stored user-purpose presence, database expiry and completed
login are already rechecked. No bounded application defect was found in that path.
Local and ancestor contracts were reviewed for fixture isolation, token custody,
fresh authority, bounded section payload and honest verification scope. The seed
contract now describes the administrator needed to model an installed system.

## Validation

Validation started from integrated main `e9a262b0` plus this improvement:

- Generated reader-authority property passed with seed 55005. The focused
  LiveView suite passed all eight checks (one property and seven examples) in
  3.3 seconds. Each of 20 generated histories exercises all three token
  invalidations, for 60 mounted-navigation/fresh-request refusal pairs.
- The full Marshall `mix precommit` passed: 1,019 passed (89 properties and
  930 tests), with two separate exclusions, seed 45677, in 252.6
  seconds. Distributed and JavaScript checks were included. Forced Dialyzer
  reported zero errors, zero skipped findings and zero unnecessary skips.
- Native hldd-browser passed in 54.24 seconds. The ordinary-reader browser
  subtest took 24.06 seconds; full package build and native execution took 340
  seconds. QEMU cleanup completed. Exact tested derivation:
  `/nix/store/4xzg1m3k0ynkg3zxaxx1fcjnqapgdfgz-vm-test-run-kittens-hldd-browser.drv`.
  Output and five screenshots:
  `/nix/store/8k773zn9k897rrwx7g7zpj8704halvd0-vm-test-run-kittens-hldd-browser`.
  Desktop and mobile screenshots were inspected. The run establishes persisted
  ordinary role immediately after login and at completion, every section and
  diagram, and both actual stored-login revocation refusals. Its immutable output
  predates documentation-only recording of these results.
- All-file `prek` (ruff formatting/lint, ty, logging and HLDD review), explicit
  browser `ty` against the pinned Playwright interpreter, contract format and
  discovery, ADR/link checks, generated options/coverage/views, and packaged Nix
  `hldd` passed. The final evidence bookkeeping repeats the structural gates;
  these records do not turn a later documentation revision into a native rerun.

Execution logs are `/tmp/verify005-focused.log`, `/tmp/verify005-precommit.log`,
`/tmp/verify005-static.log`, `/tmp/verify005-extra.log`,
`/tmp/verify005-nix-hldd.log` and `/tmp/verify005-native.log`. The native build log is
`/home/ghuntley/.local/state/nix/build-logs/1790342103359-58797-0.jsonl`.

## Integrated validation

Integration with pushed main `3a898ca3` preserves improvements 003/004 and the
user's static Source code navigation from `d3a84ee8`. New native assertions check
that this link immediately follows HLDD in both Workspace and Control room, has
the exact repository destination and uses ordinary href navigation. They do not
request GitHub. This changes the native assertion scope, so the new native run
below supersedes the original artifact for this combined scope.

- Combined Marshall `mix precommit` passed: **1,026 passed (92 properties and 934
  tests), two excluded**, seed `371491`, in 299.4 seconds. JavaScript checks passed;
  forced Dialyzer reported zero errors, skips and unnecessary skips. The subsequent
  fixture-only login error guard does not change application code or these tests.
- Integrated native hldd-browser passed in 49.65 seconds, including ordinary
  persisted roles, every section/diagram assertion, source-link position and href
  in both signed-in contexts, actual login-error redaction and both revocation
  refusals. The browser subtest took 21.75 seconds; total delta build/run took 60
  seconds. QEMU cleanup completed in 0.47 seconds. Exact tested derivation:
  `/nix/store/nrgwckjhvcranzjyqccsnbqd3pa32pyz-vm-test-run-kittens-hldd-browser.drv`.
  Output and screenshots:
  `/nix/store/lw1v6nx09ps6fx38bp6wxdj97zf65mgg-vm-test-run-kittens-hldd-browser`.
  The desktop screenshot was inspected and shows Source code immediately below
  HLDD. No GitHub request is part of this test.
- The immediately preceding source-link native run passed in 53.32 seconds
  (`/nix/store/wys4nvjac6abrng17qkbly3q1a56dl2d-vm-test-run-kittens-hldd-browser.drv`);
  it does not establish the later login-error guard. The final fixture delta
  reused the same Marshall package and reran the actual native journey.

Combined logs: `/tmp/verify005-combined-precommit.log`,
`/tmp/verify005-navigation-native.log`, `/tmp/verify005-final-native.log` and
`/tmp/verify005-integrated-static.log`. Final native build log:
`/home/ghuntley/.local/state/nix/build-logs/1790344605090-1107967-0.jsonl`.
Reviewed receipt, generated-reference, contract, Python and packaged HLDD gates
also cover the final evidence-only bookkeeping; that bookkeeping is not a new
native execution. The final diff preserves the inherited runtime boundaries and
has no remaining contract mismatch in the inspected paths.

## Remaining limits

The native check uses one source-built Marshall instance, fixture PostgreSQL,
verified HTTPS and Chromium on one NixOS machine. It retains every section,
diagram teardown, history, dark theme, mobile containment, print and public-route
assertion. It does not prove hardware authenticators, multiple replicas, browser
heap limits on other clients, physical guest isolation or semantic accuracy of
every handbook statement. Production deployment is outside this campaign.
