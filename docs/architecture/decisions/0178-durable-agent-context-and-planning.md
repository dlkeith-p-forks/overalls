# ADR-0178: Durable agent context, compaction and planning

- ID: ADR-0178
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: Marshall Agents, Threads, Ziggy, shared protocol, browser workspace
- Supersedes: none
- Superseded by: none

## Context

Marshall owns the model loop and retained thread history under ADR-0100. The
current request builder selects a bounded recent event window. That bound is
not a context checkpoint: it can discard earlier decisions and instructions,
and it does not describe which events a summary covers. Users also need a
planning workflow, durable clarification questions and a composer command
palette without moving work to a different machine.

The user's October 16, 2026 implementation request authorizes this decision and
the companion guest instruction and skill decision, ADR-0179. Existing thread
sharing, execution fencing and ambiguous-effect recovery remain in force.

## Decision

### Context and compaction

`Marshall.Agents` owns immutable context snapshots and checkpoints separately
from retained transcript events. Admission captures collaboration mode,
reasoning, working directory, configuration owner and explicit skill identities.
Guest collection happens outside database transactions; a verified snapshot is
attached atomically before inference. It records source identities, digests and
the applied instruction content. It is a verified-content snapshot, not an
atomic snapshot of an entire guest filesystem. Changed source collection retries
twice, then returns `context_changed` without silently accepting mixed versions.

Requests reconstruct eligible context from a checkpoint and its continuation.
Coverage identifies eligible turns and the active turn's event frontier, rather
than relying only on a global event sequence. Later queued prompts cannot enter
an earlier active turn, even when their sequences precede its tool results.
Complete tool-call/result groups remain together. Current application
instructions and the latest user request remain available after compaction.

Compaction is a separate durable model-work purpose with independent validation,
completion handling and iteration accounting. Automatic compaction evaluates
the complete projected request before inference and between tool iterations. It
triggers at 90% of a configured input-token allowance or 75% of the existing
byte/item bounds. Token usage is an explicit estimate, not a provider tokenizer
measurement. When the model token limit is unknown, byte/item bounds apply
and the UI reports token capacity as unknown. Oversized historical context is
folded through bounded batches; required instructions plus current input that
cannot fit receive an explicit size refusal.

The default compactor uses a tool-free model summary preserving decisions,
constraints, completed work, open work and needed references. The summary is
generated context, never trusted application policy. Native Responses compaction
uses `compaction_trigger` only for provider/model capabilities independently
verified for its returned state, with tools disabled for the maintenance request.
Deployment configuration binds that verification to an exact provider/model
allowlist record and a lowercase SHA-256 evidence digest; a legacy global
boolean cannot enable it. Marshall currently accepts only OpenAI routes and
rechecks the pair when queuing and claiming, while omission leaves native
compaction disabled.
Both paths keep the existing Ziggy pull,
inference admission and accounting route; no listener or host service is added.

Checkpoint publication compares the current generation and covered frontier in
the same transaction that installs a complete validated result. Stale, failed,
cancelled or incomplete results preserve the previous checkpoint. Continuation
events are included exactly once. Definite context-limit refusals have bounded
recovery; no-progress loops stop. A claimed model call whose outcome is ambiguous
is not automatically replayed. Compaction consumption enters ordinary usage
accounting, separately from the current active-context estimate.

### Planning and interaction

Threads default to **Work**. **Plan** is a distinct collaboration mode, separate
from the existing low/medium/high/ultra reasoning setting. The selected mode is
persisted and captured on each admitted turn; children inherit mode and context
settings. Changing mode while work is running or waiting for answers refuses.
Plan supplies trusted instructions to explore, ask material questions and return
a decision-complete proposal. It is an instructional workflow, not a read-only
sandbox or a new tool-permission boundary. Repository text, skills, summaries
and user prose cannot change the persisted selected mode.

Root Plan turns can issue the Marshall-owned `request_user_input` control tool.
One request contains one to three questions with stable identifiers, choices
and a free-text alternative. Pending questions and answers survive browser and
Marshall restart. Current write authority and the active question identity are
rechecked when answering. Identical retries return an immutable result;
competing submissions cannot replace an accepted answer. Cancellation,
archival and loss of authority invalidate the pending request.

A completed `<proposed_plan>` response yields a sanitized plan card. Incomplete
output has no implementation action. **Implement plan** binds the latest
completed proposal and atomically admits a Work turn in the same thread and
machine. **Revise** retains the planning workflow. Switching collaboration mode
does not alter reasoning or machine identity.

