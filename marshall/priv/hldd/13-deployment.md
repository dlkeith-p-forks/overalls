# Installation and deployment

Source2 and manifest4 are a coordinated application/image cutover under
[ADR-0157](repo:docs/architecture/decisions/0157-multi-provider-authenticated-repository-launch.md).
The one-time database migration converted stored GitHub source rows into current
provider/revision fields and disabled obsolete image catalog entries. It did not
rewrite immutable execution snapshots, guest source records or Lilly journals.
ADR-0159 pruned those applied data statements; a fresh installation creates the
provider/revision columns directly.
Select newly built source-capable guest images and matching applications together.
Obsolete source-bearing retained guests require recreation for current source
delivery. The migration has no automatic down path; rollback needs the pre-cutover
database backup and matching revision. This does not establish safe historical
restore alongside newer retained guest disks: permanent guest UUID/UID reservations
and the sequence also require reconciliation under
[ADR-0158](repo:docs/architecture/decisions/0158-durable-guest-identities.md).
Source eligibility for an unsourced retained start does not waive generated-identity
image/recreation requirements. No production cutover is recorded here.

Marshall's existing HTTPS deployment closure also includes its selected immutable
browser launcher package. Null disables downloads; enabling it creates no new host,
listener, service identity or external signing service. Public archive availability
does not establish a successful authenticated guest launch.

Canonical source and fleet deployment continue using `antithesishq/overalls` on
`main`. Host clone/ancestry checks, enrollment probes and updater defaults agree
on this branch. ADR-0147 accepts the Standard profile for fresh state. The
retained-state extension,
[ADR-0151](repo:docs/architecture/decisions/0151-existing-state-standard-profile-migration.md),
completed on both hosts and is superseded by ADR-0159: the one-way database
migration was applied and its file then pruned, and Lilly no longer renames
private state at startup.
Do not treat a previous system generation as a database rollback.

Provisioning acceleration originally deployed compatible audit readers and the
additive pool-audit database column before enabling template/readiness
producers. Those producers are now unconditional and their switches were
removed (ADR-0159). Rollback after publication requires a compatible corrective
release (`git revert`) that retains all journals; an older reader cannot
validate new resource states. Existing guests retain their independent disks and boot bundles.
Guest image outputs are content-addressed. After an Ubuntu builder correction,
independently rebuild and compare full rootfs/manifest identities across both
enrolled hosts, then register and enable the **new** catalog image ID before
matching it to fresh authenticated host offers. The older ID may remain for
existing placements; a same-name image or same derivation path with differing
bytes cannot stand in for the new ID. Hold benchmark mutations and producer
activation while host image offers disagree. The benchmark runner
also checks both installed Nix-store paths and registered NAR hashes, installed
artifact digests/sizes against selected catalog images, catalog enablement,
fresh image offers and the expected off/on producer budget before
writing a campaign manifest; enabled comparison also binds the recorded baseline
NAR identities. This read-only check is not host admission or a
replacement for cross-host rebuilt artifact verification.

## Prepare a host

Use reviewed x86-64 hardware with working KVM, supported firmware, stable disk IDs,
and authenticated administrative SSH. The host tool requires Python, OpenSSH,
lsblk and iproute2. Pin the rescue host key out of band. Keep operator private keys
and generated plans outside the checkout.

```sh
nix run .#host -- discover --platform hetzner --name example \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key --output /private/example.candidate.json
```

Use `--platform ec2` for supported EC2 bare metal. Review the full hardware and
network inventory before publishing `fleet/hosts/example/host.json`. Select disks
by stable IDs, firmware, a persistent nonzero host ID, budgets, public Git trust,
and `reviewed = true`. Hetzner uses mirrored system disks; EC2 separates persistent
EBS system state from local NVMe guest storage. Local NVMe loss is guest data loss
unless a usable backup exists. `--platform hcloud` (ADR-0231) describes a Hetzner
Cloud virtual server: one system disk with a ZFS `zroot/root` root, no guest
storage, quota or Lilly, only the `arcMaxMiB` budget, and no KVM probe in the
guard or storage receipt. Discovery proposes its on-link `172.31.1.1` IPv4 and
`fe80::1` IPv6 routes for review. Salopettes, the Susan host, is the only one.

