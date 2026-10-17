---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "11: Wildcard"
status: complete
---

# Property discovery focus 11: Wildcard

The fixed focuses cover integrity, concurrency, recovery, protocols, resources, access, coordination, lifecycle, replay and versions. This pass asked where apparently correct local states compose into an incorrect global statement. Four distinct seams survived source review: time spent in measurement after an authority grant, a logical generation change without a new physical boot, a complete backup containing different moments, and VM readiness preceding workspace checkout. These are proposed properties, not established guarantees or confirmed defects. All planned SDK assertions are **missing** in the [fresh scan](../existing-assertions.md). Research-only scratchbook changes have no architecture or HLDD behavior impact; ADR-0070/0128/0140/0157/0158 are claims to test.

### galileo-accounting-delay-does-not-renew-old-grant — Observer wait and grant age

| | |
|---|---|
| **Type** | Safety |
| **Property** | A synchronous accounting wait cannot make an already aged Galileo authorization usable for a new upstream effect without successful current renewal. |
| **Invariant** | `Always` **"Galileo accounting delay cannot start an upstream effect on an aged grant"** compares grant age, renewal result and first real upstream accept/read; each new effect must have live authority. |
| **Antithesis Angle** | Stall or crash the independent request recorder after Marshall grants the 2-second TTL, revoke authority during the stall, then release Galileo to race lease creation and upstream connection. |
| **Why It Matters** | An observability dependency could unintentionally extend execution authority. [Evidence](property-candidates-11/galileo-accounting-delay-does-not-renew-old-grant.md); P0, medium-high confidence. |

**Open Questions:** Is grant TTL anchored at Marshall response or deliberately at later upstream lease creation? Is elapsed time subtracted in another adapter?

### continuing-boot-advances-generation-without-second-boot — Logical and physical identity

| | |
|---|---|
| **Type** | Safety |
| **Property** | Adopting newer running intent on the same placement/VM epoch preserves one physical boot while old-generation delivery cannot settle the new journal. |
| **Invariant** | `Always` **"Logical generation adoption retains one physical boot and fences old delivery"** joins native VMM identity, boot challenge, current intent and exact delivery journal on every adoption/replay. |
| **Antithesis Angle** | Delay trust/workspace replies across actor or Control restart while intent generation advances on a continuing guest. |
| **Why It Matters** | A generation number alone neither proves a new boot nor authorizes an old reply to finish new work. [Evidence](property-candidates-11/continuing-boot-advances-generation-without-second-boot.md); P0, high confidence. |

**Open Questions:** Which native fixture can delay a guest workspace reply through a committed generation advance while retaining the VMM?

### backup-time-skew-never-activates-historical-authority — Mixed-time recovery graph

| | |
|---|---|
| **Type** | Safety |
| **Property** | A complete backup whose guest, database and host components represent different moments remains isolated until historical authority and guest identity reservations are explicitly reconciled. |
| **Invariant** | `Always` **"Restored mixed-time backup remains isolated from live fleet authority"** checks restore target, live endpoints/processes and UID allocation effects, not the manifest's `complete` flag alone. |
| **Antithesis Angle** | Create/relocate/delete guests and allocate a new guest UID between sequential captures, then restore an individually valid manifest beside the live fleet. |
| **Why It Matters** | A locally valid restore graph can still be unsafe as immediate current authority. [Evidence](property-candidates-11/backup-time-skew-never-activates-historical-authority.md); P1, medium confidence. |

**Open Questions:** Is there a repository-provided historical activation/claim command, or can this run only prove isolated restore and a separately staged drill?

### guest-ready-does-not-claim-workspace-checkout — Separate guest and checkout status

| | |
|---|---|
| **Type** | Safety and reachability |
| **Property** | VM ready may coexist with a pending or failed Git checkout, while any checkout-complete claim requires the actual guest's durable completion and content. |
| **Invariant** | `Always` **"Guest readiness does not claim repository checkout completed"** checks checkout claims against guest marker/HEAD. `Sometimes(condition)` **"Guest remained ready while workspace checkout was pending"** requires one meaningful independent-state observation. |
| **Antithesis Angle** | Boot a real guest while Git is unavailable, then heal/move a ref and interrupt clone around rename and completion publication. |
| **Why It Matters** | Conflating ready VM with ready workspace misleads users and hides checkout failures. [Evidence](property-candidates-11/guest-ready-does-not-claim-workspace-checkout.md); P1, high confidence. |

**Open Questions:** Does any current user-facing surface label checkout complete, or is the claim confined to guest/internal status?

## Breadth and limits

Read the completed SUT synthesis, assertion scan, wildcard directions and covered-focus titles; then inspected Galileo/Marshall grants and accounting, Lilly boot/trust/workspace journals and tests, guest service ordering, backup capture/restore and durable guest identity ADRs. The wildcard source pass also identified native descendant custody, shared guest workspace permissions and Nix mount-namespace ownership; focused concurrency, security and resource candidates already cover their core assertions, so they are not repeated here. The Galileo source ordering is a specific suspected timing gap; only a controlled upstream effect witness can establish whether it violates intended grant age. The backup candidate explicitly respects unsupported automatic historical repair. Real services can verify grant timing and restore isolation; native TCG/ZFS/guest observation is needed for physical boot, checkout and retained-disk claims. No runtime tests or mutant patches were run for this research-only change.
