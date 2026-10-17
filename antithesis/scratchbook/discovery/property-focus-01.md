---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "01 — Data Integrity"
status: complete
---

# Property discovery focus 01: Data integrity

Read the fresh [SUT synthesis](../sut-analysis.md), [existing-assertions scan](../existing-assertions.md), source contracts and relevant ADR chains. All proposed SDK assertions are **missing**. These are test targets, not established guarantees or confirmed defects. The six candidates cover PostgreSQL transaction closure, external-effect accounting, corruption refusal, cache/Git publication and backup reference retention. No production change, mutant, runtime test or native machine execution was made. This scratchbook text has no architecture impact; it records candidate checks against existing decisions and changes no contract.

### marshall-admission-atomic-allocation — Joined admission allocation

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each acknowledged new admission has one joined VM, placement, reservation, address, provision operation and persisted dispatch job; definite failed new admission leaves none. |
| **Invariant** | `Always` **"Marshall acknowledged admission has one joined allocation and dispatch job"** on a consistent PostgreSQL snapshot; each sampled settled admission must satisfy it. Timed-out calls are reconciled by ID. |
| **Antithesis Angle** | Race same-key callers across nodes and cut near commit or job insertion; a lost reply must preserve original allocation identity. |
| **Why It Matters** | Partial allocation or absent dispatch work can strand capacity and VM intent. [Evidence](property-candidates-01/marshall-admission-atomic-allocation.md); P0, high confidence. |

**Open Questions:** Can persisted AshOban args be correlated to operation ID in the pinned version? Which PaperTrail/audit row is mandatory for new admission?

### ziggy-completion-once-accounted — One completion, one accounting contribution

| | |
|---|---|
| **Type** | Safety |
| **Property** | An acknowledged inference completion persists one immutable projection and contributes exactly once to its Marshall daily aggregate despite duplicate delivery. |
| **Invariant** | `Always` **"Ziggy completion acknowledgment conserves one Marshall accounting update"** at settled snapshots; optional `AlwaysOrUnreachable` at slot removal checks exact ACK before deletion. |
| **Antithesis Angle** | Lose completion replies, restart Ziggy around spool deletion, duplicate reporters and vary unknown versus complete usage. |
| **Why It Matters** | Lost or doubled usage distorts billing and operational SLOs. [Evidence](property-candidates-01/ziggy-completion-once-accounted.md); P0, high confidence. |

**Open Questions:** How can a dedicated owner/day/provider/model aggregate bucket be isolated with real authority? Can spool deletion be observed only after its sync boundary settles?

### lilly-corrupt-intent-never-becomes-receipt — Corrupt intent refusal

| | |
|---|---|
| **Type** | Safety |
| **Property** | A malformed or differently bound durable placement command cannot justify a new successful delivery receipt. |
| **Invariant** | `AlwaysOrUnreachable` **"Lilly refuses receipt when stored placement intent is unreadable"** at the optional corruption path: if reached, refusal must hold. |
| **Antithesis Angle** | Restart the real host owner with truncated, wrong-versioned, wrong-bound or unsafe command files and deliver newer intent. |
| **Why It Matters** | Reinterpreting corrupt storage as absence could authorize execution without durable identity. [Evidence](property-candidates-01/lilly-corrupt-intent-never-becomes-receipt.md); P0, high confidence. |

**Open Questions:** Which Runtime exchange response exposes existing-placement corruption? What owner pause/stop seam permits corruption seeding without violating lock custody?

### brady-cache-complete-publication — Complete cache hits

| | |
|---|---|
| **Type** | Safety |
| **Property** | Every hit for a controlled cache key returns one complete observed origin object; incomplete or aborted writes never become hits. |
| **Invariant** | `Always` **"Brady cache hit serves a complete committed object"** on every hit, comparing independent origin bytes and client bytes. |
| **Antithesis Angle** | Cut around chunk append, sync, metadata and rename, then restart and check recovered objects. |
| **Why It Matters** | A partial cached response could silently corrupt many downstream consumers. [Evidence](property-candidates-01/brady-cache-complete-publication.md); P1, high confidence. |

**Open Questions:** Which independent signal proves a cache hit without only trusting Store state? Does hosted storage permit a persisted power-cut test, or process kills only?

### enrico-published-head-remains-addressable — Published Git content

| | |
|---|---|
| **Type** | Safety |
| **Property** | A commit SHA that Marshall still publishes remains resolvable with the same controlled blob through failed or interrupted mirror refresh. |
| **Invariant** | `Always` **"Enrico published Git head remains addressable through failed refresh"** after settled failure, comparing pinned SHA/object bytes with an independent workload ledger. |
| **Antithesis Angle** | Force-push upstream and cut Enrico around fetch/retained-ref updates or Marshall settlement. |
| **Why It Matters** | Losing the published commit makes a registered mirror unusable despite durable catalog state. [Evidence](property-candidates-01/enrico-published-head-remains-addressable.md); P1, medium-high confidence. |

**Open Questions:** Do all read routes pass explicit published SHA, or must the oracle inspect Git directly? What safe hook can cut within native Git substeps?

### backup-retained-manifest-closure — Retained restore graph

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each component referenced by a retained complete backup manifest remains present and restorable to the workload's recorded sentinel hash. |
| **Invariant** | `Always` **"Retained backup manifest references restorable component snapshots"** after settled publication/retention, verified by independent Restic list and isolated restore. |
| **Antithesis Angle** | Interrupt component capture, manifest publication and batched forget while prior retained points remain. |
| **Why It Matters** | A manifest with missing components creates a false recovery point. [Evidence](property-candidates-01/backup-retained-manifest-closure.md); P0, medium-high confidence. |

**Open Questions:** Can two retained manifests share a component snapshot ID in a real fixture? Which safe isolated restore sentinels cover guest and host components?

## Breadth and limits

The pass inspected admission and operation transactions, Lilly Store/PrivateFiles, Ziggy spool/reporter and Marshall totals, Brady cache Store/recovery, Enrico mirror publication, and Restic backup runtime/retention, plus the architecture and assertion scan. Diagnostics spool, request recorder and guest workspace checkout remain material integrity lanes for other focus passes or synthesis; this report makes no claim about them. Hosted real services establish service/database/file handoffs; software-emulated storage or guest adds bounded content evidence; native Firecracker, ZFS ownership, physical backup and independent-host durability require recorded native runs. A source contract or historical review is rationale, never current passing execution.
