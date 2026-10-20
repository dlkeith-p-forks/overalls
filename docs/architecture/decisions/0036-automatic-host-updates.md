# ADR-0036: Automatic host updates with verified recovery

- ID: ADR-0036
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: NixOS deployment, Marshall migrations, Lilly readiness, SecretSpec custody
- Supersedes: ADR-0030
- Superseded by: ADR-0038

## Context

[ADR-0038](0038-http01-validation-and-peer-routing.md) replaces the inherited
Route 53-only validation choice and carries forward every other decision below.
This record retains its historical rationale and implementation evidence.

The user requested Loom-style Git polling and automatic NixOS switching, then
explicitly selected automatic database migrations, compatible upgrades, a reusable
opt-in module, ten-second polling, and independent hosts. The approved plan adds
health verification, private secret compatibility checks, a shared secret
implementation, phase-aware retries and real Lilly upgrade tests. There is no
canary promotion or fleet coordinator in this version.

## Decision

Replace ADR-0030's operator-only migration requirement with an explicit automatic
pre-switch migration phase. Carry forward all its remaining source-build,
runtime, TLS, connection-budget, secret custody, independent role, storage and
installation requirements. Serving application startup still never migrates.

Each enabled host fetches its configured branch, selects one immutable commit,
builds with committed locks, stages and validates candidate secrets, applies
candidate Marshall migrations, switches the exact built system, and verifies
health before recording success. The default poll interval is ten seconds with
up to two seconds of jitter. Updates are host-local; simultaneous fleet updates
and colocated Marshall restarts are possible. There is no fleet HA guarantee.

Every Marshall host may run the candidate migrator under Ecto's PostgreSQL advisory locking
with two connections. Reserve two connections per declared replica beyond the
serving pools and existing ten operator connections. Run migration without serving
the application, unprivileged, using candidate staged credentials and verified
database TLS. Migrations must remain compatible with running older releases.
Successful migrations are not undone after activation or health failure.
All maintained migration entrypoints share that advisory lock. Unlike Ecto's
default table-lock transaction, it survives a migration worker running longer
than the serving sessions' fifteen-second idle-transaction deadline. Keep the
existing lost-client connection deadlines and bound the migrator's lifetime.

Reuse ADR-0032's resolver and persistent SSH identity. Resolution, staging and
publication share one implementation. Stage secrets privately without affecting
running consumers; bind staging to complete candidate descriptors. Reject changes
to deployed database credentials or shared token/cookie signing secrets. Permit
Cloak additions only while retaining prior tags/bytes and the active encryption
key. Promotion/removal requires coordinated maintenance. Compare privately and
never log values. Initial installation can establish the baseline; an existing
running role without a usable baseline cannot approve itself for unattended
replacement.

During activation stop affected consumers, publish complete bundles atomically,
and restart consumers after successful prerequisites, including secret-only
changes. Publication remains per bundle; neither the system nor the database and
secrets form one atomic transaction. Git credentials must already be usable from
the current configuration before fetching.

Marshall success requires TLS-verified readiness of each local instance. Lilly
exposes only bounded public readiness over a private local Unix socket, without
Erlang distribution. Its readiness requires authenticated control, a delivered
report sampled within fifteen seconds, console readiness, and a completed initial
observation for each current durable VM generation. A local sample, systemd process
status or a pre-restart journal alone is insufficient. Expected stopped/failed
VM outcomes are valid observations. Require two successful checks five seconds
apart within the configurable default 120-second verification window.

Retain enrolled Lilly identity, state paths, pool bindings, journals, guest units
and networking. Preflight must never acquire competing ownership or establish a
new control session. A daemon update does not replace existing Firecracker
processes or guest kernels. Delivering a newly issued host credential is allowed;
issuing authority, enrollment, identity replacement, and reboot maintenance remain
separate workflows.

Persist sanitized phase/candidate/active/last-healthy/failure state. Back off a
failing revision from thirty seconds to fifteen minutes while continuing branch
polling; a new revision bypasses that delay. Revalidate lost runtime staging and
retry idempotent migrations after uncertainty. An already activated candidate
awaiting health is verified without repeatedly restarting healthy services.
Never automatically roll back schema, reboot, collect generations or declare a
failed deployment successful.

## Alternatives

Polling and switching without readiness cannot distinguish a connected Lilly from
a fenced daemon. Per-host timers do not implement safe fleet sequencing; the user
selected independent updates instead of canary promotion or a rollout coordinator.
Reimplementing secret parsing in the updater risks different candidate/live values;
systemd remains the parser for EnvironmentFile and the existing resolver remains
the custody boundary. Automatically reverting code after migration cannot undo
database changes and was not selected.

## Consequences

Release authors must supply compatible schemas and protocols and use coordinated
maintenance for incompatible authority changes. A failed activation can be partial;
the status must preserve the distinction between active and healthy. The updater
is a privileged executor of the configured trusted repository. Its credentials,
checkout, state and staging need protected ownership. Initial machine identity,
enrollment and deployment inputs remain explicit prerequisites.

## Invariants and verification

