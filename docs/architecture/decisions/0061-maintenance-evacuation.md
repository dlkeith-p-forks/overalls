# ADR-0061: Maintenance evacuation campaigns

- ID: ADR-0061
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, administration, AshOban
- Supersedes: none
- Superseded by: ADR-0155

## Context

[ADR-0155](0155-stopped-only-relocation.md) removes pre-copy, so "Prefer
existing pre-copy selection" no longer applies and every running workload needs
explicit downtime approval before its move; stopped workloads still need none.
All other campaign requirements below are carried forward unchanged.

The user requested maintenance that moves a Lilly node's workloads elsewhere,
preserving running/stopped state and showing real progress. ADR-0026's existing
drain stops guests in place and disables the host. Current ingress and SSH serving
also check enabled state; disabling a source while moving guests would prematurely
disconnect workloads. ADR-0037 already provides placement-preserving relocation,
capacity reservations, transfer slots, physical outcomes and cleanup.

## Decision

The approved admin plan authorizes a separate durable evacuation campaign.
Retain stop-in-place drain unchanged. Add `evacuating` as an admission-excluding
mode that keeps the host enabled for existing ingress/SSH. Only outgoing moves
bound to the current open campaign may use that source. Destinations must remain
normal and satisfy the existing fresh capacity/image/transfer requirements.

Under the source host lock, a current administrator requests an idempotent campaign
and a fixed workload/placement/epoch cohort. Record requester provenance and
enqueue periodic durable advancement atomically. Campaign acceptance survives
requester demotion; later controls and approvals require current administrator
permission. This is campaign-scoped authority, not conversion of ordinary requests
to unrestricted system authority.

Each advancement locks candidate hosts in UUID order before campaign and VM state
and schedules at most one cohort workload through existing relocation reservations
and jobs. Prefer existing pre-copy selection. If a running workload requires a
full stopped copy, retain a blocker until an administrator explicitly approves
that workload's fixed placement/epoch. Stopped workloads need no downtime approval.
Pause prevents new admissions while accepted moves and source restoration continue.
Record fixed safe blocker codes and attempts; never expose raw failures or guess
transfer completion percentages or arrival times.

Maintenance-ready requires fresh execution-ready host and pool reports, no current
workloads, no retained compute/disk/temporary holds and no unfinished relocation.
Job completion or disconnection is insufficient. Resume rechecks physical emptiness
and restores admission without moving guests back. Retirement additionally revokes
host credentials and permanently retains disabled host identity/history. Installation,
erasure, enrollment and secrets remain deployment concerns.

The complete console must show advisory destination/capacity preview and recheck at
admission, current-administrator admission/CPU/RAM margin controls, per-workload approval and blockers, real relocation phases/bytes/downtime,
cleanup progress and a correlated timeline. Changed workloads and completed
cancellations require explicit re-planning rather than silently extending approval
to a new placement/epoch.

## Alternatives

Reusing stop-in-place drain would retain disks locally and cut serving authority.
Unconditionally allowing all moves from maintenance hosts would bypass the fixed
campaign and downtime approval. Calling ordinary user relocation with the original
actor would strand accepted work after demotion. Releasing resources when jobs
finish would mistake orchestration completion for physical cleanup.

## Consequences

The schema and all Marshall replicas must support the new mode before requests
are enabled. Existing Lilly commands and shared protocol remain unchanged. The
current coordinator bounds one campaign to 1000 workloads and its candidate fleet
to 128 hosts, rejecting larger inputs without partial enrollment. These bounds do
not establish throughput. One move per source transfer slot preserves existing
bandwidth and capacity limits. A blocked or cancelled workload can hold maintenance
open until explicit operator resolution; no forced cleanup override is introduced.

## Invariants and verification

- Request, fixed cohort, admission exclusion and initial job commit together.
- Current admin checks govern controls; accepted work survives requester demotion.
- Ordinary source admission remains excluded; only campaign-bound source moves
  and restoration are permitted, never new destination placement on that source.
