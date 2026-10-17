# `authenticated-create-to-retained-guest-file`

**Status:** candidate for catalog synthesis; no implementation or passing run.
**Priority:** P0 for wrong-user custody/lost retained bytes, with P1 usability
impact. **Type:** safety `Always` plus a distinct successful-path `Reachable`
assertion. The [existing-assertions scan](../../../existing-assertions.md)
reports that both planned SDK assertions are missing. Source contracts and ADRs
below state intent; they do not prove current behavior.

## Claim and precise witness

For an authenticated User UUID `U` and create key `K`, a definite successful
create or a later reconciled unknown reply identifies one VM `V` and immutable
request shape. Whenever the workload claims a **usable retained guest** for
that attempt, its fresh authorized personal terminal must be bound to V's
current placement/epoch/physical boot and the GuestAccount UUID/UID reserved
for U. A file written by that shell at `/home/u<uid>/.antithesis-journey/<nonce>`
must have the expected UID and exact unpredictable bytes after `sync -f` has
completed. After an actual VM stop/start and recovery, a **new** authorized
terminal process must reread the same file and UID before an overwrite. The
workload compares its own off-guest expected hash, not an echoed write command
or a database field, and only then may overwrite with another independently
fsynced marker. It must never label a row, a running status, terminal `ready`
reply or command echo alone as guest-file success.

Proposed literal SDK messages, both unique within the current catalog:

- `Always`: **"Authenticated create-to-guest-file success preserves request VM boot UID and fsynced bytes"**. Evaluate for every settled success claim with an explicit boolean joining `U,K,V`, immutable shape, current placement/epoch/boot, GuestAccount UUID/UID, terminal session binding, and the independently reread marker. A selected guest template must evaluate it; a skipped check is a failed reach requirement, not a pass.
- `Reachable`: **"Healed create journey reached fresh guest-file reread after real restart"**. Emit only after at least one recorded fault/reply uncertainty, observed restoration of its affected dependency, a real stop/start with a new boot ID, and a fresh session's exact pre-overwrite read. This is a path/replay anchor, not per-operation liveness or a substitute for the `Always` check.

No `Sometimes(true)` or `Sometimes(success)` is proposed. The latter is
existential across the campaign and cannot prove completion for each accepted
create. A per-attempt progress ledger should record accepted, uncertain,
definitely refused, healed, ready, file-written, restarted and reread states;
after a *measured* post-heal bound, a still-pending attempt is reported
separately. An accepted create during an ongoing partition or a guest that is
not actually bootable is not an immediate liveness violation. A rejected input
must not be promoted to success by a later marker from another VM.

## Primary source path and contracts

| Boundary | Source evidence and implication to test |
| --- | --- |
| Browser identity and create | `marshall/lib/marshall_web/router.ex:91-129` keeps machine and terminal routes in the authenticated LiveView session. `marshall/lib/marshall_web/live_user_auth.ex:31-68,90-112` verifies login at mount/events; `marshall/lib/marshall_web/live/machines_live.ex:110-147` sends parsed shape, `request_key` and `current_user` to `Compute.provision`. A lost UI reply says nothing about commit. |
| Durable admission | `marshall/lib/marshall/compute/admission.ex:34-82,143-202,228-270` locks owner/key, compares request shape, selects a fresh capable host, and creates joined allocation/operation rows. `marshall/lib/marshall/compute/virtual_machine.ex:400-454` stores key and owner identity. Read these through authorized domain projections plus read-only snapshot; do not write rows or bypass Ash to drive the SUT. |
| Physical start and readiness | `lilly/lib/lilly/vm/driver.ex:368-420,486-545` uses retained disk on restart, prepares a new boot on stopped start, and rechecks the exact boot around guest readiness. `lilly/CONTRACTS` requires VM lifetime independent of Lilly and physically confirmed execution. A modeled actor receipt is insufficient. |
| Durable personal UID | `marshall/lib/marshall/accounts/guest_accounts.ex:10-18,65-96` allocates a permanently reserved UID; ADR-0158 specifies `u<uid>` and `/home/u<uid>`. `marshall/lib/marshall/terminal/authority.ex:8-63,93-111` obtains that account for the authenticated actor under Cedar write authority, and `marshall/lib/marshall/terminal/creation.ex:10-67,96-145` reserves and settles one opening. |
| Actual guest process and file | `nix/domains/artifacts/terminald/src/session.rs:226-267,816-826` calls the account helper and spawns a PTY for the resolved user; `nix/domains/artifacts/terminald/src/pty.rs:113-135,186-257` sets passwd UID, HOME and cwd before exec. The file/UID/hash and exit status must come from the guest, then from a distinct process after restart. |

The related accepted decisions are ADR-0017 (durable actor/physical ownership),
ADR-0022 (live login), ADR-0083 (terminal stream/registry), ADR-0117 as carried
forward through ADR-0125/0158 (personal terminal and permanent guest identity),
ADR-0140 (inconclusive database loss), and ADR-0158. Their historical native
evidence remains revision-specific. Relevant source contracts are root
`CONTRACTS` (`repository-test-claim-boundary`), `marshall/CONTRACTS`,
`marshall/lib/marshall/CONTRACTS`,
`marshall/lib/marshall/compute/CONTRACTS`,
`marshall/lib/marshall/terminal/CONTRACTS`,
`marshall/lib/marshall_web/CONTRACTS`, and `lilly/CONTRACTS`.

