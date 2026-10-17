# Live Porsche acceptance

The opt-in [runner](../scripts/porsche_acceptance.py) exercises the live SSH
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
