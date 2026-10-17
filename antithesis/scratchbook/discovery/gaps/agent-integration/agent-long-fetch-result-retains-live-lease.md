# agent-long-fetch-result-retains-live-lease

P0 liveness; high source-hypothesis confidence, medium hosted feasibility. Canonical candidate. Primary `Sometimes(condition)` message: **"A permitted slow guest fetch reaches a durable completed tool result"**. The meaningful condition is one authorized guest `web_fetch` to a controlled, healthy local TLS origin that records a complete response after >30 seconds and <120 seconds, with the *same command* durably `completed` and its result delivered to its turn. It is conditional progress in a selected finite healthy tail, not a claim that every network request finishes. Antithesis assertion instrumentation is missing according to `antithesis/scratchbook/existing-assertions.md`.

## Source hypothesis and distinction

`marshall/lib/marshall/agents/executor_session.ex:8,96-105,335-345` issues a 30-second lease, extends it only on heartbeat, and rejects a terminal transition once expired. `lyra/src/agent.rs:110-125` sends a heartbeat before a claimed command; `:135-169` executes it synchronously before sending the final transition. There is no heartbeat call in that execution interval. `lyra/src/agent/web_fetch.rs:18-28,34-55,71-94` accepts timeouts from 1 to 120 seconds and performs a blocking HTTP send/read. ADR-0108 `:20-33` documents the same supported timeout range and a bounded result. `marshall/lib/marshall/agents/executor_session.ex:357-365` only retires a stale `started` command to `uncertain` upon a later registration, while `marshall/lib/marshall/agents/loop.ex:157-181` then fails the turn. The source suggests a supported fetch lasting beyond the executor lease can perform the remote GET yet lose its terminal result. No timed composed reproduction was run; this is a source hypothesis, not a confirmed defect.

This is distinct from `agent-started-tool-effect-not-redispatched`: non-replay can work exactly as designed while a healthy permitted slow fetch becomes unnecessarily uncertain. It is also distinct from `galileo-accounting-delay-does-not-renew-old-grant`: this path is Lyra's 30-second executor lease and guest HTTP client, not Galileo's 2-second upstream lease.

## Workload and oracle

Select a deterministic model response that requests one `web_fetch` with `timeout=60` or `120`, `format=text`, and a fixed local HTTPS URL reached through actual guest networking and its CA store. The origin accepts one request, waits e.g. 29, 31, 45 or 60 seconds under workload control, then sends a small valid text response. The fixture records only a synthetic request ID, accept/response timestamps and count. Read Marshall's command/executor/turn rows and the authorized result view after delivery. The primary condition requires origin response sent successfully, exact command completed, and exact result delivered, with current owner/write authority, live guest, available Ziggy/Audi/Marshall/PG and no injected failure during the final healthy interval. A 30-second transport timeout or client cancellation must be distinguished from lease expiry; use shorter control delays and verify a separate native guest TLS success first.

Supplementary `Reachable` **"Slow guest fetch outlasted the executor lease before result RPC"** at a safe SUT transition boundary would guide the rare timing path. A companion safety assertion could state that a rejected stale result never changes a terminal row, but that is already the fence mechanism and does not establish the desired successful completion. Any SUT-side timing metadata must be numeric/fixed and exclude URL, content or credential.

## Fault/value menu and limits

Delay at 0/29/31/45/60 seconds; fetch timeouts 30/60/120 seconds; lose/recover heartbeat RPC before claim, block the final result RPC, replace executor during wait, and withdraw actor access while origin is open. Keep these separate from the healthy long-fetch progress case. An old expired lease must never be treated as authorized merely because the origin responded; after replacement, an uncertain started effect still must not replay. Delayed origin response and bytes prove remote effect, but a failed terminal transition proves outcome loss only when the same command/fence and client timeout are observed. TCG guest tests actual Lyra execution and guest networking, not physical egress isolation or public provider behavior.

Open question: Does a successful controlled fetch taking >30 seconds lose its final transition with no in-tool heartbeat? `(partial: source has 30-second lease and synchronous fetch with no observed heartbeat; no timed composed guest/origin run)`

### Investigation Log (2026-10-13)

#### Does a successful controlled fetch overrun the executor lease?

- Examined: `lyra/src/agent.rs:110-169`, `lyra/src/agent/web_fetch.rs:18-94`, `marshall/lib/marshall/agents/executor_session.ex:8,96-105,335-365`, ADR-0108, `antithesis/scratchbook/discovery/focus-11-assumptions.md:18-24`.
- Found: heartbeat occurs immediately before synchronous tool execution; the fetch allows 120 seconds; Marshall's transition checks a 30-second expiry. Source contains no in-tool heartbeat in this path.
- Not found: a composed run with a controlled >30-second successful guest fetch and matching durable result/expiry observations, or evidence that another process renews this executor during execution.
- Conclusion: source-grounded high-value timing hypothesis; retain partial tag until origin and durable-command receipts discriminate lease expiry from network or client failure.
