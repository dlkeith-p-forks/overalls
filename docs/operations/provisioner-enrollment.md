# Protected provisioner enrollment

Marshall's operator commands create disabled hosts and storage pools and export
credentials to private files. Lilly reads these files at startup. See
[ADR-0025](../architecture/decisions/0025-protected-provisioner-enrollment.md).
Commands require administrative access to the release, database and encryption
keys. They are not public APIs and print only public identities and metadata.
Run them with `eval` in a separate process, never through `rpc` or an existing
serving node's console. The command starts only persistence, encryption and
authorization services; it does not bind web ports or run background queues.
Production commands also require the shared database TLS, replica/connection
budget and instance identity settings in the [deployment guide](deployment.md).
Set `PHX_SERVER=false` for a standalone operator process.

## Prepare and enroll

Follow the [v3 host prerequisites](provisioner-transport.md#executable-v3-runtime).
Using `bin/lilly eval`, inspect `Lilly.Host.Identity.read()` and
`Lilly.Host.Pool.inspect_path("/your/guest/pool")`. These return the application
machine hash and native ZFS GUID identity. Supply the pinned host tools in the
trusted service PATH. Enrollment does not create physical prerequisites.

On Marshall, prepare an existing directory owned by the operator/service account,
mode 0700, on a local durable filesystem. Ancestors must be root- or service-owned
and not writable by others, except protected sticky directories such as `/tmp`.
Store this request in a regular, single-link file owned by that account, mode 0600:

```json
{
  "version": 3,
  "name": "lilly-host-01",
  "architecture": "x86_64",
  "machine_id": "sha256:REPLACE_WITH_64_LOWERCASE_HEX_DIGITS",
  "overhead_cores": 1,
  "overhead_memory_bytes": 1073741824,
  "credential_ttl_seconds": 157680000,
  "pools": [
    {
      "name": "guests",
      "storage": {
        "backend": "zfs",
        "zpool_guid": "123",
        "dataset_guid": "456",
        "dataset": "tank/lilly"
      },
      "overhead_bytes": 1073741824
    }
  ]
}
```

GUIDs above are illustrative: use the observed GUIDs. Only ZFS pools and
provisioner v3 are supported under [ADR-0035](../architecture/decisions/0035-zfs-only-provisioning.md).
All fields are required. Names start with an ASCII letter/digit and contain at
most 128 letters, digits, `_`, `-` or `.`. Enroll 1–64 pools with distinct names
and filesystem IDs. Lifetime is 1 second to five 365-day years (157680000 seconds). Overheads are capacity
deductions; evaluate the example values for the intended host and workload.
Pools carry no logical budget: Lilly refuses one in its configuration and session
pools, and Marshall refuses an enrollment pool carrying the retired
`logical_budget_bytes` (or any other unknown key) with `invalid_enrollment_request`
([ADR-0159](../architecture/decisions/0159-remove-legacy-compatibility.md)).

For hosts intended to participate in relocation, also include
`transfer_endpoint` in the enrollment request:

```json
{
  "transfer_endpoint": {
    "address": "lilly-host-01.example.net",
    "port": 2222,
    "host_key": "ssh-ed25519 REPLACE_WITH_CANONICAL_PUBLIC_KEY_BLOB"
  }
}
```

Obtain that public key through the authenticated operator channel for the
intended dedicated transfer service. The record accepts only lowercase DNS names
or canonical IP literals, a port from 1 to 65535, and an Ed25519 public key without
comments or authorized-key options. No key discovery or trust-on-first-use occurs.
The example key is a placeholder and is rejected until replaced.

Omitting the record leaves a host ineligible for relocation; ordinary provisioning
still uses its existing readiness and capacity checks. The pin is retained across
control-credential rotation and cannot be changed by host reports, sessions or
ordinary admission configuration. Enrollment alone does not deploy an SSH service,
prove connectivity or grant an export permit. The dedicated service and coordinated
transfer workflow remain under implementation in
[ADR-0037](../architecture/decisions/0037-workload-placement-and-relocation.md).

With the release's protected environment loaded:

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' enroll /private/request.json /private/host-01.json
bin/marshall eval 'Marshall.Operations.CLI.main()' verify /private/host-01.json
bin/marshall eval 'Marshall.Operations.CLI.main()' show lilly-host-01
```

Use absolute canonical paths; symlinks are rejected. The output must not exist.
Its parent must be mode 0700. The file becomes mode 0600 before credentials are
written; data and directory entries are synced before database commit. Results
include host/pool IDs, credential ID and expiry, never the token. The host starts
disabled with unknown capacity. Repeated names or machine identities do not
silently update existing hosts. Keep keys and credentials out of command arguments.

## Install and activate

After issuance and verification succeed, transfer the file through your
authenticated administrative channel. Install it on Lilly as a root-owned,
single-link regular file, mode 0600, under trusted directories. Use the returned
public IDs in the [complete v3 configuration](provisioner-transport.md#executable-v3-runtime),
and add this field:

```json
{"credential_file": "/etc/lilly/host-01.json"}
```

Remove the inline `credential` field; supplying both fails startup. Keep the full
configuration root-owned and mode 0600. The envelope must match `host_id`; v3
authenticates the physical machine identity through the existing protocol.
Start Lilly with `LILLY_CONFIG_FILE`. Once it reports current execution readiness:

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' enable HOST_UUID
```

Enabling requires a fresh v3 `execution_ready` report. Every admission still
checks images, capacity, reservations and freshness. `disable HOST_UUID` stops
new admission/start eligibility. It does not stop guests, delete disks, release
reservations or implement a complete drain workflow.

## Rotate and revoke

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' rotate HOST_UUID 157680000 /private/host-01-next.json
bin/marshall eval 'Marshall.Operations.CLI.main()' verify /private/host-01-next.json
bin/marshall eval 'Marshall.Operations.CLI.main()' revoke HOST_UUID
```

Rotation immediately archives old authority and invalidates observations/sessions.
Install the new file, update `credential_file` if needed and restart Lilly with
its original bound state. Files are read only at startup. Rotation intentionally
interrupts authenticated control until installation/restart; VMMs and reservations
remain. Revocation issues no replacement. A lost file can be replaced by rotating
to a new path after confirming host identity through `show`. Revocation, not
deleting a local copy, removes authority.

## Recover uncertain results

PostgreSQL and files are separate storage systems. Crashes or rollback can leave
an empty/inactive file; a lost response after commit can leave an active file.
Failures retain artifacts and never overwrite an existing output. Verify first:

- Success returns current public metadata. It does not prove Lilly received the
  credential or that execution is ready.
- `credential_inactive`: the presented credential is not currently accepted.
- `invalid_credential_file`: contents or binding are invalid. This does not prove
  that a credential inside a damaged file has been revoked.
- `verification_unavailable`: database/key authority could not be checked.
  Retain the file and restore correct database/key access; do not infer inactivity.

Use `show NAME` to recover IDs after a lost enrollment response. Do not delete the
only copy or blindly retry during uncertain verification. Verification can become
stale immediately after rotation, revocation or expiry; exchanges always perform
fresh authentication. Secret-store custody, transport and rotation scheduling
remain deployment responsibilities.

Do not discard an output while its issuing process or database transaction may
still be running: a concurrent commit can also change a negative verification
result. Resolve the outstanding operation or revoke the identified host's
authority before treating that artifact as obsolete.

For host-wide stop, guarded resume and permanent empty-host retirement, see
[host maintenance](host-maintenance.md). `show` also reports maintenance mode and
the open drain ID. Enable cannot bypass maintenance; retired hosts cannot rotate
credentials.
