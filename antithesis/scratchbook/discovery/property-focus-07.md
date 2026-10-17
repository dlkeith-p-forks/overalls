---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "07: Distributed Coordination"
status: complete
---

# Property discovery focus 07: Distributed coordination

These five candidates cover shared PostgreSQL host authority across independent Marshall processes, Control credential rotation and notifier loss, and stopped relocation handoff/cancellation. They are proposed test targets, not established guarantees or confirmed defects. The [fresh assertion scan](../existing-assertions.md) found no Antithesis SDK callsites, so every proposed assertion here is **missing**. The scratchbook changes no production behavior, architecture decision, or HLDD contract. ADR-0003, ADR-0141, ADR-0142 and ADR-0155 are the main accepted claims being tested; their partial implementation states are not proof of hosted execution.

### host-session-successor-fences-old-exchanges — Successor host session fence

| | |
|---|---|
| **Type** | Safety |
| **Property** | Once a successor host session commits, an old nonce/session and connection epoch cannot add outcomes, refresh reports or receive new executable commands through another Marshall replica. |
| **Invariant** | `Always` **"Superseded Lilly host session cannot change exchange state or dispatch work"** compares committed rows and host effect IDs after the successor's linearization point; safety must hold at every sampled stale exchange. |
| **Antithesis Angle** | Race session opens and stale replay across two independently pooled Marshall processes, losing replies on either side of commit. |
| **Why It Matters** | An old host connection could resurrect stale command authority. [Evidence](property-candidates-07/host-session-successor-fences-old-exchanges.md); P0, high confidence. |

**Open Questions:** Which safe fixture can hold two real Lilly clients for one host without breaking the host-owner lock?

### host-credential-rotation-fences-old-socket — Rotation fences live Control sockets

| | |
|---|---|
| **Type** | Safety |
| **Property** | After host credential rotation/revocation commits, an already-open socket carrying the archived token cannot make a new domain request effective. |
| **Invariant** | `Always` **"Committed host credential rotation fences old Control request authority"** checks effect rows after the host-lock order is known; a request serialized before rotation may commit first. |
| **Antithesis Angle** | Race old socket request tasks against rotation on separate Marshall replicas, then reconnect old and new credentials. |
| **Why It Matters** | Upgrade-time authentication alone would leave a stale transport with live host power. [Evidence](property-candidates-07/host-credential-rotation-fences-old-socket.md); P0, high confidence. |

**Open Questions:** Can the hosted fixture retain a live Control socket across operator rotation?

### lost-host-hint-eventually-delivers-command — Lost hint recovery

| | |
|---|---|
| **Type** | Liveness |
| **Property** | Given a committed host command, finite notifier/Control isolation and available host/database, Lilly eventually accepts and physically resolves that exact command after healing. |
| **Invariant** | `Sometimes(condition)` **"Committed host command reached Lilly after notifier isolation healed"** requires the semantic accepted-command plus physical-result condition at least once; it does not equate a resync event with progress. |
| **Antithesis Angle** | Drop the cross-replica hint during notifier isolation and allow relay resync and Lilly's periodic exchange to race after healing. |
| **Why It Matters** | Hints are latency aids; losing one must not strand durable work. [Evidence](property-candidates-07/lost-host-hint-eventually-delivers-command.md); P1, high confidence. |

**Open Questions:** Can one Marshall notifier be isolated independently of its Repo and the other replica?

### relocation-handoff-one-current-execution — One current relocation authority

| | |
|---|---|
| **Type** | Safety |
| **Property** | A relocation handoff publishes one destination placement, successor VM execution epoch and activation outbox together, while source and destination do not both exercise current writable execution authority. |
| **Invariant** | `Always` **"Relocation handoff has one current placement epoch and one activation outbox"** checks each committed snapshot and correlates native execution identities; safety must hold across every coordinator replay. |
| **Antithesis Angle** | Race two or three Marshall coordinators, final import delivery and process cuts around the handoff transaction for running and stopped VMs. |
| **Why It Matters** | A split handoff could create two writers or a VM with no activation path. [Evidence](property-candidates-07/relocation-handoff-one-current-execution.md); P0, high confidence. |

**Open Questions:** Which native observer can identify both VMM custody and guest write authority during handoff?

### cancelled-relocation-restores-after-revocation — Cancellation restoration and custody

| | |
|---|---|
| **Type** | Safety and liveness |
| **Property** | Pre-commit cancellation restores source execution only after source revocation and fresh-epoch physical proof, retaining each destination and stream hold until its required receipts; a healable cancellation eventually regains its original state. |
| **Invariant** | `Always` **"Cancelled relocation restores source only after revocation and retains cleanup custody"** checks every settled phase. `Sometimes(condition)` **"Cancelled relocation regained its original source state after physical proof"** requires one finite-fault restoration to complete, so it is a meaningful progress assertion. |
| **Antithesis Angle** | Race cancellation with handoff and lose revocation/stop/start replies across Marshall and Lilly restarts. |
| **Why It Matters** | Premature restart or custody release risks double execution or leaked transfer authority; stalled restoration harms availability. [Evidence](property-candidates-07/cancelled-relocation-restores-after-revocation.md); P0, high confidence. |

**Open Questions:** Can the native fixture cut between source revocation and stop without breaking the owner lock?

## Breadth, overlap and limits

Inspected host-session history, per-request credential validation, Control service/socket/client, PostgreSQL hints and relay, Lilly's periodic exchange/fencing, relocation coordinator, receives, readiness, cleanup, cancellation/restoration, related ADRs and focused/distributed tests. Shared admission atomicity, Control transport replay and Ziggy completion already have independent focus 01/04 candidates, so this focus avoids repeating them. Existing distributed tests use independent Repo pools and several BEAM nodes; the proposed hosted workload must still record actual execution. PostgreSQL is one shared authority here. ADR-0003 explicitly leaves the production HA vendor, failover and 100-node capacity open; these candidates do not invent a database quorum guarantee. Host connection epochs and VM execution epochs are distinct state machines. Service-only runs can prove DB fences and progress to dispatch; native TCG/ZFS/guest observations are required for physical no-dual-writer, stream quiescence and restoration claims. No runtime tests or mutant patches were run for this research-only change.