The top composer has a Commands button, composer-scoped Ctrl/Cmd+K and slash
completion for `/plan`, `/work`, `/compact`, `/skills`, `/context`, `/terminal`,
`/code`, `/share` and `/help`. `/plan [task]` and `/work [task]` select the mode
and optionally submit a task atomically. Mode selection on a new-thread form
does not provision a machine. Unknown commands preserve the draft and explain
the refusal; a leading space submits slash-looking text literally. Keyboard,
touch, focus restoration and IME composition remain supported. Viewers remain
read-only and every action rechecks current server authority.

## Alternatives

Keeping only recent events loses context without an auditable coverage boundary.
Replacing the transcript with a summary would erase user-visible history and
make checkpoint recovery part of transcript retention. Giving model summaries
instruction authority would let generated text change application policy.
Changing only a prompt label would not make questions or implementation choices
durable. A new read-only execution sandbox is a separate isolation decision and
is not part of this instructional mode.

## Consequences

Additional Ash resources, retained snapshots and immutable receipts increase
storage and require explicit retention inventory. Compaction adds model latency
and usage. Native compaction remains disabled without provider-specific evidence.
The browser gains durable waiting and proposal states without becoming an
execution authority. Existing machine bindings, leases, personal identities and
thread ACLs continue to govern all work.

## Invariants and verification

- A checkpoint cannot cover an ineligible queued prompt or omit accepted
  continuation events. Generated replay histories must include interleaved
  queued prompts, tool calls/results and repeated compaction.
- Failed, stale or incomplete compaction cannot replace the active checkpoint;
  uncertain provider work is never automatically retried.
- Instructions are rebuilt from the recorded snapshot after compaction; a
  summary cannot change mode, permission, owner or tool policy.
- Pending questions survive restart and admit one answer under current write
  authority. Revoked, cancelled, archived and stale requests refuse.
- Implementation binds the exact completed proposal and admits one Work turn
  under current authority without changing machine or reasoning.
- SQL-backed tests and properties establish state transitions only. Native
  Marshall-to-Ziggy-to-provider-fixture continuation, browser keyboard/mobile
  behavior and actual provider-native support require separate execution.

## Implementation evidence

The [agent domain](../../../marshall/lib/marshall/agents.ex) registers
[ContextSnapshot](../../../marshall/lib/marshall/agents/context_snapshot.ex),
[ContextCheckpoint](../../../marshall/lib/marshall/agents/context_checkpoint.ex),
[PlanningQuestion](../../../marshall/lib/marshall/agents/planning_question.ex)
and [PlanProposal](../../../marshall/lib/marshall/agents/plan_proposal.ex).
The [context coordinator](../../../marshall/lib/marshall/agents/context.ex)
collects guest manifests through durable commands and reconstructs eligible
events by turn ordinal and checkpoint frontier. The
[manifest validator](../../../marshall/lib/marshall/agents/context_manifest.ex)
checks contiguous digest-bound file chunks; the
[compactor](../../../marshall/lib/marshall/agents/compaction.ex) builds bounded
summary/native requests and validates purpose-specific results.
[Planning](../../../marshall/lib/marshall/agents/planning.ex) defines trusted
mode instructions, durable question/answer state and exact proposal admission.

[Compaction tests](../../../marshall/test/marshall/agents/compaction_test.exs),
[planning parser properties](../../../marshall/test/marshall/agents/planning_test.exs)
and [planning persistence cases](../../../marshall/test/marshall/agents/planning_persistence_test.exs)
are present. Native maintenance admission is bound to exact provider/model
capability evidence and rechecked at queue and claim; omission leaves native
compaction disabled. The focused Marshall feature suite passed 64 cases (61
tests and 3 properties), including schema migration and integrated loop
fixtures. The distributed recovery suite adds four process-loss cases for
pending questions, checkpoint projection, compaction-plan reconstruction and
managed-skill dispatch across replacement peers; it observes committed
PostgreSQL state and does not establish guest/provider completion. Native guest,
browser and deployment acceptance remain tracked separately in the [context
review](../reviews/2026-10-16-agent-context-and-planning.md). Source presence
does not establish live provider or browser acceptance.

## Open questions

None for the accepted behavior. Provider-native capability verification and
native recovery acceptance remain delivery requirements.

## Related decisions

- [ADR-0100: Pulled agent work](0100-pulled-agent-work-over-ziggy-control.md)
- [ADR-0159: Remove legacy compatibility](0159-remove-legacy-compatibility.md)
- [ADR-0161: Monospace presentation](0161-monospace-web-presentation.md)
- [ADR-0174: User threads](0174-user-threads.md)
- [ADR-0175: Thread sharing](0175-thread-sharing-and-bound-machine-authority.md)
- [ADR-0179: Guest instructions and managed skills](0179-guest-instructions-and-managed-skills.md)
