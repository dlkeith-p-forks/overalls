# Credential management histories: passkey and SSH-key administration

## Scope and architecture impact

Campaign improvement 061 uses branch `verify/061-credential-management` in its
own worktree, based on published main `c14ae27d`. The user journey is an
account holder managing passkeys and SSH keys through the credential surfaces:
register and verify passkeys, rename and remove passkeys, add and remove SSH
keys, and observe session effects of removal. All work runs against disposable
local PostgreSQL fixtures; no production system or deployment is exercised.

This improvement adds verification evidence only: generated property histories
and fixed bound/refusal tests through the real actions, plus documentation.
No production runtime, schema, protocol, permission or deployment change is
introduced. ADR statuses and accepted rationale are unchanged; recorded
discrepancy adjudications are documented below.

## Governing decisions (read before implementation)

- [ADR-0065](../decisions/0065-passkey-administration.md) (superseded by
  ADR-0119, then ADR-0123): passkey MFA, exactly 300-second elevation by
  database time without sliding renewal, one-use 60-second challenges bound to
  account/login/credential/generation, first enrollment requiring email
  authentication in the previous five minutes, credential changes requiring a
  verified passkey, ordinary last-key removal disabling MFA and revoking
  sessions, and administrators being unable to remove their last key.
  ADR-0119 retains those requirements while widening Control room reads;
  [ADR-0123](../decisions/0123-remembered-browser-authority.md) clarifies
  remembered logins and retains every other requirement.
- [ADR-0110](../decisions/0110-cedar-guest-ssh-accounts.md) →
  [ADR-0115](../decisions/0115-ssh-roster-boot-authority.md) →
  [ADR-0117](../decisions/0117-personal-terminal-machine-workspace.md) →
  [ADR-0125](../decisions/0125-fresh-guest-identities.md): Marshall-owned SSH
  key registration with current account authority, active revocation and
  durable evidence; campaign 014's repair under ADR-0066 requires new key
  registration to hold the shared account admission fence through commit.
- ADR-0058 (carried by ADR-0065): administrative authority changes commit
  together with append-only audit events.

## Pre-implementation record

### User operation

Account credential self-management through the real `Marshall.Accounts` user
`:security` action (`Marshall.Accounts.Security`) and the
`Marshall.SSH.Key` owner actions (`Marshall.SSH.KeyActions`), the same actions
the [`Security` settings page](../../../marshall/lib/marshall_web/live/account_live.ex)
and the [SSH key page](../../../marshall/lib/marshall_web/live/account_live.ex)/
[SSH command surface](../../../marshall/lib/marshall/ssh/commands.ex) invoke.

### Allowed results

- `begin_register`/`finish_register` with a real signed fixture attestation
  adds a passkey, enables MFA on first registration and emits
  `passkey.registered` plus `passkey_add` audit.
- `begin_verify`/`finish_verify` with a real signed assertion completes MFA for
  that stored login only and starts the fixed 300-second elevation bound to
  `verification.credential_id`.
- `rename` under recent elevation relabels the passkey without touching
  `credential_id`, `public_key` or `sign_count`.
- `remove` under recent elevation removes the passkey (passkeys are hard
  deletes; SSH keys archive). Removing a non-last passkey keeps MFA; removing
  the last passkey of an ordinary account disables MFA, bumps the MFA
  generation and revokes **all** stored sessions including the current one.
- `SSH.add_key` registers one canonical fingerprint per account up to the
  100-key limit; `SSH.remove_key` archives the owner's key, which stays
  archived.
- The committed credential inventory (passkey set, active/archived SSH key
  set, verification receipts, token purposes and account MFA state) matches an
  independent model recomputed from raw SQL after every operation, and
  `Security.recent?` agrees with that recomputation.

### Refusal cases

- `rename`, `remove` and (once enrolled) `begin_register` without recent
  elevation refuse with `:mfa_required` and change nothing.
- Removing the only passkey of an administrator refuses with
  `:last_admin_passkey`.
- First enrollment without a fresh-email receipt refuses with
  `:fresh_email_required` (no verification row, and a receipt aged past the
  five-minute primary window; the 299-second boundary remains admissible).
- The tenth passkey registers; the eleventh refuses with `:credential_limit`
  at both challenge issuance and completion admission; the tenth outstanding
  challenge is admitted and the next refuses with `:try_later` until expiry
  prunes history; the 100th SSH key registers and the 101st refuses with
  `:key_limit`.
