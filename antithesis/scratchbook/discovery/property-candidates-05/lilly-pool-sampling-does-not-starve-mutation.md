---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# lilly-pool-sampling-does-not-starve-mutation

**Claim, priority, confidence.** P1 conditional liveness, medium-high confidence in the intended scheduler contract. Continuous host sampling and storage pressure must leave acquisition opportunities for an eligible pool mutation and for a separate pool's neighbor work after a finite obstruction clears. Proposed unique assertion: Sometimes("lilly queued pool mutation and separate pool neighbor finish during ongoing samples", designated_mutation_physical_receipt && neighbor_physical_receipt && sampling_still_enabled). Sometimes matches the meaningful combined progress state; no universal completion deadline is claimed. Missing per ../../existing-assertions.md.

**Source and history.** lilly/lib/lilly/control/runtime.ex:252-296 records that back-to-back samples previously starved disk mutations and uses OverallsProtocol.Cadence for one sample in flight with dropped ticks. Runtime tick at :404-429 and sample completion at :445-478 determine when the next report can start. lilly/lib/lilly/host/storage.ex:4-44 uses a one-second default mutation acquisition window, zero-wait observation and lock release in after. lilly/lib/lilly/host/pool.ex:202 calls Storage.locked with zero wait for snapshot; :147/191/224 classifies busy as unavailable evidence. marshall/lib/marshall/compute/host_reports.ex:227-241 retains an old busy observation without refreshing its age; stale admission may refuse during obstruction. The source comment documents a clone-source relaunch starvation history, but this pass did not reproduce it on current code.

**Workload and oracle.** Use real Lilly Runtime, native host lock helper and two real ZFS pools in a TCG storage VM or native machine. Continuously tick/sample while one pool has clone/create/delete/refill mutation queued and another has an independent eligible operation. Temporarily block one pool observation/mutation, then release it while continuing samples. Observe actual dataset GUID/contents, native lock holder retirement and durable operation receipt for both targets, not merely a sample_task counter or an Ash job state. Record each zero-wait busy result and report timestamp to ensure unavailable evidence cannot be mistaken for new capacity. Gate success on valid source/image, retained authority, enough storage and a measured quiet interval after release; permanent foreign lock or physical ENOSPC permits refusal.

**Limit menu.** One/two pools; 0, 1 and repeated slow samples; lock hold just below/above default one-second mutation window; report age below/at/above five-second capacity freshness; one blocked and one healthy neighbor; clone/refill/delete operations. Keep sample cadence at production one-second tick in the full-stack run.

**SUT guidance and limits.** Mark Cadence start/done/dropped-tick, pool-lock acquisition/refusal and per-operation physical receipt. An isolated fake Collector can validate cadence transitions but not ZFS lock fairness. Hosted TCG storage can test real ZFS within its VM; native fleet topology still needs a separate machine campaign. Open questions: Which measured post-release interval is sufficient for each operation class? Can the TCG fixture keep two independent real pools and genuine lock contention under fault injection?

**Architecture/HLDD impact.** No design, implementation or handbook update; this tests an existing capacity/recovery claim.
