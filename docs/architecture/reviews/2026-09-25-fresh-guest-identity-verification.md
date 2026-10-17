# Fresh guest identity verification

## Scope and checkpoint

Campaign improvement 018 starts from published `7681806b` and incorporates
upstream `0cfa6302` (ADR-0124 SSH host CA), then `aaba77ee` (gateway
certificate startup recovery and deployment evidence) and published `8773b1b4`
(campaign 011 shared fleet trust prerequisites). The coordinator
reviewed and authorized the design under the existing campaign scope. The
allocator, additive migration, batch roster and durable SSH discovery are now
implemented under ADR-0125. The full Marshall precommit and static governance
gates pass. The fourth complete NixOS native journey passed, including fresh
SSH/browser identities, preserved shared homes and packaged managed Lyra SSH.
The three earlier failed attempts retain their exact scopes below.

The user operation is ordinary verified registration after another account with
the same email has retired, followed by installer account discovery, personal
guest SSH and a browser terminal. Existing homes, UIDs, old grants and credentials
must not transfer to that fresh UUID. Explicitly sharing a surviving VM with the
fresh UUID must not break access for its existing writers.

## Baseline defects corrected by this change

1. **High: fresh guest allocation is unavailable.** ADR-0066 permits a new UUID
   with the released email; the exact-name requirement inherited from
   ADR-0110 through ADR-0115/0117 permanently reserves the previous local part.
   `GuestAccounts.ensure!/1` tries that name again and the PostgreSQL
   `account_guest_accounts_username_never_reused_index` rejects it. Improvement
   009 observed this on a real guest. The new real-action generated history
   independently reproduces the conflict after actual retirement and verified
   magic-link registration.
2. **High: one colliding writer refuses the complete shared roster.** A real
   `GuestAccess.roster/2` test first materializes an owner and an explicitly
   shared writer. After retirement, the owner's roster succeeds alone. After
   same-email registration and a new explicit share, the complete request fails
   at the username unique index. This establishes the database/API consequence;
   it does not yet establish how a running guest behaves during that refusal.
3. **Medium: account discovery can advertise an unusable identity.**
   `SSH.Commands` derives `whoami.result.guest_username` directly from the email.
   It does not use the allocator. Updating allocation alone would leave Lyra's
   managed SSH profile pointed at the old name. The account-proof regression
   exercises the real registered-key/gateway/session/command actions.

These are related to the concrete `guest-account-never-reassign`,
`email-guest-username-exact`, `guest-roster-bound-current-writers` and
`lyra-proved-guest-account` contracts. Permanent identity reservation remains
necessary; simply allowing the old username to be reused would violate the home
ownership rationale. Exact local-part naming needs an explicit narrow replacement.

## Accepted decision in ADR-0125

Carry forward ADR-0117 and its predecessor requirements. Replace only the rule
that every incarnation must use exactly the local part:

- Preserve an existing allocation while its stored source local part matches the
  current eligible email. Never rename an allocated identity in place.
- When creating an incarnation, use the full safe local part if no historical
  allocation owns that name. Otherwise use a bounded prefix of that same local
  part plus `_g` and a fresh sequence UID, at most 32 ASCII bytes. The UID suffix
  distinguishes generations and preserves a readable email-derived prefix.
- A suffix that happens to equal another permanently reserved name must also be
  skipped. Allocate another never-reused sequence value and try its suffix; never
  reassign that reservation or mutate its home. A complete batch has at most 512
  users and a shared budget of 64 occupied suffix candidates; exhausting that
  budget refuses the whole batch. Sequence gaps are permitted, as they already
  are on transaction rollback. Existing noncycling UID range 200000 through
  999999 stays unchanged; exhaustion refuses with the previous incarnation intact.
- A rename, including returning to a prior local part, creates a fresh
  incarnation. Repeated calls for the same current local part reuse its account,
  name and UID. Case normalization retains current semantics.
- Persist `email_localpart` separately from `username`. Backfill existing rows
  from their historical exact usernames, including retired rows; deriving from
  today's User email would corrupt rename history or read a retirement tombstone.
- Use an additive nullable column for old-release inserts, with a narrow legacy
  fallback to the stored username when the new field is null. New allocation
  always writes the source local part. Retain the permanent username/UID indexes,
  current-user partial uniqueness, UID range and Linux name constraints.
- SSH account discovery resolves `GuestAccounts` in its existing authenticated
  transaction and returns that durable username. First discovery may allocate
  before any VM exists, with the authenticated user as PaperTrail actor. Stable
  repeats do not add versions, and retirement denies the old authenticated
  session. Browser personal terminals
  already use the same allocator. Wire fields and guest account reconciliation
  remain compatible; no caller may derive a suffixed name independently.

