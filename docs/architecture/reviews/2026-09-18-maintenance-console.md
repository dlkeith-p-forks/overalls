# Maintenance console and explicit re-planning

## Scope and architecture impact

This implements additional [ADR-0061](../decisions/0061-maintenance-evacuation.md)
requirements: bounded current-admin views, advisory preview, console controls and
explicit recovery planning. ADR-0037 relocation selection and progress semantics
are reused; the shared protocol and Lilly execution behavior are unchanged.

## Evidence and findings

[Re-planning](../../../marshall/lib/marshall/compute/evacuations.ex) serializes on
the source host, campaign, item and VM. It requires current admin authority and the
displayed item revision, excludes unfinished relocation/resize, binds the current
placement/epoch/desired state and records a fresh move request key. It clears prior
downtime approval. Removed/archived workloads may be marked resolved; readiness
still checks source physical cleanup. Approval also requires the displayed revision,
preventing a stale browser from approving a newly re-planned placement. Late blocker
writes check the revision so they cannot overwrite new planning state.

The [cohort resource](../../../marshall/lib/marshall/compute/evacuation_item.ex)
retains re-planning identity and audit history through PaperTrail. The migration is
forward-only. Existing accepted move links are preserved until explicit re-planning;
historical links remain in audit and relocation history.

[Capacity selection](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
now has one preparation helper used both by preview and actual reservation. Preview
does not acquire host capacity locks or create reservations/slots/jobs. Admission
repeats the same selection under sorted locks. Each row is an independent advisory
fit, not a simulated reservation for the whole campaign; the UI states this.

The [domain views](../../../marshall/lib/marshall/compute/evacuation_views.ex) recheck
current administrator authority and return at most 50 nodes or 20 workloads per
page. They expose no credentials or transfer endpoints. Progress describes the exact
linked relocation rather than whichever move of the VM happens to be latest.
The [console](../../../marshall/lib/marshall_web/live/admin/lilly_nodes_live.ex) uses
fresh login/admin hooks, polls inventory every minute and campaigns every fifteen
seconds, and loads preview only on explicit request. Historical byte counts are
never displayed as a completion percentage; downtime uses existing physical evidence.
The capacity panel also displays configured CPU/RAM admission overhead separately
from deployment-managed physical limits.

## Remaining obligations

- Aggregate whole-campaign planning remains unfinished. The console exposes
  per-pool explanations from the actual admission arithmetic: measured headroom,
  configured overhead, startup holds, temporary copy/resize holds and available
  resources. Current preview reports the exact selector's safe blocker code.
- The console now shows bounded historical campaign milestones and retained
  redacted relocation job states. Command/readiness/cleanup correlation remains.
- Independent-peer request/re-plan/approval/blocker races and actual cancelled-move
  recovery need verification beyond serialized fixtures.
- Native two-Lilly data/state/address/sharing/serving continuity, physical cleanup,
  restored-source re-planning and overload/latency acceptance remain required.
- LiveView tests verify rendered state and events, not visual browser inspection.

## Verification and contracts

The focused maintenance/domain suite now passes 35 tests, including capacity
explanations and the non-destructive health view. The earlier 29 tests included
eight campaign/domain, eighteen existing
relocation-capacity and three maintenance LiveView cases. They cover stale approval
rejection, re-planning approval reset, unfinished-move exclusion, write-free preview,
  request/pause/demotion, rendering actual workload/relocation controls, and the durable
  campaign/workload timeline. Ash snapshot
consistency passed. The latest Marshall gate passed 618 tests (50 properties) and
Dialyzer completed successfully. The existing isolated `relocation-fleet` Nix
check is environment-blocked because the builder lacks the required `nested-kvm`
system feature.

Reviewed ancestor compute/web/component contracts, existing Ledger and relocation
selection/status consumers. New notes specify revision-bound re-planning, bounded
read cadence, advisory preview and exact-relocation progress. No native acceptance
or completion of the full admin plan is claimed.