- Undersized/oversized payloads: decode inputs longer than 65,536 bytes,
  invalid base64url, malformed CBOR attestation, malformed client data and
  over-limit labels (passkey 80, SSH 128) and public keys (4096) refuse
  without credential or MFA-state changes.

### Failure and recovery cases

- A malformed or oversized attestation consumes its single-use challenge but
  does not activate MFA; a correct later ceremony on a fresh challenge still
  succeeds.
- A failed assertion consumes its challenge without elevation; expiry prunes
  retained challenges and restores challenge admission.
- Removing exactly the passkey recorded as `verification.credential_id` kills
  elevation and login-MFA completion for that session
  (`elevation-fixed-session-deadline` requires a retained credential), while
  removing a different passkey preserves both.
- Last-passkey removal of an ordinary account revokes every stored `user`
  session token (two concurrent logins are observed), after which every
  management operation on those actors refuses `:unauthorized`.

### Independent property oracle

The oracle is raw SQL over `users`, `account_passkeys`, `ssh_keys`,
`account_verifications`, `account_passkey_challenges` and `tokens`, per
operation: exact passkey `{id, label, credential_id}` tuples, active and
archived SSH key identities, account `mfa_enabled`/`mfa_generation`, the
verification receipt for each session, and live `user`-purpose token presence.
Elevation is recomputed from the receipt fields (generation match, fixed
300-second freshness window, retained owned credential and live stored login),
not through `Security.recent?` alone; `Security.recent?` must agree with the
recomputation. Unrelated committed fixtures are preserved through
`Marshall.CommittedFixtureInventory.snapshot/assert_restored!` on the complete
public-table row-hash inventory (029 pattern).

### Native boundary (documentation-only disposition)

No new native execution is part of this improvement. Passkey ceremonies are
exercised with the existing synthetic P-256 WebAuthn fixture (real signatures
and Wax verification) already used by the recorded native virtual-authenticator
journeys (`control-room-browser`, `mfa-login/browser.py`); those retain their
captured revisions and scopes. Credential management adds no new
transport/isolation surface beyond those journeys, and hardware authenticators
and independent physical hosts remain explicitly external acceptance.
This is a documentation-only native disposition.

### Dependencies

Existing `Marshall.PasskeyFixture` authenticator/registration/assertion/action
helpers, `Marshall.CommittedFixtureInventory`, `Marshall.SSH` domain actions,
the pinned Elixir/PostgreSQL test runtime and `MIX_TEST_PARTITION=verify061`.
No new dependency, schema or fixture service.

### Required checks

Focused new suites, full `mix precommit` in `marshall/` (includes distributed
tests, forced Dialyzer and `contracts.check`), all-file `prek run --all-files`,
`elixir scripts/check_adrs.exs`, `elixir scripts/check_hldd.exs`,
`elixir scripts/hldd_options.exs --check`, `elixir scripts/hldd_coverage.exs
--check`, `elixir scripts/hldd_views.exs --check` and
`nix build .#checks.x86_64-linux.hldd`. One bounded mutant (dropping the
elevation recheck on rename) must be detected by the properties, restored and
recorded.

## Design and implementation

No production source changed. The new suites are:

- [Generated histories](../../../marshall/test/marshall/accounts/credential_management_history_test.exs):
  25 generated histories (ordinary vs administrator is generated) invoke the
  real `User :security` and `Marshall.SSH.Key` actions and a passwordless
  synthetic P-256 authenticator: register with signed attestations, verify
  with signed assertions, rename, remove, owner SSH key add/remove and fresh
  re-login. After every operation a raw-SQL oracle over `users`,
  `account_passkeys` (exact `{id, label, credential_id, public_key}` tuples),
  `ssh_keys` (active and archived identities), `account_verifications` and
  `tokens` is checked against the model. Elevation and login completion are
  recomputed in SQL (generation match, fixed 300-second window, retained
  proving credential, live stored login) and both `Security.recent?/1` and
  `Security.completed?/2` must agree. Session effects are asserted across
  every login of the account: ordinary last-passkey removal revokes all
  sessions including the issuing one, and every later passkey operation on a
  revoked session refuses `:unauthorized`. SSH key actions remain refused for
  pending-MFA or revoked sessions at the Cedar entry policy, which rechecks
  `Login.present/2` per call. Registration and verification retain challenge
  rows for sixty seconds, so generated histories keep at most eight
  ceremonies; the challenge budget itself is covered by the bounds suite.
