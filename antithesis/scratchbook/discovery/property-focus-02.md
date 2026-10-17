---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "02 — Concurrency"
status: complete
---

# Property discovery focus 02: Concurrency

Eight source-grounded candidates cover database preparation, actor result identity, production supervision, native process custody, pool fairness, service lease expiry, Git concurrency and threaded terminal retirement. These are claims to test, not established guarantees or confirmed defects. The [fresh assertion scan](../existing-assertions.md) finds every proposed Antithesis assertion **missing**. The detailed files carry source anchors, independent witnesses, schedules, value menus and limits. This scratchbook research changes no SUT, contract or architecture; no mutant, hosted run or native acceptance was performed.

### native-utility-descendant-custody — Descendants retain mutation custody

| | |
|---|---|
| **Type** | Safety |
| **Property** | An exclusive native mutation cannot overlap another on the same lock inode while a first utility or adopted descendant remains active. |
| **Invariant** | `Always` **"Native utility descendant custody blocks a second mutation until retirement"** at each competing acquisition and completion, using PID and inode evidence. |
| **Antithesis Angle** | Kill caller/helper, let the leader exit, create a new-session grandchild, then race a second mutator. |
| **Why It Matters** | Premature ownership release can overlap destructive ZFS/transfer effects. [Evidence](property-candidates-02/native-utility-descendant-custody.md); P0, high confidence. |

**Open Questions:** Can hosted Linux expose stable descendant and inode evidence after forced helper death?

### lilly-async-result-keeps-command-identity — Old results cannot gain new authority

| | |
|---|---|
| **Type** | Safety |
| **Property** | A result for an older Lilly command cannot publish a newer command's live, capacity or outcome proof. |
| **Invariant** | `Always` **"Lilly asynchronous result retains its original command generation"** across Store, Journal, Execution and physical receipt observations. |
| **Antithesis Angle** | Pause executor, commit a replacement generation, and release the old result amid actor restart/exchange. |
| **Why It Matters** | Relabeling stale work could grant VM authority to the wrong physical execution. [Evidence](property-candidates-02/lilly-async-result-keeps-command-identity.md); P0, high confidence. |

**Open Questions:** Which existing executor pause seam preserves production actor/journal timing?

### lilly-view-restart-withdraws-stream-authority — Production View restart fencing

| | |
|---|---|
| **Type** | Safety |
| **Property** | A View restart cannot permit an old stream to forward a new guest effect before dependent components reestablish current authority. |
| **Invariant** | `AlwaysOrUnreachable` **"Lilly View restart withdraws stale stream authority before forwarding"** on the optional real-supervisor restart path. |
| **Antithesis Angle** | Kill Execution under `rest_for_one` while racing command replacement and stream bytes; observe actual connector teardown. |
| **Why It Matters** | A direct ETS lookup race matters only if later stream/effect fences fail. [Evidence](property-candidates-02/lilly-view-restart-withdraws-stream-authority.md); P0, medium confidence. |

**Open Questions:** Which forwarding seam provides a post-restart byte witness synchronized with connector and command identity?

### pool-contention-preserves-neighbor-progress — Pool fairness under samplers

| | |
|---|---|
| **Type** | Liveness and safety |
| **Property** | Once transient contention clears, a repeated independent pool mutation completes; contention alone does not discard retained placement or outcome. |
| **Invariant** | `Sometimes(condition)` **"Lilly independent pool mutation completes during sustained sampling pressure"** where condition is actual neighbor completion after overlap and fault cessation; `Always` **"Lilly pool contention preserves retained placement and outcome"** on `storage_busy`. |
| **Antithesis Angle** | Saturate sampling, prewarm/refill and concurrent create/delete/clone; vary lock hold near retry bounds. |
| **Why It Matters** | Starvation strands VM creation while false loss consumes or releases capacity incorrectly. [Evidence](property-candidates-02/pool-contention-preserves-neighbor-progress.md); P1, medium-high confidence. |

**Open Questions:** What useful service deadline does a current native load baseline support?

### terminal-kill-progress-under-pty-backpressure — Kill while input stalls

