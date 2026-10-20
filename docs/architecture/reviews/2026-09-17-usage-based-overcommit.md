# Usage-based overcommit implementation review

Date: 2026-09-17

## Scope and architecture impact

The operator authorized ADR-0050's usage-based CPU/RAM/disk admission, full-shape
startup holds, best-effort pressure behavior and revised overalls physical limits.
ADR-0006, ADR-0010, ADR-0037 and ADR-0048 retain their rationale; ADR-0050 carries
forward requirements outside capacity admission and reviewed resource tuning.

## Stage one: resource-policy updater

The old updater rejects guest CPU/RAM and installation-quota changes. The
[resource helper](../../../nix/domains/system/auto-update/resources.py) introduces an
exact allowlist tied to unchanged enrolled dataset/pool GUIDs. Original receipts
are journaled before native effects; interrupted updates accept only their old or
target receipts. CPU/RAM/quota decreases remain maintenance operations. Properties
are applied to the live slice and existing dataset, with native readback. Boot
reapplies the reviewed policy. No formatting, guest stop or new session is involved.

The [unit tests](../../../nix/verification/tests/machines/auto-update/resources_test.py) passed
allowlist, identity substitution, policy removal/decrease, native-quota drift and
interrupted receipt reconciliation scenarios. Existing authority-compatibility
tests passed. ADR structure and code-contract syntax/coverage checks passed.
The host-planning checks passed after updating a constructor-bypassing test fixture
to provide its configuration. The initial existing updater machine suite passed.

The expanded [updater machine](../../../nix/verification/tests/machines/auto-update/driver.py)
checks slice changes preserve a live process. The
[native ZFS fixture](../../../nix/verification/tests/machines/auto-update/native_resources.py)
checks real property updates, interruption recovery, GUID/receipt preservation
and a surviving guest-slice process. The expanded native ZFS suite passed in 277 seconds and the actual Git/NixOS
updater suite passed in 100 seconds. Host-planning and storage-configuration
checks also passed. Overalls auto-updated to `6ef437e29dc862c270736558f6f006e3d4ca5416`; the updater
reported healthy with that exact last-healthy revision before stage two began.

## Stage two: physical admission

The report carries versioned, bounded headroom and interval coverage. CPU uses
cgroup `usage_usec` deltas across the guest scope, constrained ancestors and root;
RAM uses the minimum of cgroup headroom and host MemAvailable. Reset, missing or
long intervals remain unknown. Proofs must remain identical across both sample
boundaries and match current authenticated physical outcome identity before
settling provisional holds. Retained ownership is never released by low usage.
The additive migration defaults old reservations to provisional holds; old reports
remain decodable but cannot admit new work without usage telemetry.

Provision, manual restart, crash recovery and destination activation share host
serialization. Every new execution must fit its full shape (including 64 MiB VMM
allowance); recovery refusal retains the disk. Disk startup holds only credit their
own observed allocation, while temporary snapshot holds remain conservative.
Legacy enrollment logical budgets are immutable metadata and no longer admission
ceilings. Catalog/UI display current headroom, with unknown distinct from zero.
Telemetry separates assigned resources, pending holds and measured headroom.

Overalls declares 32 CPU cores, 116036 MiB guest memory, 1593 GiB guest quota and
4 GiB ARC; trusted operator actions set all scheduler overheads to zero. The
resource updater preserves native identities and receipts. System RAM and disk
margins are in physical ceilings and are not deducted again.

Targeted usage-admission tests passed aggregate CPU/RAM/disk overcommit, pending
holds, absent native allocation, stale generation, unknown/zero pressure, and
recovery rejection. The protocol gate passed 73 cases and Lilly passed 216, both with forced Dialyzer.
Marshall's final full gate passed 396 cases including distributed races, six
browser state tests, and forced Dialyzer (the existing upstream suppression only).
This includes operator-margin authorization/idempotency and UI
unknown-versus-zero regressions. Contract discovery was checked for usage and startup settlement;
all changed native notes and consumers were reviewed manually.

Native ZFS passed in 291 seconds, including a sparse 3 GiB file on a 2 GiB
quota, quota write failure, real cgroup CPU/RAM pressure and recovery, and the
resource updater's interruption/process-survival checks. Host-planning and
storage-configuration checks passed. The proposed overalls policy also passes
the helper's compatibility check against the live stage-one manifest.

