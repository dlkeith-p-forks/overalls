# Clone cleanup liveness review — 2026-10-13

## Scope and authority

The user reported refusals and "stuck" machines around resizing and cloning on
the production fleet and authorized investigation with host shell access,
database reads, Porsche machine creation and deletion, and changes without
limit to make the workflows better, more hardened and more performant.
[ADR-0162](../decisions/0162-clone-cleanup-liveness.md) records the decision;
this review records the evidence behind it and the verification performed.

## Production findings

Every resize request in the fourteen days before the review completed (five
requests, 12 to 40 seconds each). The refusals came from cloning and relocation.

| Observation | Evidence |
| --- | --- |
| Clone `edd90b26` (same-host, overalls) published at 12:18:04 and stayed in `cleaning` with `failure = prune_unconfirmed`; its prune effect was offered at 12:18:06 and never completed | `compute_clone_requests`, `compute_clone_effects` |
| Lilly's journals for the source placement were healthy: snapshot pointer bound, `lilly-b` ready, dataset GUID matching | `/var/lib/lilly/pool/.lilly-zfs/active/<placement>` |
| Neither Lilly nor Marshall logged a reason: the clone runtime reduced every failure to a bare unconfirmed result and Marshall recorded `<kind>_unconfirmed` without an event | `lilly/lib/lilly/clone/runtime.ex`, `marshall/lib/marshall/compute/clone_effects.ex` at `f2970dfe6` |
| 31 of the last 67 clone requests failed `source_unavailable` within one to three seconds of submission; `clone.failed` logged the folded `activation_failed` | database and `marshall-overalls.service` journal |
| Two relocations of VM `05f3855d` were refused `transfer_busy` while the stuck clone held the host's transfer slot | journal 12:46 and 13:14 |
| The clone card showed "Needs attention / Retry"; each retry failed again immediately | owner report, `clone_components.ex` |
| After the Phase 0 deploy (`2be51b48c`) the prune reported `snapshot_unconfirmed` (alternating with `execution_unavailable` placement-lock contention against the source VM actor's periodic trust check). The ZFS state was clean: `lilly-b` present, no holds, no clones, journals bound. The source VM had a GitHub workspace source and its start command after the clone restart carried it; `snapshot_source` pinned the full spec against the claim journaled without one, so every prune refused. All 19 previously completed clones had sources without a workspace source | `lilly.clone_effect_unconfirmed`, `zfs list -t snapshot`, `/var/lib/lilly/control/commands/<placement>.json`, `compute_workspace_sources` |
| The two resize requests made on the clone copy and the one on `05f3855d` all completed (13 to 40 seconds) | `compute_resize_requests` |

## Architecture assessment

Initial and final assessments: the change alters the clone control protocol
(exchange version 5, closed unconfirmed reasons), clone persistence (three
columns on effects, four on requests), the clone coordinator's state machine
(deadline completion, deferral, stop failure branch, immediate scheduling) and
the transfer slot ownership rule (release at both revocations). Authorization,
isolation, capacity accounting of physical resources, recovery of physical
state and deployment topology are unchanged: no deadline releases a physical
resource, and the source temporary hold moves only on the prune receipt.
ADR-0055's slot release clause is superseded with reciprocal links; ADR-0145,
0143, 0140 and 0061 keep their decisions and gain evidence notes through the
handbook. ADR-0159 applies: no compatibility path for the protocol version.

## Verification

| Gate | Result |
| --- | --- |
| Protocol `mix precommit` | passed (Phase 0 commit `2be51b48c`) |
| Lilly `mix precommit` | passed, 535 tests and 103 properties (Phase 0) |
| Marshall `mix precommit` | recorded below once the full gate completes on the liveness commit |
| Marshall clone, relocation, evacuation, drain, LiveView, SSH and capacity suites | see the final summary |
| `elixir scripts/check_adrs.exs`, `check_hldd.exs`, `hldd_views.exs --check` | run before commit |

Property coverage added or extended:

- `clone_cleanup_deadline_test.exs`: deadline completion with the hold
  retained, source excluded, prune still offered, another machine's clone
  activating on the host, the same-source request deferred
  `source_cleanup_pending`, settlement on the prune receipt, activation after.
- `clone_restoration_history_test.exs`: slots release on both revocations
  before pruning; the competitor is deferred `transfer_busy`, not failed.
- `clone_history_test.exs`: cancellation obligations with slots released at
  quiescence; reasoned unconfirmed receipts.
- Lilly `clone/runtime_failures_test.exs`: one diagnostic per effect and
  change of reason or internal stage; stage never becomes a peer value.
- Lilly `host/claim_shape_test.exs`: a ready claim matches the placement's
  spec with or without a workspace source and refuses shape changes.
- Protocol `clone_control_test.exs`: closed reason acceptance and refusal.

## Production acceptance

| Observation | Evidence |
| --- | --- |
| Phase 0 (`2be51b48c`) deployed; the stuck prune reported `snapshot_unconfirmed` (alternating with `execution_unavailable`), which led to the storage-shape finding | `lilly.clone_effect_unconfirmed` 15:20 |
| Phase 1 with the storage-shape fix (`24bc653b9`) deployed at 15:52; the prune confirmed on the first exchange (`lilly.clone_effect_completed` 15:52:19), the request completed with `cleanup_completed_at` 15:52:20, `clone.effect_confirmed` and `clone.completed` were logged, the `lilly-b` snapshot is gone, no transfer slot is held (0 of 47) and the source hold is 0 | journals, `compute_clone_requests`, `compute_transfer_slots`, `zfs list` |
| The source VM's `trust_unconfirmed` deferral loop (130 events since 12:19, placement-lock contention with the prune) stopped: none after 15:53 | `vm.execution_deferred` |
| 31 older finished requests had no cleanup receipt; none is offered a prune (the offer requires an existing prune effect) and no diagnostic recurs | `compute_clone_effects`, Lilly journal |
| A same-host clone of a running source through Porsche at `cda064f36` completed with its prune confirmed 16 s after submission | [resize hardening review](2026-10-13-resize-hardening.md) |

## Limits and follow-up

- Synthetic receipts prove database authority, not physical readiness; the
  native clone matrix, cancellation and restart tests must be rerun on the
  liveness commit and recorded here.
- No native test clones a source that carries a workspace source; the fixture
  profiles refuse egress sources and the test network has no GitHub. The
  storage-shape rule is pinned at the claim layer and accepted in production
  by the stuck request's prune confirming after deployment.
- A prune waiting on the pool lock holds the placement lock for up to two
  seconds, so the source VM actor's periodic trust re-check can defer
  `trust_unconfirmed` meanwhile; it retries and does not stop the guest.
- A request whose destination settled as failed still waits for the prune
  before failing; the deadline does not shortcut it.
- The standby-disk refill storm, capacity-report damping, ARC sizing and
  deploy-restart churn found in the same investigation are separate changes.