| | |
|---|---|
| **Type** | Liveness, source hypothesis |
| **Property** | A controlled terminal with blocked input/output can still be explicitly killed and have its process and quota retired. |
| **Invariant** | `Sometimes(condition)` **"Terminal explicit kill retires session under blocked PTY input"** after synchronized blocked-write/kill overlap; `Reachable` **"Terminal PTY input write blocked while kill requested"** proves the precondition. |
| **Antithesis Angle** | Stop the guest's PTY reader, saturate input, withhold viewer credit and kill through a second connection. |
| **Why It Matters** | A held session mutex could keep a dead session and quota indefinitely; source alone does not establish a defect. [Evidence](property-candidates-02/terminal-kill-progress-under-pty-backpressure.md); P1, medium confidence. |

**Open Questions:** Can the PTY buffer be saturated and its blocked write witnessed in the deployed daemon? `(partial: source opens master without O_NONBLOCK)`

### enrico-native-refresh-cap-survives-manager-restart — Native Git overlap cap

| | |
|---|---|
| **Type** | Safety |
| **Property** | Native slot and repository flocks bound physical Git overlap through Manager restart and result-before-exit intervals. |
| **Invariant** | `Always` **"Enrico native Git ownership bounds physical concurrent refreshes"** across actual utility trees and lock holders. |
| **Antithesis Angle** | Pause eight Git utilities, race a ninth and same-repository replay, then restart Manager. |
| **Why It Matters** | BEAM task counts can understate surviving native effects, causing resource saturation or mirror corruption. [Evidence](property-candidates-02/enrico-native-refresh-cap-survives-manager-restart.md); P1, high confidence. |

**Open Questions:** How can real Git be paused after native slot acquisition without changing its ownership path?

### lease-expiry-independent-of-blocked-renewal — Deadline fences service effects

| | |
|---|---|
| **Type** | Safety |
| **Property** | Audi, Ziggy and Galileo admit no new downstream effect after their lease expires without current renewal. |
| **Invariant** | `Always` **"Expired service lease cannot forward a new upstream effect"** at independently witnessed effect admission. |
| **Antithesis Angle** | Block renewal and transport simultaneously, then deliver a late renewal or revocation across owner/watchdog races. |
| **Why It Matters** | Transport backpressure must not extend revoked authority into provider, integration or guest access. [Evidence](property-candidates-02/lease-expiry-independent-of-blocked-renewal.md); P0, medium-high confidence. |

**Open Questions:** Which irreversible admission boundary can each service expose independently of bytes buffered before expiry?

### source-stop-after-committed-placement-holds — Prepared clone source stop

| | |
|---|---|
| **Type** | Safety |
| **Property** | A clone source interruption follows committed destination placement, source temporary-disk hold, destination reservation and transfer slots. |
| **Invariant** | `AlwaysOrUnreachable` **"Clone source interruption follows committed placement and capacity holds"** on the optional source-stop path, using PostgreSQL and physical source witnesses. |
| **Antithesis Angle** | Race host report, admission, cancel and source-stop delivery around the commit boundary. |
| **Why It Matters** | Interrupting the sole recoverable source before copy preparation can strand a VM. [Evidence](property-candidates-02/source-stop-after-committed-placement-holds.md); P0, medium-high confidence. |

**Open Questions:** Which physical stop event and reservation fields best witness the clone transition?

## Breadth and limits

Inspected the fresh SUT/Assertion syntheses, earlier concurrency map, root architecture/ADR guidance, Lilly actor/Runtime/Execution/View and pool lock paths, native host-lock/source-export, Marshall clone/relocation preparation, Audi/Ziggy/Galileo lease paths, Enrico Manager/native Git owner, and terminald mutex/pump/retirement. The repository also contains PostgreSQL admission/host-report locks, Brady cache leases, Porsche connection tasks, request accounting, browser async selection, backup/update flocks and guest Inception semaphores; their core integrity/recovery or authority claims are represented by other focus reports or remain synthesis gaps. This pass is targeted source analysis rather than exhaustive line-by-line verification.

Hosted real services cover BEAM scheduling, PostgreSQL commits, Unix ownership, flocks, Git and PTYs. TCG adds explicitly scoped guest/ZFS behavior; native machines remain necessary for Firecracker/cgroups, real ZFS ownership and physical transfer custody. A historical review or ordinary test presence is not a fresh passing execution. Any suspected PTY mutex stall or multi-row View race remains a **hypothesis** until a composed workload distinguishes SUT, environment and oracle behavior. Architecture impact of this final diff: none; it records candidate tests and changes no decision or implemented contract.
