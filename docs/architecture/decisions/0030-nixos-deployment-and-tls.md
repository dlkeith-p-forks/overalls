# ADR-0030: NixOS deployment and TLS

- ID: ADR-0030
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: NixOS hosts, Marshall runtime, Lilly services, HAProxy, deployment tooling
- Supersedes: ADR-0027
- Superseded by: ADR-0036

## Context

[ADR-0036](0036-automatic-host-updates.md) replaces the operator-only migration
requirement with an opt-in automatic pre-switch workflow and carries forward
the remaining decisions. The rationale and evidence below are historical.

[ADR-0126](0126-bounded-database-client-recovery.md), through the later inherited
decision chain, replaces only the 30-second TCP limit with 15 seconds and adds
one-second active disconnect polling. The original settings and rationale below
remain historical; the captured convoy failures and combined correction are
recorded in its verification review.

The user selected reusable NixOS machine specifications that run Marshall, Lilly,
or both; source-built packages; installer and QEMU images; and preservation of
the disko/nixos-anywhere workflow. The reference host has mirrored NVMe ZFS root
storage and two EFI partitions. PostgreSQL will be supplied as an external
AWS-managed service; provisioning AWS infrastructure is outside this change.

The existing release workflow builds with Mix before wrapping the result in a
Nix closure. Its HAProxy example passes TLS through to Marshall. The user instead
selected public TLS termination at HAProxy, verified TLS to Marshall, and ACME
issuance through Route 53 DNS validation. These materially replace ADR-0027.
The instruction to implement the ADR plan authorizes recording these choices;
it does not establish that the new deployment exists.

## Decision

Provide a root flake with pinned inputs and implementation under `nix/`. Export
Marshall/Lilly packages, reusable NixOS modules, reference machine configurations,
installer ISO and QEMU image outputs, and checks. Build releases, assets and
native dependencies from source inside Nix builds; do not consume a developer's
existing `_build` directory. Share the pinned Elixir/OTP toolchain with development
and retain debug information for Dialyzer. Production releases remain independent
and use the shared protocol library, not each other's application runtime.

Expose independent `services.marshall.enable` and `services.lilly.enable`
options, with neither implicitly enabling the other. Include HAProxy integration
and options for instance identities/counts, addresses, database/connection budgets,
credential paths, TLS trust, host networking, storage and resource budgets.
Reject incompatible or incomplete enabled-service configurations. Secrets are
resolved at runtime under [ADR-0032](0032-ssh-derived-age-identities.md).

The reference host runs Lilly, three Marshall instances and HAProxy. Preserve its
existing mirrored pool, dual EFI boot, network configuration and persistent SSH
identity; do not repartition an existing host during service activation. Export
the declarative disko installation separately. Reference budgets are configurable:
24 logical guest CPUs, 96 GiB guest memory, 4 CPUs/8 GiB collectively for Marshall,
8 GiB maximum ZFS ARC, and a 1 TiB Lilly storage budget. These are resource limits,
not throughput guarantees or dedicated physical failure domains. Storage follows
[ADR-0031](0031-sparse-zfs-storage-and-capacity.md); unvalidated tuning follows
[ADR-0034](0034-mixed-workload-storage-tuning.md).

HAProxy terminates public HTTPS and establishes a separate TLS connection to
each Marshall backend. Verify backend certificate chains and hostname, including
readiness checks; route only to backends returning 200 from `/health/ready`.
Preserve the public hostname and WebSocket upgrades. Restrict backend listeners
to the configured proxy/private network. Do not add a PROXY protocol header or
trust client-supplied forwarding headers as authority. Marshall still serves
HTTPS; TLS bridging does not require bypassing its force-SSL boundary.

Use automatic ACME certificates with Route 53 DNS validation. Deliver DNS
credentials privately and limit their authority to the required challenge zone.
Renewal validates and publishes the certificate before reloading HAProxy; a failed
renewal must not replace a working certificate with an invalid one. Public DNS
names, ACME contact, hosted zone/access configuration, backend certificates/trust
and AWS database endpoint/credentials are required deployment inputs. Database
provider setup and real-provider acceptance remain separate operational work.