The schema is readable/writable by old releases. An old Marshall can still refuse
a new suffixed identity because its allocator compares the username with the
email and its `whoami` still advertises the old name. No new identity can inherit
the old home or credentials through this overlap. Full fresh-identity usability
requires all serving Marshall nodes to run the new code. This limitation must be
explicit in rollout documentation; this campaign does not deploy production.

## Coordination design

The baseline roster looped owner, grants and team members, taking user row locks in
that incidental order. Adding a name-allocation lock inside that loop would allow
one roster to hold the global lock while waiting for a user row held by another
allocator waiting for the same global lock. Do not use that order.

Introduce one batch allocator for the roster and a single-ID wrapper for personal
terminals and SSH discovery. A batch takes unique user IDs in canonical sorted
order, obtains every user row lock and rechecks active stored identity before
allocation. It obtains current GuestAccount rows under those user locks. Only
when at least one incarnation needs allocation does it take the PostgreSQL
transaction advisory lock for the permanent name namespace. It performs all name
selection and Ash allocation without acquiring additional user locks. Normal
repeated roster refreshes do not take the namespace lock.

The transaction retains all locks through commit; one call supplies the entire
batch. The roster retains fresh Cedar checks and its host, VM, placement, epoch,
generation and operation fences. A concurrently retired candidate must be
rechecked rather than allocated from a stale User struct. The precise retry or
refusal shape will be tested with independent BEAMs. No new local process or cache
becomes authority. Permanent PostgreSQL constraints remain the final safety net,
including during mixed-release overlap.

Enclosing lock order was traced through the production callers. SSH discovery
holds gateway/session shared locks, its per-user command advisory lock and the
authentication key shared lock before the allocator locks its User. Personal
terminal opening holds its VM row before the User. Roster retrieval holds its
credential and VM before the sorted User batch. Retirement holds the bootstrap
row, rechecks administrator authority, acquires its account admission fence and
User row, then team rows; it takes no allocator namespace or VM lock. Credential
cleanup is a later transaction. Allocation never takes a key, session, VM or
team row lock after acquiring users or the namespace. All production allocator
calls were inspected; roster is the only multiple-user caller and now supplies
one complete batch rather than looping `ensure!/1`.

## Consumers inspected

Production allocator calls now occur in `SSH.GuestAccess.roster/2`,
`Terminal.Authority.open_personal_session/3` and authenticated `SSH.Commands`
discovery. Guest account reads in
`GuestAccess.decide!/3` already compare the persisted username. `SSH.Commands`
now returns the allocator result instead of directly deriving the email base. `EligibleEmail`
uses `GuestUsername.from_email/1` as admission validation and must retain its
current exact safe-email rule; that parser returns the preferred base, not the
allocated incarnation name.

Lyra's `ssh_config.rs` validates a safe name of at most 32 bytes and writes the
server response into the wildcard profile. The Rust guest helper validates the
same shape, materializes `/home/<username>` with the roster UID and matching GID,
and expires removed accounts while keeping home data. Existing username/UID/home
conflicts still fail closed. No consumer cap was reached in these symbol searches.
The protocol, Lilly, Audi, Porsche and Ziggy source searches found no independent
production guest-name derivation to update.

## Verification plan

1. Generated real-action histories: repeated verified same-email generations;
   stable repeated allocation; all prior username/UID reservations unchanged;
   old credentials, grants and personal terminal receipts not inherited. Add
   rename/return histories, maximum-length names and generated-name collisions.
2. Independent roster oracle: original owner and other allowed writers survive;
   replacement excluded before a new explicit share; replacement included with a
   distinct durable identity afterward. The integrated same-email team rejoin
   history also covers this candidate path with improvement 012's accepted policy.
3. Account-proof and personal-terminal actions: returned/installable username and
   opened personal shell use exactly the current allocated identity, and retries
   reuse it. Stale UUID and stale requested username remain refused.
4. Three independent Marshall BEAMs: simultaneous allocation of one fresh account
   produces one durable identity; rosters with overlapping writers and opposite
   ownership acquire user locks in one order; name collision and retirement
   schedules observe actual production SQL barriers and final committed rows.
