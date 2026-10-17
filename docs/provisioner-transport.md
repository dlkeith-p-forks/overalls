# Provisioner v3 transport

Marshall and Lilly use the shared bounded v3 contract in `protocol/`.
[ADR-0035](architecture/decisions/0035-zfs-only-provisioning.md) removes the
receipt-only provisioner v1 API and ext4 host storage. Deploy both consumers
together; there is no mixed-version or legacy-state conversion path.
Since [ADR-0142](architecture/decisions/0142-overallsprotocol-control-websocket.md)
the v3 actions travel only as `lilly.<action>` requests on the control
WebSocket (`GET /api/control/v1`, `overalls-service: lilly`); the
Only the `/api/provisioners/v4/stream` upgrade remains; every other provisioner path answers 404.
All v3 actions, including clone, decode through the same bounded protocol
parser. A malformed document is answered `invalid_message` before a host
control transaction; unexpected internal transaction errors return the fixed
`temporarily_unavailable` name. A credential check that cannot complete (for
example an undecryptable stored secret) answers the upgrade with 503, not 401.

## Encryption and host authority

Marshall requires `MARSHALL_CLOAK_KEYS` in production. Its value is an ordered JSON
array of objects with `id` and `key` fields. `key` is a Base64-encoded 32-byte random
key; `id` is a unique 1–32 character alphanumeric, underscore or hyphen tag. Supply
this through the deployment secret store, never a committed configuration file.
The first entry encrypts new attributes. Retain previous entries to decrypt old
records while rotating/re-encrypting them. Keep the same keyring on every Marshall
instance. Backup restoration needs the matching keys as well as PostgreSQL data.
Development and test have an explicitly non-production key; production cannot
fall back to it.

Hosts and pools are enrolled through the trusted Compute coordinator. Hosts
default to disabled. `Marshall.Compute.Credentials.rotate(host_id, ttl_seconds)`
issues an opaque `Issued` result whose `token` field must be delivered privately
to Lilly. TTL is required and capped at five 365-day years (157680000 seconds). Rotation archives the previous
credential and invalidates capacity observations and sessions in one transaction.
`Credentials.revoke(host_id)` does the same without issuing a replacement.
These are operator functions inside the application, not public user APIs. An
operator CLI now writes and verifies protected credential files; see the
[enrollment guide](provisioner-enrollment.md). Do not print the token from a release
console or put it in process arguments.

AshCloak encrypts the secret attribute. AshArchival retains revoked metadata and
AshPaperTrail records issuance/revocation without plaintext or encrypted secrets.
Cedar protects credential, session and audit resources from ordinary users.
The API rechecks credential expiry/revocation while holding the host row lock.
Revocation retains every VM reservation and does not assert that a host is dead.

## TLS and client configuration

For a direct Marshall TLS listener, set absolute `MARSHALL_TLS_CERTFILE` and
`MARSHALL_TLS_KEYFILE` paths, with optional `MARSHALL_TLS_PORT` (default 4443).
Enable the release's endpoint with `PHX_SERVER=true`. Use a certificate valid for
the hostname Lilly will connect to. The API rejects non-TLS requests in production.
The NixOS HAProxy module terminates public TLS and verifies backend TLS. Arbitrary forwarded headers do not make
an HTTP request trusted.

`Lilly.Control.Client.new(url, host_id, token, options)` accepts an HTTPS origin,
without userinfo, query, fragment or path. `cacertfile` can name a private CA
bundle. Certificate and hostname checks stay enabled. The explicit
`allow_insecure_loopback: true` option allows literal `127.0.0.1`/`::1` HTTP only
for local development; Marshall permits that exception only in dev/test.

Requests travel over one `Lilly.Control.Link` connection, with no implicit
retries: a request in flight when the socket drops is unproven and surfaces as
a transport error. Frames are bounded by `OverallsProtocol.max_body()` plus
4 KiB, each request has a 5-second deadline, and reconnect backoff is capped
at 4 seconds. Transport errors expose no request, credential or raw response
diagnostics.

## Version 3 executable contract

The control upgrade requires `Authorization: Bearer <credential-id>:<secret>`
and a hello binding the credential's `host_id`. Never log this header.

- `lilly.sessions` requires `version: 3`, a UUID `session_id`,
  and the enrolled `machine_id`. Retrying the current nonce returns its epoch;
  a replaced nonce cannot displace its successor. Responses include immutable
  ZFS pool identities (exactly `id`, `name`, `filesystem_id` and `storage`
  per pool) and the one-second reporting interval. Lilly refuses any other pool
  key, including the retired `logical_budget_bytes`.