All other decisions in [ADR-0027](0027-production-release-deployment.md) continue
to apply, including:

- Production declares 3–100 distinct Marshall instances and budgets each Repo
  pool plus one Oban notifier connection, with ten operator/migration connections.
- PostgreSQL remains the shared durable authority; verify its TLS and hostname,
  reject URL verification overrides, and connect only to a writable primary.
  Preserve only the existing explicit loopback development exception.
- Production Repo sessions set `idle_in_transaction_session_timeout=15s` on the
  server so a lost client machine cannot retain an idle transaction's locks
  indefinitely. This matches the ordinary client query deadline but survives
  client loss. It does not cap active statements or establish whether an
  uncertain commit succeeded; durable idempotency still governs retries.
- Repo and inherited notifier TCP parameters request idle keepalives after
  15 seconds, retries every 5 seconds, three missed probes and a 30-second
  unacknowledged-data limit. A lost machine's idle connections must be reclaimed
  so repeated restarts do not consume the fleet's connection budget. Healthy
  idle sessions remain usable; this is not an idle-session expiration policy.
- Readiness requires the expected migrated database; migrations remain an
  explicit, serialized operator step, never serving-node startup behavior.
- Marshall runs unprivileged. Lilly is the trusted root agent and retains the
  host mount visibility needed by independently supervised VMs in `lilly.slice`.
  Restarting the daemon must preserve guests, disks, state and physical identity.
- Keep private configuration outside release artifacts, validate the runtime
  closure, and apply existing rollout, enrollment and maintenance fences.

Deliver artifacts and rollout instructions before live activation. A colocated
reference machine and three processes do not establish production HA.

## Alternatives

Keep the existing Linux/systemd templates as the historical supported deployment;
they do not supply reproducible host installation or source builds inside Nix.
TLS passthrough preserves the earlier boundary but does not implement the selected
proxy certificate management. Plaintext backends would weaken the selected TLS
boundary. Managing PostgreSQL locally or provisioning AWS was not selected.

## Consequences

Nix builds must account for all native dependencies and frontend assets without
runtime secrets or network-dependent build steps. TLS custody moves to HAProxy
as well as Marshall. Host configuration must coordinate firewall ownership,
resource limits and guest supervision without weakening Lilly confinement.
Deployment inputs and compatible migration order must be supplied before rollout.

## Invariants and verification

- Evaluate all service combinations and reject invalid port/resource budgets.
- Boot actual modules/packages, the installer, the installed UEFI image and
  each surviving mirrored boot disk under [ADR-0033](0033-nixos-machine-verification.md).
- Verify three-machine shared state, node loss, database loss/recovery and
  rejected invalid backend/database TLS; test WebSockets through HAProxy.
- Exercise local ACME/DNS fixtures, renewal and reload without production keys.
- Confirm no automatic migrations, no privileged Marshall, and no loss of
  running guests when Lilly restarts. Retain existing compiler/Dialyzer gates.

## Implementation evidence

The [Nix layout guide](../../../nix/README.md) describes package, module and
machine ownership. The [refactor review](../reviews/2026-09-16-nix-layout-and-test-refactor.md)
records preserved public exports and regression checks after internal paths moved.

The [root flake](../../../flake.nix) and
[source packages](../../../nix/domains/artifacts/default.nix) build independent releases
with the pinned Elixir/OTP runtime, hash-verified Mix/Cargo dependencies, a
source-built Cedar NIF and prefetched frontend tools. Both
[release checks](../../../nix/verification/tests/release/default.nix) pass, including exact runtime
agreement, actual Cedar execution, asset manifests and consumer independence.
The [release script](../../../scripts/package_release.sh) now checks these
packages and exports their complete closures; both exports were exercised.

