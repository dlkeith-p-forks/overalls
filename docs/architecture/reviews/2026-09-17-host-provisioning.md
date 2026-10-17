# Declarative host provisioning review

Date: 2026-09-17

## Scope and architecture impact

ADR-0043 replaces generic bootstrap deployment with authoritative machine
inventory, provider profiles, explicit installation and non-destructive enrollment.
It supersedes ADR-0033, ADR-0038 and ADR-0041 while retaining their independent
service/TLS, fleet-user, secret, updater and real-machine requirements. ADR-0035's
ZFS-only guest storage policy remains unchanged. Existing application and
observability changes in the checkout are outside this implementation's scope.
Concurrent follow-on Lilly enrollment commands are also outside the recorded
machine-test snapshots; a Python standard-library name collision in their SSH
bridge was corrected without changing that workflow.

## Findings and resolution

- **High, fixed:** nixos-anywhere 1.13.0 puts disabled host-key verification before
  caller options. The pinned package patches those defaults; caller known-hosts
  files remain explicit. The kexec image retains authenticated installer access.
- **High, fixed:** kernel NVMe numbering cannot distinguish EBS from local media.
  Planning binds controller model, serial, stable aliases and complete membership;
  installer guards reject changes, active disks and ambiguous identities.
- **High, fixed:** generic images supplied a production-looking quota and resource
  defaults. Production declarations now require budgets, and only Hetzner's
  shared-root dataset has a quota. Test limits live in profile fixtures.
- **High, fixed:** boot-time recreation could hide ephemeral storage loss.
  Formatting exists only in the explicitly authorized installer. Readiness and
  enrollment compare persistent system-disk baselines and native pool/dataset
  GUIDs. Missing EC2 storage does not make the system root depend on that pool.
- **High, fixed:** ordinary updates lacked installation bindings. Candidate
  preflight now rejects platform, firmware, disk, topology or identity changes.
- **High, fixed:** BIOS GRUB cannot read the selected modern ZFS feature set.
  Each system disk now has an independent ext4 boot partition; UEFI retains an
  independent ESP. Disko's implicit GRUB device list is cleared so each disk is
  installed exactly through the explicit mirrored-boot entries.
- **High, fixed:** declaration-only bindings could miss Nix module overrides.
  Bindings now include evaluated boot, filesystem, disk and pool settings.
- **High, fixed:** enrollment must share the updater's activation lock and private
  cleanup. It now runs as a bounded systemd unit, masks polling before staging,
  removes stale receipts, authenticates Git with staged credentials, verifies
  storage, and writes receipts only after successful activation and health checks.
  Its runtime includes pinned disk/ZFS inspection tools.
- **High, fixed:** disko exposes a package directory with an executable entry
  point. The installation wrapper now resolves that entry point explicitly. The
  conversion suite uses the production guard/formatter against exact fixture
  hardware, rather than substituting a formatting wrapper.
- **High, fixed:** creating `/etc/ssh` with mode 0700 prevents named users
  from reading the authoritative public authorized-key files. Installation now
  creates that directory with mode 0755 while generating private host keys under
  umask 0077. Actual post-conversion SSH authentication exercises this boundary.
- **High, fixed:** locally built enrollment closures are unsigned. Their transfer
  now explicitly accepts the exact built closure over pinned administrative SSH;
  the target still restricts this operation to trusted administrators.
- **High, fixed:** OpenSSH public-key output can include the generated comment.
  Enrollment now compares normalized key type and key material on both sides,
  matching discovery and inventory identity checks.
- **High, fixed:** first enrollment introduces secret services absent from the
  accessible base. Activation now stops only existing secret-preparation units,
  rather than failing while trying to stop an unknown unit before switching.
- **High, fixed:** ordinary configuration updates stopped unchanged secret
  services without restarting them. Activation now prepares every candidate
  secret bundle before restoring consumers, and health includes those services.
