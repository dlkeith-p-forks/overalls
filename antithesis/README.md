# Overalls Antithesis harness

The default `config/docker-compose.yaml` starts one PostgreSQL 18 primary, a
separate migration process, two source-built Marshall releases, one Lilly
release, an operator enrollment process, and the workload bootstrap. It is the
`control-core` topology described in the research scratchbook. Each SUT process
has a separate fault boundary; PostgreSQL, the two Marshall instances and Lilly
retain independent named volumes. The workload alone emits `setup_complete`.

The PostgreSQL entrypoint creates disposable database, TLS and Marshall signing
secrets at first boot in `synthetic-credentials`. It refuses a retained database
volume if the credential volume is missing. Migration runs through the real
Marshall release before either serving instance becomes healthy. A separate
`oracle-credentials` volume gives the workload only the CA, a SELECT-only
PostgreSQL role password and the nonsecret fixture manifest. Lilly publishes
its durable, root-owned machine identity and a v3 enrollment request. The
operator container invokes Marshall's reviewed enrollment CLI, which writes
the private credential envelope and a nonsecret fixture manifest. Lilly then
loads its v4 config. The hosted health check requires an authenticated Control
connection and terminal stream authority; the workload separately checks a
current committed host report. The native execution readiness bit stays false
because the configured controlled pool reports unavailable capacity. This setup
does not imply schedulable storage or native VM isolation.
On rootless Podman, Lilly uses the host cgroup namespace so the hosted collector
can read the container's actual cgroup subtree, including enabled ancestor
limits. The cgroup filesystem is read-only inside the container; the report
still publishes no schedulable capacity.
Marshall's browser HTTPS listener uses port 443, matching its production
Endpoint origin and the synthetic certificates' hostnames. Its separate fleet
Control listener uses port 5443.

The enrollment container stays running as a narrow Control operator after
enrollment. It copies the initial Lilly envelope to the private
`control-credentials` volume, which the workload can only read. The workload
writes mode-0600 `rotate_lilly` requests to `control-requests/requests`; the
operator validates the enrolled host and fixed request shape, calls Marshall's
actual `rotate` and `verify` CLI actions, then writes a mode-0600 result under
`control-requests/results`. An `issued` result references the private output
file and committed host connection generation; refusal or uncertain outcome
never stands for successful rotation. The operator does not retry an ambiguous
mutation. Request and result directories use separate named volumes, so the
workload can write requests but only read operator results. The credential
revalidation command lives alone in the `control_rotation` test template as a
`singleton_driver_`: Antithesis runs it once on a timeline and does not run
ordinary Control serial drivers before or after it on that timeline. Rotation
is terminal for that timeline because Lilly keeps its startup credential and
can become stale after the commit. The helper checks a fresh Control client
using the issued credential; it does not claim Lilly reconnects or resumes
normal work after rotation. An uncertain rotation result is never retried.

The separate `host_sessions` singleton opens two authenticated Marshall Control
sockets and compares read-only PostgreSQL snapshots before and after an old
session is superseded. Its `lilly.exchange` requests contain no fabricated
capacity, acknowledgements or physical outcomes. The `host_rotation` singleton
rotates authority once and is terminal for the same cached-credential reason.
Both are one-command singleton templates in the selected `control-core`
command roster; each timeline runs at most one singleton.

The private request channel also accepts a fixed `compute.*` namespace for
the three synthetic fixture accounts. `compute.catalog` reports currently
eligible images and measured available capacity. `compute.provision` accepts a
catalog image, UUID request key, profile and bounded shape; exact retries may
reuse their own archived request history. `compute.lifecycle` submits start,
stop or delete intent. `compute.get`, `compute.list` and `compute.operation` are
read-only projections; the operation projection includes its committed physical
outcome when present. `compute.set_access` and `compute.list_access` use the
authorized sharing actions with fixture recipients only. Mutations use
Marshall's Ash actions with a fresh, passkey-verified fixture actor. Success
receipts are published after the action returns. Missing or uncertain results
require reconciliation by the stable request key. The private placement and
execution epoch projection grants no guest execution authority. A submitted
lifecycle request does not prove physical completion; its accepted outcome and
an independent guest witness provide that evidence.

The `control/serial_driver_delivery.py` command uses a loopback WebSocket peer
to inventory actual request frames from the maintained
`OverallsProtocol.Control.Client` across a dropped reply, two reconnects and a
fresh explicit sentinel call. The separate
`control_delivery/singleton_driver_ambiguous_commit.py` command sends a real
authenticated Marshall Control request with a unique Lilly session ID, closes
before reading its reply, and queries that exact session in PostgreSQL; the
following fresh session uses a different ID. This SQL-effect command is
terminal for its timeline because a new session may fence Lilly's live session;
it is selected in `control-core` as the `control_delivery` singleton template.
The `control/serial_driver_version_refusal.py` command runs the same shared
client against the loopback peer's `version_refusal` mode: a welcomed 4001
close with one held call must keep the `unsupported_version` class, retire the
call as unproven and open no new transport for a bounded 5,000 ms window. It
does not observe Marshall emitting 4001 or a service adapter stopping.
The peer can establish transport non-redelivery; the SQL receipt can show that
reply loss concealed a committed effect. Neither witness implies native
execution. Missing peer output, failed SQL reads and uncertain writes remain
unexercised rather than passing evidence.

