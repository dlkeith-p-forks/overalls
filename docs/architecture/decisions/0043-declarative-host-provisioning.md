# ADR-0043: Declarative bare-metal host provisioning

- ID: ADR-0043
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: host inventory, Hetzner, EC2, NixOS installation, secrets, automatic updates
- Supersedes: ADR-0033, ADR-0038, ADR-0041
- Superseded by: ADR-0048

## Context

[ADR-0048](0048-single-host-service-deployment.md) carries forward this policy
with an explicit nonredundant single-host service/database deployment option.
The rationale and verification scope below remain historical evidence.

The approved implementation plan replaces generic bootstrap images with one
reviewed declaration per physical machine. Generic QEMU disks, UEFI-only boot
and a default one-TiB guest quota do not describe either provider's production
storage. Installation, persistent identity and enrollment need separate failure
boundaries. This task explicitly authorizes this replacement decision.

## Decision

Carry forward ADR-0038's HTTP-01/optional Route 53 policy and inherited service,
TLS, migration, updater and secret custody decisions. Carry forward ADR-0041's
named fleet users, independent recovery grants, authenticated host recipients
and ciphertext reconciliation. Carry forward ADR-0033's real NixOS machine,
three-Marshall/two-Lilly, real nested KVM and independent physical acceptance
requirements. Their original rationale remains in those superseded records.

`fleet/hosts/NAME/host.json` owns reviewed public hardware facts, firmware,
network configuration, stable disk membership, explicit resource budgets,
persistent identity and encrypted document references. Configurations and
secret recipient inventory derive from it. An optional local configuration.nix
supplies enrolled application roles. Discovery writes a separate unreviewed
candidate and never overwrites the declaration.

Hetzner uses two physical disks in a ZFS root mirror and a dedicated guest
dataset with a reviewed quota. Install BIOS GRUB on both disks or removable
UEFI loaders on both ESPs according to discovered firmware. EC2 uses the
existing EBS root reformatted as ext4 and every local instance-store NVMe in a
ZFS stripe. Identify controllers and serials; never include another EBS volume
in the guest pool. Bind the complete inventory, allowing numbering changes
but rejecting missing, added or substituted devices. Retain LZ4, no filesystem
reservations and explicit logical admission; EC2 has no arbitrary guest quota.
Test-image sizes and resource limits belong exclusively to fixtures.

The Python `host` command exposes discover, plan, install, enroll and verify.
Arguments cross subprocess boundaries as arrays; the SSH shell boundary is
quoted. Tools, disko, nixos-anywhere and kexec inputs are pinned. SSH checking
is strict, including the installer connection. A reviewable secret-free plan
binds the authenticated target, machine identity, firmware, reviewed network,
complete inventory, published Git revision, exact system and installer paths,
and the disks to erase. Build before formatting. Revalidate inactive devices
inside the installer under a formatting lock. Every destructive retry needs
explicit plan-digest authorization and retains its last reported phase.

Install an accessible base with no application role or polling. Generate its
new private host key only inside the installed filesystem; retrieve its public
key through the authenticated installer connection before reboot. Retain the
storage GUID baseline on system storage. Enrollment never formats or generates
host identities. It encrypts the supplied shared Git deploy key to the installed
host and all recovery users through the existing SOPS inventory tool. After
publication, activate that exact enrolled revision with the existing secret
staging, compatibility, migration and health machinery. Verify pinned Git access,
host access, actual KVM VM creation and storage before persisting a receipt and
starting polling. Receipts and journals live on system storage.

EC2 uses networkd with reviewed platform networking, NVMe/ENA support and serial
console diagnostics. Do not import metadata-driven access, user-data execution
or implicit SSM policy. Missing local disks or changed pool/dataset GUIDs withhold
Lilly readiness and updates while leaving EBS-backed SSH reachable. Never create
a replacement pool on boot, discard journals or reuse enrollment after loss.
Recovery requires deliberate storage maintenance and control-plane reconciliation.

Ordinary updates reject any change to installation bindings: platform, firmware,
boot disks, complete physical inventory, pool topology and persistent identity.
Such changes require explicit host maintenance. Updates default to this repository
over SSH on main at the existing interval. There is no automatic reboot,
provider-resource creation or restoration of lost guest data.

## Alternatives

Keeping generic bootstrap exports leaves duplicate inventories and test limits
masquerading as production policy. Enrolling in the RAM installer leaves a host
unavailable while publications are prepared. Reusing rescue keys confuses old
and installed identities. Selecting NVMe by kernel name includes EBS and misses
renumbered instance storage. Boot-time pool creation could silently destroy the
only evidence of an unreconciled host loss. These alternatives are rejected.

