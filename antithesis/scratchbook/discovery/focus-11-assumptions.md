---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Focus 11: Unproven assumptions

This pass identifies assumptions whose truth cannot be inferred from successful syntax checks, isolated resource transitions, or a healthy process. It examined the current reset worktree at the captured baseline, including its existing reset changes, without editing repository files or consulting the retired Antithesis tree. A refusal caused by expired authority, uncertain cleanup, or an invalid manifest is normally intentional. The useful question is whether ordinary authorized work can reach that refusal because another component assumes incompatible timing, ordering, or proof semantics.

The findings below distinguish **source hypothesis**, **isolated witness reported by a subpass**, and **documented gap**. None establishes universal deployment behavior. Source citations use repository-relative paths and line numbers for the inspected worktree.

## Ordering, leases and clocks

### A01. Guest tools assume execution finishes before the lease needs renewal

Marshall issues thirty-second executor leases and requires an unexpired lease for every result transition (`marshall/lib/marshall/agents/executor_session.ex:8,96–104,335–344`). Lyra renews in its session loop, immediately before executing a claimed tool; execution and the final transition run synchronously in that same loop (`lyra/src/agent.rs:114–124,151–168`). Yet `web_fetch` explicitly accepts timeouts through 120 seconds (`lyra/src/agent/web_fetch.rs:38–40,82–83`; ADR-0108).

**Source hypothesis:** a healthy fetch taking more than thirty seconds cannot heartbeat, so Marshall refuses its terminal result. Subsequent registration makes the already-started command uncertain (`executor_session.ex:357–363`). The stale-result refusal and prohibition on replaying ambiguous effects are correct. The unproven premise is compatibility between supported tool duration and heartbeat ownership. Test a slow successful origin and distinguish its actual response from the committed tool outcome.

### A02. Byte caps assume I/O finishes and read errors are equivalent to EOF

Lyra accepts an absolute `read_file` path, opens it synchronously, and reports completion after `read_limited` returns (`lyra/src/agent.rs:218–230`). The reader turns every `Read::read` error into the same termination as EOF (`:234–246`). Shell tools use `timeout --kill-after=2 20`, then wait for both reader threads to finish (`:181–209`).

**Source hypotheses:** FIFO/device opens, stalled filesystem reads, or descendants retaining inherited pipes can block heartbeat progress beyond the advertised tool bound. A post-open I/O error can also yield partial content labeled completed. Intentional output truncation is a competing explanation for limited bytes, but it does not establish a duration bound or justify treating EIO as successful EOF. The relevant obligation is `lyra-agent-fenced-execution` (`lyra/CONTRACTS:16–20`). No native EIO or escaped-agent-pipe reproduction was run here.

### A03. Galileo assumes authorization age starts when its guardian runs

Marshall returns a 2,000 ms authorization TTL (`marshall/lib/marshall/galileo/authorizations.ex:11,34–38`). Galileo obtains that response, then admits request accounting before invoking the upstream stream (`galileo/lib/galileo/http.ex:99–116`). Recorder admission can block for five seconds (`elixir/request_accounting/lib/overalls/request_accounting/producer.ex:57–64`). The guardian computes its initial deadline inside the subsequently spawned process (`galileo/lib/galileo/upstream.ex:411–428`), before upstream connection work at `:83–98`.

**Source hypothesis:** recorder delay or guardian scheduling starts an upstream effect using authorization older than its intended lease. Even a receipt-relative TTL interpretation does not explain starting after additional local delay. Audi provides a contrasting explicit request-start boundary (`audi/lib/audi/authority/lease.ex:7–17`). Establish the intended Galileo clock origin before turning this into a safety property; carry request/receipt/start times in the witness.

### A04. Galileo assumes mailbox timeouts dominate expired queued messages

Both guardian loops answer a matching status query with `true` without checking the current clock (`galileo/lib/galileo/upstream.ex:438–440,506–518`). Renewal and expiry enter through `receive ... after` (`:431–448,491–518`). A late renewal response does explicitly compare the old expiry and closes instead of resurrecting authority (`:520–525`).

**Source hypothesis:** suspend the guardian across expiry, enqueue status queries, then resume it. Matching messages can be handled before an already-expired receive timeout, allowing the caller to observe an open lease and proceed with request/body writes (`:153–159,245–248`). This is a more precise condition than “timers run late”: the status handler itself lacks an expiry predicate. Compare with Ziggy's direct owner-kill timer and explicit late-renewal check (`ziggy/lib/ziggy/lease.ex:19–28,52–65`). No runtime guardian-pause witness was executed.

### A05. Persisted provisioning deadlines assume wall-clock continuity

Lilly persists launch time and a 120-second budget, or forty minutes for Inception (`lilly/lib/lilly/vm/provisioning.ex:140–149`). Remaining time and readiness acceptance use `System.system_time` (`:67–81,96–107`), while the guest exchange receives a newly constructed monotonic deadline (`lilly/lib/lilly/vm/driver.ex:528–538,944–969`). The lifecycle validator also compares readiness against wall time (`lilly/lib/lilly/lifecycle/provisioning.ex:46–63`).