5. Typed packaged NixOS journey: ordinary registration and key setup; an old
   writer creates a home marker on a shared survivor; retirement disables old
   credentials; same-email replacement has no inherited share; installer proof
   returns the new name; personal SSH and browser terminal use its new home/UID;
   explicit re-sharing leaves the owner's guest access usable and the original
   home/UID/marker unchanged. Fresh own-VM SSH must also succeed. Existing data
   ownership, account expiry and sudo policy are native assertions. Authorized
   writers retain passwordless sudo: this is no automatic identity/home transfer,
   not confidentiality from newly authorized administrators inside the guest.
6. Review the final diff, update ADR supersession, overview/index and HLDD access,
   interactive, deployment and scenario evidence. Run full Marshall precommit and
   forced Dialyzer, contract/logging gates, all-file prek, ADR/HLDD/options/coverage/
   views and Nix HLDD. Preserve explicit native and mixed-release gaps.

## Executed baseline

At `7681806b` plus the new regression file, seed `18018`, the first focused run
finished in 0.6 seconds: 0/2 passed (0/1 property, 0/1 test). Both failed at the
permanent username index; the generated history shrank to two requested
generations and failed on its first replacement. Log:
`/tmp/verify018-baseline.log`. These are expected defect reproductions, not a
passing verification claim. The subsequent run adds the SSH account-proof case;
it finished in 1.3 seconds, seed `18018`: 0/3 passed (0/1 property, 0/2 tests).
The two index failures remained, and account discovery returned exactly the
permanently reserved old username. Log: `/tmp/verify018-baseline-three.log`.
This run had no compiler warning. It ran under the pinned development shell,
using the isolated `marshall_testverify018` database. No type-checker or native
verification claim is made from this deliberately failing run.

## Completion boundaries

The implementation and complete NixOS native journey have passed their recorded
checks. Final integration below preserves those captured scopes; publication is
coordinated separately. Production deployment, populated migration, mixed-release
acceptance and separate native Ubuntu fresh identity acceptance remain outside
this recorded run.

## Focused implementation execution

Focused allocation, identity history, SSH roster/command and personal-terminal
checks passed: **36 passed (6 properties, 30 tests)**, seed `18019`, 13.2 seconds.
Log: `/tmp/verify018-focused.log`. This includes the original three regressions,
rename generations, legacy nullable allocation and old allocator rollback.

The corrected bounds and identity/discovery run passed: **8 passed (2 properties,
6 tests)**, seed `18020`, 3.0 seconds. Log:
`/tmp/verify018-bounds-corrected.log`. Generated histories include 0, 1, 63, 64 and
65 occupied suffix candidates plus generated extras, unchanged permanent
reservations, previous-incarnation rollback, and a combined two-user collision
budget that rolls back its earlier successful allocation. The sequence exhaustion
fixture uses transactional `ALTER SEQUENCE` within SQL sandbox isolation, never
`setval`, and checks the unchanged 200000/999999/noncycling bounds.

An earlier bounds fixture attempted a manual SQL savepoint outside Ecto's
transaction bookkeeping and failed; the corrected fixture uses monotone distinct
reservations inside the ordinary sandbox. The audit-version observation also
needed explicit test-only privileged reads because the generated Version resource
has no public read policy. These fixture failures established no production defect.

## Independent-process execution and mutation

At combined base `0cfa6302`, the five three-BEAM schedules plus the five bounds
checks passed: **10 passed (1 property, 9 tests)**, seed `18022`, 5.5 seconds.
Log: `/tmp/verify018-ca-distributed.log`. Each independently started BEAM uses a
distinct Repo pool. Actual target INSERT/retirement UPDATE gates, User-row waits
and namespace advisory-lock waits establish contention. The third BEAM observes
committed state before release. Both opposite-owner rosters then succeed with
the same two persisted identities.

Removing only the canonical User-ID sort killed that last usability oracle:
**0/1 passed, 4 excluded**, seed `18022`, 4.4 seconds. The second roster returned
PostgreSQL `40P01 (deadlock_detected)` and failed its final `{:ok, accounts}`
assertion. Log: `/tmp/verify018-sort-mutant-corrected.log`. PostgreSQL's blocking
queue observation alone does not prove which user row is held; the final
deadlock and failed roster are the decisive mutation result. The shell trap
restored the sorted allocator, the process exited, and a direct database audit
found zero users, hosts, VMs, guest accounts and gate functions in the isolated
partition. No permanent production reservations were modified.

An earlier unsorted run failed in setup because two synthetic terminal fixtures
could place the second VM on the first host and then present the wrong physical
identity. That run established no mutation sensitivity. Setup now commits both
fixtures or neither and temporarily disables only the captured first host while
creating the second; the real machine-identity fence remains intact. Captured
leaked fixture IDs from the failed attempt were removed and their zero inventory
checked. An earlier teardown foreign-key cycle was corrected by clearing each
captured operation's outcome pointer and deleting its placements/VM atomically.

