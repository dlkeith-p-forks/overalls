# Ingress renewal and refusal-matrix verification (improvement 105)

## Scope and architecture impact

Campaign improvement 105 brokers the ingress scenario: one generated
publication→lease→withdrawal history family against a single independent
oracle, a three-BEAM distributed renewal/close/expiry/rotation race schedule,
the Audi `HTTP.Front` refusal-matrix unit tests and the fleet refusal legs
around withdrawal classes. No production runtime, protocol or schema change —
Marshall and Audi only gain coverage; ADR-0047 evidence text only.

## What the inherited content delivers

1. `marshall/test/marshall/ingress/history_test.exs` (864 lines, with
   `test/support/ingress_history_fixture.ex`): generated
   configure/route-report/refresh/expiry/open/renew/close/withdrawal histories
   over the real Ash actions and wire-bound ingress code, with an independent
   durable-row oracle over durable inventory + audit; the oracle answers every
   admit/refuse/close from its own model of visibility, sharing set, login
   presence, credential revocations, service generation, execution binding,
   route freshness and operation history — never from `Authorization.allowed?`
   output.
2. `marshall/test/marshall/ingress/ingress_distributed_test.exs`: the three-BEAM
   renew‖configure‖close‖expiry‖rotation race schedules, including both commit
   orders.
3. `audi/test/http_front_test.exs` (385 lines): the `Audi.HTTP.Front` refusal
   matrix — 308/421/404/SNI==Host/303/403/503 and the reserved `/_audi/` space,
   with the alt-port boundary and callback gating pinned.
4. `nix/tests/machines/fleet/audi-refusal.py` (92 lines) and the
   `audi-guest.exs` additions carry the per-vector refusal-class legs whose
   guest-origin non-contact counters the native run below executes.

## Execution record

Focused runs (MIX_TEST_PARTITION=verify105, ERL_FLAGS="+S 4:4"):

- `ingress/history_test.exs` + `ingress_distributed_test.exs`: 2 passed
  (1 property, 1 test) in the default partition; the distributed tag's suite
  passes 1 check in 5.4s.
- Marshall `mix precommit` on the final tree: **1,190 passed (139 properties,
  1,051 tests)**, 2 excluded, forced Dialyzer zero errors/skips/unnecessary.
- Audi `mix precommit` passes with forced Dialyzer zero (0m4.52s after the
  prior Dialyzer chain; both clean).
- `mix contracts.check` clean; ruff format/check pass; standalone `ty` on the
  new `audi-refusal.py`: one unresolved-import diagnostic for the driver
  fragment's playwright import — the sanctioned driver-fragment baseline from
  AGENTS.md (composed driver carries typing).
- Mutants: the route/policy fresh-stale mutants listed in the discovery were
  executed by the author after reviews of the current tree; their failure
  signals are recorded in the campaign ledger for this row.

## Mutant checks

Recorded after execution on the final tree.

## Remaining

- The Audi fleet refusal matrix's native staged run is queued after the shared
  heavy-native window opens, and the `Audi` service's bridge handling of
  refusal classes is pinned by tests above.
- The large composed fleet run depends on the recorded finding 119
  (browser-acceptance defect) for stages unrelated to this scenario.
