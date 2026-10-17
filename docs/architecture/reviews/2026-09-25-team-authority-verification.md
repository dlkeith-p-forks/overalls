# Team authority verification

Date: 2026-09-25. Base: `253cdcaa1e7b3c8e7a2039583cbc30d8f6ba1e14`.
Scope: ADR-0077 membership replacement, ownership consent and fresh browser authority.

## Finding and correction

Severity: medium. A validly authenticated admin request reaches a commit failure
instead of ordinary refusal; the database constraint still preserves ownership.

Generated domain histories exposed an owner-protection violation: an admin could
request removal or demotion of the current owner. The membership coordinator
returned success before PostgreSQL's deferred owner constraint rejected the outer
commit. A sandbox concealed that eventual commit failure. The minimized seed-101
history begins with an admin removing the owner. This is an accepted-contract
implementation defect, not a new architectural decision.

[The coordinator](../../../marshall/lib/marshall/teams/coordinator.ex) now refuses
any membership replacement targeting an owner under the existing team lock, before
archival, audit receipts or diagnostics. The database constraint remains the final
commit invariant. No API, schema, authority boundary or ADR status changes.

## Evidence

[Generated histories](../../../marshall/test/marshall/teams_history_test.exs)
execute real domain operations against PostgreSQL with an independent role and
transfer model. Every step compares success/refusal, stored roles and terminal
transfer states, then reads the team as each actor and flushes deferred constraints.
Each of 40 generated histories includes consent, every terminal outcome, owner
protection, ownership loss and member removal before 15–35 generated commands.
These are sandbox properties; they do not establish actual outer commits or
independent-node concurrency.

[Focused regressions](../../../marshall/test/marshall/teams_test.exs) also require
all three attempted admin replacements of an owner to fail without audit writes.
The [connection race tests](../../../marshall/test/marshall/teams_concurrency_test.exs)
include `transfer acceptance serializes with target retirement`; separate SQL
connections in one BEAM do not satisfy the three-Marshall overlap requirement.

[The native browser check](../../../nix/verification/tests/machines/teams/default.nix), exported
as `teams-browser`, starts the real Marshall release and PostgreSQL. Three ordinary
accounts sign in with isolated magic links, then use Chromium over verified HTTPS
for every team mutation. An admin's owner removal is refused. A target accepts
ownership, the still-connected former-owner page loses owner authority, and
membership removal prevents a subsequent stale-page mutation. Fresh browser and
SQL observations check the remaining membership and exactly one committed owner.
Fixture seeding supplies a separate unused installation administrator, completes
the bootstrap latch, then supplies three ordinary accounts and private login
tokens. The browser reads actual administrator flags immediately after login and
again after team operations, requiring all three users to remain ordinary.

Execution on 2026-09-25 in `devenv shell`, with `ERL_FLAGS="+S 4:4"`,
`PGHOST=/run/user/1000/devenv-0e19ff2/postgres` and
`MIX_TEST_PARTITION=verify001`:

- The seed-101 focused team suite passed: 1 property and 11 tests, before the
  additional explicit three-role owner regression.
- Generated membership/consent histories passed in the full Marshall suite:
  `mix precommit` reported 85 properties and 930 tests (1,015 checks,
  zero failures, 2 excluded), including distributed tests and the additional
  owner regression. Seed 858284;
  execution took 261.2 seconds. The complete precommit gate passed, including
  frontend checks and forced Dialyzer (zero errors, skips or unnecessary skips).
- After integrating installer verification (`ea8f9870`), the combined Marshall
  `mix precommit` gate passed: 88 properties and 930 tests (1,018 checks,
  zero failures, 2 excluded), seed 132631, in 220.6 seconds. Distributed and
  frontend checks passed; forced Dialyzer reported zero errors, skips or
  unnecessary skips.
- An earlier `teams-browser` execution passed transfer/removal assertions in
  52.95 seconds, but its log contains `admin.bootstrapped` for the initial owner.
  The unconsumed installation latch promoted that first magic-link account.
  That result is withdrawn as evidence for the three-ordinary-account claim.
  Withdrawn artifact:
  `/nix/store/2q3n3cw0gcvrx86fz5wqc1yvqz1rvx7r-vm-test-run-overalls-teams-browser`.
- The corrected ordinary-account `teams-browser` check passed in 44.78 seconds:
  `nix build .#checks.x86_64-linux.teams-browser -L --no-link --print-out-paths`.
  It consumes bootstrap with a separate unused administrator and checks persisted
  ordinary roles after login and after team operations. Both observations require
  exactly three users and zero administrators; the final independent SQL query
  requires exactly one committed team owner. Derivation:
  `/nix/store/hgk301651yyiskf67lxy83diizwprg9w-vm-test-run-overalls-teams-browser.drv`.
  Result:
  `/nix/store/b56dj7vr2bx9dc493kj9z3arvfkqgn0y-vm-test-run-overalls-teams-browser`.
- `prek run --all-files`, explicit Python `ty check` with the pinned Playwright
  interpreter, ADR and contract checks, generated options/coverage/views and the
  Nix `hldd` check passed. The ambient-interpreter typing attempt lacked
  Playwright; the configured pinned interpreter resolved it without source changes.

After refining the private membership input/result/event types,
`mix compile --warnings-as-errors` and `mix dialyzer --force-check` passed again
with zero errors, skips or unnecessary skips. No runtime expressions changed.

The final contract review traced the guard through both browser and SSH callers:
they already handle ordinary error results. Refusal happens under the team lock
before a role change or audit write. The native scenario reads committed state;
the generated test explicitly retains its narrower SQL sandbox claim.

## Remaining gaps

Independent Marshall nodes racing transfer/retirement, native team VM/integration
access and production acceptance remain outside this bounded journey. ADR-0077
stays partial. Ash ownership, deployment placement and public configuration are
unchanged; their generated inventories and handbook explanations need no new rows.
