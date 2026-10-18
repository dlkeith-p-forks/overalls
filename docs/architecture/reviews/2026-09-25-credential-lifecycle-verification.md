# Credential registration and account retirement verification

## Scope and architecture impact

Campaign improvement 014 uses `verify/014-credential-lifecycle` and its own
worktree, based on published main `8773b1b4`. The scope is ordinary manual SSH
key addition and browser key approval overlapping account retirement and completed
cleanup, entirely in disposable local PostgreSQL fixtures.

The change repairs the existing admission requirement in ADR-0066. It retains
ADR-0046's shared owner-scoped key action, immutable registration identity and
post-commit diagnostics. No new resource, schema, protocol, permission, service
or deployment decision is introduced. ADR-0066 remains partial because its
broader physical recovery and deployment obligations remain separately tracked.

## Existing coverage and reproduced mismatch

The original [key property](../../../marshall/test/marshall/ssh/key_test.exs)
checks duplicate ownership, removal and re-registration. The existing
[approval histories](../../../marshall/test/marshall/ssh/authority_model_test.exs)
vary approval, expiry, gateway rotation and revocation. The
[account histories](../../../marshall/test/marshall/accounts/account_lifecycle_history_test.exs)
exercise sequential identity generations and old-UUID cleanup. None overlapped
new key registration with completed retirement cleanup.

Baseline `8773b1b4`, seed `14014`, ran the four new deterministic schedules
before any production edit. Both registration-first schedules reproduced the
same defect: the real manual or approval action paused at its selected account's
key INSERT, a second Marshall completed retirement and `DeleteUserMachines`,
then the first action committed an active registration for the retired UUID.
The third Marshall observed both the completed deletion receipt and the active
key. The assertion requiring no active keys failed. The retained tombstone UUID
allows the foreign-key relationship; the active fingerprint remains occupied.

The retirement-first baseline schedules failed their account-fence observation
deadline. Those failures do not independently establish another product defect.
All four calls were drained before cleanup; the isolated database then contained
zero fixture keys, gateways, deletion receipts and trigger gates. Baseline log:
`/tmp/verify014-baseline.log`; 0/4 passed, 11.3 seconds.

This is a durable workflow consistency defect. Current SSH session authorization
separately checks that the user remains active; these tests establish no access
bypass and perform no live-system probes.

## Repair and lock review

[KeyActions](../../../marshall/lib/marshall/ssh/key_actions.ex) now calls the
existing [account admission fence](../../../marshall/lib/marshall/accounts/account_lifecycle.ex)
before the key owner and fingerprint locks. That fence rechecks the current user
after acquiring shared transaction authority. Retirement holds its exclusive
counterpart before disabling the account. If registration wins, retirement waits
for its outer commit and cleanup sees the committed key. If retirement wins,
registration refuses and leaves key and audit state unchanged.

The manual [LiveView](../../../marshall/lib/marshall_web/live/account_live.ex)
and nested [approval action](../../../marshall/lib/marshall/ssh/authority.ex)
both call the same public key action. Approval retains gateway, session and
approval locks through the nested registration and outer commit. Retirement
does not acquire those locks; its later cleanup archives keys separately.
The new account fence precedes the existing key owner/fingerprint locks. Current
SSH commands expose key listing/removal; there is no separate command registration
path. Internal raw resource registration remains restricted to trusted coordinators.

The reviewed contracts include repository evidence/privacy rules, Marshall's
durable authority and Ash resource boundaries, SSH owner selection and immutable
revocation identity, account admission, PaperTrail actor propagation, and test
isolation/three-independent-BEAM requirements. The final implementation retains
existing diagnostic emission after the outer commit; nested key addition still
leaves approval's existing outcome event responsible for that transaction.

## Verification design

The [distributed schedules](../../../marshall/test/marshall/ssh/credential_retirement_distributed_test.exs)
start three distinct Marshall BEAMs, each with an independent Repo pool and shared
committed PostgreSQL state. The parent is excluded from the three. Targeted
[fixture triggers](../../../marshall/test/support/credential_retirement_fixture.ex)
pause actual production writes without acquiring account locks on their behalf.
The competing process must wait on the exact account advisory lock. A separate
process verifies unchanged committed state while the first action is paused.

Both manual and approval paths run in both orders. Assertions compare exact
registration IDs, archival state, user registration/system cleanup PaperTrail
attribution, approval consumption, session binding, deletion completion and
administrator event inventories. All three peers replay stale registration and
completed cleanup without changing these projections. A fresh account explicitly
registers the released fingerprint with a new key ID. Failed assertions unlock
and drain both actions before removing only the fixture's records and triggers.

The [generated histories](../../../marshall/test/marshall/ssh/credential_retirement_history_test.exs)
run twelve generated histories, each containing two or three same-email identity
generations. They vary manual/approval registration, duplicate attempts,
revoke/re-add and cleanup replay. Real magic-link registration creates a new UUID
while old cleanup is pending. It inherits no keys and cannot reuse the fingerprint
until cleanup releases it. Stale login-bound actors cannot mutate inventories;
old authenticated sessions do not become current through replacement key IDs.
The administrator uses real signed fixture WebAuthn registration and verification.