- **Medium, fixed:** an empty legacy floppy controller appears as a Linux disk.
  Discovery excludes floppy controllers and still fails closed for unidentified
  whole storage disks. Imported ZFS consumers are inspected with canonical paths.
- **Acceptance gap:** physical Hetzner/EC2 targets, real published host declarations
  and production credentials were not supplied. No live provider was installed.

## Executed validation

Nix checks ran from isolated source snapshots while unrelated work continued in
the shared checkout. The conversion suite includes the final production guard
and host-key-directory fix; the firmware matrix independently exercises the
profile layouts, access, surviving disks and lost-data behavior.

- Host command package built with patched pinned nixos-anywhere.
- Four-profile BIOS/UEFI storage evaluation passed.
- Fifteen Python tests passed, including complete inventory/EBS exclusion,
  numbering changes, active disks, plan tampering, install failure boundaries,
  shared-key bundle shape, lost GUIDs and enrollment failures at staging,
  preflight, Git access, migration, activation and health boundaries.
- Real automatic-update machine test passed (96.63 seconds), including rejection
  of an installation-binding change before generation or healthy-state advance,
  after the final secret-service lifecycle changes.
- Real secret-custody machine test passed (179.50 seconds), exercising the existing
  SOPS custody and independent recovery machinery. The integrated host test
  below additionally exercises encrypted delivery and activation.
- Uninstrumented Hetzner UEFI image test passed (278.69 seconds), including distinct
  generated host identities and both independent surviving-disk boots.
- ADR checker passed for 47 decisions. The full-checkout contract check
  passed (76 CONTRACTS files, 566 native notes, 761 maintained source files).
  These are structural checks; semantic findings and fixes are listed above.
- The host package built and `nix run .#host -- --help` succeeded.
- EC2 BIOS and UEFI installation suites passed (391.22 and 430.26 seconds),
  including EBS-root SSH access with every guest disk removed, persistent host
  identity/data, no recreated pool and withheld Lilly readiness. Native ZFS
  discovery delays missing-pool boot by up to approximately sixty seconds.
- Hetzner BIOS installation and both independent surviving-disk boots passed
  (598.04 seconds), including authenticated SSH and persistent host identity/data.
- Hetzner UEFI installation and both independent surviving-disk boots passed
  (646.95 seconds), with the same SSH and persistence checks.
- Recovery-Linux BIOS conversion passed (285.90 seconds): authenticated kexec,
  the production guard/formatter against exact fixture hardware, installed boot
  with a new authenticated key, persisted GUID receipt and actual KVM readiness.
- Ubuntu conversion passed (260.61 seconds), exercising the pinned Ubuntu
  source image through actual kexec and the same installed-boot, authenticated
  identity, storage-receipt and KVM readiness checks.
- Full published host-enrollment machine test passed (256.16 seconds): the real
  production profile, strict administrative SSH, unique installed identity,
  SecretSpec/SOPS shared-key delivery, rejected Git-server pin, successful retry,
  exact-revision activation, durable receipt and subsequent ordinary update.
  Secret preparation remains active and usable after that update. Application
  roles are disabled in this host-specific acceptance fixture.

No application code was changed for this implementation, so existing user work
in Marshall, Lilly and protocol was not presented as newly verified here.

## Remaining acceptance

Physical Hetzner and EC2 acceptance remains outstanding, including provider
controller identities, real rescue/Ubuntu networking and independent physical
failure domains. The integrated published-host enrollment sequence passed locally;
that result does not establish physical provider acceptance or restoration of
ephemeral guest data.

## Subsequent physical deployment

The [overalls review](2026-09-17-overalls-provisioning.md) records physical Hetzner
UEFI installation, enrollment and automatic updating, including two deployment
defects found and corrected on the real host. Its result narrows the physical
acceptance gap above; EC2, physical single-disk boots and independent multi-host
failure validation remain outstanding.
