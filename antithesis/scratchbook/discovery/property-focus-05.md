---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
status: complete-source-discovery
---

# Resource boundaries property discovery

Eleven candidates target actual backing, durable slots, physical headroom, process/FD custody and progress beside saturated work. The fresh [assertion scan](../existing-assertions.md) found no Antithesis SDK assertions in current source; every proposed assertion below is missing. Source contracts, ADRs, ordinary tests and local review records describe intended behavior or past test sensitivity, not a current hosted baseline. Candidate files contain literal unique messages, exact source anchors, independent oracles, value menus, replay/branch guidance and scope limits.

Inspected breadth: terminald PTY rings and viewers; Ziggy Spool, Reporter, task/lease/HTTP limits; Brady cache pressure, read/write leases and transparent listeners; Marshall locked admission, budget and reports; Lilly pool locks and sampling cadence; Enrico Manager, task supervisor and native Git locks; Control WebSocket pending calls; SQLite trace archive and Nix quota; BEAM request producer and native recorder. The SUT synthesis and discovery reports supplied deployment and failure context. This pass did not establish a global RSS/FD ceiling for all eight releases, total Linux cgroup memory reservation, unconditional progress SLA or native fleet isolation from one TCG machine. No external incident tracker was consulted.

### terminal-physical-scrollback-budget — Actual terminal ring backing

| | |
|---|---|
| **Type** | Safety and reachability; P0; high confidence |
| **Property** | Concurrent PTY creates, growth and overwrite keep allocated ring backing within aggregate reservations; full-budget refusal preserves survivors. |
| **Invariant** | Always checks live deque allocation against ring_total and configured cap; Reachable targets an intended valid create refusal at saturation. |
| **Antithesis Angle** | Mixed growth, full-ring overwrite, pump death and retirement while viewer references remain. |
| **Why It Matters** | Prevents memory growth beyond quota without sacrificing live terminals. [Evidence](property-candidates-05/terminal-physical-scrollback-budget.md) |

**Open Questions:** Can hosted TCG expose exact backing snapshots without perturbing allocation? Which guest-vsock route preserves concurrent PTYs under outer faults?

### terminal-stalled-viewer-neighbor-progress — Terminal queue isolation

| | |
|---|---|
| **Type** | Conditional liveness; P1; high confidence |
| **Property** | A viewer withholding read credit leaves another authorized terminal able to create, attach and deliver bytes during a healthy finite interval. |
| **Invariant** | Sometimes checks designated neighbor nonce bytes while the first viewer remains credit-stalled; the combined state is meaningful progress. |
| **Antithesis Angle** | Queue high-water waits, socket backpressure, viewer kill and shared registry locks. |
| **Why It Matters** | One stuck reader should not freeze neighboring sessions. [Evidence](property-candidates-05/terminal-stalled-viewer-neighbor-progress.md) |

**Open Questions:** What measured native/TCG quiet interval is appropriate? Can hosted faults retain a stalled but open viewer socket?

### ziggy-spool-capacity-before-provider — Durable effect-slot admission

| | |
|---|---|
| **Type** | Safety and reachability; P0; high confidence |
| **Property** | Provider or agent effects require a previously durable bounded spool slot; full or unavailable spool refuses new effects while preserving admitted receipts. |
| **Invariant** | Always compares provider fixture accepts with durable admitted IDs and slot count; Reachable targets intended full-spool refusal. |
| **Antithesis Angle** | Fill slots, lose completion ACKs, restart Ziggy and attempt new HTTP/agent work. |
| **Why It Matters** | Prevents unaccountable external effects when completion custody is exhausted. [Evidence](property-candidates-05/ziggy-spool-capacity-before-provider.md) |

**Open Questions:** Which HTTP/agent routes share a spool in the chosen deployment? Can hosted faults expose directory-sync uncertainty?

### brady-cache-physical-headroom-and-leases — Shared disk pressure

| | |
|---|---|
| **Type** | Safety and reachability; P0; high confidence |
| **Property** | New and growing cache writes require fresh native pool and guest-parent headroom after pending reservations; stale pressure preserves completed leased reads. |
| **Invariant** | Always checks admitted writes against independent physical headroom and retained reader bytes; Reachable targets safe bypass at the floor. |
| **Antithesis Angle** | Guest growth, snapshots, chunked writes, stale samples and live readers during eviction. |
| **Why It Matters** | Cache traffic must preserve physical guest safety margin and active reads. [Evidence](property-candidates-05/brady-cache-physical-headroom-and-leases.md) |

**Open Questions:** Can TCG expose independent pool and parent snapshots at append boundaries? Which fault reaches uncertain temporary deletion safely?

### marshall-admission-measured-physical-capacity — Locked placement budget

| | |
|---|---|
| **Type** | Safety; P0; high confidence |
| **Property** | Each committed placement fits fresh measured CPU, memory and disk headroom after startup, copy and resize holds. |
| **Invariant** | Always reconstructs the exact locked report and retained holds for each new reservation. |
| **Antithesis Angle** | Competing creates, host reports, pool contention, clone/resize holds and lost admission replies. |
| **Why It Matters** | Prevents oversubscription from stale samples or virtual sizes used as physical credit. [Evidence](property-candidates-05/marshall-admission-measured-physical-capacity.md) |

**Open Questions:** Which adapter preserves Collector freshness while providing independent usage/ZFS samples? Can hosted faults produce real pool-lock busy reports?

### enrico-native-git-admission-after-manager-restart — Inherited Git slots