Focused fixed-candidate verification passed: 5 passed (1 property, 4 tests),
seed `14015`, 10.0 seconds. Runtime code is based on `8773b1b4` with the admission
repair and new tests. The focused log is `/tmp/verify014-focused.log`.

Removing only the admission call after the focused pass reproduced both late
active-key failures (seed `14016`, 14.2 seconds, `/tmp/verify014-mutant.log`).
Both retirement-first schedules again failed the account-fence observation. The
mutant was restored before subsequent checks; fixture inventories were drained.
Restored broad focused verification passed: 38 passed (4 properties, 34 tests),
seed `14017`, 12.7 seconds (`/tmp/verify014-restored.log`), covering key, approval,
account retirement and browser key/approval suites. The coordinator reviewed the
restored source, callee lock order, tests and contracts without a finding in this
scope.

Full Marshall precommit passed at captured tree
`eb2474b9703fdcfe4407a45b69e2c291b4baa998`, base `8773b1b4`: 1,043 checks
(100 properties, 943 tests), two exclusions, seed `170803`, 367.6 seconds.
Compiler, runtime, logging, contracts, browser state checks and forced Dialyzer
all passed. The dependency PLT was rebuilt; final application analysis took
47.08 seconds with zero errors, zero skips and zero unnecessary skips.
The complete log is `/tmp/verify014-precommit.log`.

All-file prek passed, including ruff, formatting, ty and application logging
checks. ADR, HLDD receipts, generated options, coverage and Ash/deployment views
passed. The initial Nix HLDD result was
`/nix/store/w6pkkw9gmil2bpkwsjm8652g35vmx4lh-overalls-hldd-check`.
Post-suite fixture inspection found zero keys, credential gateways, deletion
receipts and trigger gates in the isolated database.

After the full gate completed, the branch integrated main `df5f2a3f` (campaign
015's pinned browser helper typing and documentation). Its changes do not alter
Marshall application behavior. The repair and tests are unchanged from the
captured tree. Combined credential and shared ADR/HLDD tests passed: 50 checks
(9 properties, 41 tests), seed `14018`, 12.1 seconds. All-file prek, contracts,
ADR/HLDD/generated-reference and Nix HLDD checks passed on that integration.

The branch subsequently integrated published main `daa8491d` (campaign 012).
Review confirmed the only production changes were the team-member Cedar
read/write repair and a closed Galileo refusal-reason logging allowlist, with
mail redaction retaining precedence. Account/key/approval handlers were unchanged.
Only documentation evidence and review receipts required conflict resolution.
Both improvements' records remain intact.

At combined runtime tree `29459962a772e6c2e487736435f7d70642efbbc2`, credential,
Cedar, log-filter, Teams resource/retirement and SSH/Galileo API checks passed:
29 checks (13 properties, 16 tests), seed `14019`, 40.5 seconds. The log is
`/tmp/verify014-final-combined.log`. A trailing separate Dialyzer invocation
initially selected the development environment; its owned process was stopped
while compiling, and no result is claimed. A new explicit `MIX_ENV=test` forced
analysis includes the regression fixtures and passed in 53.08 seconds with zero
errors, zero skips and zero unnecessary skips. Its log is
`/tmp/verify014-final-test-dialyzer.log`.

Final combined fixture inspection found zero keys, credential gateways,
deletion receipts, credential gates and team-retirement gates. This integration
uses the scoped focused runs; the full 1,043-check result remains attached to its
earlier captured source.

Final combined all-file prek, ADR, contract, HLDD review, generated options,
coverage, Ash/deployment view and Nix HLDD checks passed. The complete record is
`/tmp/verify014-final-static-combined.log`. Final architecture review found no
new policy or schema change: the existing retirement admission requirement is
now enforced at the shared credential registration boundary. Native, mixed-release
and historical-record limitations remain as stated below.

## Limits and remaining work

These are real Ash/PostgreSQL workflow and multi-process ordering tests. They
create no VMs and claim no guest isolation, physical cleanup, network or browser
transport evidence. Existing native Porsche/browser registration and account
retirement journeys retain their recorded revisions and scope. Native tests do
not expose a deterministic database insertion schedule, so this change uses
generated histories and committed distributed tests for that boundary. A future
combined native browser/SSH registration-versus-retirement journey would cover
transport delivery under concurrent user actions; arbitrary failures and separate
physical control-plane hosts remain outside this evidence.

The repair prevents new late registrations once all registration-serving Marshall
replicas include it. Mixed-version operation retains the older writer's gap. This
change does not inspect or sweep any existing production registrations created
by older code after an already-completed deletion receipt. No production
connections, data migration or deployment were performed.

Affected decisions: [ADR-0066](../decisions/0066-account-retirement.md),
[ADR-0046](../decisions/0046-porsche-ssh-management.md).
