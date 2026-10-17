# Administrative account mutation authority verification

## Scope and architecture impact

Campaign 022 has one worktree and branch `verify/022-admin-account-authority`.
Investigation and baseline used published `3f679eff`. Full component and native
acceptance captured tree `30492fea5c1bdf7365f5aaffef6f322f068c436c` on published
`d2a47671`. The final branch integrates published `d8f05479`, including terminal
startup recovery, application READMEs and private-web verification; the account
production/test/native files are byte-identical to that capture. Fixtures are
disposable; this change performs no production deployment.

This reconciles inherited ADR-0058/0065 authority with ADR-0123 and ADR-0066.
Current role, login and elevation remain prerequisites for account mutations,
held through their audit commit. Previously committed durable retirement work
still survives later authority loss. No schema, protocol, permission, dependency,
bootstrap or account/team/guest admission decision changes. All serving replicas
must receive the correction before relying on its ordering guarantee.

## Existing evidence and baseline

Existing administrator tests cover bootstrap once, no self-demotion, last-admin,
forged/stale roles and audit. The Control room generated/native journey covers
ordinary reads, audited role changes, demotion and mounted login revocation.
Account lifecycle histories/native acceptance cover invitation and same-email
retirement with real old-UUID guest reclamation. Fresh guest identity verification
covers sorted multi-user roster allocation. These retain their original scope;
none proved account mutations versus actor-only elevation lock or ordinary
sign-out at transactional audit commit.

Before production edits, a real role grant paused at its actual audit INSERT
failed the ordering oracle: a second Marshall completed `Security.lock`, a third
observed revoked elevation, and the paused grant still returned success.
The initial test failed, seed `22001`, 4.4 seconds.

The full unchanged-production matrix reported **2/20 passed, 18 failed**, seed
`22002`, 9.2 seconds. Role grants, global browser-session revocation, MFA resets
and invitations failed both orders against elevation lock and ordinary sign-out
(16 failures). Retirement-first passed both competitors, but revocation-first
waited and still returned success (two failures). A late foreign-key wait is a
source hypothesis for that retirement asymmetry, not a claimed SQL-traced cause.
These are overlapping-operation findings, not evidence that requests begun after
completed revocation were admitted. Logs: `/tmp/verify022-baseline.log` and
`/tmp/verify022-baseline-matrix.log`.

## Correction and lock review

[Security.lock_admin_participants!](../../../marshall/lib/marshall/accounts/security.ex)
locks actor/target once in sorted unique ID order. Actor-only rows use
`FOR NO KEY UPDATE`; the target retains `FOR UPDATE` from its initial acquisition.
The weaker actor lock still excludes Security, sign-out and User authority
mutations, while permitting unrelated foreign-key `KEY SHARE` references. The
original single-user `Security.lock_user!` remains unchanged. The helper preserves missing
and retired rows for the caller's existing semantic checks; it does not create
an identity or grant authority. Administrators and AdminUsers retain the
installation latch, lock actor and target, then freshly check authority before
mutating and auditing. MFA reset follows the same participant order.

Retirement takes installation → exclusive target account-admission fence →
sorted actor/target User rows → existing team/integration/retirement writes.
It freshly checks authority even when returning an existing deletion receipt.
Invitation takes installation → actor User → token/outbox recipient lock → audit.
The actual Ash Authentication Request path performs a target lookup read, issues
a resource-subject magic-link token, and enqueues encrypted mail. It does not
sign in, mutate a recipient User row or allocate a guest identity.

Reviewed lock consumers include Security ceremonies, remembered exchange,
ordinary mixed-cookie sign-out, GuestAccounts allocation/SSH roster, bootstrap
and registration, Teams membership/transfer retirement and account admission,
MFA reset/global revoke, retirement integrations and the Users LiveView. Sorted
participant locking agrees with mixed-cookie and guest allocation sets. The
retirement fence remains before every participant User lock. Team-owned work,
credential admission and later durable cleanup retain their accepted fences.

### Rejected strong-actor candidate

The first correction used `FOR UPDATE` for both participants. Parent review
identified a specific cycle with Teams: actor A owns team X, retired target T is
a nonowner member, and A concurrently adds unrelated U. Actual membership holds
team X before its `recorded_by_id` foreign-key reference to A; retirement held A
before waiting for X. The new three-peer audit fixture reproduced PostgreSQL
**40P01 deadlock**, seed `22007`, **0/1 passed**, 4.6 seconds. Restoring the exact
published accounts source made that same schedule pass **1/1**, 4.9 seconds.
This was a regression in the initial candidate, not a pre-existing Teams defect.
Logs: `/tmp/verify022-team-cycle-candidate.log` and
`/tmp/verify022-team-cycle-baseline.log`.

The final participant helper permits the unrelated reference with `NO KEY UPDATE`
for actor A. Target T keeps the historical strong lock before Team work or a
unique-email change; no late target-lock upgrade was introduced. The exclusive
T admission fence still excludes sanctioned membership/transfer work involving T.
The added schedule requires both unrelated membership and retirement to commit,
then independently checks U retained, T removed and T retired. The repaired schedule passed in the seed `22008` combined run described below.