- Full stopped-copy approval cannot transfer between workloads or placements.
- Duplicate workers cannot create duplicate reservations or relocation links.
- Pause does not cancel accepted moves or undermine their recovery obligations.
- Readiness, resume and retirement require current physical evidence.
- Native two-Lilly testing must prove identity/data/state/ingress preservation,
  source cleanup and recovery under failure, beyond coordinator fixtures.

## Implementation evidence

[Campaign](../../../marshall/lib/marshall/compute/evacuation.ex) and
[cohort](../../../marshall/lib/marshall/compute/evacuation_item.ex) Ash resources
retain request/approval/control provenance and periodic jobs. The
[coordinator](../../../marshall/lib/marshall/compute/evacuations.ex) implements
request, pause/continue, approval, bounded scheduling and empty-host readiness/
resume/retirement. [Relocation capacity](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
reuses transactional Budget/slot logic with campaign-bound source admission.
Source stop/restoration eligibility accepts only a matching open campaign.
Composite FKs bind relocation source to campaign host, and cohort links to the
correct VM, placement and campaign relocation.

The [maintenance views](../../../marshall/lib/marshall/compute/evacuation_views.ex)
now provide bounded node/cohort pages and explicit advisory preview through the
same selection helper used by admission. The
[console](../../../marshall/lib/marshall_web/live/admin/lilly_nodes_live.ex) exposes
preview, request, pause/continue, per-workload approval, re-planning and ready-host
resume/retirement. Progress describes the exact linked relocation and its existing
physical-evidence downtime/attempt-byte projection. Inventory polls every minute,
campaigns every fifteen seconds; preview is never polled.

Explicit re-planning rejects unfinished moves/resizes, binds current placement/
epoch/state, rotates the request key and clears prior approval. Approval and
re-planning require the displayed item revision. Removed workloads may be resolved,
while campaign readiness still requires physical source cleanup. PaperTrail retains
earlier links/approvals and the re-planning administrator. Administrator requests, controls,
approvals and replans also write redacted append-only account audit events in the same
transaction as the campaign/item mutation. The same maintenance projection also lists bounded historical campaign milestones
and retained redacted relocation job states, without reading raw Oban payloads.

Eight [campaign/domain tests](../../../marshall/test/marshall/compute/evacuations_test.exs),
eighteen existing relocation-capacity tests and three
[browser-state tests](../../../marshall/test/marshall_web/admin_lilly_nodes_live_test.exs)
pass. The preceding foundation gate passed 595 tests and Dialyzer. These establish
coordinator/UI fixtures, not actual guest movement. Detailed command/readiness/
cleanup correlation, concurrent campaign races, native recovery acceptance and
final deployment gates remain required.

## Open questions

No unresolved product choices. Native recovery, serving continuity and fleet-scale
latency remain to be measured before completion can be claimed. Multi-disk
Inception workloads now relocate under
[ADR-0072](0072-multi-disk-workload-transfer.md), and blocker rotation also
recognizes `clone_in_progress` defensively
([evacuations](../../../marshall/lib/marshall/compute/evacuations.ex)).

## Related decisions

[ADR-0026](0026-host-maintenance-and-retirement.md) retains stop-in-place drain.
[ADR-0037](0037-workload-placement-and-relocation.md) retains relocation identity,
transfer, physical evidence and cleanup semantics.
[ADR-0058](0058-administrative-authority.md) defines current administrative authority.

## Verification continuation

The [maintenance verification review](../reviews/2026-09-25-maintenance-evacuation-verification.md)
records generated control/readiness histories and independent-process schedules.
Measured overlapping revocation-first requests and controls committed after
elevation lock or sign-out; source inspection identifies a late User foreign-key
path after the earlier authority check. Current
controls retain actor User authority after the required Host/campaign/item/VM locks
and recheck Cedar before mutation. Automatic advancement retains accepted campaign
authority after requester demotion. The captured browser/two-Lilly campaign passed
all seven stages (587.51-second script), including actual running/stopped moves,
physical source cleanup, data/ingress identity and fresh-elevation admission resume.
Native full-stop consent, cancellation/replan permutations, independent hosts and
deployment remain separate. Exact source scope and earlier failed fixture attempts
remain in the review. Accepted rationale and partial status remain.