## Native extension

The existing typed account-lifecycle topology now includes Porsche and retains
its original retirement, offline/busy hold, recovery and shared-VM preservation
assertions. The extension registers distinct old/fresh/survivor keys through the
browser, uses real authenticated account discovery, and tests personal SSH and
browser terminal username/UID/home. The survivor verifies the old shared home
marker and UID remain, its account expires and its sudo policy is removed.
New connections with the old key, a fresh unshared identity, and the old requested
username are explicit refusals. Re-sharing enables the fresh account while the
survivor remains usable. Packaged Lyra setup obtains real HTTPS CA trust and uses
the returned suffixed name. This source presence is not yet passing native
evidence. Fresh authorized writers retain sudo; home preservation does not claim
confidentiality from a newly authorized guest administrator.

After restoring sorted source, the combined allocation/history/bounds/distributed
selection passed **18 passed (3 properties, 15 tests)**, seed `18023`, 9.0 seconds.
Log: `/tmp/verify018-restored-focused.log`. Initial Python formatting found one
import-order issue, subsequently corrected; that log does not claim a Python
type-check pass.

ADR-0124's issuer, certificate bootstrap purpose and CA trust requirements are
preserved after the upstream merge. ADR-0125 changes only durable guest-name
allocation and its caller/discovery behavior. Compatibility tests execute the
previous allocator on the additive current schema, including null-source inserts
and rolled-back suffix refusal. They do not execute an old-release deployment or
backfill existing populated production rows; the migration's historical-username
backfill has been reviewed separately and that upgrade acceptance remains outside
these results.

## Build and gate checkpoint

At combined base `0cfa6302`, the full Marshall suite passed **1054 passed
(102 properties, 952 tests), 2 excluded**, seed `928307`, 386.1 seconds.
Log: `/tmp/verify018-precommit-installed.log`. Forced Dialyzer passed after rebuilding the dependency PLT: zero errors,
zero skips, zero unnecessary skips; analysis took 1m1.35s. The complete
`mix precommit` process exited zero. Pinned toolchain, ADR, HLDD, contract format/discovery and the
19 contract regressions, catalog logging, compiler and browser state checks passed.
All-file `prek run --all-files` passed all logging, HLDD, ruff formatting/lint and
ty hooks (`/tmp/verify018-prek.log`). ADR, generated options/coverage/views and Nix
HLDD checks passed; Nix output:
`/nix/store/lfarfzrjbwhh8cqsh5iaahhdfki01i0j-overalls-hldd-check`.

The original native driver build passed in 314 seconds, including browser `ty`
and strict composed-driver type/lint checks:

- Driver: `/nix/store/csp8r0lwhrfqlknfs8zrc20f1rxhpyzr-nixos-test-driver-overalls-account-lifecycle`
- Driver derivation: `/nix/store/l1xpg0p8dqcip06bv15g9c76cjmqgnca-nixos-test-driver-overalls-account-lifecycle.drv`
- Matching execution derivation: `/nix/store/j8bd4klijypnyz789fic7ndqg28xqwk1-vm-test-run-overalls-account-lifecycle.drv`
- Build log: `/tmp/verify018-native-build-corrected.log`.

The first browser type check rejected direct dict lookup after an object boundary;
explicit string-key validation now provides `dict[str, object]` before field
validation. No unchecked cast or type ignore was added. Privileged fixture CA and
Audi route-key inspection establish strict certificate use only. The packaged
Lyra step separately tests its HTTPS trust/configuration path. Old/fresh browser
terminals on different VMs establish distinct-account controls, not shared
workspace revocation or established-session termination. Native Ubuntu, retained
old disks and independent physical hosts remain separate acceptance.

After the full suite, the isolated database contained zero fixture users, VMs,
hosts, guest accounts and identity gate functions. The native driver is retained
through `/tmp/verify018-native-driver-root`.

## First native execution and fixture correction

The frozen `j8bd4` derivation above captured source tree
`a0f6676eefaf649b68fb0ab5e39c2c409e79b277` at base `0cfa6302`.
The later staged tree `0aa854632e097dcdff7a81ffbbb5035278ea8796` changed only
review, receipts, campaign ledger and security prose. Native boot passed in
56.59 seconds, admission-service setup in 113.47 seconds and ordinary browser
invitation/registration in 38.27 seconds. Both initial guests booted; old and
survivor SSH and the old personal browser terminal passed.

