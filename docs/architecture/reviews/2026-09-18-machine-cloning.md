# Queued machine cloning

## Scope and architecture impact

The authorized change adds independently owned machine copies to the Compute Ash
model, durable AshOban execution, Porsche commands, and Marshall's machine page.
[ADR-0055](../decisions/0055-queued-machine-cloning.md) records the decision.
It extends [ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md),
[ADR-0018](../decisions/0018-persisted-sharing-and-user-machine-access.md),
[ADR-0037](../decisions/0037-workload-placement-and-relocation.md),
[ADR-0046](../decisions/0046-porsche-ssh-management.md) and
[ADR-0053](../decisions/0053-vm-disk-limit.md) without changing relocation handoff
or ordinary lifecycle ownership. No backward compatibility is required: release
Marshall, Lilly and the shared protocol together.

Queue admission reserves identities only. Under source advisory serialization,
activation rechecks current access, stable source state, host freshness and
capacity. Sorted host locks precede VM locks. Native uncertainty retains resource
holds. Distinct keys queue distinct destinations; identical keys retain one
request, destination and job. Publication serializes with cancellation and grants
ordinary destination lifecycle authority. Source destruction remains excluded
until its owned snapshots are reclaimed.

The final integration includes origin/main's newly landed Inception profile
(ADR-0054). Its multi-disk transfer path is intentionally unavailable. Cloning
preserves that boundary in public admission, activation and the closed protocol,
with a visible UI explanation and a no-effects regression. The cloning decision
was renumbered to ADR-0055; both native fixtures retain distinct guest identities.

## Findings and resolutions

- **High, snapshot cycle identity (ADR-0037/0055):** relocation's snapshot index
  required an increased execution epoch for each new transfer. Repeated clones
  retain the source placement and epoch. The index now persists explicit clone
  purpose and allows the same epoch only across a clone transition, with a new
  transfer ID and a fully retired predecessor. Current driver generation checks,
  immutable snapshot GUIDs and historical tombstones remain required. The index
  regression covers repeated clones, stale retirement, and later relocation.
- **High, imported disk UID (ADR-0017/0055):** a received clone retains the source
  slot's host UID. Native adoption originally rejected that disk. Before
  publication, the importer now checks the exact admitted source UID plus regular
  file, single-link, size and directory ownership, then rebinds to the new slot.
  Ready disks still require destination ownership. Arbitrary received UIDs are
  not accepted.
- **High, stopped-source capture race (ADR-0055):** an initially stopped source
  must remain lifecycle-fenced until its immutable capture is retained, even
  though it needs no restart. The coordinator regression verifies a premature
  Start fails and Start after capture succeeds without changing the snapshot.
- **High, durable command identity (ADR-0017/0055):** the native fleet exposed
  a source restart rejected because `clone_id` was treated as placement identity.
  The store now treats clone readiness metadata like resize readiness metadata.
  New generations and distinct operation IDs remain required, and resource or
  identity changes remain rejected. The regression covers store reopen, replay,
  stale delivery, restoration and subsequent ordinary lifecycle.
- **High, restart capacity (ADR-0037/0055):** ordinary running coverage before
  capture must not settle the future source restart reservation. Startup-hold
  settlement now observes the clone lifecycle fence; a PostgreSQL regression
  proves the hold survives until restoration.
- **High, stopped destination evidence (ADR-0017/0055):** publication of a stopped
  copy issues a real lifecycle Stop and waits for its outcome. A fabricated
  observation would leave Lilly unaware of the adopted placement and make later
  coverage or deletion unreliable.
- **High, delayed cancellation work (ADR-0017/0055):** local copy and adoption
  recheck permanent destination key retirement under receive ownership. Local
  pipelines also enforce the source lease with monotonic expiry; bypassing SSH
  does not bypass revocation. Capture creation serializes with export revocation.
  Cancellation acknowledges cleanup only after both endpoints are quiescent.
