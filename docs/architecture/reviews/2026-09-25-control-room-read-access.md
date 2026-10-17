# Control room read access review — 2026-09-25

## Scope and architecture impact

The user authorized read-only access to all administrator pages for signed-in
users, with administrator mutations unchanged. ADR-0119 replaces the read
restrictions in ADR-0059, ADR-0062, ADR-0065 and ADR-0114. ADR-0060's monitoring
evidence now references the wider audience. No protocol or persistence changes.

## Findings and resolution

- Accounts used `admin_read` to admit both listing and account mutations.
  Split these policies and require elevated `admin_accounts` for mutations.
- Workload, SSH and membership projections matched a caller's administrator
  field. Replace that admission with fresh Cedar checks for current users;
  retain the dedicated mutation permissions and locked mutation rechecks.
- The LiveView guard must distinguish read events from mutations after admission
  widens. Explicit mutation permission mapping and fresh role/elevation checks
  halt forged events before callbacks, including ordinary users acting on their
  own workloads. Unrecognized events halt. UI flags only control presentation.
- Promotion during an open view refreshes the session-bound actor before
  callbacks, preserving lifecycle/relocation administrator audit context.
- Navigation, monitoring history, inventories and usage export share current
  read authority. Existing redacted projections and stored-login checks remain.
  Other accounts' fleet metadata is intentionally visible under the approved
  policy; this does not extend VM/terminal/SSH authority.

## Validation

All 40 focused tests pass on the worktree updated to main commit `04b24b3e`,
including populated pages, detail routes, exports, forged mutation events,
revoked/expired/retired and MFA-pending logins, promotion auditing, and existing
administrator step-up. Domain tests exercise recently elevated ordinary users
and forged administrator flags. Marshall `mix precommit` passed inside
`devenv shell`: 900 tests and 76 properties, including distributed tests (two host/capacity cases excluded), pinned
runtime, ADR/contract/logging checks, compiler, frontend checks and forced
Dialyzer with zero errors, skips or unnecessary skips. The standalone ADR
checker and contract syntax/discovery checks also pass. Final diff review found
no unresolved contract or authorization findings in this change. This review
makes no production deployment or load claim.

## Remaining work

No implementation work remains for the accepted read-access change. Deploying
the release and restarting Marshall replicas is separate from this source change.
Existing native and scale gaps in the inherited ADRs remain outside this review.
