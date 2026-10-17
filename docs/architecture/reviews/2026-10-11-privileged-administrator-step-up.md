# Privileged administrator step-up review — 2026-10-11

## Scope and authority

The development redesign retains ordinary signed-in Control room reads and moves
privileged administrator actions to fixed fifteen-minute passkey step-up with
inline continuation of the exact pending action for enrolled administrators.
An administrator without a key visits Security settings for fresh-email first
enrollment, returns to the original page and explicitly retries the action.
Passkey changes continue to require verified credential authority, and
Cedar's Customer owner boundary remains intact. Backwards compatibility is not
required. This review records the decision, implementation boundaries and
acceptance criteria separately from native execution evidence.

[ADR-0160](../decisions/0160-privileged-administrator-step-up.md) supersedes
[ADR-0123](../decisions/0123-remembered-browser-authority.md). The older record
preserves its remembered-cookie and revocation rationale and historical evidence;
ADR-0119/0065 remain historical links in that chain. The documentation portion
includes ADRs, architecture indexes, this review, HLDD chapters/scenarios and
reviewed receipts. Marshall coordinator and LiveView changes are implementation
evidence; source and document checks do not establish native verification.

## Architecture assessment

The decision changes browser authority lifetime and mutation continuation. It
does not add an Ash domain, resource ownership boundary, service listener, guest
protocol, deployment role, or storage owner. PostgreSQL remains the shared
authority for current login, role, verification and committed mutations.
Privileged action admission must retain its existing locks and append-only audit
transaction. A successful WebAuthn ceremony cannot replace a fresh Cedar decision.

| Finding | Evidence and consequence | Disposition |
| --- | --- | --- |
| Step-up loses mutation intent | Baseline `LiveAdminAuth.authorize_event/2` redirects expired mutation events to Security with a return path; it stores no canonical action or arguments. Returning to a page cannot prove what the user requested. | ADR-0160 keeps one exact actor/login/resource/action/arguments continuation in the current socket for five minutes, discards it before one callback retry and retains fresh transactional admission. |
| Current elevation lifetime is inherited five minutes | Baseline `Security` uses a 300-second receipt; prior generated/browser results target that lifetime. | Replace with a fixed 900-second database-time receipt. Retain historical results without claiming the new boundary is tested. |
| Login and privileged authority were coupled | Baseline pending-MFA hooks halted protected mounts before a passkey; a no-key administrator could not reach the action that needs setup. | Let the stored email-authenticated login use ordinary workspace and read projections; require passkey proof at privileged mutation and passkey-change admission. |
| A new administrator may have no key | `begin_verify` requires a credential; first enrollment uses fresh-email proof. | Keep setup on Security settings with an allowlisted return path. Enrollment alone performs no administrator action; the user returns and explicitly retries. No action arguments survive setup navigation. |
| SSH key authority differs from passkey management | Owner-managed SSH actions already require the current login and immutable owner, while administrator overrides require Cedar elevation. | Preserve those existing SSH boundaries. Do not describe owner-managed SSH keys as requiring a recent passkey receipt. |
| Credential changes are authority changes | Baseline Security binds verification to the proving credential and account generation; proving-key removal ends authority and administrators cannot remove their last key. | Preserve verification, locking and inventory/audit refusals. Do not let a new key authorize its own incomplete enrollment. |
| Elevation is not Customer ownership | Baseline Cedar and the Customer adapter retain profile-specific owner refusal, including elevated foreign administrators. | Carry that boundary forward and require it again when a continuation resumes. |
| Expired override access had no specific recovery | A mounted machine/terminal that lost an administrator override returned to the ordinary machine list; resize exposed only generic unavailability. | Preserve refusal, then return non-Customer override users to Fleet workloads with an expiry explanation. Resize hides mutation controls, retains its draft URL and offers that recovery link. Owner/sharing rights and Customer exact-owner refusal remain independent. |