Contracts reviewed: repository privacy/evidence, Ash domain ownership, stored
login authority, permanent bootstrap, audited role/revocation, account admission,
fixed elevation, remembered-token ordering and three-independent-BEAM fixture
isolation. New contracts specify participant ordering, invitation, reset and
retirement commit authority. No conflicting requirement was found.

## Verification

[Generated histories](../../../marshall/test/marshall/accounts/admin_account_history_test.exs)
call actual account actions with independent role/login/elevation and target
state models. Five operation families include lock, signed passkey verification,
ordinary sign-out, new login, real demotion/promotion, idempotence and retirement
retries. Forged cached administrator flags cannot change admission. Refusals
compare complete row inventories, including hashed credential/token contents,
outbox/jobs, target identity, deletion receipts and audit.

[Distributed schedules](../../../marshall/test/marshall/accounts/admin_account_distributed_test.exs)
use three separately started Marshall BEAMs and pools; the parent is not counted.
Actual audit or revocation writes are gated without adding production authority
locks. A third peer observes committed state and PostgreSQL blocking. Both orders
cover all five actions and both revocations; subsequent mutations refuse on every
peer with identical inventories. Separate ungated calls start only after completed
revocation. An existing-retirement receipt must wait and recheck authority.

Reversed actor/target IDs contend with real GuestAccounts allocation and actual
mixed-cookie sign-out. A separate shared-admission-fence schedule proves retirement
has not taken actor User while waiting for that fence. A deliberately failing
nested gate preserves its original assertion, releases the gate, drains both
mutations and checks subsequent refusals and fixture removal. All remote mutations
use peer-side completion envelopes; uncertain peers are stopped before cleanup.

Initial corrected source passed **25 checks (5 properties, 20 distributed tests)**,
seed `22003`, 18.9 seconds. The expanded suite on `d2a47671` passed **31 checks
(5 properties, 26 distributed tests)**, seed `22005`, 29.4 seconds. The prior
expanded run passed 28/29: its only failure was exact formatting of the intentional
ExUnit failure message, corrected to a content match. An intermediate test edit
failed compilation due to a missing optional parameter; it supplies no runtime
evidence. Logs: `/tmp/verify022-focused.log`, `/tmp/verify022-focused-2.log`,
`/tmp/verify022-focused-3.log`, `/tmp/verify022-focused-4.log`.

A descending-order mutant initially survived the reversed-participant oracle:
**2/2 passed**, seed `22006`, 4.3 seconds. `pg_blocking_pids` includes soft queue
edges, so two callers waiting for the higher row appeared ordered even when the
mutation had not attempted the lower row. The oracle now requires an actual
ungranted transaction-ID lock whose owner is the sorted consumer. The same mutant
then failed **0/2 passed**, 10.5 seconds; source was restored. Those historical
mutants used the initial strong-actor candidate. Repeating the descending-order
mutant against the final mixed-mode helper failed **0/2 passed**, seed `22009`,
12.8 seconds; the final helper was restored. Log: `/tmp/verify022-final-mutant.log`. Logs: `/tmp/verify022-mutant.log`, `/tmp/verify022-mutant-2.log`.

The mixed-mode correction plus existing administrator/lifecycle tests reported
**50/51 passed (5 properties, 46 tests)**, seed `22008`, 26.1 seconds. The new
Teams cycle and all ordering schedules passed. The sole failure compared a
parent-node Ash resource struct with a peer-node struct: persisted row hashes
and exposed attributes were identical, while hidden process-context metadata
made full struct equality fail. Snapshot convenience projections now contain
explicit persisted User/audit fields; full row digests remain unchanged and
continue to cover every stored field. Log: `/tmp/verify022-final-focused.log`.
Final integrated validation follows below.

The shared disposable baseline partition was inspected after failed and corrected
runs: users, tokens, account audit, deletions, outbox, Oban jobs, guest accounts and
gate functions all contained zero fixture rows. This is explicit cleanup evidence,
not a clean new partition concealing residue.

### Captured complete component gate

The frozen tree above passed **1,124 checks (116 properties, 1,008 tests)**,
two excluded, seed `334525`, in 505.3 seconds. This includes the final five account
history properties and **27 distributed tests**, with canonical persisted
snapshots and the actual Teams foreign-key cycle regression. `MIX_ENV=test mix
precommit` also passed compiler, contracts, ADR/HLDD, logging and JavaScript gates.
Its forced test-environment Dialyzer completed with **zero errors, skipped findings
or unnecessary skips**, 53.86 seconds after the PLT rebuild. Log:
`/tmp/verify022-full-gates.log`.

The completed full-suite partition was independently inspected: users, tokens,
account audit, teams, retirement receipts, outbox, jobs, guest accounts and
administrative gate functions all contained zero rows. No account peer BEAMs
remained. Earlier failed/mutant partition cleanup is separately recorded above.