| | |
|---|---|
| **Type** | Safety and reachability; P1; high confidence |
| **Property** | Manager replacement cannot admit a ninth live native Git ownership tree or a competing mutator for one repository. |
| **Invariant** | Always counts process-held slot locks and per-repository mutators; Reachable targets ninth-request refusal while eight locks remain. |
| **Antithesis Angle** | Helper/caller death, inherited descriptors, result-before-exit and Manager restart. |
| **Why It Matters** | A fresh BEAM counter must not hide old physical Git work. [Evidence](property-candidates-05/enrico-native-git-admission-after-manager-restart.md) |

**Open Questions:** Does hosted Linux preserve inherited-FD and descendant custody semantics? Can local fixtures satisfy production source-origin restrictions?

### control-inflight-limit-and-retirement — Control request memory

| | |
|---|---|
| **Type** | Safety; P1; high confidence |
| **Property** | Pending Control calls never exceed the validated welcome window, and busy calls create no outbound request frame. |
| **Invariant** | Always compares pending calls with negotiated limit and proxy-observed wire IDs. |
| **Antithesis Angle** | Held replies, timeouts, half-close and reconnect with a server task committing after reply loss. |
| **Why It Matters** | Bounds connection memory and prevents hidden replay under saturation. [Evidence](property-candidates-05/control-inflight-limit-and-retirement.md) |

**Open Questions:** Can a proxy retain exact outbound frames across half-close? Which server operation safely witnesses postcommit reply loss?

### trace-spool-physical-quota-with-retained-custody — Archive saturation

| | |
|---|---|
| **Type** | Safety; P1; medium-high confidence |
| **Property** | Quota or ENOSPC refusal cannot erase unexpired accepted trace bytes, including exported batches; exhausted backing stops new ACKs until recovery. |
| **Invariant** | Always compares independently reread SQLite digests and physical ENOSPC history with admitted IDs. |
| **Antithesis Angle** | Fill pending and retained quotas, exporter ACK/replay, WAL checkpoint, restart and disk exhaustion. |
| **Why It Matters** | Keeps trace custody under storage pressure without gating business progress. [Evidence](property-candidates-05/trace-spool-physical-quota-with-retained-custody.md) |

**Open Questions:** What exact transient SQLite/WAL footprint envelope applies? Can hosted storage enforce recoverable real ENOSPC?

### request-recorder-capacity-does-not-admit-phantom-work — Measurement slots

| | |
|---|---|
| **Type** | Safety; P1; high confidence |
| **Property** | Saturated recorder admission yields unrecorded coverage, never an invented durable ticket or clean interval, while application effects retain their own authority. |
| **Invariant** | Always checks durable pending count, ticket IDs and quality marker against 4096 slots and effect witnesses. |
| **Antithesis Angle** | Hold 4096 workers, attempt one more, lose replies and retire a worker. |
| **Why It Matters** | Measurement saturation must be visible and cannot fabricate SLO coverage. [Evidence](property-candidates-05/request-recorder-capacity-does-not-admit-phantom-work.md) |

**Open Questions:** Is a full 4096-worker hosted run feasible without unrelated OS limits? Which fixture retains systemd producer identity while faulting recorder?

### brady-listener-socket-worker-bound — Transparent socket capacity

| | |
|---|---|
| **Type** | Safety with conditional liveness; P1; high confidence |
| **Property** | A listener owns at most configured live workers, closes overload sockets and accepts a valid successor after a slot frees. |
| **Invariant** | Always checks live worker socket inodes against max_connections; Sometimes checks origin receipt after saturation and retirement. |
| **Antithesis Angle** | Hold incomplete headers, race excess accepts, transfer failure and worker death. |
| **Why It Matters** | Bounds accepted FDs and leaves later connections usable. [Evidence](property-candidates-05/brady-listener-socket-worker-bound.md) |

**Open Questions:** Which TCG fixture produces transparent sockets and exposes inodes? What measured freed-slot quiet interval is justified?

### lilly-pool-sampling-does-not-starve-mutation — Sampling fairness

| | |
|---|---|
| **Type** | Conditional liveness; P1; medium-high confidence |
| **Property** | Repeated samples leave an eligible queued pool mutation and a separate pool neighbor able to finish after finite lock obstruction. |
| **Invariant** | Sometimes checks both physical receipts while sampling continues, under valid authority, capacity and a measured quiet interval. |
| **Antithesis Angle** | Slow one-in-flight samples, zero-wait busy observations and clone/refill/delete locks. |
| **Why It Matters** | Monitoring must not starve physical work needed to restore capacity. [Evidence](property-candidates-05/lilly-pool-sampling-does-not-starve-mutation.md) |

**Open Questions:** Which measured post-release interval fits each operation? Can TCG retain two real pools and lock contention?

## Boundaries for synthesis

Terminal ring backing and viewer queue fairness are independent: bounded rings can still freeze neighbors. Brady cache leases and listener connections are distinct. Ziggy durable slots differ from task/lease/Finch ceilings, and Enrico native slots differ from Manager.active. Marshall reservation arithmetic is a committed-decision invariant; TCG physical samples add reporter evidence without certifying native fleet placement. Diagnostic refusal cannot become a lifecycle failure oracle. The known Ziggy 128-head permanent-conflict case is a documented fairness gap, so no unconditional reporter-drain property is proposed. Focus03 recovery and focus04 Control candidates overlap mechanisms but these preserve unique physical or saturation witnesses.

No production files, shared catalog, handbook, ADR, governance receipt or another focus's candidates were edited; no children were spawned. Architecture/HLDD impact assessed before and against this research diff: no implementation, documented behavior or passing verification status changed. ADR-0082, ADR-0100, ADR-0132, ADR-0140 and ADR-0149 remain accepted constraints or claims to test. Read-only source and file consistency checks are appropriate here; production gates apply when instrumentation or behavior changes.