The original inspected baseline is `168be13f`. The final integration applies the
feature to origin/main `1722fbdf`, preserving upstream ADR-0159 legacy removal
and the reverted queued-clone activation behavior. ADR-0160 uses the next free ID;
it does not replace origin's ADR-0159 or its reciprocal supersession metadata.
Source evidence is
[LiveAdminAuth](../../../marshall/lib/marshall_web/live_admin_auth.ex),
[Security](../../../marshall/lib/marshall/accounts/security.ex),
[Cedar](../../../marshall/lib/marshall/authorization/cedar.ex), and
[compute policy](../../../marshall/priv/cedar/compute.cedar). The
[continuation grammar](../../../marshall/lib/marshall_web/admin_elevation.ex)
holds canonical arguments and route/view/resource/idempotency bindings. It does
not freeze all mutable target fields: the original domain action rechecks its
current resource and workflow preconditions. Harmless read refreshes do not
broaden the pending submission. Navigation and reconnect discard socket-local
intent; shared PostgreSQL remains the only durable authority.

Before publishing, feature commit `4ef9edd1` was merged with origin/main
`f603be11`. The incoming ADR-0159 Push 3 removes obsolete runtime parent
configuration, four-field roster fallbacks and unsupported-terminal creation
status; the MFA source overlaps only the obsolete terminal notice removal.
The sole conflict is the reviewed HLDD receipt manifest. Resolution preserves
both source groups and their evidence, including the upstream 34-case
startup-refusal scenario as present and the ADR-0083 creation-probe correction.
The `1722fbdf` native artifacts below retain their feature-capture scope.
The separate pushed-merge capture establishes the later rerun at `d4bd0214`.

## Verification and evidence limits

The focused backend run passed 35 checks (3 properties, 32 tests) in the pinned
`devenv` test runtime: [continuation examples](../../../marshall/test/marshall_web/admin_elevation_test.exs),
[receipt properties and security actions](../../../marshall/test/marshall/accounts/security_test.exs)
and [administrator user actions](../../../marshall/test/marshall_web/admin_users_live_test.exs).
`mix compile --warnings-as-errors` also passed in that runtime. The continuation
examples use the installed LiveView hook and real WebAuthn signatures. They
inspect exact target and audit state for one-use continuation, second-intent and
argument substitution, cancellation/navigation, role/login/key-generation loss,
expired or invalid challenges followed by retry, cross-socket nonce refusal,
and a retired target refused by current domain admission. The binding example
checks five-minute expiry and changed login/resource/request identities.
Receipt properties establish exact fifteen-minute timestamp arithmetic; they
do not prove a native database-clock/browser-timer journey.

The typed browser hook passed TypeScript checking and four browser state unit
tests for challenge validation, nonce/action transport, cancellation before a
begin reply, and disconnect with a late authenticator result. These run against
the hook with a simulated DOM and authenticator; they do not establish real
dialog focus behavior or native WebAuthn. The hook now uses a native `dialog`
for focus containment and routes Escape, close-button and backdrop dismissal
through the same abort/discard path.

The [machine recovery examples](../../../marshall/test/marshall_web/admin_machine_recovery_test.exs)
cover mounted terminal expiry, retained resize draft URL and hidden controls,
header power refusal, owner/shared-manager continuity and foreign Customer
denial without an elevation hint. The five focused machine recovery tests passed;
an earlier combined Terminal/Resize/Machines suite passed 35 tests.
The recovery helper does not authorize a mutation; the original domain remains
the authority. Security status says **Passkey verified** because a receipt does
not grant administrator membership to an ordinary account.

Initial packaged browser checks passed for `mfa-login-browser` and
`admin-account-browser`. These NixOS fixtures run real Chromium, verified TLS
and a virtual WebAuthn authenticator with the packaged Marshall release.
The login fixture observes actual HTTP and WebSocket serving replicas across
three colocated Marshall instances sharing one PostgreSQL in one VM. It passed
ordinary and remembered read/export access without passkey proof, one inline
administrator action and target audit, the issued 900-second database interval,
mounted/copied-cookie cross-replica revocation, an expired challenge with
surviving ordinary reads, and fresh verification on another replica. The
account fixture passed lock-to-modal, cancellation with focus restoration and
unchanged state, reopened verification with exact reset continuation, and stale
mounted mutations after demotion.