**Source hypothesis:** clock steps between persistence, recovery and conversion change the effective elapsed budget. A backward step before launch can additionally violate the required `launched_at >= started_at`; a forward step can cause conservative early refusal. Existing tests prove original-deadline preservation and late-proof refusal (`lilly/test/vm/provisioning_test.exs:48–87`; `lilly/test/lifecycle/provisioning_test.exs:141`), not actual clock-step histories. Refusal is intentional; eventual authorized recovery under corrected clocks remains the question.

### A06. Host-report progress assumes database and Lilly clocks remain compatible

Marshall deliberately uses fresh database time (`marshall/lib/marshall/compute/ledger.ex:228–234`). Host reports must be no more than one second ahead and within the host-authority window (`host_reports.ex:197–219`); future accepted samples are clamped (`:169–170`). The whole exchange commits outcomes, report, acknowledgments and returned commands together (`provisioner_control.ex:154–181,208–217`).

**Source hypothesis:** sustained skew or an unreconcilable command can repeatedly roll back otherwise valid physical outcomes, so a healthy transport does not establish settlement progress. Lilly correctly avoids replaying a sent sample as fresh (`lilly/lib/lilly/control/runtime.ex:823–858`), and report tests cover malformed, future and late snapshots (`marshall/test/marshall/compute/host_reports_test.exs:252–285`). Test recovery after skew correction and isolate batch poisoning from safe atomic refusal.

## Atomicity and proof versus effect

### A07. Readiness assumes concurrent observations preserve verdict order

Marshall readiness reads a shared atomics cell, performs a database observation, then writes the resulting last-ready value (`marshall/lib/marshall/operations/health.ex:34–38,77–95`). Definite negative answers clear it; inconclusive answers preserve the value previously read for at most thirty seconds (`:41–50`).

**Source hypothesis:** one probe reads a recent ready value, another probe observes a definite refusal and clears it, then the first inconclusive probe restores its stale value. That can let subsequent inconclusive probes retain readiness after a definite negative observation. The pure sequential property and sequential unanswered-probe test do not exercise overlapping observations (`marshall/test/marshall_web/health_test.exs:41–90`). The thirty-second conservative availability policy is explicit, not itself a defect; the unresolved issue is ordering of shared verdict updates.

### A08. Versioned views assume individual exact reads compose into current authority

`OverallsProtocol.View.fetch` gives an individual ETS read, while versions increment per view-process lifetime and reset to zero on restart (`protocol/lib/overalls_protocol/view.ex:73–90,93–99,135–151`). Lilly joins runtime, intent and live proof using three separate reads and returns only the proof version (`lilly/lib/lilly/execution.ex:106–114`). Owner-death removal arrives asynchronously through `DOWN` (`view.ex:182–189`).

**Source hypotheses:** interleaving a disconnect or view restart with the join may combine rows that never jointly held authority; consumers relying only on version equality can encounter version reuse after restart. Missing tables safely produce refusal, and owner cleanup is explicitly eventual in the generated model (`protocol/test/view_test.exs:215–224`). This needs consumer-specific linearization and lifetime analysis, not an indiscriminate claim that ETS or asynchronous monitors are wrong.

### A09. Certificate rotation assumes logical fallback still has physical material

Audi installs new material before probe and acknowledgment (`audi/lib/audi/tls/fleet_worker.ex:136`). The store replacement removes the sole older stored generation (`audi/lib/audi/tls/store.ex:153`). A failed probe leaves the old logical serving generation, but the worker can subsequently find its material absent and expire readiness (`fleet_worker.ex:236`). The failed-probe preservation note at `:102` is stronger than this physical replacement sequence.

**Source hypothesis:** a transient probe or acknowledgment failure during rotation discards prior valid availability. Verify old/new on-disk generations, selected generation, actual TLS handshakes and Marshall acknowledgment separately. Refusing retired or unproven material remains intentional. This finding identifies a proof/effect seam, not evidence that current production certificates are unavailable.

### A10. Session closure and diagnostic completion assume successful remote settlement

Marshall durably opens counted Porsche sessions with twelve-hour authenticated lifetime (`marshall/lib/marshall/ssh/authority.ex:115`). If the open reply is lost, Porsche retains an error rather than the issued session (`porsche/lib/porsche/connection.ex:77`); termination can close only locally retained sessions. **Source hypothesis:** repeated postcommit reply loss accumulates counted slots until expiry. Separately, closure ignores the remote close result and emits `session_closed` unconditionally (`connection.ex:125–128`): that event proves an attempted close, not durable closure.

