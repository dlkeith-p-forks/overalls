---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# marshall-admission-measured-physical-capacity

**Claim, priority, confidence.** P0 safety, high confidence in the admission contract. A successful placement must fit fresh measured CPU/memory/disk headroom after outstanding startup and copy/resize holds, and a busy or unavailable pool cannot invent new credit. Proposed unique assertion: Always("marshall placement fits fresh measured physical headroom and all outstanding holds", each_new_reservation_fits_locked_fresh_snapshot). Missing per ../../existing-assertions.md. This is stricter than checking only sum of nominal VM sizes against a host total.

**Source and history.** marshall/lib/marshall/compute/admission.ex:40-93 commits VM, placement, reservation, address, operation and job together; allocate at :143-222 locks each candidate host and reads its reservations before Budget.fits?. marshall/lib/marshall/compute/budget.ex:10-45 subtracts startup compute from measured headroom and pending disk growth; :47-82 shares arithmetic with explanation; :93-130 charges creation, materialized physical credit, temporary copies and resize bytes; :132-138 requires all three positive dimensions. marshall/lib/marshall/compute/host_reports.ex:104-115 rejects partial/stale snapshots and preserves sample time; :227-241 distinguishes unavailable (clear credit) from busy (retain old timestamp, age naturally). lilly/lib/lilly/host/storage.ex:4-15 gives observations a zero-wait lock attempt. Existing successful admissions and counters alone do not prove guests physically fit.

**Workload and oracle.** Use two Marshall serving instances over one PostgreSQL primary, real Lilly reporting/Store/Runtime and real TCG storage or native machine for physical disk. Race new creates with host reports, clone/resize temporary holds, pool mutation, and an observation that returns busy. Snapshot committed host/pool report sequence and timestamp, all retained reservations and the admission transaction identity; independently sample actual ZFS allocation/free bytes and host cgroup usage at quiescence. The safety oracle checks each commit against the exact locked report and holds, while physical samples detect a corrupt or overstated reporter. Lost create reply is reconciled by idempotency key. A stale report may legitimately refuse and a busy pool retains old but aging credit; neither is an admission failure if a different fresh pool fits.

**Limit menu.** Host capacity freshness default 5 s; 4.9/5.0/5.1 s sample ages, exact-fit and one-byte short memory/disk, CPU 999/1000/1001 millicore edges, one/two pools, no/one/several startup holds, and concurrent same/different host attempts. Scope accepted v4 normal execution-ready hosts and enabled compatible images.

**SUT guidance and limits.** Mark host-lock acquisition, selected report sequence and Budget.available breakdown at commit; this is replay guidance, not an oracle substitute. TCG proves real disk byte arithmetic in its own VM, not native fleet host isolation. Open questions: Which hosted adapter can supply independent host usage and ZFS samples without changing the production Collector's freshness semantics? Can a fault hold the real pool mutation lock long enough to exercise busy samples?

**Architecture/HLDD impact.** No implementation change. ADR-0140 and capacity decisions remain test claims.
