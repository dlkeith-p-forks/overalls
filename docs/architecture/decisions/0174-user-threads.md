# ADR-0174: User threads own isolated work machines

- ID: ADR-0174
- Date: 2026-10-15
- Status: superseded
- Implementation: partial
- Components: Marshall
- Supersedes: none
- Superseded by: ADR-0175

## Context

[ADR-0175](0175-thread-sharing-and-bound-machine-authority.md) replaces only this
record's creator/team-only authority with durable thread sharing that contributes
to the current bound machine's ACL. All task ownership, provisioning, readiness,
lifecycle, retained-history and recovery decisions below remain in force.

Marshall already exposes agent conversations under a machine URL. Users need a
higher-level task object with a stable URL that creates and owns the machine
where its agent work runs. Provisioning can outlive the browser request and
must recover after a control-plane or worker restart.

## Decision

`Marshall.Threads` is a distinct Ash domain. A thread stores its creator/team,
objective, generated title, immutable mode, typed machine specification,
create idempotency key, machine admission key, provisioning state and the bound
VM/agent identities. Creation
commits the pending thread and its Oban job atomically before the worker calls
existing Compute admission. The worker records the admitted machine identity,
waits for Compute to observe the VM running, binds the
automatically registered agent root/thread, submits the initial objective with
a stable request key, and then marks the user thread ready. Retries reuse the
machine admission key and initial turn. Prompts and terminal sessions resolve
through that bound machine and continue to use the existing Cedar/team authority.

Modes are a closed `low`/`medium`/`high`/`ultra` set mapped by validated runtime
configuration to model and reasoning settings. A bounded title generator runs
after admission and falls back to the objective without blocking the thread.
Archiving and deletion record deleting intent and use the existing VM lifecycle
coordinator. A durable archive worker marks the thread archived only after
Compute records the VM as deleted. The thread, objective and authorized
transcript remain available as read-only history; VM identity history is never
erased. An authorized reopen clears the retired binding, preserves the original
create idempotency key, assigns a fresh machine admission key, and queues
provisioning again. PaperTrail retains the retired binding in thread history.

## Consequences

Thread creation may remain pending or failed and needs an explicit retry path.
Readiness includes both the observed running VM and acceptance of the initial
objective. Row locks and the machine admission key fence every provisioning
write from deleting, archived or superseding generations. A stale worker must
not bind a machine or resurrect a retired thread generation. Failed admissions
require physical cleanup before retry can assign a replacement machine key.
The thread domain coordinates Compute and Agents but does not replace either
domain's persistence or authorization. A reopened archived thread requires a
new machine binding. The first UI release includes transcript and terminal
access; richer machine panes remain separate work.

## Alternatives

Reusing machine-scoped agent threads would keep the existing URL shape, but it
would leave machine provisioning and lifecycle visible to users and could not
represent a durable task before admission. Creating the machine synchronously
inside the browser request would make provider latency and retries part of the
request lifecycle. A separate thread record with asynchronous admission keeps
the user-facing task stable while reusing the existing machine and agent
boundaries.

## Invariants and verification

- A thread has at most one active machine per machine admission key and retries
  reuse that Compute admission. Reopen assigns a fresh key after archival;
  replaying the original create request still returns the same user thread.
- A thread reaches ready only after an observed running VM and idempotent
  acceptance of the initial objective by its bound agent thread.
- Deleting remains durable until Compute confirms physical deletion. A stale
  provision worker must not move a deleting or archived thread to ready.
- No prompt or terminal operation bypasses current team/machine authorization.
- Reads of retained transcripts recheck user-thread authority and validate the
  paired agent-root and agent-thread identities before reading agent events.
- A mode cannot change after its agent work begins.
- Provisioning failures remain recoverable and do not expose raw provider data
  in events or diagnostics.
- A committed event on the current bound agent thread advances the enclosing
  user thread's `updated_at` activity clock after commit. The projection locks
  the user-thread row and skips archived or deleting threads; stale bindings
  cannot grant lifecycle or machine authority.
- Unit, LiveView, authorization, worker-replay and lifecycle tests provide
  bounded evidence; native isolation, failure recovery and production
  model-provider acceptance require separate execution evidence.

## Implementation evidence

