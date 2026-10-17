# Team creation verification

Date: 2026-09-25. Final integration combines `d3a84ee8` (the Source code navigation
link over Control room, installer and corrected team authority) with implementation
`bc0a3523`. The earlier application gate ran on `e2289ae1` plus this improvement;
each scope is recorded below. The later integrations preserve its production team
code and native creation assertions byte for byte.
Scope: ADR-0077 team creation, retries, name collisions and archived names.

## Finding and correction

Severity: medium. The creation coordinator returned any historical team with a
matching name. An unrelated account received a successful result containing that
team's identity, and the browser displayed creation success without any membership.
A former creator could receive the same false success after transfer and removal.
An archived row also satisfied creation despite the active-only name identity.

Seed 44004 reproduced both generated-history failures and the browser refusal
failure against the old coordinator (one of four checks passed). Existing team
unit tests passed before the added regressions. This corrects the accepted
creator-owner and current-authority contracts in ADR-0077 without introducing a
new resource, migration, public signature or authorization model.

[The coordinator](../../../marshall/lib/marshall/teams/coordinator.ex) serializes
creation by active name. It returns an existing team only to its original creator
while they remain its current owner; other active collisions return the closed
`team_name_taken` reason. Existing browser and SSH callers handle ordinary error
results. No membership, version, receipt or outcome event is added on reuse or
refusal. Archived names acquire a fresh team identity with one owner, retaining
old records. The active-only unique database identity remains the final constraint.

The lock order is shared account admission fence, name advisory lock, then the
existing team row lock. Membership and transfer paths take account fences before
team rows and never acquire the name lock; the new lock adds no reverse-order
path. The team lock makes ownership decisions current against transfers.

The domain's `idempotency_key` does not store durable results. Same-name reuse has
always provided its retry behavior; this change bounds it to current creator
ownership. The SSH command boundary already stores semantic inputs and pinned
results in `Marshall.SSH.Request`. A repeated SSH request ID preserves its original
result even after archival and name reuse, while changed inputs conflict. No new
receipt store or alternate source of authority is introduced.

## Evidence

[Generated histories](../../../marshall/test/marshall/teams_creation_test.exs)
exercise real domain operations with independently modeled actor/name ownership.
Twenty-five histories each include creation, a creator retry, a foreign collision,
1–15 generated actor/name/key requests, and archival followed by fresh creation.
Fifteen generated transfer histories vary member role, creator removal and retry
keys. Assertions compare stored memberships, team/member versions and admin
receipts after refusals and retries, including each receipt's actor.

[Browser state regressions](../../../marshall/test/marshall_web/teams_live_test.exs)
require a collision error without false success and successful fresh-name recovery.
[SSH command regressions](../../../marshall/test/marshall/ssh/commands_test.exs)
check pinned request replay, semantic conflict, foreign refusal without a receipt,
and old pinned results after an archived name belongs to another account.

