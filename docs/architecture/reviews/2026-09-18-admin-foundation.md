# Administrative authority foundation

## Scope

Implementation is isolated in `feat/marshall-admin`. The original checkout's
uncommitted disk-limit work is excluded. This review covers the initial account
authority, bootstrap migration, Cedar extension and user-management LiveView.
It does not claim completion of the [full admin plan](../../admin-implementation.md).

## Architecture impact

[ADR-0058](../decisions/0058-administrative-authority.md) replaces the exhaustive
sharing-role matrix from ADR-0018 with an additional persisted administrator role;
other sharing and archival requirements remain. ADR-0022's current-login checks
are retained. Account role changes enter an authorized Ash action, serialize on a
durable bootstrap row, recheck Cedar and atomically write role/audit records.

The custom `/admin/*` routes are compiled in production behind the authenticated
LiveView session; development AshAdmin remains compile-gated under `/dev/resources`.
The [migration](../../../marshall/priv/repo/migrations/20260918031222_admin_authority.exs)
consumes bootstrap for existing databases without choosing an administrator.
The authorized production promotion is still pending and has not used sudo.
The [bootstrap change](../../../marshall/lib/marshall/accounts/bootstrap_administrator.ex)
retains registration metadata and encloses grant/audit/latch writes in registration's
transaction. The [Cedar adapter](../../../marshall/lib/marshall/authorization/cedar.ex)
reads current membership instead of trusting passed user structs.

## Verification performed

- Focused authorization/account/browser run: 17 passed (one property, sixteen tests).
- Initial ordinary Marshall suite: 513/515 passed. SMTP fixture generation lacked
  OpenSSL in the worktree shell; the 10,000-endpoint publication query exceeded its
  existing 1.5-second deadline. OpenSSL is now in the pinned development packages.
- Focused SMTP/publication rerun: 19 passed, including the unchanged query deadline.
- Three independent Marshall peers racing cyclic administrator revocations: passed.
  Parallel test runners exhausted the private fixture's connection limit during
  that run; the full gate is being run sequentially with four schedulers.
- ADR structure/link checks and contract syntax/discovery passed. They do not
  establish semantic compliance or deployment acceptance.
- Full precommit's test phase: 547 passed (50 properties, 497 tests), including
  distributed tests. Dialyzer subsequently passed (one existing suppression),
  completing the foundation gate. Subsequent Jobs changes need a new gate.
  No native fleet or deployed-account acceptance is claimed.
- [Fresh bootstrap probe](../../../marshall/scripts/verify_admin_bootstrap.exs):
  three independent peers concurrently registered three accounts; one administrator
  and one bootstrap audit event persisted, and all peers agreed on authority.

Tests use a separate PostgreSQL instance on localhost port 55439 and database
`marshall_testadmin`; `MARSHALL_TEST_PORT` selects it without changing production
configuration or the default test port.

## Remaining findings and work

- Bootstrap concurrency passed the dedicated fresh-database probe; deployment
  migration/promotion remains separate.
- Existing-database migration and the exact one-time promotion need operational verification.
- The bounded users page has current-role and login-revocation tests. Administrators
  can now revoke another account's stored browser sessions through a serialized,
  audited action; guest-session demotion/revocation remains broader platform work.
- The bounded [access authority console](../../../marshall/lib/marshall_web/live/admin/access_live.ex)
  now inventories current VM grants, registered SSH fingerprints and active SSH
  sessions. Its admin actions revoke grants, archive keys and close sessions while
  redacting terminal bytes, public-key material and session tokens. Focused sharing,
  key and LiveView tests cover these projections and revocation paths.
- Fleet monitoring, job history, operations pages and evacuation remain in the
  implementation ledger. Existing ingress requires `host.enabled`; evacuation
  cannot reuse disabled-host behavior without separating admission from serving.
- Detailed monitoring must not expand the current capacity-locked recorder into
  per-workload writes. The approved batched history/storage benchmark remains required.

## Contracts

Reviewed ancestor repository, Marshall, Accounts, authorization, web, config,
resource/migration and test contracts. New notes cover bootstrap atomicity,
persisted role lookup, serialized membership changes, bounded account projection
and current LiveView authority. The Cedar role matrix was changed explicitly with
ADR-0058; the internal-system boundary remains intact. Final diff and full-gate
review remain required before this foundation is submitted.