- **Medium, replay and recovery (ADR-0017/0055):** out-of-order jobs cannot fail a
  different queue head. Failed source restart retains compute and snapshot holds;
  explicit retry issues a new generation without recapturing. Later user lifecycle
  intent is never overwritten. Destination initial-start failure or supersession
  does not leave snapshot cleanup waiting on an impossible running receipt.
- **Medium, late receipts (ADR-0017/0055):** previously offered, correctly bound
  receipts arriving after cancellation are retained as evidence, without reviving
  publication. Unoffered, wrong-session and conflicting receipts are rejected.
- **Medium, transient native failures (ADR-0046/0055):** unconfirmed effects remain
  durable retryable work, with a bounded public error. They do not prematurely
  fail a Porsche wait. Terminal source restart failure requires explicit retry;
  a published destination uses ordinary lifecycle recovery.

- **Medium, CLI conflict reporting (ADR-0046/0055):** the native setup exposed
  Porsche collapsing explicit capacity refusal into a generic HTTP conflict.
  A closed response vocabulary now preserves capacity and clone refusal reasons
  as command errors. Unknown bodies remain generic, and no automatic resubmission
  is added. HTTPS and command-runner regressions cover the boundary.

- **Medium, cancellation receipts (ADR-0046/0055):** the original clone receipt
  becomes superseded when cancelled, while the explicit cancellation command
  succeeds only after the durable cancelled state. Separate receipt assertions
  prevent successful cancellation being presented as a failed command.

## Verification

The code-contract review examined admission, current authorization, lock ordering,
placement/capacity, snapshot ownership, import UID rebinding, permanent retirement,
lease expiry, protocol discriminators and publication boundaries. Contract syntax
checks are only structural; PostgreSQL and native tests supply separate evidence.

The pinned Elixir 1.20.4/OTP 29 gates passed:

- Marshall: 581 passed (60 properties, 521 tests), including the three-node
  concurrency test; strict Dialyzer passed with its one existing exclusion.
- Lilly: 294 passed (31 properties, 263 tests), strict Dialyzer passed.
- Shared protocol: 118 passed (43 properties, 75 tests), strict Dialyzer passed.
- Porsche: 60 passed (8 properties, 52 tests), strict Dialyzer passed.
- Ash migration generation in check mode passed against isolated PostgreSQL.

The complete `zfs-guest` native ZFS/KVM suite passed (1,203 seconds), including
isolation, crash recovery, resize and Inception sparse-drive lifecycle regressions.
Its clone scenario covers capture, source restart during copy, exact replay,
adoption across distinct slot UIDs, cleanup and cancellation, independent guest
writes, and a working clone after source deletion.

The dedicated `cloning-fleet` passed (407 seconds) with three Marshall nodes,
two Lilly hosts, PostgreSQL, a TLS proxy, native SSH and Chromium. It verifies
cross-host copying, idempotent Porsche replay, a second clone through the browser,
request-key retention across reload, private copies, and both copies booting with
the expected guest data after source deletion. All operations use the real
Ash/Oban/control/guest path; no physical outcomes are injected.

Drivers were built with `nix build .#checks.x86_64-linux.zfs-guest.driver` and
`nix build .#checks.x86_64-linux.cloning-fleet.driver`, then executed with KVM and
isolated runtime directories. Native tests use disposable machines and synthetic
guest data. Unit tests do not stand in for physical disk evidence.

Final integration preserves the subsequent origin/main Audi acceptance update:
application code is unchanged by that update, its fleet additions are conditional
on Audi (disabled in the clone check), and the merged clone driver builds and passes its type check.
ADR structure/link validation and code-contract checks pass. No unresolved
code/contract violation was found in the reviewed clone scope; this is not an
exhaustive platform audit or evidence of every possible storage failure.

## Remaining limits

Host/storage loss or unconfirmed physical cleanup retains reservations and transfer
slots until the host can prove cleanup. Guest disk contents include stored guest
credentials; the UI states this before submission. There is no RAM snapshot or
application-aware quiescing. Inception cloning remains unavailable until its multi-disk transfer path is
verified, consistent with the new profile's existing transfer restriction.