- `lilly.exchange` requires `version`, `session_id`, `epoch`,
  `report`, `acknowledgements` and `outcomes`. A report contains every enrolled
  ZFS pool, or is null when there is no new observation. Null never refreshes
  capacity. Each receipt/outcome collection is bounded to 16 distinct IDs.
- Responses contain executable commands and `outcome_acknowledgements`.
  Commands bind operation/VM/placement/host/pool, execution epoch, generation, immutable image, profile
  slot and resource sizes. Outcome acknowledgements must refer to sent events.

Use `Lilly.Control.Client.new/4` with the enrolled `machine_id`; its only
supported protocol version is 3. Call `Client.open/2` and
`Client.exchange_execution/5`. The shared
[codec](../protocol/lib/overalls_protocol/execution.ex) defines exact shapes.
Reports, outcomes and acknowledgements commit together under the host-row lock.
A malformed report or invalid acknowledgement aborts the whole transaction.

Lilly durably stores validated intent before acknowledging it. Receipt never
proves execution or releases reservations. AshOban/PubSub notifications are
hints; authenticated polling recovers delivery after notification or node loss.

`Marshall.Compute.lifecycle/2` accepts VM ID, start/stop/delete kind and an
idempotency key with a Cedar-authorized actor. This is currently an internal Ash
entry point. Matching physical stop/failure releases compute; matching completed
deletion releases retained storage/address and archives history. Disconnection,
unknown outcomes and stale generations cannot free capacity.

## Executable v3 runtime

Prefer the [NixOS module](nixos.md), which produces the private runtime
configuration and supplies pinned host tools. Every pool requires its actual
ZFS mount root and GUIDs. Example:

```json
{
  "version": 3,
  "control_plane": "https://control.example.test",
  "host_id": "11111111-1111-4111-8111-111111111111",
  "credential_file": "/run/overalls-secrets/lilly-credential.json",
  "state_dir": "/var/lib/lilly/control",
  "cgroup_path": "/sys/fs/cgroup/lilly.slice",
  "images": ["/nix/store/GUEST_IMAGE"],
  "pools": [{
    "id": "22222222-2222-4222-8222-222222222222",
    "path": "/srv/lilly",
    "filesystem_id": "zfs:123:456",
    "storage": {"backend": "zfs", "zpool_guid": "123", "dataset_guid": "456", "dataset": "tank/lilly"}
  }],
  "execution": {
    "state_dir": "/var/lib/lilly/vms",
    "network_state_dir": "/var/lib/lilly/network",
    "egress_interface": "eth0",
    "protected_cidrs": ["203.0.113.0/24"],
    "firecracker": "/nix/store/STATIC_VMM_OUTPUT/bin/firecracker",
    "jailer": "/nix/store/STATIC_VMM_OUTPUT/bin/jailer",
    "dtach": "/nix/store/DTACH_OUTPUT/bin/dtach",
    "unshare": "/nix/store/UTIL_LINUX_OUTPUT/bin/unshare"
  }
}
```

Replace illustrative IDs, GUIDs, networks and store paths with observed and
operator-owned values. A missing storage descriptor is invalid. A pool may carry
only `id`, `path`, `filesystem_id`, `storage`, `max_iops`, `max_iops_source`,
`template_budget_bytes` and `standby_per_image`; any other key, including the
retired `logical_budget_bytes`, fails startup.
LZ4 and zero reservation/refreservation are mandatory; see
[storage accounting](storage-capacity.md). `rootfs.ext4` remains the guest
filesystem inside a sparse file on the owned ZFS child dataset.

Use distinct control/VM/network state directories and the exact guest cgroup
`/sys/fs/cgroup/lilly.slice`. Root owns configuration (0600) and state (0700).
Enable forwarding and reserve Lilly's documented UID/GID and transit ranges.
Executable paths are trusted local static Firecracker/jailer binaries; remote
commands cannot select them. Pool paths must leave room for the jail's Linux
UNIX socket path limit. Private state locks and paused reconciliation prevent
concurrent host ownership and execution before authenticated pool binding.

The [NixOS fleet suite](../nix/tests/machines/fleet/default.nix) exercises actual
ZFS collection, stale-capacity fencing, image disappearance, durable execution,
daemon recovery and revoked authority. The complementary
[jailed guest](../lilly/scripts/smoke_jailed.exs) and
[Marshall-to-Firecracker](../marshall/scripts/smoke_execution.exs) smoke harnesses
require root and disposable ZFS datasets.