The run then failed in the original retirement fixture before retirement:
`systemctl stop lilly.service` took 5.83 seconds after the real fresh report,
exceeding resize admission's unchanged five-second freshness window. The warmed
resize operator failed its success match and exited one. The old fixture waited
90.55 seconds for a successful dead unit before failing. This is not evidence
that retirement, fresh guest access or the complete journey passed. The native
build exited one after 408 seconds. Logs: `/tmp/verify018-native.log` and
`/home/ghuntley/.local/state/nix/build-logs/1790360585631-3069698-0.jsonl`.
The driver and all nine QEMU processes exited and were independently checked absent.

The corrected fixture disables the actual service's restart through a disposable
runtime drop-in and verifies the loaded policy before awaiting a new real report.
It sends SIGSTOP to the entire Lilly cgroup, verifies all observed processes are
stopped, and releases the warmed public resize action. Failed fixture dispatch
now fails promptly. After accepted admission it kills the still-stopped cgroup,
joins the fully inactive service and restores the original restart policy before
recovery. No freshness, capacity, workflow phase or observation is fabricated.
Guest survival, busy/offline holds and all original cleanup assertions remain.

The subsequent `aaba77ee` integration changes only gateway initial-certificate
retry policy, deployment transport activation and their evidence. The actual
source overlap preserves ADR-0124 and all new guest identity code; reviewed HLDD
receipt conflict resolution will reflect both changes. No application source
changed after the recorded full Marshall gate.

Published campaign 011 (`8773b1b4`) was then integrated. For this journey's
existing `audi = true`, private service roots, actual signers, compatible images,
49-connection budget, transfer port and DNS settings retain their effective
values. Its added guest-trust helper and 17 GiB provision-refusal shape are not
used here. The independent `guestTrust` selector stays false; the typed
account-lifecycle driver and `porsche = true` remain selected. Scenario and
campaign merge resolutions preserve 011's recorded execution separately from
018's failed first attempt. There is no application runtime source delta.

## Second native execution and systemd-state correction

The coordinator ran frozen retry
`/nix/store/fyg014c4bx0cq43i6h8rl33blmcr5kr1-vm-test-run-overalls-account-lifecycle.drv`,
capturing tree `322403cf208ba98c0d40df3066d396d094503a59` on `8773b1b4`.
Its strict driver build passed in 269 seconds. Integrated focused tests passed
13 checks (3 properties, 10 tests), followed by all five explicitly selected
independent-process cases, seed `18024`. The isolated database audit found zero
fixture users, VMs, hosts, guest accounts and gate functions. ADR, HLDD, generated
reference, contract format, all-file prek and Nix HLDD gates passed.

Native boot passed in 50.97 seconds, authenticated admission setup in 101.52
seconds and browser registration in 35.64 seconds. The real public resize was
accepted while every Lilly process was stopped, and those stopped process states
remained unchanged before SIGKILL. The kill and synchronous stop completed;
`MainPID = 0` passed. The next assertion incorrectly required `ActiveState =
inactive`: systemd recorded the injected death as `failed` with `Result = signal`,
even after reporting the unit stopped. This fixture assertion failed before
retirement or fresh guest acceptance. Log: `/tmp/verify018-native-retry.log`.
Cleanup took 3.59 seconds; the coordinator verified its driver and all nine QEMUs
had exited. This establishes no allocator failure or complete native pass.

The fixture now proves every captured PID is absent and the service cgroup is
absent or reports no populated descendants before accepting the expected signal
failure. It resets that failure only after these death assertions, requires the
unit inactive, then restores the original restart policy. Unexpected unit failure
results still fail. The real five-second freshness check, admitted resize and
original guest survival, retirement, busy/offline hold and recovery assertions
remain unchanged. A newly built native retry is required.

## Team-policy integration and rejoin history

Published `daa8491d` integrates campaign 012's current-member Cedar read/write
repair and its closed Galileo diagnostic reason allowlist, plus campaign 015's
pinned standalone browser typing. The source review preserves all fleet selectors,
including `teamResources = false` here, and the exported typed `defaultOssBrowser`.
No upstream account or SSH allocator implementation changed. Handbook resolutions
retain the newly recorded team resources and retirement overlap while preserving
018's uncompleted native scope.