The login browser subprocess took 29.02 seconds and its full VM script took
60.15 seconds; the account browser subprocess took 31.50 seconds and its script
took 60.00 seconds. Both builds exited zero. Their output paths are
`/nix/store/nlzfmgsqzp1sgynykcsl3bk0vsdj9yg3-vm-test-run-overalls-mfa-login-browser`
and `/nix/store/plvbp6slva8jqz1w795jypx7kxk9ds2i-vm-test-run-overalls-admin-account-browser`,
using release `/nix/store/mrlqrawlw9l9plnm10p7iqirk4srvrai-overalls-marshall-0.1.0`.

These initial native captures precede the final no-key setup-return addition,
generic **Passkey verified** copy, submitted-phase browser state changes and
machine target recovery. They do not establish the final merged snapshot; retain
their original scope separately from the final capture below.

Final merged packaged browser checks passed for both `mfa-login-browser` and
`admin-account-browser` on origin/main `1722fbdf` plus the final production and
fixture diff. Both builds exited zero. The login browser subprocess took
28.37 seconds and its full VM script took 59.41 seconds; the account browser
subprocess took 34.88 seconds and its full script took 61.59 seconds.
The immutable derivations and outputs are:

- `/nix/store/5hw7pa5yn9ymcnxxxfcd54gbvcy414r8-vm-test-run-overalls-mfa-login-browser.drv`
  → `/nix/store/cqa1xps3fxj42hvwa5nhhk6hm5ljgsww-vm-test-run-overalls-mfa-login-browser`
- `/nix/store/68xfwf7lk2h2ygxxggz7q5ar0wfl31h4-vm-test-run-overalls-admin-account-browser.drv`
  → `/nix/store/rz3x0q2v96h8i295d8cr34yhwnvcszh5-vm-test-run-overalls-admin-account-browser`

Both use packaged release
`/nix/store/c6x103d0jsnr1n06l9z5mnph952jy3mm-overalls-marshall-0.1.0`;
execution is recorded in `/tmp/overalls-admin-step-up-final-native.log`.
Real Chromium, verified TLS and a virtual WebAuthn authenticator passed ordinary
and remembered read/export access, no-key Security return and explicit retry
followed by exact inline action continuation, the persisted 900-second receipt,
cancellation/focus restoration, role refusal, colocated cross-replica revocation,
expired-challenge proof refusal while ordinary access survives, and fresh proof
on a third serving replica. This capture includes final no-key return, generic
verification copy, browser state and machine recovery source. These journeys
do not exercise VM target-page recovery, timed 899/900/901-second expiry,
argument substitution, reconnect or broader mutation families. Machine recovery
remains the scoped five-test evidence above. No hardware authenticator or
independent physical-host claim follows from these colocated fixtures.

Exact pushed-merge packaged browser checks passed at
`d4bd02147cf745435d558816a43eb58de93576b1` with both builds exiting zero.
The login browser subprocess took 22.95 seconds; its VM-script block took
52.13 seconds and reported finished duration was 52.16 seconds. The account
browser subprocess took 29.52 seconds; its VM-script block took 55.25 seconds
and reported finished duration was 55.27 seconds. Their immutable artifacts are:

- `/nix/store/jcv03w97hsqb9za78zcs8x0i665cf2sq-vm-test-run-overalls-mfa-login-browser.drv`
  → `/nix/store/yy8hg91x5ai3r8jhxmy2ddkvbrg90kgk-vm-test-run-overalls-mfa-login-browser`
- `/nix/store/m7bnp3xb93yk9mvayff22myhq1fcm877-vm-test-run-overalls-admin-account-browser.drv`
  → `/nix/store/qavln2hzrll9j4ivv5zjbm0s5k624kk7-vm-test-run-overalls-admin-account-browser`