The [Marshall](../../../nix/domains/system/marshall.nix) and
[Lilly](../../../nix/domains/system/lilly.nix) modules expose independent roles, private
runtime paths, resource limits, TLS/connection budgets and startup dependencies.
[Configuration checks](../../../nix/verification/tests/evaluation/module-configuration.nix) exercise role
combinations and rejection cases. The
[role machine suite](../../../nix/verification/tests/machines/service-roles/default.nix) passes on four QEMU nodes with
hardware acceleration forced, including startup, explicit migrations, verified
TLS, privileges and role independence. The expanded combined role passes with
three colocated Marshall instances, Lilly and HAProxy, checking effective resource
limits and independent restarts; the [completion audit](../reviews/2026-09-16-plan-completion-audit.md)
records the 104.32-second run. ADR-0033 now records passing fleet,
storage, secret/credential rotation and installation/image suites. The exact
existing reference-host adapter and external boot test remain outstanding. See
the [implementation review](../reviews/2026-09-16-nixos-releases-and-roles.md) for
the earlier checkpoint and the [fleet review](../reviews/2026-09-16-nixos-fleet.md)
for the final application revisions.

The service launchers now use 32-byte random hexadecimal cookies to avoid
Erlang interpreting a leading base64 `+` as an option and printing it in an
error. The [fleet review](../reviews/2026-09-16-nixos-fleet.md) records the observed
defect, role regression and separate-machine fleet verification status.

The fleet's whole-machine loss case also exposed database wait timeouts after a
client vanished. [Runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex)
now supplies the server-side idle-transaction limit above. The
[fixture operator](../../../nix/verification/tests/machines/fleet/operator.exs) and
[fleet driver](../../../nix/verification/tests/machines/fleet/driver.py) deliberately hold a real VM row lock
using those connection parameters before stopping its machine, then require the
orphan backend to disappear within 20 seconds before continuing browser recovery.
The retained-machine check demonstrated an old-release lock surviving for more
than 85 seconds and corrected-release backend termination after 14.97 seconds,
followed by successful row-lock acquisition. The complete current-source fleet
passed this deadline, browser recovery and all later capacity/lifecycle cases in
1108.23 seconds. The review preserves prior failures separately. No fixture-specific database timeout
replaces the production setting.
Repeated retained-machine crashes then demonstrated old idle connections
accumulating until normal database slots were exhausted. The runtime now also
requests the TCP bounds above. The fleet records all database backend PIDs from
the doomed node and requires their disappearance within 35 seconds of loss,
including its idle pool and notifier. All 14 recorded backends met that deadline
in the immutable run's completed browser case.

The [September 25 terminal verification](../reviews/2026-09-25-terminal-workspace-verification.md)
found a later schedule where dead clients queued on a held row lock survived that
35-second bound. Their idle-transaction timers started successively after the
preceding lock was released. A diagnostic repeat reclaimed idle connections in
30.848 seconds but did not reproduce the queued-statement schedule; terminal
reattachment then failed a separate live-status assertion. The new
[two-machine recovery fixture](../../../nix/verification/tests/machines/database-recovery/driver.py)
requires three actual blocked release-Repo connections before machine loss.
The original settings and polling-only candidate failed; combined one-second
polling and a 15-second TCP limit reclaimed all ten backends in 27.719 seconds.
[ADR-0126](0126-bounded-database-client-recovery.md) adopts that narrowly scoped
replacement. Complete integrated NixOS and Ubuntu terminal journeys then passed,
including machine-loss recovery and revocation. The 35-second acceptance assertion
and five-second host freshness remain unchanged; the historical decision above
retains its original rationale and settings.