- Evaluate independent roles, configuration rejection, connection headroom,
  private paths and updater survival through its own system switch.
- Verify exact candidate activation, failures in every phase, retries, corrective
  commits, concurrent attempts and concurrent real migrations in NixOS machines.
- Exercise real SecretSpec/SOPS, incompatible-secret rejection, candidate/live
  consistency, publication interruption, consumer ordering and leakage checks.
- Upgrade distinct Lilly releases with live guests and verify physical process
  identity, storage, networking, fresh reports and terminal recovery, including
  replacement credential delivery.
- Run component precommit and all exported Nix checks. Unit tests cannot establish
  guest survival or independent physical failure-domain acceptance.

## Implementation evidence

The [compatibility history check](../../../nix/verification/tests/evaluation/auto-update-compatibility.nix)
exports the existing fixed assertions together with generated operator key and
shared-authority histories. It executes actual `compatible` and `preflight`,
covering every serving baseline, the inactive-file fallback, staged candidate
selection, the sixteen-key bound and explicit corrected retry. Environment and
serving-process discovery are isolated fixture seams; this evidence does not
establish native migration or activation. The
[2026-09-26 review](../reviews/2026-09-26-updater-compatibility-histories.md)
records execution and preserves the original native evidence below. Policy and
decision/implementation statuses are unchanged.

The [custody history check](../../../nix/verification/tests/evaluation/auto-update-custody.nix)
executes the production run/stage/preflight/migrate/activate/verify state
machine over generated rotation and custody histories inside a disposable uid-0
namespace, with real SecretSpec/SOPS descriptors, resolution and descriptor-bound
staged handoff. It pins the capped deterministic backoff
(`operation_failed`/`stage` on custody voidance, `coordinated_secret_change` at
preflight on authority change), the verify-only recovery after a documented
manual switch (no re-stage, migration rerun or switch), stale staggered-fetch
behavior inside the retry window and post-fix convergence. systemd/Git/Nix
effects are world-model seams; no native systemd, migration or guest-survival
acceptance is established. The
[2026-09-26 review](../reviews/2026-09-26-custody-updater.md) records execution.

The [updater](../../../nix/domains/system/auto-update/runtime.py) verifies the
sticky, writable `/dev/shm` tmpfs before stopping consumers. A new Git revision
whose built system and deployment manifest exactly match the active system
advances healthy history only after live role verification, without rerunning
migrations or activation. [Focused tests](../../../nix/verification/tests/machines/auto-update/unit.py)
cover shared-memory refusal before a consumer stop; the
[updater machine](../../../nix/verification/tests/machines/auto-update/driver.py) verifies
the identical-system path keeps a live service process. The
[recovery review](../reviews/2026-09-23-auto-update-identical-system.md)
records the scope and remaining production acceptance.

The [updater](../../../nix/domains/system/auto-update/runtime.py) now quiesces
declared socket activators before stopping their consumer services and attempts
to restore previously running roles after a failed activation. The
[Overalls declaration](../../../fleet/roles/control-plane/configuration.nix) includes
its socket-activated fleet relay, and the
[updater machine](../../../nix/verification/tests/machines/auto-update/default.nix) drives a
continuous client through a candidate switch and failure recovery. This closes
the socket reactivation race observed during the 2026-09-23 Overalls rollout;
production activation is tracked in the Enrico
[review](../reviews/2026-09-23-enrico-git-mirrors.md).

Audi gateway and DNS roles now participate in candidate consumers and required
unit health. Each enabled role must also return an exact affirmative versioned,
role-bound response from its private status socket. The
[socket tests](../../../nix/verification/tests/machines/auto-update/unit.py) cover wrong roles,
negative/malformed/oversized replies and conjunction across enabled roles.
Audi's packaged DNS test verifies live authority, outage rejection and restart
recovery. The [Audi fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi.py)
also passed real gateway and DNS package updates, unhealthy-candidate rejection,
preserved healthy history and corrective-revision recovery without replacing the
guest process. This verifies corrective updates, not automatic code or schema
rollback; see the bounded run evidence in
[ADR-0047](0047-audi-ingress-and-authoritative-dns.md).

Porsche now participates in required service health, secret-consumer ordering and
encrypted diagnostic preflight. The [updater](../../../nix/domains/system/auto-update/runtime.py)
requires its bounded private socket response to report version 1 and `ready: true`.
[Socket integration tests](../../../nix/verification/tests/machines/auto-update/unit.py) exercise
the normal updater health path with affirmative, negative, malformed and oversized
responses. Deployed Porsche-to-Marshall update acceptance remains separate.


- [Updater module](../../../nix/domains/system/auto-update/default.nix) and
  [runtime](../../../nix/domains/system/auto-update/runtime.py) implement the candidate
  workflow, including durable retries and exact candidate activation.
- [Shared secret helper](../../../nix/domains/system/secrets/prepare.py) separates
  resolution from publication and supports descriptor-bound private staging.
- [Lilly runtime](../../../lilly/lib/lilly/control/runtime.ex) and
  [local status server](../../../lilly/lib/lilly/control/status_server.ex) provide
  delivery/reconciliation readiness and a bounded private transport.

