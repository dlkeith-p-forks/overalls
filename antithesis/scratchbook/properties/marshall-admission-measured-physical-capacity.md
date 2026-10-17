---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# marshall-admission-measured-physical-capacity

**Claim, priority, confidence.** P0 safety, high confidence in the admission contract. A successful placement must fit fresh measured CPU/memory/disk headroom after outstanding startup and copy/resize holds, and a busy or unavailable pool cannot invent new credit. Proposed unique assertion: Always("marshall placement fits fresh measured physical headroom and all outstanding holds", each_new_reservation_fits_locked_fresh_snapshot). Missing per ../existing-assertions.md. This is stricter than checking only sum of nominal VM sizes against a host total.

**Source and history.** marshall/lib/marshall/compute/admission.ex:40-93 commits VM, placement, reservation, address, operation and job together; allocate at :143-222 locks each candidate host and reads its reservations before Budget.fits?. marshall/lib/marshall/compute/budget.ex:10-45 subtracts startup compute from measured headroom and pending disk growth; :47-82 shares arithmetic with explanation; :93-130 charges creation, materialized physical credit, temporary copies and resize bytes; :132-138 requires all three positive dimensions. marshall/lib/marshall/compute/host_reports.ex:104-115 rejects partial/stale snapshots and preserves sample time; :227-241 distinguishes unavailable (clear credit) from busy (retain old timestamp, age naturally). lilly/lib/lilly/host/storage.ex:4-15 gives observations a zero-wait lock attempt. Existing successful admissions and counters alone do not prove guests physically fit.

**Workload and oracle.** Use two Marshall serving instances over one PostgreSQL primary, real Lilly reporting/Store/Runtime and real TCG storage or native machine for physical disk. Race new creates with host reports, clone/resize temporary holds, pool mutation, and an observation that returns busy. Snapshot committed host/pool report sequence and timestamp, all retained reservations and the admission transaction identity; independently sample actual ZFS allocation/free bytes and host cgroup usage at quiescence. The safety oracle checks each commit against the exact locked report and holds, while physical samples detect a corrupt or overstated reporter. Lost create reply is reconciled by idempotency key. A stale report may legitimately refuse and a busy pool retains old but aging credit; neither is an admission failure if a different fresh pool fits.

**Limit menu.** Host capacity freshness default 5 s; 4.9/5.0/5.1 s sample ages, exact-fit and one-byte short memory/disk, CPU 999/1000/1001 millicore edges, one/two pools, no/one/several startup holds, and concurrent same/different host attempts. Scope accepted v4 normal execution-ready hosts and enabled compatible images.

**SUT guidance and limits.** Mark host-lock acquisition, selected report sequence and Budget.available breakdown at commit; this is replay guidance, not an oracle substitute. TCG proves real disk byte arithmetic in its own VM, not native fleet host isolation. Open questions: Which hosted adapter can supply independent host usage and ZFS samples without changing the production Collector's freshness semantics? `(partial: current native probes exist; hosted TCG adapter and correlated commit-time sample are unbuilt)` Can a fault hold the real pool mutation lock long enough to exercise busy samples? `(partial: zero-wait production lock and busy protocol are confirmed; no lock-hold native admission probe was found)`

**Architecture/HLDD impact.** No implementation change. ADR-0140 and capacity decisions remain test claims.

### Investigation Log

#### Which hosted adapter can supply independent host usage and ZFS samples without changing Collector freshness?

- Examined: `lilly/lib/lilly/host/collector.ex:1-80`, `lilly/lib/lilly/host/pool.ex:130-205`, `nix/tests/machines/native-zfs/driver.py:73-90,308-321`, `nix/tests/machines/fleet/scenarios/capacity.py:1-85,185-248`, and `antithesis/scratchbook/deployment-topology.md`.
- Found: production Collector samples host inventory/limits/usage and each configured pool, carrying `sampled_at`; native ZFS tests independently invoke `zfs-check observe/headroom` and apply cgroup pressure; the fleet capacity scenario queries retained reservations and fresh physical report headroom across a race. A hosted router VMM is only a topology plan.
- Not found: a built hosted TCG adapter that runs those native probes beside the production Collector and records a correlated, independently sampled cgroup/ZFS state at each admitted transaction. A later sample can verify physical consistency, but cannot by itself reconstruct exact commit-time headroom.
- Conclusion: partial. Put the existing read-only probes inside a real TCG Linux/ZFS guest, timestamp their output, and join them to the accepted report/locked reservation snapshot. Keep production `sampled_at` and report freshness logic untouched.

#### Can a fault hold the real pool mutation lock long enough to exercise busy samples?

- Examined: `lilly/lib/lilly/host/storage.ex:6-43`, `lilly/lib/lilly/host/pool.ex:130-205`, `marshall/lib/marshall/compute/host_reports.ex:169-191,227-241`, and native ZFS driver busy-observation cases.
- Found: `Pool` uses `Storage.locked(..., 0)` for observation, so a real held `.lilly-storage` lock produces `:storage_busy`/`busy: true`; Marshall retains the prior pool row and timestamp on busy reports. Native ZFS tests exercise a usage-moving busy result, which is a distinct route to busy.
- Not found: a current source-built native admission fixture that holds the actual pool mutation lock over a Collector cycle and checks Marshall's aging retained pool credit plus admission refusal. Lock helper ownership and process lifetime need recording in that fixture.
- Conclusion: partial. Hold the real pool lock with a separately supervised native owner, sample through actual Collector/Control, verify a `busy: true` report and unchanged pool `reported_at`, then attempt admission just before/after its freshness deadline.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: exact locked report revision and holds correlated with independent CPU/memory/ZFS sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/scenarios.py:310`. Dedicated host/pool brackets unchanged SQL report and holds, waits for a newer independent inner-ZFS sample, and checks shape/overhead arithmetic; changing frames and physical free disagreement remain unknown without commit-time and CPU/memory interval correlation. No live admission has run. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