The real Firecracker suite passed in 1481 seconds, including two
2-CPU/1-GiB/4-GiB guests running within a 2-CPU/1.5-GiB/6-GiB physical budget,
CPU saturation and headroom recovery, retained guest reads, and cleanup. It also
passed the existing crash recovery and guest identity checks. The expanded fleet
suite subsequently passed as recorded below. Fleet fixtures wait for real startup settlement and explicitly place
network-isolation neighbors rather than relying on virtual-size exhaustion.

## Review boundaries

This changes capacity policy under ADR-0050, preserving physical ownership,
authorization, lock order, execution fencing and guest process limits. No fixed
ratio, ballooning, swap, eviction or allocation guarantee is introduced. Linux
pressure and sparse ZFS tests are separate from real guest workload/OOM acceptance;
no production guests are intentionally stressed. The physical margins derive from
measured overalls MemTotal and usable ZFS capacity, not nominal device sizes.


## Activation ordering correction

Stage two installed the native limits but host readiness ran before the updater's
post-switch receipt publication, causing activation to fail. All five guest PIDs
survived. The existing saved transition was resumed with the installed updater
helper under its update lock, preserving its original receipt evidence. Automatic
retry then marked `6cbfcae` healthy. Live reports show 32 cores, 113.316 GiB guest
RAM, zero scheduler margins, roughly 31.6 idle CPU cores, 111.6 GiB RAM headroom
and 1590.3 GiB physical disk free. All five guests report running and both startup
hold counts are zero.

A later read-only production check at 22:44 UTC found six running guests, six
owned compute/disk reservations and zero pending startup holds. Headroom remained
31518 millicores, 119502823424 RAM bytes and 1589.728 GiB disk, with all three
scheduler margins zero. The additional guest appeared independently of this
acceptance run; no production workload was created or stressed by these checks.

The correction orders host readiness after resource policy application and makes
that service replay an existing matching journal before checking receipts. Without
a journal it only reapplies native limits and cannot manufacture receipts. This
implements ADR-0050's existing recovery decision; it changes no authority or
identity boundary. Python regressions cover both branches and interrupted receipt
publication; the updater machine passed in 122 seconds. The native ZFS fixture
also exercises this activation/boot entry point. A separate fleet fixture repair
uses the current disko `system0`/`system1` image filenames and has no architecture
impact.


## Production acceptance and fleet fixture reconciliation

Auto-update deployed correction `990236a` and marked it healthy. All five original
guest process IDs survived both stages and the correction. Native dataset GUID
`597516776640599365` is unchanged, quota is `1710470725632` bytes and ARC target is
`4294967296` bytes. The final native ZFS run passed in 367 seconds and directly
exercised boot/activation journal replay before readiness. All three Python
resource tests, host-planning, updater, contract syntax and ADR structure checks
passed. The test daemon lacks the nested-kvm feature declaration; real guest and
fleet runs use the local Nix store with verified `/dev/kvm` and enabled nested KVM.

The first full fleet run passed enrollment but exposed a pre-existing stale
expectation in storage-failures: it expected all host reports to expire when one
pool was unavailable. The collector and receiver contracts explicitly preserve
host telemetry and invalidate only the failed pool. The corrected fixture checks
cleared pool freshness, observations and allocation credit, fresh host telemetry,
rejected admission, and recovery of pool freshness. This is test reconciliation,
not a change to the scoped failure policy. The rerun passed both scoped storage
failure and missing-image rejection, then correctly rejected a 2 GiB guest because
the shared installation fixture had a 512 MiB native quota and 512 MiB scheduler
margin. The fleet-only setup now sets a real 8 GiB quota on its isolated 12 GiB
mirrored disks before enrollment; no reported capacity or GUID is fabricated.
With that correction, three-node idempotent admission and the two-accepted,
one-rejected startup race passed. A later sequential setup request was correctly
refused while CPU headroom was 1931 millicores, below the fixture's one-core request
plus one-core margin. Sequential setup now retries only capacity refusals with a
stable request key and a bounded deadline; synchronized admission races retain
strict assertions and no retries. The subsequent full capacity scenario passed
with six running guests and settled holds, followed by network isolation, actual
release upgrades and credential-only updates preserving guest processes.