## Consequences

Deployment requires authenticated public host and Git-server keys and reviewed
budgets. Installation intentionally destroys selected disks; enrollment is a
separate retryable operation. EC2 instance storage remains ephemeral. A failed
migration or activation is not rolled back automatically. Physical provider
acceptance remains independent of local fixture results.

## Invariants and verification

Exercise BIOS and UEFI on both profiles, surviving Hetzner disks, complete EC2
NVMe selection with EBS exclusion and reordered devices, and EBS SSH survival
after data loss. Exercise recovery Linux and Ubuntu conversion through actual
kexec and installed boot. Verify interrupted install/enrollment retries, unique
identities, shared-key encryption, subsequent updates and installation-binding
rejection. Run contract and ADR gates; run application gates when changing their
code. Record physical Hetzner/EC2 acceptance separately.

## Implementation evidence

The [host transport](../../../nix/domains/artifacts/host/cli.py) now selects explicit
administrative ports for SSH and Nix copies. Plans bind source and installer ports;
post-kexec calls use the installer port. Enrollment preparation selects Marshall's
operator port independently. [Planning tests](../../../nix/verification/tests/evaluation/host-planning.py)
cover port binding and phase selection; [preparation tests](../../../nix/verification/tests/evaluation/enrollment-preparation.py)
verify the independent Marshall choice. This preserves existing identity and
erasure authorization boundaries.


- [Inventory derivation](../../../nix/platform/hosts/inventory.nix) and
  [platform composition](../../../nix/platform/hosts/profile.nix) implement public policy.
- [Host tool](../../../nix/domains/artifacts/host/cli.py),
  [target checks](../../../nix/domains/artifacts/host/remote.py) and
  [enrollment runner](../../../nix/domains/artifacts/host/enrollment.py) implement the phases.
- [Updater](../../../nix/domains/system/auto-update/runtime.py) rejects changed installation
  bindings before migrations and activation.
- [Profile evaluation](../../../nix/verification/tests/evaluation/storage-configuration.nix),
  [plan safety tests](../../../nix/verification/tests/evaluation/host-planning.py) and
  [production-profile fixtures](../../../nix/verification/tests/fixtures/hosts/configurations.nix)
  cover the explicit policy and failure checks.
- [Conversion machines](../../../nix/verification/tests/machines/host-conversion/default.nix)
  exercise real recovery-Linux and Ubuntu kexec and installed boot;
  [enrollment machine](../../../nix/verification/tests/machines/host-enrollment/default.nix)
  exercises published configuration and credential transitions. Execution
  results and remaining gaps are recorded in the review.
- [Operational guide](../../operations/host-provisioning.md) describes publication and recovery.
  [Review](../reviews/2026-09-17-host-provisioning.md) records executed checks and
  outstanding acceptance obligations, including independent physical validation.

The local automated acceptance matrix has passed. The real
the retired Overalls host declaration and
[physical Hetzner review](../reviews/2026-09-17-overalls-provisioning.md) now record
a successful UEFI rescue conversion, mirrored installation, authenticated
installed boot, secret enrollment and subsequent automatic update. Implementation remains partial pending the remaining physical
acceptance matrix. Private credentials remain outside Git.

Correction (2026-10-17): "this repository" is now `ghuntley/overalls`, whose
published branch is `trunk`. Both the retired host declarations
poll `ssh://git@github.com/ghuntley/overalls` with the same shared deploy key
and pinned GitHub host key, and the [host tool](../../../nix/domains/artifacts/host/cli.py),
[remote preflight](../../../nix/domains/artifacts/host/remote.py) and
[enrollment](../../../nix/domains/artifacts/host/enrollment.py) check `trunk`
instead of `main`. Transport and authentication are unchanged.

## Open questions

Physical single-disk failure boots, EC2 acceptance and independent multi-host
validation remain outstanding. The overalls review distinguishes completed
provider and enrollment checks from outstanding application deployment work.

## Related decisions

[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0038](0038-http01-validation-and-peer-routing.md),
[ADR-0041](0041-declarative-fleet-users.md),
[ADR-0035](0035-zfs-only-provisioning.md),
[ADR-0026](0026-host-maintenance-and-retirement.md).
[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) adds the KVM-less,
Lilly-free `hcloud` platform beside Hetzner and EC2.