Generate a plan for the exact published revision:

```sh
nix run .#host -- plan --host example --revision FULL_COMMIT \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key --output /private/example.plan.json
```

The revision must be reachable from published `main`. Inspect the selected disks, target identity, ports, and erasure digest.
`install --erase PLAN_SHA256` destroys the selected disks:

```sh
nix run .#host -- install --plan /private/example.plan.json --erase PLAN_SHA256 \
  --target root@HOST --known-hosts /private/rescue-known-hosts \
  --identity /private/operator-key
```

The installer rechecks identity and storage before formatting. Preserve the phase
journal and installed receipt. An interrupted install requires inspection and
explicit erasure authorization again; it does not silently resume formatting.
A completed plan cannot be reused to erase the host.

## Enroll

Authenticate the installed public host key from the receipt. Publish it in the
host inventory. Prepare encrypted Git custody, publish the enrolled configuration,
then activate the exact commit:

```sh
nix run .#host -- enroll --host example --deploy-key /private/shared-git-key \
  --root . --target admin@HOST --known-hosts /private/installed-known-hosts \
  --identity /private/operator-key
nix run .#host -- enroll --host example --revision ENROLLED_FULL_COMMIT \
  --install-receipt /private/example.plan.json.installed.json \
  --target admin@HOST --known-hosts /private/installed-known-hosts \
  --identity /private/operator-key
nix run .#host -- verify --target admin@HOST \
  --known-hosts /private/installed-known-hosts --identity /private/operator-key
```

For nonstandard administrative ports, pass matching `--ssh-port` throughout.
Installation also binds `--installer-ssh-port`. Management SSH cannot run host
operations. Use the declared named administrator and pinned keys.

Lilly preparation additionally binds physical machine and pool identities to a
disabled Marshall host. Use `prepare-enrollment` with the installed receipt,
Marshall administrative target, private recovery key, and pinned transport.
Publish its ciphertext and public bindings, activate, verify fresh execution
readiness, then explicitly enable scheduling. Preparing credentials alone does
not make a host eligible.

## Replace a Lilly host

Replacement hardware enrolls under a fresh machine identity, a new name and its
own ZFS pool/dataset GUIDs; a retired host's name is never recycled, and its row
persists as evidence. Retire the old host first (see Routine operations), then
prepare the replacement through the protected SSH bridge, deliver only through
the sealed bundle and activate with the enrolled binding. The replacement stays
disabled until its fresh execution-ready report satisfies the same readiness
gate as every host. Confirmation that real guest traffic to private services
runs again before the old credentials disappear from circulation is part of the
procedure. The native journey and generated histories are indexed in the
[host replacement review](repo:docs/architecture/reviews/2026-09-27-host-replacement.md).

## Build and activate a release

```sh
nix build .#marshall .#lilly
nix build .#checks.x86_64-linux.marshall-release
nix build .#checks.x86_64-linux.module-configuration
nix build .#nixosConfigurations.HOST.config.system.build.toplevel
```

Run component gates before publication. Release builds use locked dependencies and
an explicit source allowlist. Stage private secrets, verify schema and credential
compatibility, run serialized compatible migrations, then switch and verify health.
Serving application startup does not run migrations. Independent automatic updates
perform their own pre-switch migration and health sequence. Enrolled hosts poll
the `trunk` branch of `ssh://git@github.com/ghuntley/overalls` with the shared
deploy key and the pinned GitHub host key from their declaration.

For manual rolling changes, remove one backend from traffic, activate, wait for
verified `/health/ready`, and restore traffic before moving to another.
`/health/ready` answers 503 at once for a read-only database, a missing
migration or a database error. A probe that gets no answer at all (a
saturated pool, a lost connection or a timeout) keeps the node's last ready
verdict for at most 30 seconds (ADR-0140), so contention on the shared
database cannot remove every node from the load balancer at once. A freshly
started node is never ready until it has had a real answer. Include
surge instances in connection budgets. Incompatible schema, key, or identity
changes require a coordinated maintenance procedure. A previous NixOS generation
does not roll back the database.