- [Bounds and refusal suite](../../../marshall/test/marshall/accounts/credential_management_bounds_test.exs):
  ten fixed tests cover the fresh-email window (absent receipt, 301 seconds
  refused, 299 seconds admitted), elevation and unknown-credential refusal
  with unchanged credentials and challenge rows, elevation expiry retaining
  the completed login, administrator last-passkey refusal, ordinary last-key
  removal revoking two concurrent stored sessions with audit inventory
  (`passkey_add`, two `mfa_verify`, `passkey_remove`), proving-credential
  removal killing elevation and completion while another device's elevation
  survives, same-login recovery through a retained credential, exactly ten
  passkeys admitted and the eleventh refused before challenge creation, the
  completion-side limit refusal leaving its challenge unconsumed, the
  ten-retained-challenge refusal and expiry-prune recovery, malformed and
  oversized payloads (65,537-byte strings, invalid base64url, malformed CBOR,
  malformed client data, 81-byte passkey label) consuming their challenge
  without credential or MFA changes, a rename above the 80-byte label bound
  raising `Ash.Error.Invalid` without changing the row, the exact 100-SSH-key
  boundary with removal re-admitting registration, and 4,096-byte public-key
  and 128-byte label argument refusals.
- [Committed fixture inventory](../../../marshall/test/marshall/committed_credential_inventory_test.exs):
  eight committed lifecycles (enroll, verify, rename, SSH add/remove,
  non-proving removal keeping elevation, second-session completion,
  last-passkey revocation of both stored logins, fresh-email recovery
  enrollment and its removal) run unboxed and committed; an unrelated
  committed control fixture (its own enrolled passkey, completed verification
  and SSH key) is preserved, and exact teardown restores the complete
  public-table row-hash inventory through
  `Marshall.CommittedFixtureInventory.assert_restored!/1` (029 pattern).

## Defect adjudication

### Candidate (a): passkey rename emits no event and has no audit or PaperTrail

**Adjudicated: not a defect; the asymmetry is the accepted design.** Evidence:

- No accepted decision requires auditing credential label changes. ADR-0058's
  transactional audit covers administrative authority changes; ADR-0065 (carried
  through ADR-0119 and ADR-0123) requires auditability of the credential
  lifecycle that changes authority, implemented as the closed
  `account_admin_events` kind enum: `passkey_add`, `passkey_remove`,
  `mfa_verify`, plus administrative resets. No enum kind, accepted ADR or
  contract covers renames, for passkeys or any other resource.
- The analogous accepted operator for the SSH key resource — the only other
  labeled credential — deliberately excludes `:label` from its PaperTrail
  version content (`ignore_attributes [:inserted_at, :updated_at, :public_key,
  :label]`), encoding the same posture that labels are non-authority display
  data. Passkey labels surface only to the owning account's Security page
  (`:status`); no administrator projection or audit row exposes them (checked
  `MarshallWeb.Admin.UsersLive`, `AdminUsers`, `AdminEvents`).
- The reviewed structured-logging catalog
  ([fleet review](2026-09-19-structured-logging-fleet.md)) intentionally
  catalogs `passkey.registered`, `passkey.verified`, `passkey.verify_failed`
  and `passkey.removed` without a rename event; the coordinator's
  `emit_event(nil)` branch for rename is the deliberate no-event path.
- What rename *can* affect is verified by this campaign: it is elevation-gated
  (`:mfa_required`), refuses without inventory change, and the history oracle
  asserts the raw stored `credential_id` and `public_key` bytes are untouched
  by relabeling (`:update` accepts only `[:sign_count, :label]`).

Adding a rename audit kind or event would extend the closed audit enum and the
reviewed events catalog — a new architectural choice, not a repair. Per the
campaign delivery contract this is recorded as a proposal only, not enacted:
if a future threat model treats elevation-gated relabeling as noteworthy, an
append-only `passkey_rename` audit kind with catalog event can be added under
its own ADR. No behavior change is made here.

### Candidate (b): `SSH.remove_key` lacks the retirement admission fence

**Adjudicated: not a defect; the fence requirement is scoped to admission of
new work, and removal converges with cleanup under the existing row lock.**