Lilly's pool options now accept native ZFS GUID identity and a separate logical
budget under ADR-0031. They require a correctly mounted existing parent and use
the host's kernel-matched ZFS userspace. Activation does not create/import pools
or modify dataset properties. The [storage lifecycle review](../reviews/2026-09-16-owned-zfs-lifecycle.md)
records module rejection cases, role regression and native storage checks.
The [mirrored storage module](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/domains/system/mirrored-zfs.nix) now declares
two explicit disks, ZFS root/Lilly datasets and independent removable-path EFI
loaders using locked disko. It retains LZ4, no reservations, the reference ARC
cap and a separate dataset quota. Formatting remains an explicit build artifact;
normal activation never invokes it. The
[bootstrap target](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/machines/bootstrap.nix) is a generic QEMU target,
not an adapter for the existing physical host. Its
[installer](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/machines/installer.nix) contains the complete target
closure and requires an explicit destructive flag before installing on its
declared disks. The flake exports QCOW2 disk and ISO artifacts.
The module's `system.build.overallsMirroredImages` wraps the locked disko image
build with an in-VM clean root-pool export before shutdown; normal host boot
still refuses forced import. The exact exported-image check exercises this
separate build path without test instrumentation.
[Storage configuration checks](../../../nix/verification/tests/evaluation/storage-configuration.nix)
and the [firmware installation suite](../../../nix/verification/tests/machines/mirrored-installation/default.nix)
validate these definitions and boot behavior; actual results are recorded in the
[installation review](../reviews/2026-09-16-mirrored-installation.md).
The existing reference host's hardware/network adapter and its earlier external
mirrored-boot test still need to be reconciled with the supplied configuration.

The [HAProxy module](../../../nix/domains/system/proxy.nix) terminates TLS and verifies
backend trust, SNI and hostname for requests and readiness checks. The role suite
passed backend loss/recovery and wrong-hostname rejection against real Marshall.
It also verifies URL exclusion from structured request logs and isolation of
Lilly's managed uplink from host network managers.

The [secret module](../../../nix/domains/system/secrets/default.nix) supplies the initial
SSH-derived SecretSpec/SOPS integration described in ADR-0032. The reference
host adapter remains outstanding. Generic bootstrap images generate new private
SSH identities at boot and contain the pinned public administration key. The
[ACME module](../../../nix/domains/system/acme/default.nix) uses privately selected Route 53
credentials, real DNS validation and a scoped IAM policy artifact. The
[certificate publisher](../../../nix/domains/system/acme/publish.py) verifies the chain, hostname,
lifetime, key and actual proxy configuration before persistent atomic publication.
Startup/reload revalidate the cache; independent retries cover failed reloads
without requiring another issuance. The
[ACME machine check](../../../nix/verification/tests/machines/acme-route53/default.nix) passed local issuance,
renewal, provider failure, invalid material and proxy recovery. Its real Marshall
WebSocket heartbeat check is a transport check; the separate passing fleet suite
verifies authenticated terminal sessions through the proxy. See the
[ACME review](../reviews/2026-09-16-acme-publication.md) for execution results.
The manual deployment examples have been retired. The maintained
[Marshall](../../../nix/domains/system/marshall.nix), [Lilly](../../../nix/domains/system/lilly.nix)
and [proxy](../../../nix/domains/system/proxy.nix) modules now supply the service boundary.
Four historical definitions remain only as
[isolated harness fixtures](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/scripts/test/fixtures/legacy-deployment/README.md),
preserving complementary database recovery and local fault/load checks.
Historical validation remains in ADR-0027. See the [deployment guide](../../operations/deployment.md)
and [refactor review](../reviews/2026-09-16-nix-layout-and-test-refactor.md).

## Open questions

Deployment-specific DNS, certificate trust, AWS database and DNS credential
inputs remain to be supplied. Production failure domains, provider acceptance
and 100-instance load validation remain outstanding; module implementation need
not wait for those environment values.

## Related decisions

[ADR-0027](0027-production-release-deployment.md),
[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0025](0025-protected-provisioner-enrollment.md),
[ADR-0026](0026-host-maintenance-and-retirement.md),
[ADR-0029](0029-database-durability-and-recovery.md),
[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md),
[architecture review](../reviews/2026-09-16-nixos-and-sparse-zfs.md).
