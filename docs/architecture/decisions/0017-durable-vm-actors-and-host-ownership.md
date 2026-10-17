# ADR-0017: Durable VM actors and physical host ownership

- ID: ADR-0017
- Date: 2026-09-15
- Status: accepted
- Implementation: partial
- Components: Lilly runtime, VM actors, host ownership, Marshall admission
- Supersedes: none
- Superseded by: none

## Context

The authorized implementation requires automatic remote execution, per-VM actors,
independent VMM lifetime, bounded crash recovery and accurate reservations. ADR-0016
provides executable generations and transactional outcomes. A configurable state
lock alone cannot stop two Lilly instances using different directories on the same
host. A lost outcome or repeated launch after restart can also break accounting.

## Decision

Executable v2 Lilly runs as root on a dedicated x86-64 Linux/systemd/cgroup-v2 host.
Before opening a session it acquires the fixed `/run/lilly/owner.lock`, probes KVM
API/VM creation, verifies local VM UID/GID range availability and binds its host,
machine, state and pool identities in private `/var/lib/lilly/owner.json`.
The machine identifier is an application-specific HMAC of initialized
`/etc/machine-id`; raw machine IDs are never transmitted. This follows
[systemd's machine-ID guidance](https://github.com/systemd/systemd/blob/v255/man/machine-id.xml).
It detects accidental identity reuse; it is not hardware attestation.

The operator reserves UID/GID 1,000,002–1,196,606, the existing profile/transit
networks, `lilly.slice`, fixed ownership paths and the configured pool exclusively
for Lilly. Check local passwd/group and subordinate-ID files for overlap, including
primary GIDs. External identity services still require operator coordination.
A second instance cannot bypass ownership by choosing another state directory.
Do not unlink the global lock inode while an owner might exist. Identity or path
changes require deliberate host reconciliation, not automatic rebinding.

Scan all Lilly systemd units and slice subgroups against durable VM commands.
Unknown units fence execution and prevent fresh schedulable reports. Create one
supervised actor per stored VM, initially paused. Activate actors only after an
authenticated session and matching pool identities. On reconnect, adopt a proven
running VM without requiring its immutable boot image to remain staged.

Each actor owns a private durable journal and lock. Persist the attempted command
generation before work; keep a monotonic physical-outcome sequence and the last
proven running generation. Persist a validated outcome before delivery, replay its
stable ID until Marshall acknowledges it, and ignore acknowledgements for an older
outcome. Re-read durable command intent before accepting asynchronous results;
superseded results cannot be relabeled with a newer generation.

Before submitting a systemd start, persist a separate launch-attempt generation.
Never launch that generation twice, including after actor or Lilly death. Combined
with ADR-0016's native launch fence, this prevents restarts from bypassing Marshall's
crash budget. If interruption occurs after the marker but before submission,
conservative failure may require a new explicit start. Busy locks before submission
may retry. A crash is eligible for automatic recovery only after the journal records
that generation physically running.

Marshal file publication and disk removal through the native lock owner's bounded
utility process. An accepted rename/remove cannot escape a dead mutation owner and
race a successor. Retire active command files and actor processes only after a
current deleted outcome is durably acknowledged. Keep compact driver/journal
identity tombstones; remove pool VM directories after physical cleanup so pool
enumeration limits apply to live materialization, not lifetime deletions.

Marshall admits provision/start only when the host uses v2, its current report
explicitly says `execution_ready: true`, and normal freshness/image/capacity checks
pass. V1 remains receipt-only; normalize its reported readiness to false. Stop and
delete remain available while disconnected. This flag records the authenticated
provisioner's readiness claim, not independent hardware attestation.

## Alternatives

Caller-selected locks permit duplicate physical ownership. Memory-only outcomes
lose evidence after a crash. Re-running every unacknowledged launch can restart a
VM indefinitely without Marshall consuming its retry budget. Stopping VMMs when
Lilly disconnects violates independent lifetime and confuses availability with
physical absence. Removing every tombstone allows old work to recreate deleted VMs.

## Consequences

The application can recover its actors while systemd preserves VMMs and consoles.
Uncertainty retains reservations. Fixed host identity and exclusive ownership
restrict casual state-path migration; operators need a documented recovery/drain
workflow. Persistent tombstones need an eventual retention policy that preserves
replay safety. Per-VM polling and filesystem sync costs require load measurement.
V1 storage is not silently upgraded into executable storage.

## Invariants and verification

- Only one executable runtime owns a physical host, across configured paths.
- Unknown resources or failed startup checks never produce schedulable readiness.
- Replayed or superseded results cannot release a newer generation's capacity.
- Restart preserves outcome identity/sequence and cannot repeat a launch attempt.
- Credential fencing stops actors while preserving VMMs and held reservations.
- Acknowledged deletion removes active reconciliation only after physical cleanup.
- Real HTTPS/KVM tests exercise multiple profile VMs, stop/start, process death,
  crash budgets, revocation and cleanup. Unit properties do not prove isolation.

## Implementation evidence

The [waiting-intent review](../reviews/2026-10-05-launch-guard-waiting-intent.md) records an exact blocked kernel flock witness, post-wait generation/state/custody refusals and unchanged exec control. Fresh integrated native rebuild passed127seconds (3library properties,6integration checks,rustfmt/Clippy); local ordering mutation is historical and scoped. Consumer and systemd/Firecracker composition remain open. Decision/status unchanged.

The [native worker BEAM extension](../../../nix/tests/machines/zfs-guest/actor-recovery.exs)
adds abrupt process-wide release-worker loss after completed Firecracker effect
and before actor outcome recording, followed by independent Store/lock reopens.
The [review](../reviews/2026-10-03-lilly-native-beam-recovery.md) records passing
fixture Dialyzer and a passing 1,040-second native check with three new worker
histories. The production systemd daemon
is disabled in this storage fixture; authenticated activation, fixed global
ownership and production daemon restart remain separate verification gaps.

The [native actor completion-window fixture](../../../nix/tests/machines/zfs-guest/actor-recovery.exs)
and [generated driver](../../../nix/tests/machines/zfs-guest/actor-recovery.py)
extend the controlled executor history to real Executor/systemd/Firecracker/ZFS
effects. The combined real lock contention/completion extension passed in
671 seconds, exit 0, as recorded in the
[scoped review](../reviews/2026-10-03-lilly-native-actor-recovery.md); this bounded evidence
does not change this decision's partial implementation status.

[Host ownership](../../../lilly/lib/lilly/host/ownership.ex),
[machine identity](../../../lilly/lib/lilly/host/identity.ex),
[UID reservation](../../../lilly/lib/lilly/host/uid_reservation.ex),
[KVM probe](../../../lilly/native/kvm-probe/src/lib.rs) and
[runtime config](../../../lilly/lib/lilly/control/config.ex) establish startup gates.
[Runtime](../../../lilly/lib/lilly/control/runtime.ex),
[actor](../../../lilly/lib/lilly/vm/actor.ex),
[journal](../../../lilly/lib/lilly/vm/journal.ex),
[executor](../../../lilly/lib/lilly/vm/executor.ex) and
[driver](../../../lilly/lib/lilly/vm/driver.ex) implement reconciliation and delivery.
[Admission](../../../marshall/lib/marshall/compute/admission.ex) and
[report ingestion](../../../marshall/lib/marshall/compute/host_reports.ex) gate readiness.
[Actor tests](../../../lilly/test/vm/actor_test.exs),
[journal properties](../../../lilly/test/vm/journal_test.exs) and
[real integration harness](../../../marshall/scripts/smoke_execution.exs) exercise these
contracts. See the [review](../reviews/2026-09-15-durable-vm-actors.md) for actual
results and remaining operational/multi-host evidence.
The [historical focused Antithesis actor harness](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/README.md) provided a
locally validated Store/actor/journal replay workload with a durable fake launch
marker. Its [review](../reviews/2026-09-28-antithesis-local-harness.md) retains
the exact local execution and the missing mid-attempt, hosted and native coverage.
The old `antithesis/` tree is retired on 2026-10-13 before a fresh whole-repository
rebuild. Historical harness and mutation artifacts are linked at the captured
baseline; they do not establish a current hosted harness or mutation sweep.
The [new harness foundation review](../reviews/2026-10-13-antithesis-harness-foundation.md)
records a separately selected hosted Lilly variant with unavailable capacity,
false execution readiness and fail-closed controlled/guest executors. It can
observe enrollment and Control connection but cannot settle a physical guest
effect or establish current hosted actor coverage. The accepted durable actor,
host ownership and native proof requirements remain in force; implementation
stays partial. A separately selected integrated TCG host now has source-level
measured ZFS, host-bound ownership and guest observation, with a reviewed
enrollment path; no complete composed Control/guest execution is recorded.
The local [guest boot](../../../antithesis/verification/guest-boot.md) and
[router reset](../../../antithesis/verification/storage-boot.md) remain distinct
software-emulator evidence, not native ownership acceptance.
The [inner-host record](../../../antithesis/verification/integrated-host-boot.json)
adds a passing local ZFS/cgroup measurement after two failed-health attempts.
Its sample is disconnected and execution-unready: enrollment, authenticated
Control, admitted guest and crash recovery remain pending.
The later private-service fourth image also booted with measured ZFS/cgroups,
completed runtime PKI preparation and returned a workspace-source-v2 guest
image witness. It remains disconnected and execution-unready; image identity
and PKI preparation are not guest or private-service acceptance.
The [ordinary durable fake executor](../../../lilly/test/support/durable_fake_executor.ex)
continues to support the existing generated actor and fake-command properties
without depending on the retired harness. The
[reset review](../reviews/2026-10-13-antithesis-reset.md) records this evidence
boundary. Accepted custody requirements and partial implementation status remain
unchanged.

[ADR-0026](0026-host-maintenance-and-retirement.md) adds maintenance acceptance.
The [executor](../../../lilly/lib/lilly/vm/executor.ex) now defers stop/delete work
on execution/network lock unavailability, preserving the prior durable observation.
Unknown physical cleanup errors continue to block release; lock retries alone do
not create a new outcome.

The [OS lock client](../../../lilly/lib/lilly/host/lock.ex) now requests an orderly
helper exit and waits for its exit status before confirming release. Closing the
BEAM port alone could race a consecutive intent operation while the old native
helper still held its flock. A paused-helper
regression test (`lilly/test/host/locked_command_test.exs`, removed by ADR-0176
decision 4) checked that release cannot finish early; timeout reports uncertainty and never unlinks the
lock inode. Every native command frame carries an explicit response bound of
64 KiB or 4 MiB; the earlier unbounded-header frame was removed under ADR-0159. See the
[native storage review](../reviews/2026-09-16-native-zfs-observations.md).

Under [ADR-0176](0176-host-concurrency-single-writers-and-effects.md) decision 4
the per-lock helpers are replaced by one `lilly-hostd` daemon. Release is
confirmed only after hostd reports the lease's commands killed and reaped and its
descriptor closed, and a holder's death still kills its commands before the lease
frees (the [lock test](../../../lilly/test/host/lock_test.exs)
`holder-death-kills-leased-command`). The decision above is unchanged.

Under [ADR-0031](0031-sparse-zfs-storage-and-capacity.md), native ZFS host
bindings and immutable session descriptors include GUID identity and logical
budget. Per-VM dataset claims/tombstones survive outside the child being removed.
The [owned storage review](../reviews/2026-09-16-owned-zfs-lifecycle.md) records
recovery and physical guest verification separately from runtime wiring.

[ADR-0027](0027-production-release-deployment.md) adds a packaged Lilly runtime
closure and [systemd service](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/scripts/test/fixtures/legacy-deployment/systemd/lilly.service). The daemon
remains outside the guest slice and shares the host mount namespace. The KVM
harness now also hands three running guests to the packaged service and verifies
unchanged VMM PIDs, reservations, console/data access and new-session reports
after graceful service stop and automatic restart following a forced daemon kill.

The [directory cleanup repair](../reviews/2026-09-18-vm-directory-cleanup.md)
connects [nonrecursive empty-directory removal](../../../lilly/lib/lilly/host/empty_directory.ex)
to ordinary dataset deletion and retained-record retries. Cleanup and parent-sync
failures withhold success while keeping ownership records and deletion fences.
Rootless filesystem properties and native lifecycle checks have separate evidence
in that review; this does not change the decision or its partial status.

The [running VM adoption retry review](../reviews/2026-09-24-running-vm-adoption-retry.md)
records production observation flapping and the correction in
[Driver.adopt](../../../lilly/lib/lilly/vm/driver.ex) and
[Executor](../../../lilly/lib/lilly/vm/executor.ex): bounded VM-lock contention and
temporary network-lock unavailability retry without replacing the prior durable
outcome. [Network.refresh_labels](../../../lilly/lib/lilly/network.ex) also uses
the existing bounded native lock retry to absorb observed shared-lock contention
on the production host. [Focused tests](../../../lilly/test/vm/executor_adoption_test.exs)
check the error classification; actor and native guest tests provide distinct
reconciliation evidence. The accepted decision and partial status are unchanged.

The [clone restart recovery review](../reviews/2026-09-26-clone-restart-recovery.md)
records preservation of `storage_busy` before launch, generated actor persistence
histories and native authority checks. Independently owned incoming staging may
also defer a restart, after target validation and without launch or capacity credit.
Its parent identity probe retains native policy/backing checks independently of
usage decomposition; normal readiness and capacity observation remain strict.
It retains the original execution fences
and explicit retry for terminal failures; production recovery is recorded separately.

The [completed launch recovery review](../reviews/2026-10-03-lilly-completed-launch-recovery.md)
records a passing generated actor-death window after controlled executor
completion but before durable outcome recording. Replacement adopts once and
replays the same recovered outcome. This is actual actor/Store/Journal evidence
with a durable fake executor, not native systemd or Firecracker acceptance.

The [native readiness history review](../reviews/2026-10-03-lilly-runtime-readiness.md)
records a new exported source-built fleet scenario for restarted provisioners
under database outage, complete negative private readiness replies, fresh
incarnation recovery and preserved guest process identity. Native execution is
recorded: the 897.72-second machine script includes 248.40 seconds of native
readiness histories. Physical/updater/hosted and independent gate-fault gaps
retain the partial implementation status.

## Open questions

Protected enrollment now has an [operator file workflow](../../../docs/provisioner-enrollment.md)
under [ADR-0025](0025-protected-provisioner-enrollment.md), with tested SSH-derived
key custody under ADR-0032. Complete actual replacement deployment operations,
tombstone retention, independent physical-host acceptance and load validation.
ADR-0026 adds host drains and guarded
retirement. Shared access, remote terminal relay and retained telemetry have
implementation evidence under ADR-0018 through ADR-0023; the
[fleet review](../reviews/2026-09-16-nixos-fleet.md) now records browser/guest
acceptance on two simulated provisioner hosts separately from this actor foundation.

## Related decisions

[ADR-0004](0004-lilly-and-vm-actors.md), [ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md), [ADR-0009](0009-assurance-and-testing.md),
[ADR-0013](0013-capacity-collection-and-local-receipt.md),
[ADR-0015](0015-jailed-execution-and-host-networking.md),
[ADR-0016](0016-executable-generations-and-lifecycle.md),
[ADR-0027](0027-production-release-deployment.md).

The [submission recovery draft](../reviews/2026-10-05-lilly-submission-recovery.md) adds generated native before/after unit-submission histories with whole-daemon loss and authenticated settlement. Refined native execution passed337.69seconds within the1036.30-second machine script, with composed driver static checks passed. This does not upgrade the partial implementation status.
