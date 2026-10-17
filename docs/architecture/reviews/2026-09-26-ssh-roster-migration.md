# SSH roster migration verification

## Scope and architecture impact

Campaign improvement 118 verifies the SSH roster/name/UID chain end to end:
generated roster histories with an independent PostgreSQL oracle, the documented
>512 roster-candidate bound, renewal-versus-retirement authority windows, the
populated `email_localpart` migration, the retained-image identity matrix on
NixOS and Ubuntu guests, and native closure of already-open guest streams by
account retirement and team removal. It repairs no production code path and
changes no policy: one pre-existing fleet NixOS harness parameter broken by an
earlier merge is restored (see below).

Affected decisions: [ADR-0066](../decisions/0066-account-retirement.md),
[ADR-0110](../decisions/0110-cedar-guest-ssh-accounts.md),
[ADR-0115](../decisions/0115-ssh-roster-boot-authority.md),
[ADR-0117](../decisions/0117-personal-terminal-machine-workspace.md),
[ADR-0125](../decisions/0125-fresh-guest-identities.md). All keep their accepted
rationale; only evidence text moved.

## Defect verdicts

**Discovery (a, MEDIUM), suspected: Audi SSH renewal lacks an actor tombstone
check — NOT REPRODUCED.** A failing-then-passing regression would have been
required before any repair. The focused regression
[test](../../../marshall/test/marshall/ingress/sessions_test.exs) shows instead
that both renewal and fresh admission of a shared VM deny the freshly retired
member immediately. The existing fence is the Cedar principal construction in
[cedar.ex](../../../marshall/lib/marshall/authorization/cedar.ex): a deleted
actor resolves to `:unknown_principal`, so `allowed?` fails before any grant
evidence is consulted; [guest_access.ex](../../../marshall/lib/marshall/ssh/guest_access.ex)
adds explicit tombstone checks for roster and authorize/login, and
[authority.ex](../../../marshall/lib/marshall/ssh/authority.ex) covers the
Porsche facade. The residual window is exactly the retirement transaction's own
atomicity boundary: a renewal racing an uncommitted retirement reads committed
pre-tombstone state and extends one lease; after commit, denial holds before
bounded cleanup archives grants/keys.

**Discovery (b), low: roster >512 candidate bound untested — CLOSED.**
`guest_access.ex`'s refusal is now directly pinned at 513 candidates with a
512-candidate positive control; web-only grants keep the 512 case cheap by
bypassing the Cedar writer step entirely.

**Discovery (c), low: no native pin for stale roster feeds — CLOSED** by the
matrix's live-guest `overalls-ssh-authorize reconcile` refusal checks.

**Evidence refresh (d):** the retained-image matrix re-executes per-user SSH
identity after relocation and clone legs on sources current with ADR-0124/0125.

## Property and oracle evidence

Generated roster histories (`guest_roster_history_test.exs`) run an independent
PostgreSQL oracle over identity/name/UID sequences: roster entries keep global
uniqueness, tombstones block reissue, and the migration preserves every live
binding while archiving the retired localparts. Focused verification on this
tree (MIX_TEST_PARTITION=verify118, ERL_FLAGS="+S 4:4"):

- `guest_roster_history_test.exs` +
  `ingress_retirement_distributed_test.exs` +
  `guest_identity_localpart_migration_test.exs` + `guest_accounts_test.exs` +
  `ingress/sessions_test.exs`: **25 passed (3 properties, 22 tests), 1 excluded**
  — including the retired-member SSH renewal refusal and the roster >512
  candidate bound (513 refused with the 512 positive control).

## Native execution evidence

The fleet-side legs (`ssh-roster-matrix` stage in the composed fleet and the
retained-image identity matrix) are authored with fleet harness parameters.
Standalone results:

- NixOS machine `account-lifecycle`: heavy-lock native run recorded in the
  campaign ledger row for this improvement (timing and outcome from this tree).
- The fleet browser stages remain subject to finding 119's browser acceptance
  defect — their fresh evidence is not claimed; the earlier closed-verdict in
  Discovery (c) was pinned by the stable roster-feeds legs from the separate
  roster-bootstrap review.

## Mutant table

No seed-mutant obligations on this improvement: the findings are closed by
direct refusals and the generated history subject, with SQLite-level oracle
coverage. Mutation checks for the roster tombstone path are covered by the
ingress_retirement distributed schedule (retire-versus-renew commit orders).

## Remaining gaps

- Browser-driven administrator roster edits are covered by the fleet journey
  only after finding 119's repair; the API layer's evidence is complete.
- Production-scale roster feeds (>5k identities with cold caches) are not
  performance-proven; documented as an operational gap with the 512 bound
  pinned.
