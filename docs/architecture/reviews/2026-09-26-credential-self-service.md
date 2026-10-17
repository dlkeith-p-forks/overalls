# Credential self-service verification (improvement 111)

## Scope and architecture impact

This improvement verifies the account-scoped credential self-service lifecycle:
passkey rename/remove/verify/lock/register on `/settings/security`, the
ten-passkey bound, and the one-hundred SSH-key bound on `/settings/ssh-keys`.
It preserves ADR-0065's five-minute elevation and last-administrator protection,
ADR-0119's read/mutation split and ADR-0123's sign-out/token-revocation
semantics. One bounded defect is repaired (see Findings); no protocol, schema,
domain or deployment boundary changes.

## Findings

**D1 (reproduced, repaired).** A rename request whose label was missing, nil,
blank-only, over 80 characters or not a string reached
`Ledger.update!` in the
[security coordinator](../../../marshall/lib/marshall/accounts/security.ex)
unvalidated. The Ash constraint violation raised `Ash.Error.Invalid` out of
`Ledger.transaction` and the generic action, so every
`/settings/security` rename with such a label crashed the LiveView process
instead of refusing. The failure landed in the view's generic error clause, so
even a non-crashing shape would have misattributed it to missing elevation.
SecurityCoordinator now validates the label as a closed `:invalid_label`
refusal before any credential write, and the
[Security UI](../../../marshall/lib/marshall_web/live/security_live.ex) copy
names the refusal classes (name bound, fresh verification and administrator
last-passkey rule). Failing reproduction first, minimal fix, then regression
tests at domain and LiveView layers; see the mutant table for the gate check.

**D2 (pinned as intended).** Removing the credential that proves the current
elevation makes `Security.recent?/1` false immediately (the verification row
dangles) while the login and remaining credentials survive. This is ADR-0065's
"removal of the proving credential invalidates relevant authority" and is now
pinned at unit, generated-history and native layers.

**D3 (not reproduced).** `begin_register`/`finish_register` re-check the
credential limit inside the account-locked transaction; a challenge issued
under the ten-passkey limit refuses closed at `:credential_limit` when the
limit is reached, is not consumed, and stays usable after the inventory drops
below the limit within its 60-second lifetime. No divergence found.

## Evidence and reviewed boundaries

[Generated credential histories](../../../marshall/test/marshall/accounts/credential_history_test.exs)
drive the real security action for administrator and ordinary accounts through
generated rename/remove/verify/lock/register/revoke-login sequences. An
independent model tracks login liveness, elevation, credential labels,
MFA state/generation, retained challenge count and token presence; refused
steps must leave the passkey, verification, token, challenge and audit tables
byte-identical.

[Domain regressions](../../../marshall/test/marshall/accounts/security_credential_test.exs)
pin D1's closed refusal classes, rename keeping elevation and audit stability,
proving/non-proving/second-to-last/last removal semantics including the
generation bump and full token revocation, administrator last-passkey refusal
(until a second passkey exists), locked-elevation and signed-out stale-actor
refusals, the ten-passkey begin/finish bound with retained-challenge reuse, and
failed registration never enabling MFA with its challenge consumed.
[LiveView regressions](../../../marshall/test/marshall_web/security_live_test.exs)
cover rename, exact-80 acceptance, the corrected refusal copy, unknown
credentials, locked elevation and the administrator refusal without a view
crash. [SSH key bounds](../../../marshall/test/marshall/ssh/key_test.exs)
cover the hundred-key limit with closed refusal and re-admission.

[Native browser journey](../../../nix/verification/tests/machines/credential-self-service/browser.py)
uses packaged Marshall, HAProxy, PostgreSQL and Chromium in one NixOS VM with
verified TLS and virtual WebAuthn authenticators (Chrome permits one internal
authenticator at a time; each enrollment swaps authenticators). It enrolls two
passkeys, renames the proving credential, removes the proving credential and
observes immediate elevation loss from an already mounted Control room page,
re-verifies with the surviving credential, renames and removes a non-proving
credential while a mounted administrator mutation still succeeds, hits the
administrator last-passkey refusal with a byte-identical database inventory,
signs out and refuses the stale mounted view, then removes an ordinary
account's only passkey and observes MFA disabled, its generation advanced,
every token revoked and the very session that issued the removal invalidated.
Final assertions read PostgreSQL directly. Virtual authenticators do not
establish hardware-authenticator acceptance; one colocated replica makes no
cross-replica claim.