## Actions and independent oracle

1. Seed one synthetic active account through the normal supported account path, complete login/MFA, and preserve `U`, login identity, `K`, exact OSS/NixOS image/profile/shape and independent nonce in a workload-owned append-only ledger. Use the actual browser route. Select a capable image/host; an unavailable image or capacity is a definite refusal branch, not a failed usability witness.
2. Send create once through `MachinesLive`; interrupt the LiveView response or Marshall A while the admission transaction may commit. Record **unknown** if no definite response. Read back through authorized VM list/detail on Marshall B and a read-only consistent database projection, compare owner/key/shape/VM/placement/reservation/address/operation, then resend the identical browser request with K if needed. Never generate K anew for retry and never infer absence from a timeout.
3. After the exact currently running boot is independently observable, open a personal browser terminal with the original authenticated U. Compare the terminal's VM/session placement and epoch, the stored GuestAccount UUID/UID and the actual guest's `id -u`, `pwd` and file owner. Do not accept root, a client-selected guest name or a different VM. Observe the guest boot UUID/challenge and QEMU/backend identity before command execution.
4. In that shell create only a bounded synthetic file in the personal home, write a random marker, run `sync -f <file>` (or a verified per-file `fsync` helper available in the image) and require a zero status **after** the sync. Keep the expected bytes/hash in the off-guest ledger. Read via a separately opened shell/process once immediately; do not compare with a shell's echoed command.
5. Submit normal stop and start via the authenticated machine controls, inject a Lilly or guest-vmm restart at the relevant boundary, then wait for *new* boot readiness and healed Marshall/Lilly/terminal dependencies. Retain the same disk/overlay identity and U/GuestAccount/VM, allow the boot UUID to change, and require fresh terminal authority bound to the new boot. Reread the original marker and `stat` UID through this new process **before overwriting it**. Only after that read succeeds, write/sync a second marker and optionally make a third fresh read. A missing or wrong byte, wrong UID, lost overlay or wrong boot association fails the safety assertion if the journey was claimed successful.
6. Emit the `Always` evaluation on every claimed full success and on any contradictory settled observation; include only opaque IDs, booleans and hashes in test-private assertion details, never terminal bytes, tokens or payloads in SUT diagnostics. Emit `Reachable` only at the complete healed-fault fresh-read point. Preserve separate ledger entries for an inconclusive read or dependency outage; never convert those to a clean success or a proved absence.

Fault menu: lost create reply; Marshall A kill/restart while B continues over
one PostgreSQL primary; short PostgreSQL outage before or after admission commit;
Lilly Runtime restart before/after attempt and readiness receipts; delayed
Control delivery/ack; guest-vmm stop/reboot with retained overlay; terminal
creation reply loss and browser reconnect. Verify each fault is actually
applied and later healed before invoking a progress budget. Do not silently
skip a selected fault branch. Keep host reports, account roster and private
trust services real for the chosen template; they are preconditions, not
fabricated success responses.

## Environment and relation to catalog

The selected hosted configuration is `guest-journey`/`guest` plus real
`control-core` services, Marshall A/B, Lilly, Audi for private ingress/roster,
source-built browser/terminal path, and a q35 TCG `guest-vmm` with persistent
qcow2 overlay and actual vsock readiness/trust/terminal protocols
(`deployment-topology.md:88-126`). `control-core` can exercise admission
idempotency but cannot satisfy the file witness. Keep the lower executor typed
and compile-time harness-only as the topology requires; never create a fake
`running` receipt or fake terminal output. A native NixOS machine campaign
must repeat the journey to claim Firecracker/KVM, ZFS, jail, actual host UID and
systemd custody; Ubuntu and Customer profile are separate explicit selections.

This candidate composes but does not replace `marshall-admission-atomic-allocation`,
`marshall-admission-key-survives-archive`,
`guest-readiness-binds-current-physical-boot`,
`guest-identity-never-transfers-on-email-reuse`,
`terminal-create-reply-loss-one-pty`, and
`stop-retains-disk-until-restart`. Each can pass while the new full path cannot
reach a writable, retained guest file. The oracle's tuple join is the distinct
claim. Historical `nix/verification/tests/machines/zfs-guest/probe.exs:501-507` uses a
guest-written marker plus sync/readback pattern; it is a design precedent,
not passing evidence for this combined candidate.

## Open questions and investigation log

### Open questions

- Can a browser driver preserve one hidden create key through a lost LiveView reply and retry against Marshall B without changing the submitted shape? A fresh key would test another request, invalidating the idempotency portion.
- What exact read-only projection exposes the authoritative owner/key/VM/placement/epoch/GuestAccount tuple at the same snapshot as the journey ledger, and how is it tied to QEMU boot ID without trusting a stale UI row?
- Can the planned TCG image and browser-terminal path complete normal stop/start with persistent overlay, fresh boot and second personal terminal within a measured test budget? If not, hosted scope must report infeasible and native evidence cannot be inferred from it.
- Which selected fault and observed restoration point define the post-heal deadline for each attempt? Without those, report pending/inconclusive rather than universal per-op liveness.

### Investigation log

These questions remain untagged because no hosted image or browser driver has
been built in this research task. Source review establishes the path and
necessary identities, but execution feasibility and timing require the later
template smoke test. No defect is claimed.
