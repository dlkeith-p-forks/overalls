# stale-admin-tab-current-mutation-authority — Stale Control room tab cannot commit an admin mutation after authority withdrawal

**Type / priority / confidence:** Safety (`Always`), P0, high confidence in intended authority and audit contract; unimplemented Antithesis candidate. **Planned primary literal message:** **"Stale Control room tab cannot commit an admin mutation after authority withdrawal"**. Missing according to `existing-assertions.md`.

**Property and assertion semantics.** A Control room tab mounted while its actor was an elevated administrator cannot commit a new administrative mutation after a definite demotion, passkey elevation expiry/lock, login revocation, MFA reset or retirement invalidates that actor. A read-only Control room view may remain after demotion; that is not a violation. Each refused mutation must leave the target row, audit event count, auth-email outbox/jobs, token purposes and relevant workload operation rows unchanged. `Always` checks the full independent before/after inventory at each post-fence event. An authorized pre-fence event and a refused post-fence event should each get a distinct `Reachable` search marker if implemented.

**Fault history.** Use real SMTP-backed browser login and actual WebAuthn verification to mount `/admin/users` on Marshall B. Keep the LiveView socket open and its controls rendered. On A, another currently elevated administrator demotes B's actor, or invokes global session revocation/reset; separate runs use Security `lock` and database-time expiry. Delay B's refresh/PubSub or sever B's PostgreSQL link, then send a forged/old `set-role`, `revoke-sessions`, `invite`, `reset-mfa` or `delete-user` LiveView event from the stale tab. Race one event immediately before and another after the A transaction commits; classify the first by observed commit order, not by browser click time. Retry after B rejoins and verify a fresh read can still render if actor remains signed in and demoted, while mutation remains refused. An error flash without an unchanged committed inventory is insufficient.

**Independent oracle.** Query the target user's persisted `administrator`, `mfa_generation`, `deleted_at` and token purposes, plus `account_admin_events`, auth-email outbox/Oban rows and deletion records before/after the unique event. For host/job actions, include operation/receipt rows, but the primary case uses `/admin/users` account actions to keep the oracle small. Browser WebSocket event acknowledgement and UI state are secondary. Check the actor's login JTI and verification `elevated_until` against database time; no local clock assumption. A successful admin mutation before withdrawal must write the expected target/audit pair, proving the event path works.

**Source and intended contract.** `marshall/lib/marshall_web/live/admin/users_live.ex:4-6,29-95` installs required-user/admin hooks and calls real Ash account actions with its actor. `live_user_auth.ex:23-103` rechecks stored login before events; `live_admin_auth.ex:8-20,24-115` maps mutation events, refreshes the actor, checks current role, recent passkey and Cedar. `marshall/lib/marshall/accounts/security.ex:63-107,411-447` ties elevation to live login/current generation/database time and orders account locks. `marshall/lib/marshall/authorization/cedar.ex:43-71,133-163` reloads the persisted administrator flag and checks login. `marshall/lib/marshall/accounts/administrators.ex:10-65` locks, rechecks and commits role change with audit; `admin_users.ex:69-103` handles global session revocation; `account_lifecycle.ex:60-155` handles invitation/reset/retirement. ADR-0065 and ADR-0123 carry the five-minute/current-authority policy. Existing `admin_account_history_test.exs:24-79`, `admin_account_distributed_test.exs:75-116` and `nix/verification/tests/machines/control-room/browser.py:139-166` are scoped tests, not a hosted Antithesis witness.

**Value menu.** Demotion/elevation lock/five-minute expiry/session revocation/reset/retirement; `set-role`/`revoke-sessions`/`invite`/`reset-mfa`/`delete-user`; actor/target same or distinct where product policy allows; event before/after fence commit; B healthy/DB-unavailable/rejoined; mounted tab/fresh tab; target existing/deleted. Keep each trial's target and event ID unique to distinguish effects from other admins.

**Focused topology and proof boundary.** Two real Marshall HTTP/LiveView servers, shared PostgreSQL and separate Repo pools, local SMTP accept fixture for genuine browser login, browser runner with a real WebAuthn virtual authenticator and two pinned contexts. Account-row/audit/outbox proof requires no guest. A future admin VM override variant needs real guest authority and would be a distinct property, because this candidate proves Control room mutation admission.

**Open Questions:**

- Which user-facing control supplies the cleanest stale-event inventory with no dependent asynchronous worker effect? `(partial: set-role has target and audit rows; invite additionally creates outbox and mail jobs)`
- How will hosted fault injection distinguish a dropped LiveView event during database loss from an explicit authorization refusal after recovery? `(partial: source halts unavailable login checks; run needs socket/event and database recovery witness)`

### Investigation Log

#### Which user-facing control supplies the cleanest stale-event inventory with no dependent asynchronous worker effect?

- Examined `users_live.ex:29-95`, `administrators.ex:10-65`, `admin_users.ex:69-103` and `account_lifecycle.ex:60-155`. `set-role` commits one role state and audit event without a mail worker, making it the smallest primary event. The other operations broaden effects and should run only with their full inventories. Conclusion: retain `set-role` as core while preserving the value menu.

#### How will hosted fault injection distinguish a dropped LiveView event during database loss from an explicit authorization refusal after recovery?

- Examined `live_user_auth.ex:54-103`, `live_admin_auth.ex:24-115`, `login.ex:40-67` and current topology. Source distinguishes unavailable from refused and halts event processing while DB is unavailable. No hosted socket-level event ledger or fault restoration witness exists yet. Conclusion: partial; count no mutation during loss, then require a connected, processed post-recovery stale event for the refusal claim.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `access`. real-hosted-browser-identity-or-DNS-packets; physical guest route separate; independent witness: actual public callback/DNS packet plus consistent PostgreSQL authority rows. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/access/browser.py:479`. Replica B mounted LiveView, real pre-fence set-role target/audit pair, closed Ash demotion, and processed post-fence event with unchanged inventory; hosted execution and guest effects remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