[Three independent Marshall peers](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
race committed creation of one name for three accounts. Exactly one succeeds,
two return errors, and the stored team has one owner and two actor-correct admin
receipts. Concurrent creator retries on all peers preserve that identity and one
team version. The parent node does not count as a peer; cleanup touches only
fixture actors and teams. This establishes the tested creation race, not every
possible transfer/retirement overlap.

Execution in `devenv shell`, `ERL_FLAGS='+S 4:4'`,
`MIX_TEST_PARTITION=verify004`, `PGHOST=/run/user/1000/devenv-0e19ff2/postgres`
and `TMPDIR=/tmp/kittens-verify004`:

- Seed 44004: `mix test test/marshall/teams_creation_test.exs test/marshall/teams_test.exs test/marshall_web/teams_live_test.exs --seed 44004`
  passed 12 checks (2 properties, 10 tests) before incorporating team-authority's
  additional regression. The properties execute 40 generated histories.
- Seed 44004: `mix test test/marshall/ssh/commands_test.exs test/marshall/compute/distributed_admission_test.exs:68 --include distributed --seed 44004`
  passed 19 checks (1 property, 18 tests); 37 unselected distributed tests were
  excluded. This includes committed same-name creation across three peers.

The extended [native browser fixture](../../../nix/tests/machines/teams/browser.py)
uses the real packaged Marshall release, PostgreSQL and Chromium over verified
HTTPS. It checks original-owner retries, foreign creation refusals before
membership exists, current/former owner refusals after transfer, and recovery by
creating a fresh name. SQL observes one creation receipt per actual team and the
fresh team's committed owner. All three browser accounts must remain ordinary
in persisted state after login and after the journey. The separate unused bootstrap
administrator completes the installed-system latch before login.

`nix build .#checks.x86_64-linux.teams-browser --no-link -L --print-out-paths`
passed the extended native creation journey in 55.64 seconds, with verified HTTPS,
persisted ordinary-account checks before/after operations, one creation receipt
per actual team, and the fresh team's committed owner. QEMU cleanup completed.
Exact tested derivation:
`/nix/store/j36frcpcp2pgsh17rmgx4ql01q4a1gdc-vm-test-run-kittens-teams-browser.drv`.
Output, including `teams-authority.png` and `teams-creation.png`:
`/nix/store/823zcncyrxbc3hv41imrjwlw2d2ghkyb-vm-test-run-kittens-teams-browser`.
The immutable run contains this fix and the corrected ordinary-account fixture.
The later main merge retained the coordinator and all native fixture files byte
for byte; final handbook evidence changes do not alter the exercised behavior.

The complete Marshall `mix precommit` gate passed on the combined installer/team
candidate, seed 531664: the suite reported 1,023 checks (90 properties, 933 tests),
zero failures and two host/capacity exclusions, in 265.1 seconds. This includes
all distributed tests and the new creation properties. Runtime, compiler, ADR,
HLDD, contract, catalogued logging and frontend gates passed. Forced Dialyzer
passed with zero errors, skips or unnecessary skips after rebuilding the copied
worktree PLT; final application analysis took 61.48 seconds.

After integrating Control room verification from `6083aeda`, the final combined
`mix precommit` passed again, seed 761157: `Result: 1025 passed (91 properties,
934 tests), 2 excluded`, in 248.2 seconds. Browser checks passed and forced
Dialyzer reported zero errors, skips or unnecessary skips (58.9 seconds).
The pinned Elixir 1.20.4 formatter counts passing cases separately from exclusions.
Combined all-file prek, ADR, generated options/coverage/views and Nix `hldd`
checks also passed. Final delivery bookkeeping changes documentation only.
The exact native artifact above retains its tested scope; the later Control room
integration does not change the production team code or its native assertions.

The final merge with `d3a84ee88507e8bdacb2496c117e589a6f2bbccc` preserved the
Source code link immediately below HLDD, including its exact GitHub destination
and ordinary navigation. Combined Marshall `mix precommit` passed, seed 788054:
`Result: 1025 passed (91 properties, 934 tests), 2 excluded`, in 250.0 seconds.
All frontend checks passed; forced Dialyzer reported zero errors, skips and
unnecessary skips in 52.54 seconds. ADR, reviewed HLDD receipts, generated
options/coverage/views, layout contract discovery, all-file prek and the Nix
`hldd` gate also passed on this merged candidate. The final review and ledger
update records these results without changing runtime behavior.

The static external link introduces no team authority or persistence change and
preserves ADR-0119 and ADR-0122. Its dedicated native coverage and actual GitHub
access remain explicitly unverified in the handbook scenario. No new native run
was required for this navigation-only integration; the exact team artifact above
retains its original tested scope.

`prek run --all-files`, explicit browser `ty check` with the pinned Playwright
interpreter, generated options/coverage/views, and the Nix `hldd` check also
passed. The first broad static-check attempt overlapped
an intermediate merge and correctly refused conflicted review receipts; the clean
combined-tree rerun passed. An earlier precommit was stopped during compilation
to incorporate the installer branch before running the complete suite above.

## Contract and architecture review

Applicable repository, Marshall, web, test, Nix and handbook contracts were read.
The creator-owner, current-login, account-admission, ledger lock-lifetime and
transactional-receipt contracts remain in force. The new local contract makes
active-name reuse and refusal explicit. Public callers were traced through the
web event and SSH transactional command/receipt dispatch. Domain-generated
records remain Ash resources; no direct SQL mutation was added to production.
ADR-0077 stays accepted and partial. Domain/resource inventories, deployment
placement and public configuration are unchanged.

## Remaining gaps

The native browser does not exercise archived-name reuse because team archival is
currently a trusted resource operation, without a public team archive journey.
Generated database and SSH domain tests exercise that boundary. Multi-node
transfer/retirement overlap, native team VM/integration authority and production
acceptance retain their existing gaps; no physical-host or scale claim is made.
