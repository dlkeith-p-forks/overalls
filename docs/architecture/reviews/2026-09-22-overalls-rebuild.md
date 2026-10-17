# Overalls fresh installation and service enrollment

Date: 2026-09-22

## Scope and architecture impact

The operator authorized rebuilding `overalls` at `136.243.69.55`, erasing its
disks and starting with fresh application state. No old filesystem or database
was recovered. The administrator's existing recovery identity decrypted the
repository's service credentials; every Overalls document was encrypted for the
new installed host key and the retained recovery recipient.

The rebuild preserves the provisioning and receipt boundaries inherited from
[ADR-0043](../decisions/0043-declarative-host-provisioning.md), the single-host
deployment of [ADR-0048](../decisions/0048-single-host-service-deployment.md),
and [ADR-0045](../decisions/0045-declarative-lilly-enrollment.md). It introduces
no new architecture decision. Application registrations and native storage GUIDs
are new; the old host binding is not reused.

## Changes and findings

- The [host declaration](../../../fleet/hosts/overalls/host.json) records the
  authenticated replacement SSH key, transfer pin, Lilly host/pool registration
  and installation-derived ZFS GUIDs. Stable physical disk identities, IP
  addresses and resource budgets are retained.
- The [image catalog](../../../fleet/hosts/overalls/image-catalog.nix) no longer
  changes capacity on the old hard-coded host UUID. New enrollment supplies the
  declared overheads; catalog startup independently registers installed images.
- PostgreSQL, TLS and password setup were enrolled before application migrations.
  Lilly first reported execution readiness, then its dependent service
  credentials were issued through the existing trusted operator actions.
- [ADR-0091](../decisions/0091-fleet-perimeter-public-listeners.md) deliberately
  preserves approved-source access to Marshall and Porsche. A temporary public
  control-plane listener grant used during certificate bootstrap was removed;
  the final configuration does not expand that perimeter. The issued public
  certificate works, but unattended HTTP-01 renewal needs an explicit policy
  decision or an alternative validation method.
- The fresh host has no Tailscale login state. Underclass continues locally;
  its tailnet HTTPS publication is disabled until the host is authenticated.
- Reboot exposed a pre-existing administrative SSH startup race: binding
  `136.243.69.55:2222` failed before the address existed and exhausted systemd's
  start limit. The [host configuration](../../../fleet/hosts/overalls/configuration.nix)
  now orders SSH after network-online and retries at five-second intervals.
  The existing Git updater restored administrative access without rescue boot.

## Executed verification

- Authenticated rescue discovery matched the declared machine UUID and both
  Samsung NVMe serials. The pinned installer and base system built before erasure.
- Guarded installation completed, with a mirrored ZFS root, two EFI boot
  partitions, a newly generated SSH key and a retained installation receipt.
- Host planning, storage configuration and fleet firewall evaluation checks
  passed. The secret inventory check validated all 31 documents.
- Explicit enrollment and the ordinary Git updater both reached healthy state.
  Host storage/identity/receipt checks and actual KVM creation passed.
- Marshall HTTPS readiness and the Lilly, Porsche, Ziggy, Audi gateway, Audi DNS
  and Audi private readiness endpoints passed. Galileo and Underclass were active;
  no failed systemd units remained before reboot testing.
- Using a temporary account and SSH key, Porsche authenticated a real SSH client,
  provisioned `rebuild-smoke` to `running`, and deleted it to `deleted`. The key
  was revoked and the temporary account retired. No email was sent.
- A second physical reboot passed with the SSH startup fix. Pinned administrator
  login on port 2222 worked, both mirror members remained healthy, all listed
  readiness checks passed, and there were no failed systemd units. Scheduling
  was disabled for the reboot and enabled again after a fresh execution report.
- The ordinary updater verified revision
  `d46cb15e9cdc914980fd35d39be9f1d1de6093d1` as healthy after reboot. Monitoring
  persisted fresh observations for the new physical host registration.
- Repository code-contract structure/coverage and ADR structure/link checks passed.
  These checks do not establish semantic correctness beyond the reviewed scope.

## Remaining operational checks

Tailscale authentication remains an external operator step. Dungarees was not
re-enrolled into the fresh control-plane database. Its automatic update timer
was restored after maintenance; its old application
registration is not authority in the new database and needs separate reconciliation.
This rebuild does not establish database recovery, multi-host availability,
SMTP inbox delivery or guest wildcard-certificate production issuance.

Public installation receipts and private operational logs are retained outside
the checkout at `~/.local/state/overalls/rebuild-overalls`.

## Dungarees guest cleanup

The operator subsequently authorized removing all machines on Dungarees.
Local inspection found no Firecracker processes, guest systemd units, guest
network interfaces, guest mounts, or child ZFS datasets/snapshots. Six retired
machines retained actor journals and network guard files; two also retained
runtime and empty jail directories. All six had storage deletion records.

With Lilly and the update timer stopped, cleanup rechecked native storage and
mount absence and held the existing storage-owner lock. It removed those actor,
runtime, jail and guard-file remnants. The host identity, pool binding, lock
inode and storage deletion fences were preserved, consistent with ADR-0017's
retained deletion semantics. This operator cleanup changes no architecture or
application code and does not establish fresh control-plane enrollment.

After restarting Lilly and the update timer, both were active, no systemd units
were failed, all guest runtime/actor/disk/jail directories were empty, and
`zroot/lilly` had no child datasets or snapshots. Host networking and fleet
services remained installed.
