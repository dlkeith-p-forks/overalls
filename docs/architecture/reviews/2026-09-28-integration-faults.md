# Integration name-custody fencing, team liveness boundary and closed reasons (improvement 106)

Date: 2026-09-28. Discovery: verification-campaign improvement 106 (scope
`/tmp/opencode/campaign/discovery-044-integrations.md`), branch
`verify/106-integration-faults`.

## Scope and architecture impact

Small production-behavior fencing with contract annotations, closed through
existing tests: removal of a Galileo integration now closes its name history
instead of replaying onto the archived row. No protocol layout, tenant or
persistence shape changes; ADR-0046/0105 surfaces unchanged. The change
tightens existing decisions — a new behavior-class pinning, not an
architecture decision.

## Defect findings (each reproduced then fixed)

1. **Archived-name replay replaced removal.** `configure/2` matched
   `Ledger.history!(Integration, name:)` without requiring
   `archived_at: nil`, so configuring a removed name updated the archived row
   and returned a `:configured` receipt — removal was not terminal. Fixed:
   only a live row may replay; an archived row refuses (after manage-authority
   recheck) with the closed `:name_unavailable` reason, never re-typing and
   never emitting a receipt. Fresh name adoption after removal stays a future
   decision.
2. **Porsche client's closed-reason set lacked name custody.** The conflict
   boundary could not represent the new refusal. `:name_unavailable` is now a
   predefined closed reason (no atom injection path; unknown text stays
   generic per the existing contract).

## Contract annotations

- `galileo-team-owner-liveness-boundary` (authorizations.ex): records the
  existing invariant that a non-nil `team_id` implies a live team today (no
  public/internal team deletion exists), and flags the pairing point where
  introducing team deletion MUST replace this existence check.
- `galileo-configure-replay-conflict` (configurations.ex): statement now
  covers live rows only; archived rows are fenced before replay per the new
  refusal class.
- `porsche-closed-conflict-reasons` (client.ex): reason set extended to name
  custody with the no-new-atoms rule preserved.

## Evidence

- `mix test` on this tree (MIX_TEST_PARTITION=verify106, `ERL_FLAGS="+S 4:4"`):
  `renewal_history_test.exs` + `authorizations_test.exs` + `galileo_test.exs`
  = **25 passed (2 properties, 23 tests)** — including the new pins
  "removed names refuse configuration without receipts or stale exceptions"
  and "team-owned integrations bind authority to membership, not the
  configuring user".
- Porsche suite: `client_test.exs` 8 passed (1 property, 7 tests).
- Full merged-tree gates recorded against this patch at integration time.

## Carve (follow-up 122)

The stalled session was expanding `renewal_history_test.exs` into a combined
membership/attachment/**relocation-move** history whose `:move`/`:ready` legs
reach the real reservation/coordinator boundary. That expansion was NOT
landed: its generated `begin_move` model never wired destination capacity
(`RelocationCapacity.reserve_locked!` returns `{:error, :insufficient_capacity}`
for the undersized destination fixture), and a second property's member-join
wiring produced `{:error, :unauthorized}` against its own renewal expectation.
Both failures reproduce deterministically on the branch; the rewritten model
needs either capacity-sized destination fixtures or an explicit refusal leg,
plus re-derivation of the authorize expectation after joins. The branch
history preserves the unfinished model for redesign; the reverted file passes
(its own 2-property/23-test content) and the production fence + closed-reason
content above is independently pinned by the landed tests.