The new test **fresh same-email team rejoin preserves every surviving guest
identity** invokes real team creation, member admission, VM provisioning,
retirement and verified same-email registration. Across two replacements it checks
that the new UUID inherits neither membership nor a guest allocation, that the
pre-rejoin roster contains only the unchanged owner and surviving teammate, and
that explicit member rejoin admits write without manage. Its complete boot roster
contains a distinct new username/UID and the same survivors; every previous
allocation remains unchanged and excluded. Stable repeated allocation is checked.
This is database boot-roster evidence, not native home materialization or a native
team SSH claim. Distinct assigned home names follow the existing guest contract;
native filesystem acceptance belongs to the machine journey below.

The history file passed **4 checks (1 property, 3 tests)**, seed `18025`, 2.0
seconds, on this combined source. Log: `/tmp/verify018-team-rejoin.log`.

The combined selection of identity, team resource, both distributed histories,
Cedar, SSH API, Galileo API and diagnostic tests passed **43 checks (15 properties,
28 tests)**, seed `18026`, 45.5 seconds. Log:
`/tmp/verify018-012-combined.log`. A subsequent review strengthened the initial
team oracle to derive expected survivors independently from the known owner and
teammate GuestAccount rows before comparing the complete returned roster. Its
final rerun and forced test-environment Dialyzer are recorded separately. An
accidental development-environment Dialyzer launch was stopped without a claimed
result; it is not the forced test-environment gate.

The strengthened history file passed **4 checks (1 property, 3 tests)**, seed
`18027`, 1.7 seconds (`/tmp/verify018-012-final-types.log`). This rerun contains
the independent initial-survivor oracle; it does not broaden native scope.

The explicitly selected test-environment forced Dialyzer in that same final-types
log passed with **zero errors, skips or unnecessary skips**, 55.25 seconds.
ADR/HLDD/options/coverage/views/contracts, all-file prek and the Nix HLDD check
also passed on the combined 012 source. The isolated database audit found no
fixture users, VMs, hosts, guest accounts, teams, members or identity gate functions.

## Third native execution and Lyra fixture diagnosis

The coordinator executed frozen tree `6f4a40e7d9112d8dc83cbc7b19ce40e2cca98232`
on `daa8491d`, runtime derivation
`/nix/store/l99bkxpfni1ndj309smmxl135229vwbi-vm-test-run-overalls-account-lifecycle.drv`.
Its strictly typed driver build passed in 279 seconds. The native attempt ran
506 seconds and exited one only at the final managed-profile SSH command.
Cleanup completed in 4.48 seconds; the coordinator independently verified the
Nix process, driver and all nine QEMU processes absent. Logs:
`/tmp/verify018-native-third.log` and
`/home/ghuntley/.local/state/nix/build-logs/1790364395253-297280-0.jsonl`.

The third native attempt passed these scoped assertions before its final failure:

- Original user and survivor guest SSH; original personal browser terminal.
- Real resize admission while every Lilly cgroup process was SIGSTOPed, proven
  process death and expected systemd signal-result recovery.
- Typed account retirement, busy/offline holds and fresh same-email registration
  without inherited authority.
- Fresh persisted suffixed identity, its own guest SSH and its own browser
  terminal with the expected username, UID and home. Original and fresh terminals
  use different VMs; this does not verify revocation of a shared terminal session.
- Actual recovery and owned-storage reclamation, unchanged old shared home
  marker/UID, expired old Unix account and removed old sudo authorization.
- Old-key and fresh-unshared refusals, explicit fresh sharing, fresh shared SSH,
  old-name refusal and continuing survivor access.
- Packaged staged Lyra setup and `ssh -G` discovery of
  `retirement-invited_g200002` in the generated profile.

The actual final managed SSH exited 255 after approximately 0.08 seconds.
This is **not a complete native pass**. Private stderr was not printed. A copied
client qcow image and journal-replayed raw copy recovered the generated profile,
but not the last dirty `lyra.err`/`lyra.out` files. Missing crash-disk files are not
evidence that runtime setup failed to write them.

The recovered directory inode establishes that the fixture's root-run
`install -d .../.local/bin` left `.local` owned by root with mode 0755. Staged
installer setup skips normal CLI startup. Ordinary proxy startup creates
`.local/state/overalls/update`; the tester cannot create that missing state path
inside the fixture's root-owned parent. The exact packaged CLI
`/nix/store/796fzfvwncag0sc7l0rkg15248pfcr6y-overalls-linux-cli/bin/overalls`
was exercised in a disposable local directory with the equivalent unwritable
parent: `version` exited one with the fixed `CLI startup failed` error and no
state directory. Supplying the owned state directory and explicit XDG paths
made the same binary exit zero with version `0.1.0` and its startup lock created.
This reproduces the fixture defect; unavailable native stderr is not inferred.