- ADR-0066: "Credential registration must share the account admission fence
  through its outer commit... Completed cleanup must leave no active key for
  the retired UUID" — the fence prevents *creating* owned work after
  retirement. The `account-admission-fence` contract on
  `AccountLifecycle.admit!/1` says the same: "Creating owned work MUST hold
  this shared account fence through commit" (emphasis in review). Campaign 014
  repaired registration only, deliberately.
- Removal can never create an active key; it only archives one. Retirement's
  `DeleteUserMachines.cleanup_access!/1` archives every active key. Both
  orders converge: if removal wins the row lock, cleanup finds no active key;
  if cleanup wins, the archived row is invisible to the removal's active-only
  `lock!` read and removal refuses `:key_not_found`. No schedule leaves an
  active key behind.
- Authority is independently fenced per call: the Cedar entry policy for the
  owner key actions rechecks `Login.present/2`, which reads the stored
  `user`-purpose token and rejects retired accounts (their tokens are revoked
  transactionally at retirement) and stale login receipts; the authorizer's
  principal read also requires `deleted_at: nil`. This improvement's tests
  confirm pending-MFA and revoked sessions are refused `Forbidden` and key
  removal preserves archival identity.
- Adding the advisory fence to removal would buy no guarantee the accepted
  decisions do not already demand, and would serialize harmless destructor
  work against retirement; not enacted.

## Mutant detection

The bounded mutant deleted the `unless recent?(actor), do:
Ledger.rollback(:mfa_required)` recheck shared by `:rename` and `:remove` in
[security.ex](../../../marshall/lib/marshall/accounts/security.ex). At seed 0
the generated history property failed its refusal oracle ("expected refusal
:mfa_required, got ... :unknown_credential" / `{:ok, %{updated: true}}`) and
the fixed elevation-refusal test failed identically: 9/11 passed (0/1
properties, 9/10 tests). The mutant was restored and the focused suites pass
again: 12 checks (2 properties, 10 tests), seed 23207. The committed inventory
suite is intentionally insensitive to this mutant (it performs only
authorized operations); the history and bounds suites are its detectors.

## Execution evidence

- Focused credential suites (history property, bounds, committed inventory,
  plus the existing `security_test`, `key_test`, `ssh_keys_live_test` and
  `security_live_test` controls): **40 checks, 10.6 seconds**.
  Result: 40 passed (5 properties, 35 tests), seed 78123.
- Focused new suites alone at seed 0: 12 checks (2 properties, 10 tests);
  post-restore rerun: seed `23207`, 12 passed, 7.5 seconds.
- Mutant run at seed 0: detected and restored (above).
- Full Marshall suite (`mix test --include distributed
  --warnings-as-errors` on this tree before receipt freeze, with `deps.unlock
  --unused` clean): **1199 passed (140 properties, 1059 tests), 2 excluded,
  664.2 seconds**. The run's ExUnit seed was not separately captured; the
  final frozen-tree gate seed is recorded in the delivery ledger.
- Forced Dialyzer: an initial standalone invocation analyzed the development
  profile and was discarded from evidence (same trap as the 014 record). The
  explicit `MIX_ENV=test mix dialyzer --force-check` analyzed the test profile,
  including the new regression fixtures: **zero errors, zero skips, zero
  unnecessary skips, 71.7 seconds**.
- Contracts (`mix contracts.check`, pinned `cc-check`): 19 passed, 0 failures;
  `mix logging.check`: 147 catalogued events, no findings; terminal, dashboard
  and workspace checks passed. ADR checker: 124 decisions passed.

First delivery frozen-tree gate results on commit `72621da2` (after receipt
freeze): the complete `mix precommit` alias passed — toolchain (Elixir 1.20.4,
OTP 29.0.6), ADR (124 decisions), reviewed HLDD receipts, code contracts (102
CONTRACTS files, 1,816 native notes, 2,138 maintained source files covered;
structural checks only), logging (147 catalogued Marshall events), compile
with warnings as errors, the full distributed suite (`1199 passed (140
properties, 1059 tests), 2 excluded`, seed `785037`, 665.9 seconds),
terminal/dashboard/workspace checks and forced Dialyzer (zero errors, zero
skips, zero unnecessary skips, 57.3 seconds). All-file `prek` passed,
including the HLDD receipt gate; standalone `check_adrs.exs`,
`check_hldd.exs`, `hldd_options.exs --check`, `hldd_coverage.exs --check` and
`hldd_views.exs --check` all pass. The Nix `checks.x86_64-linux.hldd` build
passed in 12 seconds, producing
`/nix/store/9rz4jcskwmy7fi7ap5gsvpz7mndqfa4j-overalls-hldd-check`, and the
bookkeeping rebuild after the ledger/citation records passed in 12 seconds
producing `/nix/store/ciz5vphydcxgp9kx6nvzskia79g3kyqs-overalls-hldd-check`.

## Latent oracle failure found during integration review

After the first delivery commit, the coordinator's integration gate reran the
history property at unrecorded seed **`911959`** and the property failed
deterministically with the shrunken history `admin=false, seed <<0::128>>,
operations [:register, :verify, :remove, :relogin, :register]`: the last
ordinary passkey removal disables MFA and revokes every session (including the
verified session s0), then a fresh login and re-registration re-enable MFA.

**Diagnosis: test-modeling defect (oracle), not a production defect.** The
model maintained session completion as an incrementally updated flag. At the
re-registration step it copied each session's `verified` marker into
`completed`; for the revoked session s0 that receipt is bound to the
*pre-removal* MFA generation, so once MFA is re-enabled the receipt is stale
and `Security.completed?/2` is correctly `false` (verified marker present,
generation mismatch, credential removed). The raw-SQL recomputation agreed
with production; the model flag was wrong. Production behavior matches
ADR-0065's invalidation rules (removal, generation bump and retirement
invalidate relevant authority); the revoked session also stays dead at the
token layer. No production source changed.