The hint-loss property remains unexercised and has no selected test command.
A harness-built Marshall release declares and emits only a BEAM `Reachable`
anchor, `Marshall notifier recovered after losing a host command hint`, when
its hint relay observes the Oban notifier leave `:isolated`. That anchor marks
the window in which hints may have been dropped; it does not observe a lost
hint, a committed command, a reader re-read or Lilly progress, and it does not
satisfy either hint-loss catalog primary. It cannot fire under hosted faults:
Oban's Sonar reports `:isolated` only after 120 s with no notifier ping at all
(a fixed dependency default, not configuration), while hosted timelines end
after roughly three minutes; run `eb926cce7fee3dfcad1d6d8172b28d29-65-0`
recorded no isolation in any timeline.
The default graph has no targeted notifier isolation or reviewed action that
commits a uniquely identified host command while PostgreSQL and Lilly's reader
remain healthy. A session receipt and a generic socket disconnect do not
satisfy that property's precondition. The scenario needs an operator-controlled
commit and lost-hint barrier, followed by the real reader's full-read ledger
and exact terminal command receipt before it can emit its catalog `Sometimes`
assertion.

Images are built from the pinned Nix release closures and the root Dockerfile.
Build the `antithesis-{pg,marshall,lilly,workload}-context` exports and stage
them with `antithesis/build/prepare-contexts.sh pg marshall lilly workload`
before running Compose. The Compose build context is the repository root.
The local CLI and engine paths are recorded in
`.devenv/antithesis-environment.json`; set its `DOCKER_HOST` and
`SNOUTY_CONTAINER_ENGINE=podman` for local checks. Stage the chosen command
selection before building the workload image (staging also writes the image's
selection-scoped Python assertion catalog), then materialize that selection
with `antithesis/verification/selection.py materialize --engine podman`. Freeze
its image and config identity as described in
[the campaign guide](verification/README.md). Validate the resulting standalone
config directory for the selected profile:

```sh
docker-compose -f antithesis/config/docker-compose.yaml config --quiet
snouty validate antithesis/runtime/configs/control-core
```

For an optional profile, render and build the ordered source Compose files in
its selection, materialize with that same selection, and point Snouty at
`antithesis/runtime/configs/<profile>`. The source `antithesis/config` directory
and its override files are build inputs, not the frozen hosted config.

Only a full local `compose build` and `compose up` with PostgreSQL migration,
both HTTPS readiness probes, actual enrollment, Lilly Control readiness and
workload bootstrap passing can establish a runnable baseline. Preserve the
volumes across restarts to test retained state. A fresh independent baseline
requires a fresh Compose project and new volumes.

Optional satellite, guest-emulator and storage-router scenarios must be selected
by focused override files when their source-built images, adapters, fixtures and
oracles are implemented. The default graph makes no claims for those paths.

The `backup-restic` profile adds `config/compose.backup.yaml` to the base graph
and selects the five `backup` commands. The workload image already carries the
production backup operator and pinned Restic; the overlay mounts a dedicated
private named volume where each command creates a disposable encrypted Restic
file repository. Bootstrap requires the operator, Restic, a private root and a
real probe repository that initializes and enumerates empty before setup. A
file backend keeps raw Restic reads free of network uncertainty, because the
operator returns one failure status for an unavailable repository and for a
validator refusal. No ZFS host capture, S3 bucket or recovery target is used.

The `satellite-standin` profile renders the base graph with
`config/compose.origin.yaml`, `config/compose.satellites.yaml` and
`config/compose.satellite-standin.yaml`. The last overlay adds a labelled
**guest stand-in**: a process from the workload image that shares only
`lilly-a`'s network namespace and speaks the guest-side protocol to private
Audi at `169.254.254.1` with the private root and an internal-service SNI. It is
not a guest and has no VM, boot, tap, placement or execution authority; Lilly
binds no VM to its address, so private Audi must refuse it. It mounts only the
public private-Audi root and a fixed request/result channel. Bootstrap requires
the origin fixture's authenticated state, the private root and the stand-in's
verified-TLS receipt. The `satellite` template's unbound-source command checks
that a forged guest-side request produces no origin receipt. The Ziggy, Galileo
and editor login-code commands need a current running VM; the controlled Lilly
pool reports unavailable capacity and no editor gateway, release or wildcard is
configured, so those commands record unexercised in this graph. Because
Ziggy and Galileo credentials need an enabled host and Marshall enables only a
host with a fresh execution-ready report, `entrypoints/satellite-enroll.sh`
applies a labelled **STUB**: it sets only `lilly-a`'s administrative `enabled`
flag through the Host `:configure` action. It fabricates no readiness,
capacity, pool credit or VM binding, so admission still refuses the host.

