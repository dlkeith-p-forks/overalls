# ADR-0231: Hetzner Cloud fleet hosts and Susan placement

- ID: ADR-0231
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: host inventory, host tool, NixOS host profile, Susan, TLS
- Supersedes: none
- Superseded by: none

## Context

[ADR-0043](0043-declarative-host-provisioning.md) provisions reviewed bare-metal
hosts on two platforms: Hetzner (two physical disks in a ZFS mirror plus a
quota-bounded Lilly guest dataset) and EC2 (an EBS root plus every local NVMe
drive as guest storage). Its carried-forward lineage ends at
[ADR-0199](0199-memory-suspension-and-demand-wake.md). Both platforms exist to
run Lilly guests, so the host tool, guard and storage receipt require working
`/dev/kvm` and guest CPU, memory and ARC budgets.

[ADR-0224](0224-susan-push-relay.md) fixes Susan's public origin at
`https://notifications.overalls.dev` and left its registry, host and TLS
placement open. Susan needs no KVM, guest storage or Marshall; a small
Hetzner Cloud virtual server fits it. Such a server has one virtio-SCSI disk
and no nested KVM, so neither existing platform admits it.

## Decision

Add a third host platform, `hcloud`, for Hetzner Cloud virtual servers:

- Exactly one system disk carries a single-device ZFS pool `zroot` with the
  legacy `zroot/root` dataset mounted at `/`, plus the ESP or BIOS/boot
  partition of the reviewed firmware. There are no guest disks, no guest
  dataset and no guest quota.
- The only budget is `arcMaxMiB`. A `lilly` section, an enabled Lilly service,
  guest disks or a nonzero quota are refused by the host tool and by profile
  assertions.
- The guard and storage checks skip the KVM probe on `hcloud` and bind the
  `zroot/root` dataset GUID instead of a guest dataset. Every other check is
  unchanged: authenticated host keys, complete stable disk identity, firmware,
  the published revision, renewed erasure authorization, the storage baseline,
  pinned Git access and gated polling.
- Discovery proposes Hetzner Cloud's static routing for review: the IPv4
  address as `/32` with an on-link route to `172.31.1.1`, and IPv6 through
  `fe80::1`.

Place Susan on the `hcloud` host **salopettes** (`fleet/hosts/salopettes`), which
runs only Susan, its local PostgreSQL and nginx. Nginx terminates publicly
trusted TLS for `notifications.overalls.dev` with an ACME HTTP-01 certificate,
forwards to Susan's loopback listener and keeps no access log. The fleet
firewall admits only TCP 80 and 443 at the host's public IPv4 address; SSH stays
limited to reviewed fleet sources and Tailscale. Salopettes is enrolled like
every fleet host, so the trunk auto-updater deploys it, and it decrypts
`overalls-susan` with its own host recipient. The Nix OCI image remains a
packaging artifact; no registry is used for this placement.

This resolves ADR-0224's host and TLS placement question without changing its
origin, protocol or privacy decisions. Authorization: the operator's explicit
request to deploy Susan alone to this server, enrolled in the fleet with
autoupdate on a single ZFS disk.

## Alternatives

- **Reuse the Hetzner platform with one disk:** Hetzner's quota, mirror and
  guest-dataset invariants protect Lilly capacity; weakening them would blur a
  reviewed capacity boundary. Rejected.
- **Install outside the host tool (for example nixos-infect):** leaves the host
  without a storage receipt, enrollment gate or fleet updater. Rejected.
- **Marshall's HAProxy proxy:** it is bound to Marshall's single public host
  name and TLS backends and asserts a local Marshall. Rejected for a host that
  must not run Marshall.
- **A registry-hosted OCI container:** adds a registry and a second update path
  beside the fleet updater for no isolation gain. Deferred.

## Consequences

- Fleet hosts may be virtual and KVM-less, but only without Lilly.
- Susan's availability depends on one virtual server; Marshall's delivery
  worker already retries Susan outages and drops expired pokes (ADR-0225).
- The certificate is issued once DNS for `notifications.overalls.dev` points
  at salopettes; until then nginx serves a self-signed placeholder and
  Marshall's verified TLS refuses deliveries.
- The fleet firewall admits public listeners on IPv4 only, so the origin has
  no AAAA record until IPv6 public services exist.

## Invariants and verification

- `hcloud` hosts MUST have exactly one system disk with a ZFS `zroot/root`
  root, no guest storage or quota, only the ARC budget and no Lilly
  (`@cc hcloud-single-zfs-root`, `@cc hcloud-no-kvm-no-lilly`). Evidence: the
  `storage-configuration` check over the `hcloud-uefi` and `hcloud-bios`
  fixtures, and the `host-planning` tests
  `test_hcloud_single_zfs_root_without_guest_storage` and
  `test_hcloud_guard_skips_kvm_but_lilly_platforms_require_it`.
- Salopettes MUST run only Susan, PostgreSQL and the TLS proxy
  (`@cc salopettes-susan-only`), and the proxy MUST serve only the fixed
  origin without access logs (`@cc salopettes-susan-tls-origin`).

## Implementation evidence

- Host tool: [`cli.py`](../../../nix/domains/artifacts/host/cli.py) and
  [`remote.py`](../../../nix/domains/artifacts/host/remote.py); profile:
  [`profile.nix`](../../../nix/platform/hosts/profile.nix).
- Host: [`host.json`](../../../fleet/hosts/salopettes/host.json) and
  [`configuration.nix`](../../../fleet/hosts/salopettes/configuration.nix).
- Physical installation and enrollment are recorded below as they complete.

## Open questions

- Real APNs and FCM credentials; the deployed document still holds the
  placeholders described in `secrets/README.md`.
- IPv6 public listeners in the fleet firewall.

## Related decisions

[ADR-0043](0043-declarative-host-provisioning.md) gains the `hcloud` platform;
[ADR-0224](0224-susan-push-relay.md) gains its host and TLS placement;
[ADR-0225](0225-marshall-notifications-domain.md) retries Susan outages.