Overalls keeps no compatibility code for older releases, peers or stored formats
(ADR-0159). A change to anything two hosts exchange or a release reads ships as
ordered pushes: the consumer first tolerates absence, then the producer stops,
then the decoder becomes strict or a hand-written migration drops the column or
table. Hosts fetch only the branch tip, so each dependent push waits until both
hosts report `phase=healthy` on a revision descending from the previous push.
Old-format durable data is exported with a recorded digest, then purged; a backup
taken before such a purge is not a supported restore source.

Unattended Marshall candidates must retain the database URL, shared cookie and
token-signing authority. A candidate Cloak ring may add keys or reorder inactive
keys, up to sixteen entries, while retaining the active key and every prior
key's ID and bytes. Removal, promotion and material replacement require coordinated
maintenance. Preflight compares the staged candidate with every serving local
Marshall environment. It reads the installed environment file only when none
are serving; replacing that file cannot approve a candidate against older live
authority. Correct a refused candidate explicitly and submit it again.

Candidates must carry the complete current manifest: diagnostic preflight,
socket units and the Lilly transfer state directory. A host's reviewed resource
policy may raise CPU, RAM and quota ceilings and may lower the RAM ceiling
live only while the guest slice's current use plus two GiB fits under the new
ceiling, read just before the change; otherwise the update is refused
`resource_decrease_unsafe` and nothing changes (ADR-0164). CPU and quota
decreases, and introducing or removing a policy, like any other
installation-binding change, require maintenance. The policy also writes and
verifies the ZFS ARC dnode limit at a quarter of the ARC maximum beside the
maximum itself. No reader tolerates manifests from before these fields existed
(ADR-0159).

Activation stops only what the candidate changes (ADR-0165): a consumer,
socket or secret preparation unit whose unit file or drop-ins resolve to a
different store path than the active system's, or that exists on one side
only; the consumers of a secret bundle whose staged files differ from the live
bundle or whose preparation unit itself changed (the manifest's
`bundleConsumers`); consumers the candidate no longer lists; and the consumers
that require, bind to or are part of any of those (`consumerDependents`), so a
retained dependent's restart cannot pull a stopped unit back up. The resource
policy oneshot, whose command line names the per-release manifest, is not
restarted by the switch (the updater applies the policy itself), so Lilly,
which requires it, is not stopped by propagation. Every other running consumer, its sockets and its secret
preparation stay up across the switch, and `update.units_retained` records
how many, so a Marshall-only release no longer restarts Lilly, drops its
control channel or exits guest actors. A changed unit follows the ordered
stops, deadlines and restoration below unchanged.

The exported `auto-update-compatibility` check runs the existing fixed assertions
and generated operator histories against the actual predicate and preflight.
The histories use isolated environment/process-discovery seams and verify local
fixture preservation and finite refusals. They do not execute systemd discovery,
secret staging, migrations or activation. Recorded results and historical native
update/credential-rotation scopes are kept in the
[compatibility review](repo:docs/architecture/reviews/2026-09-26-updater-compatibility-histories.md).