The fixture now creates all HOME/XDG directories as tester and explicitly sets
its config/state paths, matching the existing packaged-user journey. The final
SSH remains a real generated ProxyCommand connection with strict CA checks and
unchanged username/UID/home/write assertions. On failure a finally handler
synchronously copies at most 64 KiB each of stdout/stderr to a private directory
outside public test output, fsyncs those copies and logs only fixed categories.
No Lyra production, account authorization or native oracle is weakened. The
fourth complete native attempt passed, as recorded below.

## Credential-retirement integration

Published `f4de549a` adds campaign 014's shared account admission fence before
SSH key owner/fingerprint locks, retained through the outer approval commit.
Source review confirms `admit!` rereads the current User without taking a User
row lock. New key insertion can wait for the allocator's User lock through its
foreign key, but allocation acquires no account-admission, key or key-mutation
lock after the User lock. No new lock cycle was found in the combined callers.
The allocator and SSH discovery source have no upstream overlap. Documentation
resolution retains 014's exact generated and distributed evidence, supersedes
only the old fresh-name refusal claim, and preserves ADR-0124 host CA decisions.
On this integrated source the ordinary focused selection passed **15 checks
(4 properties, 11 tests)**, seed `18028`, 9.5 seconds. Nine distributed cases were
excluded by the default tag configuration and are selected explicitly next.
One nonexistent SSH test path supplied to this first command was ignored by Mix;
no SSH-consumer coverage is claimed from that argument. Log:
`/tmp/verify018-014-combined.log`. Explicit `MIX_ENV=test` forced Dialyzer passed
with **zero errors, skips or unnecessary skips**, 52.24 seconds after its PLT check.

The reviewed fixture and combined source also pass ADR/HLDD/options/coverage/views,
contract syntax and all-file prek including logging, ruff format/lint and ty.
Logs: `/tmp/verify018-fourth-static.log` and `/tmp/verify018-fourth-prek.log`.
Composed native driver typing is checked by the next driver build.

The explicit `--include distributed` run passed **50 checks (4 properties,
46 tests)**, seed `18029`, 14.1 seconds. It includes all nine guest-identity and
credential-retirement schedules plus actual SSH command, roster, key and account
lifecycle consumers. Log: `/tmp/verify018-014-distributed-consumers.log`.
No native transport scope is inferred from these independently launched BEAMs.


## Fourth complete native acceptance

The complete fourth native journey passed in **494.85 seconds** (the driver
reports 495.09 seconds including its outer overhead); Nix completed in 501
seconds and nine-machine cleanup took **3.84 seconds**. This executed frozen tree
`f9d9525edad257ad8b27a7928a4c9ef18ef6edef` on `f4de549a`, runtime derivation
`/nix/store/p839kx6xq10bmzx6cv1dpqg4n916hl5p-vm-test-run-overalls-account-lifecycle.drv`.
The strict composed driver and browser helper build passed in 309 seconds before
execution. Output:
`/nix/store/whrinjds8a8qbsk6qkgxb8zscm1klyv7-vm-test-run-overalls-account-lifecycle`.

| Executed stage | Seconds |
| --- | ---: |
| Boot all nine machines | 50.99 |
| Authenticated native capacity | 120.72 |
| Bootstrap and verified browser invitation | 41.82 |
| Real Customer/shared OSS guests and offline busy cleanup | 131.02 |
| Fresh same-email registration without inheritance | 58.78 |
| Real resize recovery/reclamation with shared guest survival | 79.76 |
| Retired guest home reservation and explicit fresh sharing | 7.87 |
| Packaged Lyra discovered identity and actual SSH/home access | 3.87 |

All eight stages passed. Actual generated-profile SSH now reaches the fresh
persisted username, UID, writable home and working directory through packaged
Lyra and CA-authenticated Audi/guest SSH. The tester-owned HOME/XDG correction
was exercised; no Lyra production change was required. The preserved old shared
home, marker and UID, expired old account, removed old sudo rule, old-key refusal,
fresh-unshared refusal, explicit fresh re-sharing, old-name refusal and usable
survivor controls all passed in this complete run. Original and fresh browser
terminals used different VMs and their respective persisted identities; shared
terminal session revocation was not exercised.

The root coordinator owned execution, drained session `58095` and independently
verified Nix `1021153`, driver `1021775` and all nine QEMU processes absent. Log:
`/tmp/verify018-native-fourth.log`; full structured log:
`/home/ghuntley/.local/state/nix/build-logs/1790366265985-1021153-0.jsonl`.
The isolated database audit after combined 014 checks found zero users, VMs,
hosts, guest accounts, teams, members, SSH keys, gateways and both fixture gate
function families (`/tmp/verify018-014-db-audit.log`).