Lilly intentionally swallows diagnostic handoff failures and drops uncertain-release batches (`lilly/lib/lilly/lifecycle/publication_diagnostics.ex:40–53,59–82`). ADR-0149 permits diagnostics to fail independently of lifecycle effects. Consequently, diagnostic absence or presence cannot substitute for durable state and physical evidence in either direction.

## Guest, storage and operational assumptions

### A11. PTY kill assumes input cannot hold its required mutex indefinitely

Terminald's reader pump holds `session.inner` during blocking writes to the PTY master (`nix/domains/artifacts/terminald/src/session.rs:518–523`). Explicit kill acquires that mutex before reaching SIGKILL (`:323–344`); the master opens without nonblocking mode (`nix/domains/artifacts/terminald/src/pty.rs:158`). **Source hypothesis:** fill a stopped or non-reading slave's input queue and kill cannot obtain the mutex needed to signal it. Existing output/credit pressure tests do not establish input-queue progress.

A related lifetime hypothesis concerns resizing a raw master descriptor after releasing the liveness check, while retirement can close it (`session.rs:350–355,772–774`). Descriptor reuse could affect another session. Neither native timing witness was executed; these are precise candidate schedules, not established isolation failures.

### A12. Backups assume independently sampled wall times form valid manifests

Backup start and completion use separate wall-clock samples (`nix/domains/system/backups/journal.py:125`; `runtime.py:208–225`). Upload happens before retention invokes manifest validation. The validator requires `started_at <= completed_at` and retention validates every manifest (`restic.py:239–242,272–274`).

**Isolated modeled boundary reported by the native subpass:** start 2000, completion 1000 produces a manifest the real validator refuses. **Source hypothesis for full execution:** a backward clock step can upload such a manifest and poison subsequent retention passes. Retention's refusal protects existing snapshots; it is not the bug. The unproven premise is publication of a completed point before validating its own temporal schema. Full clock-step/Restic/native acceptance remains unexecuted.

### A13. Backup health and subprocess custody assume different proofs than their names suggest

Conservative reader retirement can wait indefinitely (`nix/domains/system/backups/common.py:181–198`), while an independent heartbeat refreshes status (`runtime.py:112–117`). The exporter detects staleness from heartbeat age (`nix/domains/system/fleet-exporter/backup_status.py:97–103`). Thus fresh running status does not prove journal progress. Test phase/sequence advancement separately; an uncertain reader must still prevent unsafe cleanup.

The delegated subpass also reported an actual isolated helper witness: a child escaped into a new session, retained a private source descriptor, and remained alive after `common.run` returned. Filtering the original process group occurs at `common.py:111,175–198`. This establishes the generic helper's custody limit, not that pinned Restic actually escapes or that native cleanup becomes unsafe; Lilly has additional lock custody. Witness artifacts were not independently replayed by this focus author.

### A14. Browser events, reporting batches and health probes assume their observations imply progress

Browser action callbacks overlap and apply captured URL state after awaits (`marvin/common/extension.mjs:20–23,39–43`). **Modeled race reported by a subpass:** a newer supported update enabled the action, then an older unsupported update disabled it. Click-time URL validation remains intact (`:59–63`); this is stale UI availability, not unauthorized transmission.

Ziggy selects the first 128 completed spool entries and retains permanent conflicts without a cursor (`ziggy/lib/ziggy/spool.ex:160`; `reporter.ex:35`). Permanent-conflict starvation is an explicitly preserved gap (`docs/architecture/reviews/2026-10-03-ziggy-reporter-histories.md:53`). Brady's admitted-origin `:invalid_http` can reach an omitted measurement case and fall back to exclusion (`brady/lib/brady/http/stream.ex:80–86`; `proxy.ex:143–160,183–187`), an untested undercount hypothesis. Enrico readiness proves directory presence and Manager registration (`enrico/lib/enrico/health.ex:11`), not writable storage or a working Git read.

## Assumptions and open questions

The review read AGENTS, architecture overview/index, research discovery/analysis/claim-validation instructions, code-contract guidance and applicable ancestor contracts. Relevant decisions include ADR-0017, 0070, 0082, 0108, 0130, 0140, 0142, 0149 and 0154. No full application, Nix, type, contract or native acceptance gates ran. The already documented boot-report bound remains unresolved: a twenty-second tool started near the thirty-second deadline can overshoot it (`nix/domains/artifacts/guest/boot_report.py:95–125`; architecture overview `:570–572`). It is observation-only, independent of readiness.

The satellite subpass had a model-capacity interruption and resumed to finish; this reduced fresh independent review time, not repository coverage authorization. Broad coverage is source discovery rather than exhaustive semantic verification. Guest/Nix subpasses supplied modeled and isolated-process witnesses whose stated limits are retained above. No external tracker or production evidence was consulted. Open work is to settle grant-clock and view-linearization semantics, obtain native PTY/clock/certificate histories, and distinguish progress oracles from liveness probes before property promotion. This artifact changes no architecture or implementation; accepted refusals and ADR rationale remain intact.