## Mutant checks

| Mutant | Injection | Oracle |
| --- | --- | --- |
| `recent?` elevation gate removed from rename/remove | delete `unless recent?(actor), do: Ledger.rollback(:mfa_required)` in `perform(:rename/:remove)` | **Fired**: `credential_history_test.exs` property fails (refusal expected after `:lock` with byte-identical snapshot), "locked elevation refuses rename and remove with unchanged inventory" and the LiveView refusal regression fail. Result: 15/18 passed, 1 property + 2 tests failed. |
| last-administrator check removed | delete `if length(keys) == 1 and actor.administrator, do: Ledger.rollback(:last_admin_passkey)` | **Fired**: "administrator last-passkey removal is refused", the LiveView administrator refusal, inherited "ordinary last-key removal revokes sessions; administrators must keep a key" and the generated history property fail. Result: 28/32 passed, 1 property + 3 tests failed. |

Both mutants were injected, observed failing at the stated oracles, and
reverted; the restored file passes the full focused suite again.

## Validation

- Focused suite: `MIX_TEST_PARTITION=verify111 ERL_FLAGS="+S 6:6" mix test
  test/marshall/accounts/security_credential_test.exs test/marshall_web/security_live_test.exs
  test/marshall/ssh/key_test.exs test/marshall/accounts/credential_history_test.exs`.
  Focused suite passed: 25 checks (2 properties, 23 tests), seed 994664;
  including the pre-existing security suite: 39 checks (4 properties, 35 tests).
- Full Marshall suite: `mix test --include distributed` passed **1203 checks
  (139 properties, 1064 tests), zero failures, two exclusions**, seed 241249.
- `mix precommit` (pinned toolchain, ADR, HLDD receipts, contracts, logging,
  compile with warnings as errors, format, tests, terminal/dashboard/workspace
  checks) passed; the full test phase passed **1203 checks
  (139 properties, 1064 tests), zero failures, two exclusions**, seed 459846,
  and forced Dialyzer reported **zero errors, zero skips and zero
  unnecessary skips**.
- `ruff format` and `ruff check` pass on the browser driver; its Nix
  `checkedBrowser` artifact holds pinned `ty` against the packaged Python and
  Playwright (campaign rule: composed-driver typing is replaced by the
  standalone artifact).
- Mutant runs: both mutants fired at the intended oracles and were reverted.
- Native: `nix build .#checks.x86_64-linux.credential-self-service-browser
  --no-link` — **credential-self-service-browser passed**: derivation
  `/nix/store/82ibbanij84p8w0xdhq6nl2cqifld41l-vm-test-run-overalls-credential-self-service-browser`;
  browser journey 28.26 seconds inside a 58.01-second VM script with 0.47-second
  cleanup. Three earlier attempts failed before acceptance and remain visible in
  this branch's history: Chrome permits one internal virtual authenticator per
  environment (fixed by swapping authenticators per enrollment), Chromium
  requires page focus for `credentials.create` (fixed with `bring_to_front`),
  and the step-up redirect after proving-credential removal is the bare
  pending-MFA gate (`/settings/security`, no `return_to`), from the shared
  `LiveUserAuth.fresh_login` path.
- Repo governance: `elixir scripts/check_adrs.exs`, `scripts/check_hldd.exs`,
  `scripts/hldd_coverage.exs --check`, `scripts/hldd_views.exs --check`,
  `prek run --all-files` and `nix build .#checks.x86_64-linux.hldd --no-link`
  (`/nix/store/pxs88gmvscln7bhdc2wyp4x5aj7h8scy-overalls-hldd-check`, 11 seconds).
  Receipts recorded per source group.
- The first full-gate attempt passed all 1203 tests but was rejected by
  `--warnings-as-errors` on unused bindings in the new history property;
  corrected and rerun clean.

## Contract review

Reviewed the repository test-claim and secret boundaries, Marshall's durable
authority contract, Accounts stored-login and email-privacy rules, the
LiveView current-login/web-domain-authority rules, the Ledger transaction
guarantees and the passkey per-file notes. The new `passkey-label-closed-refusal`
note and the `credential-history-oracle` note encode the obligations added or
relied on here; the native journey contract `native-credential-self-service`
pins the executable boundary. Fixture custody: disposable magic-link tokens
stay in private VM files and elevation uses the real ceremony.
