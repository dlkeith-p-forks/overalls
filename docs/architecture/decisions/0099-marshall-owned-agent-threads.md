# ADR-0099: Marshall-owned agent threads and VM tool executors

- ID: ADR-0099
- Date: 2026-09-23
- Status: superseded
- Implementation: partial
- Components: Marshall, Audi, Ziggy, Porsche, Lyra, guest images
- Supersedes: ADR-0063
- Superseded by: ADR-0100

## Context

Users need durable threaded agents attached to VMs. A prompt to a stopped VM
must wake it; a deleted VM must report unavailability while its conversation
history remains visible. Weaver's server owns turns and model inference while a
leased client runs workspace commands. Its child-thread tool does not run a child.
The user selected actual concurrent child agents, browser and CLI access, and
Marshall ownership of the event loop with dumb guest RPC executors.

## Decision

The user's September 23, 2026 plan and implementation request authorize this
decision. Marshall owns agent roots, threads, turns, ordered events, model
context, inference scheduling, executor leases, commands, recovery and audit.
Register one agent root for every newly admitted OSS, Standard and Inception
VM. Customer VMs receive none. Child threads run independently in the root VM;
each thread has at most one running turn, without a product agent-count limit.

Owners, managers, operators and team admins may prompt. Viewers, ordinary team
members and web-only shares may not. A permitted prompt may initiate only a
start operation through the existing host-before-VM lifecycle and capacity
path. It does not confer ordinary lifecycle management. A deleted or missing
machine refuses new prompts with an explicit unavailable state. VM deletion
retains thread history until explicit user deletion.

Marshall calls Ziggy on the VM's current host over a distinct authenticated
server ingress. Ziggy validates current Marshall admission before provider
effects and routes OpenAI calls to host-local Underclass. Guest executor RPCs
enter through Audi's pre-NAT VM binding; guest-supplied identity fields are
never authority. Leases bind placement and execution epoch and increment a
durable fence. Ambiguous tool effects are never replayed automatically.

Persist payload-free audit receipts atomically with agent state transitions.
Diagnostic events use reviewed Events catalogs and exclude prompts, command
arguments, tool output and credentials. Conversation content belongs in
authorized thread events, not audit or diagnostics. Verify state invariants
with property tests and transport/boot behavior with NixOS machine tests.

## Alternatives

A guest-owned model loop would simplify server scheduling but split durable
context and recovery authority between Marshall and VM disks. Marshall calling
Underclass directly would bypass Ziggy's existing admission and accounting.
Creating a child thread without queuing its work would not provide running
subagents.

## Consequences

Marshall becomes responsible for model and tool orchestration and needs a
trusted host-local Ziggy ingress. Guest software remains a bounded executor.
Provider, VM, or executor outages must appear in durable turn state. The
server and guest must fence stale sessions across restart and relocation.

## Invariants and verification

- One root per eligible VM and no Customer root; thread history survives VM deletion.
- Current write-capable VM access admits prompts; automatic wake creates only a
  start operation with agent provenance and retains capacity serialization.
- Turn and event order, prompt idempotency, single active turn and child result
  linkage hold under generated operation sequences.
- Old lease results cannot complete a command; uncertain tool effects are not
  dispatched again.
- Audit/log projections contain no prompt, command argument, tool result or key.
- NixOS machine tests exercise real services, stopped/deleted VM behavior,
  reconnects, and Marshall-to-Ziggy-to-Underclass routing.

## Implementation evidence

The [Ash agent domain](../../../marshall/lib/marshall/agents.ex),
[VM admission registration](../../../marshall/lib/marshall/compute/admission.ex),
[prompt coordinator](../../../marshall/lib/marshall/agents/prompt.ex), and
[executor coordinator](../../../marshall/lib/marshall/agents/executor_session.ex)
implement roots, idempotent prompts, narrow wake and lease fencing. The
[turn coordinator](../../../marshall/lib/marshall/agents/turn_coordinator.ex)
adds PostgreSQL-claimed per-thread running and terminal transitions. The
[focused tests](../../../marshall/test/marshall/agents/prompt_test.exs) and
[executor tests](../../../marshall/test/marshall/agents/executor_session_test.exs)
exercise those portions against PostgreSQL. The
[browser workspace](../../../marshall/lib/marshall_web/live/agent_threads_live.ex)
supports authorized conversation reads, prompts and child-thread creation;
the owner can read retained history after VM archival. The
[Ziggy route](../../../ziggy/lib/ziggy/config.ex) and
[NixOS machine test](../../../nix/tests/machines/ziggy-underclass/default.nix)
verify host-local Underclass discovery with the proxy credential. Inference
orchestration, Marshall-to-Ziggy and guest executor transport, running children,
CLI flows and whole-system acceptance remain open; this decision is partial.

## Open questions

None for the selected architecture. Implementation and live acceptance remain.

## Related decisions

[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) replaces the server
ingress with host-authenticated work pulling while preserving Marshall's loop.

[ADR-0042](0042-host-observability.md) governs diagnostics;
[ADR-0063](0063-private-services-and-ziggy.md) governs guest inference;
[ADR-0081](0081-independent-underclass-pools.md) governs Underclass custody;
[ADR-0096](0096-lyra-developer-ssh.md) governs the desktop CLI.