The `guest-lifecycle` profile
([selection](verification/selections/guest-lifecycle.json)) selects the one
`guest_lifecycle` command with `config/compose.guest-vmm.yaml` and
`config/compose.guest-lifecycle.yaml`. Build and stage the `pg`, `marshall`,
`lilly-guest`, `guest-vmm` and `workload` contexts for it. Hosted Antithesis has
no KVM, so the guest runs under QEMU TCG. The container `lilly-guest` release
uses **STUB storage**: a fixed synthetic pool with no ZFS, plus compute
headroom for one free guest-vmm slot. It exists only so Marshall can admit one
emulated guest and is not native ZFS, KVM, Firecracker or capacity evidence. The
bootstrap completes setup only after it observes the guest-vmm image identity
through the enrollment witness bridge and a Marshall catalog offering that
image with known capacity. See the
[guest lifecycle scope](workload/guest_lifecycle/README.md).

`config/compose.origin.yaml` and `config/compose.smtp.yaml` are optional fixture
overrides for local upstream and SMTP scenarios. They add separate containers,
private persistent state, generated runtime CA material, and read-only oracle
material for the workload. The origin also publishes three private integration
fixture values to an `origin-shared` volume mounted read-only in enrollment;
the values do not appear in Compose environment values. Their admin health
checks show only that the fixture server is accepting requests.
`config/compose.guest-vmm.yaml` selects the
source-built STUB-storage guest Lilly variant and a separate QEMU TCG server
with a private Unix control socket and retained emulator state. A distinct,
sanitized witness socket is mounted read-only only in enrollment for the closed
operator bridge; neither the mutating control socket nor raw guest boot state
reaches workload. Lilly publishes its baked guest image manifest to a
`guest-catalog` share mounted read-only in enrollment, which registers it
through `Marshall.Compute.Images.register`. Its health check confirms the
server's inventory interface, not a booted or ready guest. `config/compose.enrico.yaml` adds the source-built Enrico release
and origin fixture, private Git state and restart request/result volumes, and a
passive inode observer. The observer publishes all eight native Git admission
lock identities and bounded repository lock holders; incomplete or stale
snapshots cannot prove that no descendant remains. A successful restart result
requires distinct release PIDs and a higher durable launch generation.
`config/compose.host-vmm.yaml` adds a retained TCG NixOS host running Lilly and
ZFS on a fixed virtual data member. Enrollment receives only its private
credential share, while workload receives only a sanitized physical observation
share. A separate private fault-control share links only the host and enrollment
operator for bounded guest crash requests. The host health check requires the
inner host's current authenticated Control readiness. It is measured emulation
evidence, not native KVM evidence.
`config/compose.admission-stub.yaml` is the `admission-stub` profile. It
selects a harness **stub** storage substrate on the controlled Lilly release:
`entrypoints/lilly.sh` writes a fixed private substrate file and a tiny
non-bootable image, the harness collector reports configured stub pool totals
for the enrolled pool identity, measured cgroup memory headroom and a labelled
STUB CPU budget capped by the measured cores (the hosted VM has one logical
CPU, so a measured whole idle core never appears), and
Lilly digest-verifies the stub image before advertising it. The enrollment
operator registers that image through Marshall's reviewed catalog action. A
fully stub-backed report advertises placement readiness, so Marshall's real
admission transaction can place the atomic-allocation and key-replay
commands; the controlled executor still never launches a guest. The workload
probe requires the committed execution-ready report, measured compute, a fresh
stub pool row and an enabled advertised image in SQL before setup. This is
admission-logic evidence only: not ZFS, physical capacity, KVM or isolation.
The measured-capacity command is a separate unselected `admission_physical`
template that needs the host-vmm overlay.
`config/compose.recorder-host.yaml` adds an independent TCG NixOS recorder
host for exact service UID and cgroup authority, retained recorder state, and
bounded archive filesystem tests. Workload can submit private fixed requests
and read sanitized results and observation files; it cannot mount VM state.
The `recorder-host` selection profile selects this overlay with the three
`test/v1/recorder` commands. Its VM health check requires a fresh all-active
unit sample, both service identities, the distinct bounded archive device and
readable checkpoint and SQLite state. The workload's separate recorder probe
re-reads those witnesses through its read-only observation share, requires
every pending checkpoint admission to name the current producer PID and start
ticks, and checks its writable request and ledger volumes before the single
setup signal. No local or hosted run of this profile is recorded yet; its
evidence is TCG emulation, not native KVM. The current `control-core`
bootstrap does not check the other extra fixtures or their effects, so those
overrides are not selected for a run until matching workloads and setup probes
require that evidence. Render an override with `docker-compose -f
antithesis/config/docker-compose.yaml -f antithesis/config/compose.origin.yaml
config --quiet` (substitute the selected override as needed).