- The [updater machine check](../../../nix/verification/tests/machines/auto-update/default.nix)
  passes real Git selection and NixOS switches, phase failures, corrective commits,
  concurrency exclusion, health-only retry and identity cleanup. It now also passes
  out-of-band live-system drift reconvergence: after the running closure is switched
  outside the updater, the next attempt detects the drift once, activates the
  candidate again and records one healthy event, and the following poll is the no-op
  fast path with unchanged durable status. Unit coverage pins `migrate()` issuing one
  collected fixed migration unit per attempt, re-runnable for the same candidate.
- The [fleet check](../../../nix/verification/tests/machines/fleet/default.nix) update scenario now
  additionally passes a failed candidate activation on a Lilly host with three live
  guests: every guest VMM process identity is preserved, stopped consumer roles are
  restored, `lastHealthy` keeps the serving revision, the durable record reports the
  drifted active system, a corrective revision bypasses backoff and reconverges, and
  host credential rotation's superseded credential is refused with 401 inside its
  nominal TTL. Executions and timings are recorded in the
  [update failure matrix review](../reviews/2026-09-26-update-failure-matrix.md).
- The [credential-rotation check](../../../nix/verification/tests/machines/credential-rotation/default.nix)
  passes three concurrent candidate migrators under observed advisory locking,
  a migration longer than the serving idle-transaction deadline, staged-source
  consistency, failed migration isolation, incompatible-authority rejection,
  compatible key addition and journal leakage checks.
- The [fleet check](../../../nix/verification/tests/machines/fleet/default.nix) passes distinct
  Lilly release adoption and encrypted replacement-credential delivery while
  retaining six guest processes, disk writes, networking and authenticated browser
  terminal recovery. Subsequent database, daemon, storage and revocation scenarios
  also pass under nested KVM.
- The [implementation review](../reviews/2026-09-16-automatic-host-updates.md)
  records component gates, exported checks, fixture corrections and the isolated
  verification boundary excluding concurrent placement/protocol development.

The automatic-update capability is implemented. This ADR remains `partial`
because it carries forward ADR-0030's separate reference-host adapter, physical
failure-domain and production acceptance obligations. Nested fixtures do not
establish those properties or 100-instance throughput. Actual host configuration
and production activation are not part of this implementation.

The [native readiness history review](../reviews/2026-10-03-lilly-runtime-readiness.md)
records a new exported source-built fleet scenario for restarted provisioners
under database outage, complete negative private readiness replies, fresh
incarnation recovery and preserved guest process identity. Native execution is
recorded: the 897.72-second machine script includes 248.40 seconds of native
readiness histories. Physical/updater/hosted and independent gate-fault gaps
retain the partial implementation status.

*Correction (2026-10-07).* Two updater defects found in production on overalls
are corrected without changing the decision:

- The identical-system path verified a new revision without staging its
  secrets, so a secret-only change was never applied and an unresolvable
  candidate bundle passed, contrary to the activation rule above. The
  [updater](../../../nix/domains/system/auto-update/runtime.py) now stages every
  candidate bundle first; byte-identical bundles keep the verify-only path,
  any difference takes preflight, migration and activation, and a failed
  resolution fails at `stage`. Staged copies on the verify-only path are
  removed at once.
- Activation stopped every secret-preparation unit one at a time under one
  180-second deadline. On overalls those stops took about three minutes, so
  activation failed before switching and restored the previous system after
  six to nine minutes without its roles (2026-10-06, three attempts). Once
  every consumer is down, the independent secret-preparation units now stop in
  one transaction with a 300-second deadline; consumers keep their reviewed
  one-at-a-time dependent stops.
- `switch-to-configuration` can exit 4 for failures outside the candidate,
  such as reloading a logged-in operator's user manager, after the candidate
  system is already active (overalls, 2026-10-07). When the candidate is
  active and the switch left no newly failed system unit, the updater records
  `update.switch_incomplete` and continues to restore roles; a newly failed
  unit still fails activation, and the bounded health checks decide success.
- [Focused tests](../../../nix/verification/tests/machines/auto-update/unit.py) cover the
  switch-exit handling, the single-transaction stop, a unit that stays active, per-phase deadlines and the
  staged/live bundle comparison.
- **Update (2026-10-13, [ADR-0165](0165-restart-only-changed-units.md)):**
  activation stops only the units whose store identity, drop-ins or secret
  bundle changed and consumers the candidate dropped; unchanged consumers,
  sockets and secret preparation units stay up, after eight Marshall-only
  pushes restarted Lilly eight times in one day.

## Open questions

None for the authorized implementation. Actual host configuration and production
activation remain separate deployment work.

## Related decisions

- [ADR-0030](0030-nixos-deployment-and-tls.md), whose remaining decisions are retained.
- [ADR-0032](0032-ssh-derived-age-identities.md), secret custody and coordinated rotation.
- [ADR-0033](0033-nixos-machine-verification.md), real machine evidence.
- [ADR-0035](0035-zfs-only-provisioning.md), the earlier development schema break.
- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md), guest lifetime and physical ownership.