Both use release `/nix/store/8qiaq96va3rc5lk1c1fzpp7dswi19l0s-overalls-marshall-0.1.0`;
execution is recorded in `/tmp/overalls-admin-step-up-merged-native.log`.
The verified-TLS Chromium/virtual-WebAuthn assertion scope is unchanged:
ordinary and remembered access, no-key enrollment return and explicit retry,
exact inline continuation, persisted 900-second receipt, cancellation/focus,
role refusal, cross-replica revocation, expired-challenge ordinary-read continuity
and fresh third-replica proof all passed on the pushed merge. VM target-page
recovery, actual timed expiry, hardware authenticators and physically independent
hosts retain the gaps above. This rerun includes upstream Push 3 protocol,
runtime and obsolete terminal-notice removals.

Historical Control room, credential self-service, remembered login/revocation and Customer
tests remain recorded only at their captured revisions and scopes. They do not
establish fifteen-minute expiry, inline continuation, no-key setup/retry or
cross-tab substitution refusal. The scenario ledger adds an explicit gap for
those new boundaries and keeps historical evidence intact.

Final integration ADR structure passed for 158 decisions. Generated scenario
coverage, Ash/domain and deployment-topology checks, generated options,
conflict-marker, contract and logging checks passed after resolving the
documentation conflicts. Contract checking includes 19 JavaScript validator
tests; syntax validation is not semantic authorization proof. All-file pinned
Python Ruff formatting, Ruff linting and ty checking passed. The evaluated Nix
HLDD gate passed; its execution log is
`/tmp/overalls-admin-step-up-final-hldd-nix.log`. These structural results do not
establish runtime acceptance. Source/chapter changes after a receipt require its
review again. Exact pushed `d4bd0214` also passed all-file pinned Python
Ruff formatting/linting and ty checking
(`/tmp/overalls-admin-step-up-merged-python.log`) and evaluated Nix HLDD
(`/tmp/overalls-admin-step-up-merged-hldd-nix.log`). The pre-`f603be11` Marshall precommit was stopped after main
advanced; it has no completed result and is not evidence. The latest merged
Marshall precommit passed against `d4bd0214` with exit zero. Its Elixir result
was 1,474 passed (237 properties and 1,237 tests), four excluded, in
1,216.0 seconds. Node browser suites passed 32 terminal tests and eight
repository-launch/MFA tests; workspace TypeScript passed. Forced Dialyzer
passed with zero errors, zero skips and zero unnecessary skips. The complete
log is `/tmp/overalls-admin-step-up-merged-precommit.log`. This run includes the
first-enrollment return/explicit-retry and five machine recovery examples; those
LiveView results do not replace native target-page recovery acceptance.
Merged-source review found no concrete source conflict or authority regression;
all results retain the exact pushed-merge scope rather than later main changes.

Preferred implementation acceptance is a generated real-action history model of
login/role/receipt/continuation changes plus a NixOS browser journey over verified
TLS and real WebAuthn assertions. Include enrolled and no-key administrators,
email freshness, exact 899/900/901-second boundaries, cancelled/expired/replayed
continuations, two-tab argument substitution, role/login/key loss while open,
commit-order revocation and elevated foreign Customer refusal. Run the
continuation and its fresh authority checks across independent Marshall
processes sharing PostgreSQL. Hardware authenticators, physically independent
hosts and production cutover remain separate acceptance.

## Final diff assessment

This is an architecture-impacting change to the accepted browser
authorization policy under ADR-0160. ADR-0123 is superseded with reciprocal links;
historical rationale and executed scopes remain preserved. Handbook access,
workflow, guest launcher, interactive, service and security chapters distinguish
the new behavior from historical execution and include explicit refusal paths.
No change to evaluated Ash ownership or fleet placement is expected; those views are
checked as preserved boundaries.
