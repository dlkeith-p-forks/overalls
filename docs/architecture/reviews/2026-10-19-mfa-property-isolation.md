# MFA property fixture isolation review

## Scope and decision impact

This review covers
`marshall/test/marshall_web/mfa_login_history_test.exs`. There is no architecture
change: the correction applies ADR-0191's existing per-generated-case fixture
isolation requirement. Production authentication, authorization, persistence
schemas and native-browser behavior are unchanged.

The property retains 100 generated histories, the five fixed ceremony steps,
the bounded generated suffix, both independent login models, real signed
assertions and all mounted/read/export/revocation oracles.

## Diagnosis and correction

Commit `6fad4d34760f963464bf5dc0db66a220f5df4da9` restored 100 histories while
retaining a 240-second aggregate timeout and a comment describing twenty
histories. The test also retained one SQL sandbox for the entire Hegel run,
accumulating users, tokens, passkeys and audit rows between generated cases and
replays. That violates fixture independence and changes the user inventory seen
by later histories.

The integrated run captured in `/tmp/localization-marshall-full-test-final.log`
timed out at 240 seconds during ordinary stored-login and elevation reads. Its
stack crosses `Ash.Query.ensure_selected`, `Login.token_lookup`,
`Security.recent?` and the Cedar principal projection. These reads are expected
authentication checks; the observed stack does not establish authorization
recursion. Authentication and authorization source was unchanged by this fix.

The correction uses the existing synchronous `:hegel_case_sandbox` tag and
`Marshall.DataCase.isolate_property_case/0` before each generated case's draws
and fixtures. The helper registers Hegel cleanup and an ExUnit timeout fallback
for the exact SQL owner. Each history rolls its rows back before replay or the
next case; the existing helper retains its finite configured owner timeout.
The old test-wide `ownership_timeout` override is removed without changing the
shared helper or its 240-second override contract.

Every successful LiveView mount now registers its exact PID for Hegel cleanup
before returning to either a positive or expected-refusal assertion. This
includes a refused route unexpectedly mounting successfully: its channel is
registered before the refusal oracle can fail. The helper retains each caller's
original mount result and every existing assertion. Explicit success-path stops
and replay cleanup use the same finite five-second stop, tolerating only an
already stopped PID. Other cleanup failures remain failures. The pinned Hegel
frontend prepends cleanup callbacks and runs them after every attempted case,
including failed histories and replay. Because SQL ownership is registered first
and views afterward, channel cleanup runs before SQL rollback. The ExUnit test
supervisor alone would retain those channels until the whole test exited.

The recorded historical twenty-history execution took 91.7 seconds with seed
`922579` at `c5747868`. A linear estimate for the restored 100-history budget is
458.5 seconds. The new finite 600-second aggregate timeout adds approximately
31% load margin without changing per-operation deadlines or exploration
strength. The historical execution is evidence for sizing only, not a passing
execution of the corrected fixture lifecycle.

## Verification and evidence limits

Source review confirms the generator, fixed history, case count, model and
oracles are unchanged. Pinned-shell Elixir parsing and formatting checks passed;
the contract adapter discovers the local contracts and their ancestor scopes,
and repository contract syntax/coverage validation passed (150 `CONTRACTS`
files, 3,579 native notes, 477 parsed source files and 3,567 maintained source
files). These structural checks do not establish runtime fixture isolation.
Fresh tagged Covenant execution separately passed 36 tests in 3.0 seconds with
seed `524458`; static and recorded-result checks confirmed 36 of 36 obligations.
That contract suite does not execute this corrected 100-history property.
Scenario chapter regeneration and its read-only check passed, preserving the
independently reviewed firmware scenario changes. `git diff --check` passed.

The isolated six-suite run with seed `562021` passed 76 of 77 tests in 681.9
seconds; the earlier MFA source alone reached its finite 600-second timeout.
That process used the environment's default schedulers and 64 maximum ExUnit
cases. After the final LiveView cleanup correction, a retry with four schedulers
and seed `693066` again reached 600 seconds while mounting an authenticated
read route. The combined MFA/suspension target passed 5 of 7 tests in 600.5
seconds. The other failure is the imported suspension state-machine invariant,
outside this authentication fixture change. Neither timeout establishes a
failed authorization oracle, a completed 100-history run or an adequate current
aggregate budget. The historical sizing estimate is insufficient evidence of
current runtime completion; further measured diagnosis remains open.

The normal Marshall precommit gate has no recorded passing result. Static gates
and the interrupted broad-suite failure retain their separate scopes in the
[localization review](2026-10-19-localization-feature-catalogs.md). No passing
execution of this correction is claimed here.

The scenario ledger preserves the historical `c5747868` execution and explicitly
separates it from the corrected 100-history attempts and their timeouts. No native,
physical isolation, multi-host, hardware-authenticator or production-deployment
claim follows from this BEAM property.
