# Subsequent MFA login and cross-replica revocation verification

## Scope and architecture impact

Campaign improvement 007 implements missing remembered-browser resume and aligns
global browser revocation with persistent credentials. ADR-0123 supersedes only
the clarified browser-credential scope of ADR-0119 while carrying forward its other
decisions and inherited ADR-0065 MFA requirements. No schema, token format,
domain ownership or service/guest protocol changes. Production deployment is not
part of this work.

## Findings and implementation

The real magic-link POST generated a secure, HTTP-only remembered JWT cookie, but
the browser pipeline did not consume it. Two cookie-only resume regressions failed
with seed 77007 before the fix. The pipeline now exchanges that cookie before
loading the session, without recording primary-email freshness or copying MFA.

Generated pending-login checks also found that LiveUserAuth installed later hooks
but did not run its MFA check before a protected view's mount callback. Control
room admission consequently redirected to Machines first. The same persisted
login/MFA check now runs before mount as well as on later events/navigation/refresh.

Enabling remember exchange exposed the narrower administrative `user`-purpose-only
revocation. The coordinator now revokes `user` and `remember_me` under its existing
account row lock. The transactional remembered-login read acquires that lock in
its first before-action preparation, enclosing upstream stored-token revalidation
and after-action login issuance through commit. Sign-out locks validated
cookie subjects and current login in sorted order before library revocation,
including absent/expired login and differing remembered subject. Its outcome
event follows successful commit. Reset and retirement retain their broader
account-token revocation.

## Verification design and limits

The generated test begins with a registered account, revokes enrollment's login,
and creates two subsequent logins. An independent per-login model checks actual
workspace, Control room, handbook and export entry points. Every run includes
wrong-session refusal, correct use, replay refusal, non-UV refusal, challenge
expiry and successful independent completion. Elevation expiry preserves completed
login; later generated verify/lock/expiry/revocation operations recheck fresh and
mounted authority. Registration plus bounded histories fit ten retained challenges.

Three independent BEAM instances exercise committed exchange/revocation in both
orders. The exchange gate runs inside the real read action; a target-specific
PostgreSQL trigger pauses the real revocation update. Neither fixture supplies
the account lock. PostgreSQL wait inspection observes the opposing operation
blocked by the first transaction. The third replica observes refusal of the copied
credential and invalidation of any token issued before revocation.

The native scenario uses three independent packaged Marshall services, PostgreSQL,
HAProxy, Chromium and a virtual WebAuthn device on one NixOS VM. A fixture-only
cookie selects a backend while preserving one HTTPS origin/RP. TLS certificates
are verified on browser and backend paths; response headers identify the serving
backend, including actual WebSocket handshakes. Bootstrap is completed separately
and ordinary roles are asserted in persisted data. The browser enrolls, signs out
through the real confirmation form, signs in again through explicit magic-link
interaction, proves pending refusal, verifies, and resumes a remembered login.
Admin-UI revocation on the second instance must invalidate mounted access on the
first and copied cookies on the third. A separate ordinary no-MFA account proves
that remembered credentials themselves cannot restore access after revocation.

This is colocated replica acceptance, not physical-host failure tolerance.
Hardware authenticators, real email inbox delivery, production deployment and
guest/storage isolation are not covered.

## Validation

The native source snapshot uses published base
`00343832a546c7537b9bddf20b0c7fa7dc56ae5c`. Final application integration includes
published improvements 006 and 008 through
`0ffb07545811bc9f2f3e9f5e5f89a8b3b8c20183`.

- Final combined ExUnit run: **1,039 passed (97 properties, 942 tests)**,
  **2 excluded**, seed `54054`, in **363.6 seconds**. This includes the independent
  subsequent-MFA histories, remembered-cookie examples, committed race and final
  scoped cleanup, alongside the published 006 and 008 checks.
  The enclosing `mix precommit` completed successfully, including contract,
  logging, compiler, formatting and JavaScript checks. Forced test-environment
  Dialyzer reported **0 errors, 0 skips, 0 unnecessary skips** in **57.68 seconds**.
- `final mfa-login-browser passed`: the final transactional-read implementation
  completed the NixOS script in **57.20 seconds**, including the **23.57-second**
  browser journey and **0.78-second** successful cleanup. Output:
  `/nix/store/7man4gilnrwybsw7571l1d9avimyhvfs-vm-test-run-overalls-mfa-login-browser`.
  Derivation: `/nix/store/n1vzv4460cw8scppsv7567pmq8wzmxxs-vm-test-run-overalls-mfa-login-browser.drv`.
  The 297-second Nix command includes rebuilding the packaged source. The
  production target lock was restored and checked before capturing this derivation.
- The final standalone browser artifact passed pinned `ty` against the same
  packaged Python 3.13 and Playwright used by the machine. Output:
  `/nix/store/qmy3m7i517fi5cqd60jw32287r4ig5j6-mfa-login-browser-typed`;
  derivation `/nix/store/4v8xy9mrrqhgc75bzhg75ky2r32ag82k-mfa-login-browser-typed.drv`.
  The NixOS check now depends on and executes that checked artifact. The earlier
  direct in-tree `ty check` used an explicit path with ty 0.0.73 and did check
  the script: a temporary invalid-return probe confirmed that explicit paths
  override project include rules. The initial exclusion explanation was incorrect.
  The copied artifact uses the Nix check's different pinned checker/runtime
  environment and exposed three dictionary-narrowing errors. A typed predicate
  performing exactly the existing `isinstance(value, dict)` check resolves them without unchecked
  casts or changing validation. These two predicate substitutions and the static
  artifact wrapper followed the recorded native execution; its production code,
  browser assertions and tested scope are unchanged. No second native execution
  is claimed for those final static-check changes.
