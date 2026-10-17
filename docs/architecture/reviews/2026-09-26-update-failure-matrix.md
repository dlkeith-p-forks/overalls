# Update failure matrix verification (improvement 113)

## Scope and architecture impact

Discovery 050 (campaign): candidate update failure/recovery coverage with exact
revisions and guest survival. This improvement delivers it in ordered parts:
Part A (refusal semantics through real authorization paths, no native weight)
plus native machine legs on the existing auto-update and guest-recovery drivers
and the fleet updates scenario; the trust/SSH legs land separately (see
Remaining). No ADR or deployment topology change; ADR-0036 and ADR-0104 receive
evidence text only. No production runtime, schema, protocol or permission change
— test and documentation deliverables only.

## Part A — refusal semantics (executed, green)

- **Marshall** (`test/marshall/inference/update_authority_test.exs`,
  `test/marshall_web/inference_update_api_test.exs`): generated
  authorization/`authorize_update` coverage — Customer profile, cross-host or
  expired/rotated credential, and stale placement/epoch after relocation all
  resolve as the closed `:unauthorized` shape, surfacing as exactly one 403
  with a closed body via `MarshallWeb.InferenceAPI`; an eligible-but-unpublished
  artifact resolves as the distinct `unavailable` class. Arbitrary wire shapes
  never disclose artifact bytes. Focused suites: **14 passed (2 properties, 12
  tests)**.
- **Ziggy** (`update_artifact_test.exs` for `artifact_decision/2`): only an
  exact Marshall digest/size decision serves bytes; authority refusal is the
  only guest-distinguishable denial (403) and every other denial is a closed
  503. Focused suite: **6 passed**.
- **Lyra** (`update.rs` — extracted `mark_failed`): transient check failures
  (including closed 503 manifest denials) never create, extend or clear the
  rejection cooldown and never alter staged or applied identity. Full crate
  suites pass (52+ tests across bins/modules, 0 failures).

## Native legs (honestly scoped)

- The `auto-update` machine gains the out-of-band drift reconvergence leg, run
  natively: full driver rebuild passed in 89 seconds
  (`/nix/store/513wxp9mizimp283s76ggrvcndbfi1mx-vm-test-run-kittens-auto-update`;
  build-log `1790590305169-2930010-0`), including the new leg's own 10.82s.
- The migration-unit idempotence property sits in the same check's Python
  evaluation (`unit.py`).
- Carved-out pending repair: the guest-cli-recovery interrupted-fetch leg
  (first execution timed out inside its own post-recheck round trip — its code
  is NOT in this improvement; recorded in the campaign ledger as follow-up),
  the fleet-guest-trust driver additions (that suite is currently red on main
  for unrelated reasons — a 60-minute driver timeout, recorded separately), and
  the `updates.py` fleet legs (blocked by the recorded browser-acceptance
  defect, finding 119, until repaired).

## Full-gate record

- Marshall `mix precommit` on the final tree: **1,201 passed (140 properties,
  1,061 tests)**, 2 excluded; forced Dialyzer zero. Seed at
  `MIX_TEST_PARTITION=verify113`.
- Ziggy `update_artifact_test.exs`: 6 passed. Lyra `cargo test`: every crate
  suite green (3+52+1+11+5+5 plus others; 0 failures).
- Governance: `check_adrs.exs` (124 decisions), refreshed receipts current after
  the carve, and `prek run --all-files` green where it gates.


## Mutant checks

(The Ziggy rejection-cooldown and dependent artifact-gate mutations are
recorded here when executed.)

## Remaining

- Fleet `updates.py` addition depends on the open campaign finding 119
  (`Browser acceptance failed` at the composed fleet traversal) until that is
  repaired; its code is present but no fresh native record is claimed here
  without the completion of that leg.
- Guest-fleet trust delivery retries and the `update.rs` desktop stale-stage
  positive activation leg remain as separate queued items.