The implementation is in
[`Marshall.Threads`](../../../marshall/lib/marshall/threads.ex),
[`Marshall.Threads.Thread`](../../../marshall/lib/marshall/threads/thread.ex),
the [coordinator](../../../marshall/lib/marshall/threads/coordinator.ex),
[provision worker](../../../marshall/lib/marshall/threads/provision_worker.ex),
[archive worker](../../../marshall/lib/marshall/threads/archive_worker.ex) and
[`/threads` LiveView](../../../marshall/lib/marshall_web/live/threads_live.ex).
The [machine-key migration](../../../marshall/priv/repo/migrations/20261015120000_thread_machine_keys.exs)
introduced a nullable machine key and backfilled existing threads from their
original admission key. Both hosts converged healthy on
`d5e03c080204a33a11b8c136e983593630e4fccf` on 2026-10-15; that expansion retained
a nullable column and the temporary create-key fallback. The dependent
[required-key migration](../../../marshall/priv/repo/migrations/20261015230000_require_thread_machine_keys.exs)
backfills any late null rows and enforces `NOT NULL`. The matching resource and
workers now require and use the explicit machine key, removing the row-key
fallback under ADR-0159. Provisioning and archive jobs require a matching key;
malformed unkeyed jobs are cancelled. Create, replacement retry and reopen continue
writing that key. Both hosts subsequently converged healthy on contraction
revision `32624e1bf80df120beb69b923eee4362427aee23`; read-only SQL confirmed
`NOT NULL` and zero null keys. The
[review](../reviews/2026-10-15-user-threads.md) records the separate expansion,
contraction and database observations.
[Thread tests](../../../marshall/test/marshall/threads_test.exs),
[lifecycle tests](../../../marshall/test/marshall/threads_lifecycle_test.exs),
[required-key tests](../../../marshall/test/marshall/threads_machine_key_test.exs),
[transcript tests](../../../marshall/test/marshall/threads_transcript_test.exs) and
[LiveView tests](../../../marshall/test/marshall_web/threads_live_test.exs) are
present. The [review](../reviews/2026-10-15-user-threads.md) records a passing
31-test focused run and presentation checks on the initial working integration,
then a 32-test focused run including the required-key enforcement and refusal
cases, anchored to committed revision `32624e1bf80df120beb69b923eee4362427aee23`.
It also records one deployed production retry that reached ready with one running
VM and one completed initial objective turn, with the same identities retained
through contraction deployment. That case
does not establish native archive/reopen, cross-node worker-loss recovery or
broader provider acceptance; those remain pending.

The retained-generation extension adds [`Marshall.Threads.Generation`](../../../marshall/lib/marshall/threads/generation.ex)
and a migration that backfills one generation for every existing thread. Each
admission, retry, archive and reopen keeps a durable generation row. Authorized
readers can call `Marshall.Threads.generations/2` and
`Marshall.Threads.events/4`, and `/threads/:id?generation=N` renders the
read-only selector. The transcript test covers a reopened thread whose first
machine event remains readable while an unknown generation is refused. Native
reopen and cross-node recovery still require separate execution evidence.

The activity projection adds [`Marshall.Agents.EventActivity`](../../../marshall/lib/marshall/agents/event_activity.ex)
to event append and [`Marshall.Threads.Activity`](../../../marshall/lib/marshall/threads/activity.ex)
to advance the enclosing thread's `updated_at` clock after the event transaction
commits. It resolves the current binding, serializes on the user-thread row and
leaves archived or deleting threads unchanged. The ready-thread activity assertion
is covered in [`Marshall.ThreadsTest`](../../../marshall/test/marshall/threads_test.exs).

## Open questions

The product may later add project-scoped activity filters and richer machine
controls. Reopen uses a fresh machine and agent identity. The transcript helper resolves the
current binding by default; authorized readers can list retained machine
generations and select a prior transcript after reopen. Root, machine-owner and
thread authority checks repeat for every selection, and a retired generation
never grants machine, prompt or terminal authority. Changes to retention or
authority require a separate decision.

## Related decisions

- [ADR-0001: Architecture governance](0001-architecture-governance.md)
- [ADR-0022: Browser terminal and live login checks](0022-browser-terminal-and-live-login-checks.md)
- [ADR-0058: Administrative authority](0058-administrative-authority.md)
- [ADR-0101: Browser-approved agent CLI](0101-browser-approved-agent-cli.md)
- [ADR-0159: Remove legacy compatibility after convergence](0159-remove-legacy-compatibility.md)
- [ADR-0161: Monospace Web presentation](0161-monospace-web-presentation.md)