**Correction (test module only):** the session model no longer carries a
maintained `completed` flag. It tracks each receipt's verified marker, the MFA
generation at verification, and the durably retained credential binding
(`bound_credential`, never cleared by removals, mirroring the retained
receipt rows). Completion is computed by the same rule the raw SQL uses —
`not mfa_enabled` or (verified, generation match, binding's credential still
present) — and the oracle additionally asserts the raw receipt's credential
binding equals the model's binding in every state. The
[credential-management-history-oracle](../../../marshall/test/marshall/accounts/credential_management_history_test.exs)
contract records this obligation.

**Re-validation evidence (isolated partition `verify061iso`):**

- The coordinator's failing seed: `mix test
  test/marshall/accounts/credential_management_history_test.exs --seed
  911959` — **passes** (2.1 seconds), 25 runs, including the seed's shrunken
  history; raw recomputation and `Security.completed?/2`/`Security.recent?/1`
  agree in every state.
- The same suite at **seed 0**: passes (2.5 seconds).
- The recorded focused credential set: **40 passed (5 properties, 35 tests),
  seed `78123`**, 8.8 seconds — unchanged counts on the hardened oracle.
- Mutant re-detection: re-applying the bounded elevation-recheck deletion at
  seed 0 still fails both detectors (history property and the elevation
  bounds test; 9/11 passed), and the production source was restored
  byte-identical (empty `git diff marshall/lib/`).
- The final frozen-tree `mix precommit` rerun on the corrected tree passed:
  toolchain, ADR, reviewed HLDD receipts, contracts, logging, formatting,
  the full distributed suite — **1199 passed (140 properties, 1059 tests), 2
  excluded, seed `660207`, 643.5 seconds** — terminal/dashboard/workspace
  checks, and forced Dialyzer (zero errors, zero skips, zero unnecessary
  skips, 59.2 seconds). Receipts were refreshed after all edits and the gate
  ran with them current.

## Remaining gaps

- Hardware passkey authenticators, independent physical hosts and production
  rollout remain external acceptance boundaries, per ADR-0123's open
  questions; this work uses the synthetic P-256 fixture (real signatures and
  Wax verification) and disposable PostgreSQL only, matching the existing
  recorded native journeys' virtual-authenticator scope.
- Cross-node (multi-BEAM) ordering of credential management (e.g. elevation in
  one node vs removal racing in another) is not exercised here; campaigns 014
  and 022 cover the retirement fence and account-authority orderings, and
  challenge consumption serializes in PostgreSQL (`passkey-consumption`
  contract). A distributed credential-changes schedule remains possible future
  work.
- The SSH gateway session five-second revocation and roster paths retain their
  own recorded scopes under the `ssh` scenario; this improvement covers owner
  key management bounds only.
- No native run is included (see the native boundary disposition above).
