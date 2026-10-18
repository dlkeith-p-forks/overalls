# Live Porsche acceptance

The opt-in [runner](../../scripts/porsche_acceptance.py) exercises the live SSH
management service and creates real VMs. It excludes all three sharing verbs.
Run it on the provisioner/control-plane host: physical verification uses read-only
sudo access to PostgreSQL, systemd, processes and ZFS. The native checks currently
target the Overalls database `marshall` and dataset `zroot/lilly`.

## Private setup

Create a mode-0700 directory outside Git with a unique name of the form
`porsche-YYYYMMDD-HHMMSS`. Place these files inside it:

- `run.json`: `{"run":"porsche-YYYYMMDD-HHMMSS","host":"ghuntley.dev","account":"YOUR_ACCOUNT_EMAIL"}`.
- `primary` and `primary.pub`: a dedicated Ed25519 key pair.
- `disposable` and `disposable.pub`: a second dedicated pair for revocation tests.
- `known_hosts`: Porsche's host key, verified against its trusted local public
  key at `/var/lib/porsche/keys/ssh_host_ed25519_key.pub`.

Keep private keys mode 0600. Register both public keys for the intended account
using Marshall's `SSH.add_key` Ash action from the configured operator release.
Use sudo for that bootstrap; do not install these keys in OpenSSH's
`authorized_keys`. Porsche selects the account from the key registration.
Administrative OpenSSH remains on 2222; the runner targets Porsche on 22.

## Run phases

Pass the private directory as the first argument, followed by each phase in order:

```text
inventory
create
running
physical-running
scenarios
automation
stop
physical-stopped
start
physical-restarted
cleanup
physical-deleted
reuse
```

For example:

```sh
python3 scripts/porsche_acceptance.py /private/porsche-20260918-012013 inventory
```

Creation uses five workers and stable request IDs for 50 named machines. Admission
conflicts use bounded backoff with identical commands; all rejected attempts remain
in the evidence. Other unexpected failures stop the phase. Physical lifecycle
failures are not converted into successes by retrying or observing later recovery.

`scenarios` covers help, lookup, duplicate names, conflicting requests, pinned
replay and interactive exit. `automation` uses one additional generated-name VM
with explicit image/profile/shape, a one-second timeout, a disconnected client and
disposable-key revocation. It deletes that VM. `reuse` creates and deletes one
replacement after fleet cleanup, checking that old requests retain their original
UUIDs. The explicit automation shape is 1 vCPU, 512 MiB RAM and 2 GiB disk, matching
the deployed NixOS image's minimums in this acceptance run.

## Operating-system matrix

The separate `matrix-*` phases create one `oss` VM per selected OS using explicit
immutable catalog image IDs. The default selection requires all seven families:
`nixos`, `ubuntu`, `arch`, `almalinux`, `freebsd`, `omnios` and `windows`.
The [current matrix](../guests/os-matrix.md) records the admission and runtime
limits. OmniOS is currently unadmitted, so a default seven-OS preflight must fail;
do not substitute another image or silently omit its row.

Add `matrix.json` to the same private run directory:

```json
{
  "cli": "/absolute/path/to/overalls",
  "ssh_config": "/private/porsche-20261018-120000/guest_ssh_config",
  "known_hosts": "/private/porsche-20261018-120000/guest_known_hosts",
  "images": {
    "nixos": null,
    "ubuntu": null,
    "arch": null,
    "almalinux": null,
    "freebsd": null,
    "omnios": null,
    "windows": null
  }
}
```

Replace each available row's `null` with its reviewed `sha256:` catalog ID from
`images --json`; retain `null` for unavailable images. All seven keys are required
even for a subset, and non-null IDs must be distinct. Preflight requires the
exact expected display name for each selected ID and the intended `whoami`
account. A missing image or name mismatch refuses before creating any matrix VM.

The CLI must be executable. Its path and the two guest SSH files must be absolute,
existing files without group/other write access. Use the installed Overalls CLI
and reviewed SSH configuration for the target deployment. The guest known-hosts
file must trust its verified SSH host CA; it is separate from Porsche's management
host key. The runner uses the dedicated primary key and the current personal
`guest_username` returned by `whoami`; it refuses `root`. Guest access uses
`overalls ssh` with strict host verification, bounded transport timeouts and no
interactive input. Keep these files and evidence outside Git.

Run these phases in order, passing the private directory first as above:

```text
matrix-inventory
matrix-create
matrix-ssh
matrix-stop
matrix-start
matrix-ssh --stage restarted
matrix-cleanup
```

For an explicitly scoped run, repeat the same `--os` selection on every phase:

```sh
python3 scripts/porsche_acceptance.py /private/porsche-20261018-120000 matrix-inventory --os nixos --os ubuntu
```

Report such a run as that subset. `matrix-create` repeats inventory preflight,
creates sequentially and retains exact image IDs, names, profile, canonical
UUIDs, SSH endpoints and original request IDs in durable intents/receipts.
The accepted UUID is saved before waiting for creation to finish. Failed or
superseded terminal receipts remain bound to that same UUID for reconciliation
and owned cleanup; they are reported as failures. A transport failure cannot
stand in for such a receipt or justify another create request.
Before new lifecycle mutations or guest access, it rechecks current ownership
and each receipt binding. A changed name, owner, image, profile or endpoint
refuses. Polling is bounded to 900 seconds per request and preserves the original
request ID. Resume with the same directory and stage; use a new `--stage` only
for an intentional new lifecycle cycle.

The SSH oracle requires Linux plus the exact distribution ID, FreeBSD 14.3,
SunOS plus OmniOS r151050, or the pinned Windows Server 2025 Standard Evaluation
build 26100. A zero SSH exit status or catalog label alone does not pass. Evidence
retains output byte counts and SHA-256 digests rather than raw guest stdout or
stderr. Immutable attempt records preserve prior outcomes; the latest stage
summary records `verified=false` on failure, including a failed rerun after an
earlier success.

These phases establish only their recorded catalog, request, SSH identity and
lifecycle outcomes. They do not perform the existing 50-VM physical snapshots or
prove native kernel attestation, terminal/workspace behavior, isolation, storage
growth, physical durability or multi-host recovery. No live seven-OS acceptance
execution is recorded by adding this runner.

## Resume and evidence

The directory contains append-only command evidence, create intents, receipts,
physical snapshots and phase results. Retry `create` with the same directory to
recover uncertain creation outcomes. Repeat a lifecycle phase with its original
request IDs to reconcile accepted work. Use `--stage NEW_LABEL` only for an
intentional new stop/start cycle, such as verification after a deployed fix.
Do not silently replace a failed request with a fresh ID.

If interrupted during `automation` or `reuse`, inspect their saved intents and
receipts and reconcile the original request before continuing; these compound
scenarios are not automatically restartable at every intermediate step.

Successful JSON commands require both zero exit status and a valid result.
Malformed command syntax currently produces text errors even when the rejected
input contains `--json`; the runner records this distinction. SSH transport failure
does not count as a successful negative test. Approval links from revoked-key
attempts are redacted before evidence is written.

Preserve failure evidence and delete only UUIDs tied to this run's receipts.
The primary key remains available for operator reuse. Remove fixture databases
used for application tests separately; they are not part of the live VM workflow.