Browser acceptance then reached the production sign-in domain restriction:
existing fixture users had `example.test` addresses and ADR-0049 correctly rejected
their tokens. The isolated users then used unique organizational mailbox identities, while
normal strategy token issuance and private delivery remain unchanged. This
reconciles fixture data with ADR-0049; it changes no production authentication.
The next run passed browser sharing and terminal recovery (200 seconds), Marshall
machine loss and database outage (136 seconds), and Lilly daemon death with
surviving VMMs (33 seconds). It failed at the retained-disk start request: the
fixture matched only success and withheld the rejection reason. Restart setup now
returns only explicit capacity refusals as retryable, with a stable request key
and a 180-second deadline; any other error still fails immediately. This respects
the new full-shape restart admission contract without relaxing capacity policy.
Full lifecycle acceptance was pending at this point. An environment change
also interrupted one run and removed build-user KVM access; resumed runs use the
local root Nix builder without changing device permissions or group membership.
A transient three-second sample-freshness preflight timeout was retained as a
failed run; a retry passed it without changing any admission/freshness threshold.
Capacity-only failure diagnostics now make subsequent timeouts reviewable.

The restart-fixture rerun again passed capacity, network isolation, release updates
and credential rotation, but failed earlier in browser writer handoff: the
member's claim button did not become enabled. The same browser scenario passed
the preceding run; this failure is not a full-suite pass and its cause is not yet
established. Browser acceptance now explicitly waits for the owner's release to
complete before promotion/handoff and emits only allowlisted UI status labels on
claim-readiness failure. It retains the production authority path and all guest
effects, without printing terminal contents, tokens or session identifiers.

## Requirement audit

| Requirement | Evidence |
| --- | --- |
| Measured CPU/RAM admission without fixed ratios | [Usage sampler](../../../lilly/lib/lilly/host/usage.ex), [budget](../../../marshall/lib/marshall/compute/budget.ex), and passing [usage tests](../../../lilly/test/host/usage_test.exs). |
| CPU, RAM and disk commitments may exceed physical budgets | Passing [admission tests](../../../marshall/test/marshall/compute/usage_admission_test.exs) and [real Firecracker overcommit scenario](../../../nix/verification/tests/machines/zfs-guest/driver.py). |
| Full-shape, durable concurrent startup holds | [Settlement coordinator](../../../marshall/lib/marshall/compute/startup_holds.ex), stale/outcome/allocation rejection cases, distributed races, and the passing six-guest fleet capacity scenario. |
| Restart/recovery/relocation admission follows current headroom | [Restart capacity](../../../marshall/lib/marshall/compute/restart_capacity.ex), manual/recovery pressure tests and relocation tests in the passing Marshall gate. |
| Replace old overalls limits and overheads | Host configuration (retired Overalls host declaration), [operator reconciliation](../../../marshall/lib/marshall/compute/capacity_policy.ex), and production native/SQL readback recorded above. |
| Preserve guest limits, ownership and native identity | Native pressure/storage checks, actual release and credential updates, and unchanged production guest PIDs and dataset GUID. |
| Distinguish measured, assigned, pending and unknown capacity | [Catalog](../../../marshall/lib/marshall/compute/views.ex), budget/telemetry tests, and UI unknown-versus-zero regression in the passing Marshall gate. |
| Commit-driven two-stage deployment with recoverable receipts | Published commits `6ef437e`, `6cbfcae`, `990236a`; healthy production updater status, recorded interruption recovery and passing native journal replay checks. |

## Final acceptance

The complete source-built nine-machine fleet suite passed in 1695.56 seconds
(Nix build exit zero). It passed all scenarios in one run: schema migration and
authenticated enrollment; scoped storage failures and missing-image rejection;
three-node idempotency and concurrent startup holds; real guest network isolation;
release and credential updates preserving guests; verified browser sharing,
terminal recovery and writer handoff; Marshall/database loss and Lilly daemon
loss; retained-disk restart and confirmed deletion; stale-capacity rejection and
replacement placement; and revoked provisioner authority preserving guests.
Earlier partial, failed and interrupted runs are retained above as history and
are not counted as full-suite passes. The strengthened browser release assertion
passed; the prior intermittent failure's exact cause was not established.

The final fixture diff conforms to ADR-0050's actual-usage admission and ADR-0049's
sign-in restriction without changing production authorization or capacity policy.
Bounded setup retries accept only explicit capacity refusal and retain stable
request keys; the synchronized admission race retains its strict assertions.
Diagnostics expose only capacity evidence and allowlisted UI states. Contract
semantics were reviewed against the called lifecycle/provisioning actions and
browser authority path; syntax checks alone do not establish those semantics.

ADR-0050 is implemented for this decision's scope. Application gates, native
pressure/storage/guest acceptance, the full fleet suite and the deployed policy
provide the evidence in the audit above. Production workload benchmarking and
intentional guest OOM testing are outside these claims; overcommit remains best
effort under later contention. Inherited platform gaps retain their existing ADR
statuses. The remaining fixture/documentation commit follows the same automatic
update path and requires a final healthy-revision readback.