### Captured native browser acceptance

The [native fixture](../../../nix/verification/tests/machines/admin-account/default.nix) uses
packaged Marshall/PostgreSQL, verified browser TLS and virtual WebAuthn. The
captured **admin-account-browser passed in 53.97 seconds**, with its browser
journey taking 25.35 seconds and VM cleanup taking 0.58 seconds; Nix exited zero
in 56 seconds. All exact shell/Nix/builder/driver/QEMU/vde process IDs were absent
afterward, and the global driver/QEMU/vde search was empty.

Its browser journey enrolls three users, locks one login while another tab retains
Users, refuses the stale reset with identical inventory, reverifies and resets an
enrolled target, checks the generation/key/audit effect and mounted target sign-out,
then uses a second administrator's ordinary browser demotion. Five separately
mounted pages submit the five stale account mutations and require individual error
acknowledgments plus unchanged inventories. The demoted user retains read-only
Users access. Real guest reclamation remains credited to its prior native suites.

| Captured input/result | Exact artifact |
| --- | --- |
| Native derivation | `/nix/store/ymm9lzbm8aavbc416nbwz7kwf61ll15f-vm-test-run-overalls-admin-account-browser.drv` |
| Native result | `/nix/store/7h86cy0337b66c9qzcja053ds1zawl7n-vm-test-run-overalls-admin-account-browser` |
| Driver | `/nix/store/5ffpbvn55610gsiqd86w0iq4pmm17kz0-nixos-test-driver-overalls-admin-account-browser` |
| Packaged Marshall | `/nix/store/ms8ya2dybr8g2qlxg7fi4gi8baiw8bi9-overalls-marshall-0.1.0` |
| Typed browser artifact | `/nix/store/vv0xw6y7bvn5a74gbwb2n5jhc9ks4s60-admin-account-browser-typed` |
| Python SHA-256 | `80ae95427c15ec8e963f27a5501a167aad90100dea9d3e874c74d073ed6c0b03` |
| JavaScript SHA-256 | `9ea00f0f4b9174642809311818b1d051287cd26c9450c331bc21de6fb7bbbc7e` |

The final browser hashes match the executed typed artifact. It passed pinned
Python/Playwright and strict JavaScript checking; the NixOS framework checked the
composed driver. The first build attempt failed at the removed `nodePackages`
alias and started no runtime. The corrected top-level TypeScript artifact
`43vgp5v58fxwb3bvqscz005jnghz032b` preceded final private-error wrapping/formatting;
only the final `vv0xw6y7` artifact is attributed to this native run.
Runtime log: `/tmp/verify022-native-runtime.log`; complete archive:
`/home/ghuntley/.local/state/nix/build-logs/1790372821784-3689615-0.jsonl`.

The frozen driver, Nix `hldd` and `python-static` gates passed together in 254
seconds. All-file `prek` passed logging, HLDD, Ruff formatting/lint and ty;
ADR, generated options/coverage/views and contract checks passed. Native Elixir
annotation discovery was also reviewed manually because upstream `cc-check list`
does not discover that syntax; repository `mix contracts.check` remains the
structural gate, without claiming it proves contract semantics.

Integrated checks after `d8f05479` are recorded separately below. The captured
full/native results do not claim execution of that later whole repository revision.
Hardware authenticators, independent physical hosts, production rollout and SMTP
delivery remain separate acceptance boundaries.

### Integration on published `d8f05479`

Integrated tree `5be7589948b2718d7a7e3acda70f2b86c28b201f` retains the account
source/test/native inputs byte-for-byte from the capture. Only the ADR index and
receipt JSON needed merge reconciliation; both upstream and account evidence
remain intact. Final architecture assessment preserves the accepted decisions,
domain ownership, protocol and deployment topology. Parent review found no
remaining semantic or contract blocker.

The focused account/private-web/terminal run passed **15 checks (10 properties,
five tests)**, seed `22010`, 50.0 seconds. Its standalone invocation kept the
default distributed exclusion (27 excluded). An explicit subsequent
`--include distributed` run passed **27/27 account schedules**, seed `22011`,
10.3 seconds. These are distinct scopes, not a second complete suite. Compiler
warnings-as-errors, format and contract checks passed, and forced test Dialyzer
reported **zero errors, skipped findings or unnecessary skips**, 57.16 seconds.
Logs: `/tmp/verify022-integrated-focused.log` and
`/tmp/verify022-integrated-distributed.log`.

The same full-suite partition again had zero users, tokens, account audit, teams,
deletions, outbox, jobs, guest accounts and administrative gate functions; no
account peer BEAMs remained. Audit: `/tmp/verify022-final-fixture-audit.log`.
The integrated ADR, HLDD, generated options/coverage/views and all-file `prek`
checks passed; their log is `/tmp/verify022-integrated-governance.log`.
Final evidence/receipt edits do not alter application, test or native inputs.
