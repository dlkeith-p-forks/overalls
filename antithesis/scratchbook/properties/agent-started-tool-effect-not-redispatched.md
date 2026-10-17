# agent-started-tool-effect-not-redispatched

P0 safety; high design confidence, medium hosted feasibility. Canonical candidate. Primary `Always` message: **"A started agent command is never redispatched after uncertain executor loss"**. The assertion checks every observed state of the selected durable command after its acknowledged `started` transition; an uncertain command may have zero or one real effect, but never a second dispatch/effect under the same command identity. An explicit new user invocation has a new command/turn/request identity and may create a second effect. Antithesis assertion instrumentation is missing according to `antithesis/scratchbook/existing-assertions.md`.

## Source and decision trail

- `lyra/src/agent.rs:119-124,135-169` claims and heartbeats, acknowledges `started` before dispatching `exec_command`, `read_file` or `web_fetch`, then sends one terminal result. `lyra/CONTRACTS:16-20` requires the start-before-side-effect and fail-closed RPC boundary.
- `marshall/lib/marshall/agents/executor_session.ex:131-189` moves a queued command to `claimed` under current actor/profile authority; `:256-302` validates the same executor/fence for `started` and terminal transitions; `:335-365` invalidates a predecessor and retires `claimed` as cancelled versus `started` as uncertain. `marshall/lib/marshall/agents/command.ex:13-16,32-52` retains command/turn/call identity and terminal state.
- `marshall/lib/marshall/agents/loop.ex:157-181` fails a turn with `tool_uncertain` when any command is uncertain. `marshall/priv/hldd/11-agents.md:115-133` states no redispatch and explicit new invocation after uncertainty. ADR-0100/0101 provide the accepted durable executor and approved CLI context.
- The SQL-backed history explicitly does not prove guest effect (`docs/architecture/reviews/2026-09-26-executor-loss-histories.md:24-46`). A prior native run did observe one real started effect and one explicit retried effect at `:120-143`; `nix/verification/tests/machines/executor-loss/driver.py:460-513` inspects exact command/fence and finite no-replay window. This supports fixture shape, not new hosted or all-interleaving coverage.

## Workload and independent oracle

Use a deterministic provider fixture to issue exactly one `exec_command` with a fixed synthetic marker action in an authorized OSS/Standard guest. The guest action appends a run-scoped constant marker to an isolated fixture file and fsyncs it; the observer reads marker count from the guest after the fault and after healing. It must never journal the command text, prompt, arguments or output. Before injecting loss, witness both Marshall's committed `started` row for exact command ID/fence and either guest marker count 0 or 1. Fault only the executor/child or its RPC link, not the whole guest filesystem. Restart/re-register normally and observe the new fence, old command `uncertain`, `tool_uncertain` turn, no second `claim`/effect for the old command, and identical request-key replay returning the old turn. Then submit a genuinely new approved invocation while authority is current and allow exactly one new command/effect; withdraw permission and verify a further fresh invocation does not reach a guest marker. If the first marker was absent when the interruption happened, absence alone cannot distinguish pre-effect loss from delayed work; the post-heal finite window and command inventory are required.

The oracle is the product of two independently owned observations: PostgreSQL command/executor/turn history, and exact guest-owned marker count. A CLI failure, audit receipt or model answer cannot substitute for the latter. A new invocation's second marker is expected and must not be called a duplicate old-command effect. Consider supplementary `Reachable` **"Agent started command retired uncertain after executor replacement"** as a branch/replay anchor, and `Sometimes(condition)` **"Explicit agent retry completes one new guest effect after uncertain loss"** only with a healthy authorized tail. They have distinct literal messages and do not replace the primary safety check.

## Fault and value menu

Vary loss immediately before acknowledged `started`, immediately after it but before the marker, after fsynced marker before terminal RPC, after terminal RPC send before reply, and after accepted terminal transition. Vary executor process death, child process death, Ziggy/Audi RPC partition, Marshall replica failover, and identical request-key replay. Compare pre-start cancellation with post-start uncertainty. Keep the root VM and retained guest disk stable unless a separate physical-loss property is selected. Record old/new command ID, executor ID, fence epoch, turn/request identity and marker counts as typed structured observations; never emit arguments or marker content to ordinary diagnostics.

## Limits and questions

The hosted `guest-vmm` must run real Lyra and its private verified TLS/relay path; a mock RPC or command-status-only test is insufficient. A TCG guest can establish actual file effect and software restart behavior, not Firecracker isolation. The prior native fixture is one strict sequence, not an Antithesis baseline.

Open question: Can selected hosted composition stop only the executor after `started` while preserving the same guest file, and expose the exact command/fence through a safe test observer? `(partial: a native fixture does so, but hosted guest-vmm and observer are not built)`

### Investigation Log (2026-10-13)

#### Can selected hosted composition preserve the guest effect while replacing only the executor?

- Examined: `lyra/src/agent.rs`, `marshall/lib/marshall/agents/executor_session.ex`, `nix/verification/tests/machines/executor-loss/driver.py:460-513`, the executor-loss review and `antithesis/scratchbook/deployment-topology.md:56-96`.
- Found: source retains command/fence states, and the native fixture freezes one real effect before targeted process loss. The topology proposes a real guest and separately faultable services.
- Not found: a built hosted guest-vmm observer or recorded hosted fault result in this fresh scratchbook.
- Conclusion: retain partial feasibility tag; do not promote the native run to a current hosted or arbitrary-interleaving result.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
