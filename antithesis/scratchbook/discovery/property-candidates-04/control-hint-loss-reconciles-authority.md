# control-hint-loss-reconciles-authority

Priority: P1. Confidence: medium; source backstops are visible, composed hosted progress untested. Type: Safety plus conditional liveness.

## Guarantee and proposed assertions

A hint is only a prompt to re-read durable authority; duplicate/stale/forged hints cannot authorize an effect. After a committed change and finite notifier/socket obstruction, a healthy subscribed reader eventually observes current authority through resync or its backstop. Use `Always(hint_never_substitutes_for_authority_read, "Control hints cannot authorize an effect without fresh durable authority")` at each effect boundary. Use `Sometimes(reader_reconciled_after_hint_loss, "Control reader reconciles committed authority after lost hint")` only in a scenario that commits a change, restores transport/database availability and keeps the real reader cadence alive. These unique assertions are missing per `../../existing-assertions.md`.

## Evidence and failure history

- `marshall/lib/marshall/control/hints.ex:5-16,60-76,91-105,126-148` documents transactional notify, closed payloads, local fanout and forced resync. `marshall/lib/marshall/control/socket.ex:70-74,150-165` sends hints only after identity binding and subscribes to resync.
- `lilly/lib/lilly/control/link.ex:31-45` wakes Runtime for host commands while periodic exchange remains; `ziggy/lib/ziggy/control/link.ex:31-47` wakes claim work while periodic poll remains; `audi/lib/audi/control/link.ex:31-50` wakes registered local readers and leaves their cadence intact. `galileo/lib/galileo/control.ex:78-81` currently has no pushed state, so Galileo is excluded from this push property.
- Accepted ADR-0141/0142 describes hint semantics. No current failing reproduction or closed issue is established; transient notifier absence is an expected fault, not itself a defect.

## Fault history, independent oracle and workload

Commit a fixture authority change in PostgreSQL, suppress its notifier delivery or sever the bound socket, then deliver duplicates, stale IDs and malformed/foreign hints while retaining real reader supervision. Observe actual effect admission, independently query committed DB revisions, and require the reader's request ledger to show a post-change full authority read before any newly authorized effect. For revocation, try the forbidden effect after the existing lease deadline; do not claim instantaneous revocation before the allowed lease expires. Restore finite faults and observe a fresh query and reconciled state without issuing a new mutation. A positive sentinel read proves the reader is alive.

Parameter menu: commit/rollback; dropped/duplicated/reordered hint; notifier restart and `resync_local`; socket reconnect; Lilly commands, Ziggy work, Audi gateway catalog and stream lease; one/all subscribers. Bound progress by each real reader's configured cadence plus a generous fault-recovery window, not an invented global deadline. Branch anchors at notifier relay recovery and reader full-read completion can guide replay without storing credentials or payloads. Hosted real PostgreSQL/BEAM service scope; native effect or guest access needs separate witness. No mutant or hosted result.

## Open Questions

- What exact cadence bound should each reader use after a lost hint? The links confirm a backstop exists, but this candidate does not assign one shared timeout across components.
