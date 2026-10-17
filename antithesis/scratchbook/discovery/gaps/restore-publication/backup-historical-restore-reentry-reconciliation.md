# backup-historical-restore-reentry-reconciliation — Deferred positive reentry candidate

P1 policy gap; **not yet promotable to an SDK assertion**. The proposed eventual
property is: after a deliberately isolated restore is explicitly approved for
serving, a durable reconciliation receipt must bind all retained identity and
execution axes before any restored authority serves traffic or allocates a new
guest identity. A future primary `Always` could use the unique literal message
**"Restored backup authority serves only after retained identity reconciliation"**,
but only once an implementation defines the receipt and activation transaction.
No callsite exists in the [fresh Antithesis scan](../../../existing-assertions.md).

## Why this is distinct from quarantine

`backup-time-skew-never-activates-historical-authority` already checks the
negative boundary: a mixed-time restored graph stays isolated from live fleet
authority. It does not promise that an operator can eventually activate that
graph. `nix/modules/backups/runtime.py:313-345` restores numbered component
directories and writes a final `manifest.json`; it has no activation or claim
operation (`:252-267`). A valid marker proves byte restoration, not safe
serving. ADR-0070 requires old-node fencing and explicit reconciliation before
traffic (`docs/architecture/decisions/0070-host-recovery-backups.md:86-102`);
ADR-0158 explicitly says an older database alongside newer retained guest disks
is unsupported until guest UUID/UID reservations and sequence are reconciled
against **all retained state**, and adds no automatic repair
(`docs/architecture/decisions/0158-durable-guest-identities.md:106-110`).

## Proposed receipt and oracle, pending policy

A safe reentry design would need a named, durable receipt that binds the selected
manifest ID and repository/host identity; verified restored DB identity and
sequence; all live and retained GuestAccount UUID/UID/home reservations; every
retained guest disk/drive GUID and owner; old-node fencing evidence; current
Lilly host binding, physical boot and execution epochs; and endpoint ownership.
The receipt must be invalidated by any change to those inputs before serving.
This is an investigation checklist, **not a claim that such a receipt exists**.

An independent future oracle would inventory the live fleet and retained disks
outside the restored DB, reconcile UUID/UID sets and sequence, observe actual
old-node process/endpoint fencing, then watch a selected synthetic customer
login/guest action through the newly serving endpoint. It would check that no
UID/home or disk GUID gets reassigned and that only the reconciled current
execution can serve. A historical `manifest.json`, a successful `pg_restore`, or
an operator-mode Marshall process alone cannot satisfy it. Faults would target
receipt persistence, lost activation reply, a later-created UID on the survivor,
stale host binding, and old endpoint revival. This requires a fenced, isolated
multi-host native drill and explicit product policy. Do not inject an older DB
into a production primary to obtain a reach witness.

## Open questions

- What is the authoritative receipt/transaction for activation, and which
  component signs or verifies it? `(needs human input)`
- How are all retained, possibly offline, guest UUID/UID and disk GUID claims
  enumerated before advancing the restored sequence? `(needs human input)`
- What exact serving action is authorized after reconciliation, and what old-node
  fencing proof is required? `(needs human input)`

### Investigation Log

#### What is the authoritative receipt/transaction for activation, and which component signs or verifies it?

- Examined: `nix/modules/backups/runtime.py:252-345`, ADR-0070, ADR-0158,
  `docs/backups.md:313-350`, existing
  `backup-time-skew-never-activates-historical-authority` evidence.
- Found: a restore-target marker and manual operator guidance only; ADR-0158
  explicitly disclaims automatic historical repair.
- Not found: a source-defined activation command, receipt schema, owner or
  signature/transaction boundary.
- Conclusion: needs product/design input before asserting successful reentry.

#### How are all retained, possibly offline, guest claims enumerated before advancing the restored sequence?

- Examined: ADR-0158 `:99-110`, backup manifest component sequence in
  `runtime.py:122-225`, and the mixed-time backup property evidence.
- Found: restored DB sequence alone cannot establish that later UIDs are unused;
  component captures occur at different times.
- Not found: an external reservation registry or all-retained-disk census and
  reconciliation operation.
- Conclusion: needs a policy and implementation that names the independent
  inventory. An isolated negative quarantine assertion remains valid now.

#### What exact serving action is authorized after reconciliation, and what old-node fencing proof is required?

- Examined: ADR-0070 `:86-102`, `docs/backups.md:313-350`, backup runtime CLI
  operations and the topology's native KVM boundary.
- Found: manual fencing and isolated recovery instructions; no automatic serving
  operation on a restored target.
- Not found: a testable activation linearization point and acceptable fencing
  proof for old-node versus disconnected-node histories.
- Conclusion: needs product/design input. Do not turn a generic recovery drill
  into a positive activation liveness claim.