A new revision whose system closure and manifest equal the active ones still
stages every candidate secret bundle privately. Byte-identical bundles keep the
verify-only path; any difference (a secret-only change) takes preflight,
migration and activation, and an unresolvable bundle fails at `stage` without
touching live bundles. During activation, once every consumer has stopped, the
independent secret-preparation units stop in one transaction under their own
300-second deadline, while consumers keep one-at-a-time dependent stops. This
corrects overalls activations that ran past a single sequential deadline and
restored the previous system after several minutes (ADR-0036, 2026-10-07). A
switch that exits non-zero after the candidate system is already active (for
example a logged-in user's manager failing to reload) and leaves no newly
failed system unit records `update.switch_incomplete` and proceeds to role
restoration and health checks; a newly failed unit still fails activation.

The update failure and recovery boundaries are exercised natively. A build, preflight,
migration or activation failure is recorded with its phase, failure counter and retry
deadline while the serving revision remains last-healthy. An out-of-band drift of the live
system closure — for example an operator switching the running generation back by hand —
reconverges exactly once on the next attempt with a single healthy record; a further poll
is a no-op fast path and leaves neither staging nor handoff residue. A failed activation
on a Lilly host with live guests preserves every guest VMM process identity, restores the
prior consumer roles, keeps last-healthy pinned to the serving revision and records the
drifted live system honestly, and a corrective revision reconverges without replacing
guests. Host credential rotation archives the superseded credential immediately, so a
retained pre-rotation envelope is refused with 401 even inside its nominal TTL. Recorded
executions and per-leg durations live in the
[update failure matrix review](repo:docs/architecture/reviews/2026-09-26-update-failure-matrix.md).

The durable guest identity cutover is a breaking development release under
[ADR-0158](repo:docs/architecture/decisions/0158-durable-guest-identities.md).
Its migration preserved every current/historical GuestAccount UUID and UID,
canonicalized database names to `u<uid>`, retained the noncycling sequence and
audit payloads, removed `email_localpart` and retired surviving current rows of
already-deleted Users. Old editor leases closed without rewriting their saved
identity. ADR-0159 pruned those applied data statements; the `u<uid>` CHECK
remains. Mixed old/new Marshall releases and rollback to email naming are
unsupported. All serving instances and compatible fresh guest images must agree.

No migration changes guest disks or physical VM state. Publishing an image or
updating a host does not convert an existing writable disk. Recreate incompatible
guests from current images and copy/verify selected data while retaining the old
disk unless deletion is separately authorized. No retained-disk conversion or
feature deployment has been performed. Refresh the
Overalls installer/setup on old clients so their managed SSH block discovers the
generated name. The complete development lifecycle journeys on base `63a1443c`
plus the durable feature precede main integration and are scoped
in the [durable identity review](repo:docs/architecture/reviews/2026-10-10-durable-guest-identities.md),
separately from deployment and the old
[email-derived verification](repo:docs/architecture/reviews/2026-09-25-fresh-guest-identity-verification.md).

Separate explicit authorization allowed deletion of the four existing live
guests as preparation on 2026-10-10. Trusted root maintenance admitted normal
public lifecycle requests using fresh actual stored owners and stable request
UUIDs, with operator initiation recorded separately. All four operations then
completed, their VMs were archived with desired/observed deletion and released
holds, and native inspection confirmed guest service/dataset absence on both
provisioners. The service/cache/template inventory was retained. This preparation
does not establish feature deployment, the identity database migration, guest-disk
conversion or historical-restore reconciliation; see the scoped review above.

Acceptance requires the deployed revision, healthy required services, current host
reports, an authorized guest lifecycle, terminal/SSH access, and working configured
mail/provider paths. A build or push alone proves none of these runtime outcomes.

Evidence: [host tool](repo:docs/operations/host-provisioning.md), [enrollment](repo:docs/operations/provisioner-enrollment.md),
[deployment](repo:docs/operations/deployment.md), [updater](repo:nix/domains/system/auto-update/runtime.py).

The SSH CA change requires the certificate database migrations and updated
Marshall, gateways, client and new guest images as one coordinated development
release. Deliver the encrypted signer before activating Marshall. Gateway startup
obtains a certificate with its own service credential. Missing initial authority
keeps the listener closed and retries every five seconds without exhausting a
start limit. On Overalls, gateway activation also starts the fleet API relay socket;
remote gateways recover independently when Marshall returns. Daily renewal jobs
receive their own systemd credentials. Confirm the public policy, gateway readiness and a
fresh installer session on both guest distributions. Old writable disks are not
upgraded by this release.

## Provisioner readiness across incarnation restart

Lilly's private readiness socket requires a newly delivered authenticated report
and completed observations of the current durable placement authorities. Restored
journals and a running systemd main process cannot establish deployment readiness.
The `lilly-runtime-readiness` check places six native guests on two provisioners,
stops fixture PostgreSQL and restarts each daemon main process one or two times.
Each incarnation must produce a complete negative socket reply before a bounded
negative watch. After database restoration, the test requires newer authenticated
host epochs, fresh reports, affirmative readiness and unchanged guest process
identities. The native check passed its 897.72-second machine script, including
248.40 seconds for readiness histories; execution scope is recorded in the
[readiness review](repo:docs/architecture/reviews/2026-10-03-lilly-runtime-readiness.md).
Exact report-age
boundaries retain separate direct Runtime property coverage. Physical rollout,
updater promotion and hosted fault exploration remain separate acceptance.

## Windows image build inputs

The foreign Linux catalog entries for Arch Linux and AlmaLinux reuse the
version-4 kernel image assembly. Their deterministic distribution markers make
the identities distinct, and the evaluation check covers builder shape before
staging. This is structural evidence only; neither distribution has a native
boot, recovery or independent-host acceptance claim here. Preliminary FreeBSD
and OmniOS/illumos version-6 image packages and catalog entries exist without
standby metadata, but the rolling FreeBSD source endpoint is retired and
replaced by a checksum-pinned archive capture. Nix evaluates the pinned native
receipts, but their placeholder kernel artifacts make image construction stop
before a stock disk is copied. The OmniOS row uses the explicit `illumosGuest`
constructor. Bundle version 3 is implemented and structurally tested, but
signed rollout and launch remain unrecorded.

`freebsd-kernel-candidate` is a separate complete cross-built kernel, while
`illumos-kernel-object-check` compiles the modern framework, all consumers and
the custom socket/transport code. The latter emits ELF object and input/hash
evidence; it does not emit natively linked kernel modules or a bootable image.
The separate native link/install helper verified and linked all nine illumos
modules in the matching scratch guest, installed them into an alternate ZFS boot
environment and rebuilt its boot archive. The original was preserved and the
guest shut down cleanly. That helper refuses the running root and cannot grant
native admission. The corrected clone passes QEMU boot and a native TCP bind;
Firecracker virtio-vsock execution remains open.
The recorded native Lyra package linked eighteen production executables for both libc families,
with separate test-only probes.
Its exact interpreters, non-executable stacks and absence of Nix/Linux runtime
references are checked. The official OmniOS SDK carries explicit content hashes
and archived-source TLS acquisition limits. None of these artifacts replaces
the unavailable receipts selected by the image builders.

Both native terminal daemons also cross-link with native interpreters and
verified manifests. The integrated closure remains incomplete: OS-native
SSH/service execution and the full boot/recovery scenarios
are missing. The rc.d/SMF supervisor, readiness PID checks and linked binaries
provide packaging evidence only; they cannot confer fleet admission.
The new nested-KVM `native-freebsd-transport` gate and its separate test-only
listener bind credit-window exchanges to the executing token and exact
disk/firmware/VMM hashes. A scoped 139-second run passed; subsequent candidate
inputs require a fresh recorded execution. It does not enable the production
services or catalog.

The separate [FreeBSD candidate](repo:nix/domains/artifacts/guest/freebsd/candidate.nix)
passed two offline QEMU boots with all installed file hashes, native Git/trust,
kernel digest and executing sysctl token checks. The
[OmniOS kit](repo:nix/domains/artifacts/guest/omnios/README.md) packages exact base
GPT, interpreter, kernel objects, complete service/bootstrap and Git roots. Its
root-only helper verifies a separately identified unimported pool, preserves the
base BE, installs into a clone and exports before fresh-boot verification. An
export failure retains the mounted workspace for recovery. Nine helper safety
tests passed for the recorded kit. Eleven updated helper regressions and pinned
Ruff/ty checks pass with the offline vendor-service profile. Native execution on the matching image imported the
separate pool, linked/installed all nine modules and 758 payload entries into a
clone, rebuilt its boot archive, selected its bootfs and cleanly exported. A
separate QEMU boot reached that clone; fresh-boot verification and loader/cache
persistence remain pending. Both outputs retain native admission false.

The new growth service runs after local filesystems and before native bootstrap
on every boot, with a mandatory volatile mounted-root receipt. Its production
binary expands the target set to ten per OS; the exact twenty-executable native
package cross-build passed. Three native FreeBSD QEMU boots passed unchanged
root plus two expansions and retained-data/GPT/foreign-disk checks. Final
Firecracker composition and the source-qualified OmniOS service/growth replay are recorded separately; interrupted growth and native isolation remain pending. The native isolation
machine driver builds and uses actual packaged
Lilly router/TAP rules; a Linux nft smoke passed, while the native two-boot
scenario remains unexecuted. These are disposable verification programs, not new
deployed hosts or application domains.

The Windows guest spike ([ADR-0169](repo:docs/architecture/decisions/0169-firmware-booted-windows-guests.md))
adds build-time requirements without touching fleet activation. The builder
needs the `kvm` system feature (`requiredSystemFeatures = ["kvm"]`, the same
mechanism `pkgs.vmTools` and the NixOS test framework use) because Windows is
installed under QEMU inside the sandbox, and it downloads the roughly 6 GiB
Windows Server 2025 evaluation ISO as a fixed-output fetch pinned in
[iso.json](repo:nix/domains/artifacts/guest/windows/iso.json). Installation takes 20 to
40 minutes and is not reproducible, so rebuilds happen only when an input pin
changes. Production use needs licensed media swapped into the pin file; the
evaluation licence covers 180 days of guest uptime.

The [patched Firecracker](repo:nix/domains/artifacts/infrastructure/firecracker.nix) replaces the plain
nixpkgs package in Lilly's release metadata and the development shell. It keeps
the `1.16.1` version string Lilly matches, so no fleet ordering constraint
follows from this change; hosts pick it up with their next activation like any
other package update.

Launch path rollout ([ADR-0170](repo:docs/architecture/decisions/0170-lilly-firmware-guest-launch.md)):
the protocol, Lilly and Marshall changes that admit manifest version 5 and
bundle version 2 land together, and every host runs a release that understands
both shapes before the operator stages the image in `services.lilly.images` and
registers it in Marshall. Relocation destinations adopt from the streamed
bundle and clones copy `firmware`, so an older Lilly fails closed on a firmware
placement. The current converged image is registered in
`fleet/guest-images.nix`; the named create, workspace,
roster and relocation observations do not replace a repeatable Marshall-driven
fleet matrix.

Agents rollout ([ADR-0171](repo:docs/architecture/decisions/0171-windows-guest-agents.md)):
the first converged push carries the `windows-v1` agent set and capability
table, the vsock-capable firmware jail, the then-current `{ path; standby }`
image shape (with `standby = true` on the Linux entries; ADR-0177 later removed
the `standby` key), the 48 GiB template budget on both
hosts and the Windows agents code with no image staged. Because the Windows
installation is not byte-stable, the image is then built once, its closure
copied to both hosts with `nix copy`, and the same store path verified on each
(and `disk.raw` verified sparse) before the second push stages it in
`fleet/guest-images.nix` without standby metadata; hosts substitute the image
instead of each building a different one with a different identity. The
procedure is in [docs/operations/nixos.md](repo:docs/operations/nixos.md); acceptance is recorded in
the [agents review](repo:docs/architecture/reviews/2026-10-14-windows-guest-agents.md)
and the [multi-OS review](repo:docs/architecture/reviews/2026-10-16-multi-os-guest-images.md).
## Reflection deployment

The private frontend routes `reflection.internal` to Peach's Unix socket.
The declared module runs as the unprivileged `peach` user with a private runtime
directory, dedicated host-bound Marshall credential and CA delivered as systemd
credentials. It depends on Lilly for the local host identity. Peach is optional
beside `audiPrivate`: disabled Peach produces a null backend socket, and
`reflection.internal` refuses before guest authority is requested. Enabling it
requires a bounded canonical Unix-socket path. Mandatory Lilly, Ziggy and Galileo
dependencies remain. Fleet enablement, socket access and credential lifetime,
and complete native guest journeys remain separate acceptance work.

Before enabling reflection, reissue the private leaf through the existing offline
issuer custody with the fixed `reflection.internal` SAN. Read-only inspection
found only `llm.internal` and `*.integration.internal` on deployed leaves. Current
private health checks validate `llm.internal`; their success does not establish
reflection hostname verification. Disabled Peach requires no certificate change.

Marshall's serving, migration, operator and pre-start release commands use the
same module-selected mail environment. The GitHub restore-credential invalidation
pre-start command must apply it before evaluating runtime configuration; inherited
remote SMTP settings cannot override an enabled local relay. Environment removal
options precede assignments, including the optional executor bootstrap manifest.
A source-built release and successful migrations do not establish successful
pre-start execution, activation, fresh control reports or ordinary CLI routing.