This acceptance covers fresh NixOS disks on colocated nested-KVM/ZFS provisioners,
three Marshall replicas, verified HTTPS, virtual WebAuthn and a local encrypted
outbox. It does not establish native Ubuntu fresh-identity behavior, every
retained guest disk, populated production migration, mixed-release rollout,
physical independent hosts, real hardware authenticators or external email
receipt. Team rejoin retains its separate database-roster scope. Authorized
shared writers retain passwordless sudo; distinct names and home ownership do
not establish confidentiality from other authorized guest administrators.


## Final published-main integration and review

Published `7b8e4afe` integrates campaign 016 renewal evidence and campaign 017
Enrico authority/attempt settlement. No allocator, identity resource, migration,
SSH discovery or guest roster source overlaps. Enrico catalog mutations now
lock their current User before their Repository, while its worker settles only
the current locked Repository and waits for network calls outside that lock.
Neither path acquires guest namespace locks, and allocation acquires no Enrico
Repository lock. No new cycle with the guest User/namespace ordering was found.
The new generated/distributed fixtures remain isolated and clean captured rows.

Campaign 016 adds an opt-in `integrationRenewals` selector, extra driver suffix,
proxy renewal-path boolean projection and native origin connection counters.
This account-lifecycle check keeps the scenario selectors `integrationRenewals`,
`teamResources` and `galileo` false and `accountLifecycle`, `audi` and `porsche`
true. Common Galileo services on both provisioners remain enabled as before;
the false `galileo` scenario selector controls the optional synthetic origin. The renewal
script/proxy additions and changed Galileo origin are not selected. Campaign
017 adds its separate Git browser check; it does not change this fleet's selected
services. Native and application runs above retain their captured revisions;
final configuration equivalence and combined gates are recorded below.

The final semantic review preserves the accepted ADR-0125 replacement only of
exact local-part allocation. All permanent historical names/UIDs, active-user
rechecks, canonical complete-batch locks, finite collision/UID refusal, rollback,
legacy null fallback, actor-attributed discovery and fresh roster authorization
remain in their production callers. The native helper correction changes fixture
ownership and private failure capture only. No production CA, transport, Cedar,
guest account reconciliation or sudo boundary changed in 018. The remaining
Ubuntu, retained-disk, populated migration and mixed-release limits remain explicit.


On integrated `7b8e4afe` source, the combined ten-file selection passed **35 checks
(7 properties, 28 tests)**, seed `18030`, 39.7 seconds, with `--include distributed`.
It includes 018 allocation/history/bounds and contention, 014 credential histories,
016 renewal/peer histories and 017 Enrico history/authority schedules. Log:
`/tmp/verify018-final-combined.log`. The final source comparison finds no change
from the executed `f9d9525e` tree in 018 allocator/discovery/roster code or its
native account-lifecycle scripts.

The complete evaluated account-lifecycle `testScript` is **byte-for-byte
identical** to the executed driver script (47,193 bytes). Effective configuration
retains all nine nodes, `skipTypeCheck = false`, Porsche on m1, Audi and common
Galileo on both provisioners. The optional renewal proxy hook and egress Galileo-origin service are absent. These
are configuration/type-scope checks, not another native execution; the NixOS pass
retains its `f4de549a` source and the new independent Enrico implementation retains
its own captured native evidence.


The same integrated source passed explicitly selected `MIX_ENV=test`
`mix dialyzer --force-check`: **zero errors, skips or unnecessary skips**, 53.66
seconds after its PLT check. The isolated database audit found zero users, VMs,
hosts, guest accounts, teams, members, SSH keys, gateways, Enrico repositories,
Galileo integrations/attachments/peer tokens/credentials and all three SQL gate
function families (`/tmp/verify018-final-db-audit.log`). Every owned application
and evaluation session was drained. No additional native runtime was launched.

Final ADR, reviewed HLDD receipts, generated options/coverage/views, contract
syntax and all-file prek passed (`/tmp/verify018-final-static.log`), including all
Elixir logging catalogs, Python ruff format/lint and ty. The contract review
inspected all three production allocator callers, both preferred-name parser
callers and their authorization/transaction consumers; no caller cap was reached.
No semantic contract violation was found in the inspected final scope. Structural
checks alone do not establish that conclusion or broaden the runtime evidence.
