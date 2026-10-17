# Login issuance/revocation race fencing and ceremony refusal verification

## Scope and architecture impact

Campaign improvement 100 (discovery 037) verifies and repairs magic-link
sign-in issuance racing administrative revocation, records the ordinary
sign-out versus remembered-exchange ordering, bounds evidence for retained
passkey challenges, and extends the native MFA login check with an
expired-ceremony refusal leg.

ADR-0123 carries the now-explicit fenced magic-link issuance semantics: the
accepted exchange/revocation ordering boundary is documented to cover fresh
sign-in issuance, and the pre-existing intentional fresh-sign-in-after-global-
revocation behavior is documented rather than changed. No schema, token format,
domain ownership, protocol or deployment boundary change. No production rollout.

## Findings and implementation

1. **Callback crash on raced revocation (repaired).**
   `MarshallWeb.AuthController.success/4` hard-matched
   `{:ok, jti, _} = Login.verify(token, user, true)`. A revocation committed
   between sign-in issuance and the controller callback made the stored login
   absent or revoked, the match failed with `MatchError` and the request
   crashed instead of refusing. Reproduced pre-fix by the controller suite
   failing with exactly that `MatchError`; the fix emits the catalogued
   `auth.sign_in_failed` event with closed reason `:session_revoked` and
   redirects the browser to sign-in with a generic predefined message and no
   session, token or failure detail.

2. **Unfenced post-commit session issuance (repaired).**
   `sign_in_with_magic_link` runs real locking (installation latch and the
   account-row upsert) through its identity commit, but the authoritative
   browser session token was minted and stored by the authentication strategy
   **after** that commit. A revocation whose token UPDATE observed the database
   between the identity commit and the post-commit store would keep the newly
   issued session alive with no ordering invariant. Reproduced
   deterministically: the gated race parked the sign-in after commit but before
   the post-commit store while the revocation committed; the issued session
   verified `{:ok, ...}` afterwards (pre-fix failure recorded at seeds 901747
   and 893776-era runs). The fix follows the remembered-exchange pattern: a
   dedicated change mints the authoritative login inside the sign-in
   transaction, revokes the strategy's unfenced post-commit token before the
   action returns, and returns the fenced credential in the action metadata.

3. **Challenge retention bound (evidence).** `Security.challenge!/2` prunes
   expired rows at issuance and refuses retained issuance beyond ten per
   account. The evidence now covers the exact boundary: ten retained rows,
   the specific `:try_later` refusal of an eleventh, deletion of backdated
   rows on the next issuance, and refill to the same boundary.

4. **Ordinary sign-out versus remembered exchange (evidence).** The
   controller sign-out takes the ordered credential account locks inside its
   transaction; the exchange's first before-action preparation holds the
   account lock through revalidation and issuance. The committed race on three
   independent BEAM nodes passes both orders: exchange committed first keeps
   its independently issued browser login while the supplied remember
   credential is then revoked; sign-out committed first fences the later
   exchange into refusal. Copied-credential refusal afterwards is asserted on
   every replica.

## Verification design and limits

The race oracle runs real production actions on three independent BEAM nodes
with committed PostgreSQL state. Advisory/xact gates pause the sign-in inside
its transaction (after production locks and single-use consumption hold) and
after its commit but before the post-commit credential store; a
target-specific trigger pauses the revocation inside its tokens UPDATE.
`pg_stat_activity` proves the opposing operation waits on production locks.
Committed token rows — not response copies — decide the outcomes: issuance
ordered before revocation ends with all live browser credentials revoked on
every replica; MFA reset and retirement ordered first refuse issuance (the
consumed link is revalidated as revoked); **Sign out everywhere** ordered first
admits the fresh magic-link sign-in ADR-0123 preserves. Fresh sign-in after
every settled outcome, including a same-email registration after retirement
with a distinct UUID, remains intact.

Limits: gates use PostgreSQL advisory locks, so the schedules prove lock
ordering, not arbitrary interleavings. Native replicas are colocated in one VM
with one PostgreSQL; hardware authenticators, independent physical failure
domains and production rollout remain external. The pruning/boundary unit
evidence is single-node.

## Gate evidence

Focused suites (partition `verify100`, `ERL_FLAGS="+S 6:6"`):

- `test/marshall/compute/distributed_admission_test.exs:345` — race test:
  1 passed, seed 710003, 8.8s; full file afterward: 41 passed, 51.5s, seed
  (second full run) — and repeated after fixes.
- `test/marshall/compute/distributed_admission_test.exs:591` — sign-out vs
  exchange: 1 passed, seed 893776, 9.0s.
- `test/marshall_web/auth_controller_test.exs` — 5 passed.
- `test/marshall/accounts/security_test.exs` — 15/15 passed (incl. challenge
  bound evidence).

Mutant table (inject → observe → revert):

| Mutation | Intended oracle | Result |
| --- | --- | --- |
| Restore unfenced callback match (drop `:error` refusal) | `auth_controller_test` refusal leg | Fails with `MatchError`; 4/5 pass (detected, reverted) |
| Drop `change Marshall.Accounts.MagicLinkSignIn` | race test completed-then-revoked assertion | Fails: session verifies `{:ok, _}` after committed revocation (detected, reverted) |

## Native execution

First gated attempt
(`/nix/store/faiv3q8liwg2403ah4x4qs4ixjwy13dm-vm-test-run-kittens-mfa-login-browser.drv`,
472s): all pre-existing legs and the new expired-ceremony refusal passed — the
UI refused without elevation — while the first fresh-retry variant never
completed: the browser-side WebAuthn call was cancelled because a resident
passkey lives only in the virtual authenticator attached to the page that
registered it, and the fresh browser context's authenticator was empty. The
instrumented replay (339s) printed `status='Verify your identity...'` with the
cancellation flash, confirming no server-side ceremony event occurred. The retry
now deliberately reuses the same browser page (the resident credential holder)
and rebinds its WebSocket backend observation to the third replica.

Final passing run: derivation
`/nix/store/aphfmwvmidwg5irl7chhqfh5mgz0yys4-vm-test-run-kittens-mfa-login-browser.drv`,
output
`/nix/store/mdg7dmz5yf8w9804qckwncgkwvr02xrl-vm-test-run-kittens-mfa-login-browser`,
exit 0 in 74s wall (cached build) under the MEDIUM native lock; the browser
subtest "Subsequent MFA and remember-me logins; cross-replica revocation and
expired-ceremony refusal" finished in 27.77 seconds with the expired ceremony
refused without elevation and the fresh begin/verify succeeding on the third
replica with its WebSocket handshake observed there.

## Remaining gaps

- The ordering evidence uses the Postgres latch/row-lock serialization with
  gates; it does not bound arbitrary scheduler interleavings beyond the lock
  boundary (the failure mode is fenced, not made impossible under adversarial
  clocks).
- Hardware WebAuthn authenticators and physically independent hosts remain
  external acceptance per ADR-0123's open questions.
- The refusal-to-retry native leg models database-clock expiry through SQL
  backdating; wall-clock expiry at 60 seconds is unchanged and separately
  covered by unit evidence.