- The earlier wrapper implementation passed its native script in **75.40 seconds**,
  including a **33.49-second** browser journey and successful VM cleanup. Output:
  `/nix/store/7mi35f8fkspcxn2yfi00aqd8766nbzix-vm-test-run-overalls-mfa-login-browser`.
  Derivation: `/nix/store/ascd7izamqkh578ji260fq8rih4zmmqj-vm-test-run-overalls-mfa-login-browser.drv`.
  The Nix command's 89 seconds includes build overhead.
  The first attempt exposed a fixture expectation: anonymous `/` redirects to
  `/sign-in` (failed derivation
  `/nix/store/qzfcggnr9d4jmw1zvm6v6lm6bghjc5sf-vm-test-run-overalls-mfa-login-browser.drv`).
  Correcting that expected destination produced the recorded pass.
- Focused remembered-login examples passed **5 tests**, seed `77007`, including
  first-enrollment freshness, copied-cookie sign-out/global revoke, reset and
  retirement refusal.
- The transactional read passed the refined three-node race (**1 passed,
  38 excluded**, seed `77007`, 9.3 seconds) and the combined remembered-login and
  Control room access checks (**15 passed**, seed `77007`, 6.0 seconds).
- A temporary mutation removed only the production target-account
  `Ash.Query.lock(:for_update)` in `AdminUsers`. The same refined race failed
  (**0/1 passed, 38 excluded**, seed `77007`, 11.5 seconds) at
  `opposing replica did not wait on the account lock`. The fixture therefore does
  not supply the serialization guarantee it claims to verify. Exact source bytes
  were restored and checked against the saved original before subsequent builds.
  The restored race passed again (**1 passed, 38 excluded**, 8.9 seconds).
- The first combined run after 006 found one token left by that deliberate
  mutation, causing two empty-table assertions to fail (1,034/1,036 passed,
  all 95 properties passed, seed `16785`): its delayed exchange could finish
  after failed-test row cleanup. Nested task scopes now release the gate and
  drain both real actions before reraising the original lock assertion, including
  failure before the second action exists, then remove only their fixture rows.
  A failed RPC stops its fixture peer; because peers are shared by the file,
  subsequent failures cannot be reported as passing acceptance. The single proven
  orphan in the isolated `verify007` database was removed by exact subject and
  creation time after confirming its user was absent. This fixture correction
  changes no production behavior or native acceptance scope.
- With scoped cleanup, the race passed (**1 passed, 38 excluded**, 8.4 seconds),
  then the repeated no-target-lock mutation failed at the intended lock assertion
  (**0/1 passed, 38 excluded**, 8.4 seconds). An injected leading-only gate
  assertion also failed as intended (**0/1 passed, 38 excluded**, 6.8 seconds).
  Both failure probes left **zero tokens, zero users and zero fixture triggers**
  in the isolated database. Exact production and test bytes were restored before
  integration and the final gate; seed `77007` was used for each probe.
- The initial complete application run passed 1,032 of 1,033 checks, including
  all 93 properties. Its sole failure was an old pending-MFA redirect assertion:
  the new pre-mount check correctly redirects directly to security setup. That
  assertion is corrected and passes in the final combined run.
- Initial Dialyzer found an upstream `around_transaction` callback type declaring
  arity one although the actual hook accepts two arguments, and a fixture passing
  a structured Ash error to the atom-only `Ledger.rollback/1`. The final design
  uses Ash's declared read transaction and accurately typed before-action hook;
  the fixture invokes the real action directly. No type exclusions or dependency
  overrides were introduced. The corrected test-environment forced Dialyzer check
  passed with **0 errors, 0 skips, 0 unnecessary skips** (1m3.45s analysis).
  The final native pass above includes this production source refinement.
- Final governance passed: ADR structure/local links (121 decisions), HLDD
  receipts, generated scenario/options references, Ash/deployment views, contract
  syntax/discovery, all-file `prek` logging/HLDD/ruff/format/ty hooks, and the Nix
  `hldd` check. The browser subprocess's actual type evidence is the separate
  copied artifact recorded above. Structural gates do not establish runtime
  architecture or external acceptance.

## Contract review

Reviewed repository evidence/secret contracts, account stored-login authority,
current-user LiveView hooks, administrative revocation and upstream remember
helpers. The upstream helper stores raw signed JWT cookies with secure/httpOnly
flags, so ordinary `fetch_cookies` supplies the correct value for subject locking.
The new account preparation does not grant internal SystemActor authority to a
browser. Native routing and backend observation are isolated fixture behavior.
The final diff preserves this review's ADR-0123 impact: persistent browser
authority and transaction serialization change as described; schema, ownership,
transport and guest/service contracts are unchanged. The final browser typing
wrapper preserves the existing runtime checks. No contract violations were found
in this inspected scope; external acceptance limits remain as listed above.
