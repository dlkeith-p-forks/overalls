# ADR-0166: Resize hardening: Porsche command, named refusals, recorded stop evidence and pre-mutation cancellation

- ID: ADR-0166
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: Marshall Compute, Marshall SSH gateway, Marshall Web, shared SSH command catalog, Porsche
- Supersedes: none
- Superseded by: none

## Context

The 2026-10-13 investigation found every production resize of the previous
fourteen days complete, but the workflow had sharp edges that made it hard to
operate and to accept: no scriptable entry point (ADR-0051 left an SSH resize
command out of scope, so acceptance needed a browser), a refusal reached the
owner only as a generic page flash with no event naming the reason, one host
receipt (a stop confirmed without its disk) was treated as an invalid outcome
and rolled back the host's whole exchange, and a request could not be
withdrawn even before any size had been applied.

## Decision

1. **Porsche `resize MACHINE [--cpu N] [--memory MIB] [--disk GIB]`.** The
   command resolves only the machine and delegates sizes, generation fencing,
   capacity holds and manage authorization to `Compute.resize/2`. An omitted
   option keeps the current size; a request with no size option is refused
   `invalid_vm_size`. The receipt pins the resize request and follows its
   phases: complete is succeeded, cancelled is succeeded for the cancel
   receipt and superseded for the original, a finished failure is failed, and
   a retryable failure keeps the receipt accepted with the recorded phase.
   `request retry` and `request cancel` act on resize receipts through the
   domain actions.
2. **Named refusals.** Every refused resize, retry or cancel emits
   `vm.resize_refused` with the closed coordinator reason beside the machine,
   except inside a gateway transaction, where the rollback propagates to the
   gateway and it logs the reason as `api.request_unauthorized`.
3. **Stop evidence without a disk is recorded.** A stop receipt that confirms
   the guest down but not its disk records `physical_state_unconfirmed` on the
   request with every hold retained; it no longer rolls back the host exchange
   as an invalid outcome. Retry re-issues the stop.
4. **Cancellation before mutation.** A resize may be cancelled while it is
   stopping (or already cancelling) and not fenced by unconfirmed physical
   state. Cancellation restores the original holds at once and records
   `cancelled_at`; a pending stop is awaited in the `cancelling` phase; a
   confirmed stop restarts an originally running machine through an ordinary
   start with its unchanged sizes, and the request finishes as `cancelled` when
   it runs; an originally stopped machine finishes as cancelled on the stop
   receipt. Once sizes are being applied, cancellation is refused
   `resize_not_cancellable` and retry remains the only path. The resize page
   offers the control while stopping and shows the cancelling stages;
   `vm.resize_cancelled` is emitted on completion.

## Alternatives

- Cancelling during the resize phase by reverting sizes: rejected; the disk
  growth is irreversible and the restart path already exists for failures.
- Reporting the diskless stop as a host protocol violation: rejected; it is
  evidence about one machine and must not block the host's other outcomes.
- A browser-only acceptance: rejected; operators and tests need a scriptable
  path with durable receipts like clone and relocation.

## Consequences

Resize joins clone and relocation in Porsche with the same receipt discipline.
`ssh_requests` gains `resize_request_id`; `compute_resize_requests` gains
`cancelled_at` and two phases. ADR-0051's "cancellation and SSH resize commands
remain outside scope" clause no longer holds; it is superseded here while its
other decisions stand.

## Invariants and verification

- A cancel is accepted only in `stopping`/`cancelling` with the stop not fenced;
  it never applies or reverts a size and never releases a hold the running
  machine needs.
- A cancelled request's machine keeps its original sizes and power state.
- A stop without a disk keeps holds and the `stopping` phase.
- Every refusal of resize, retry or cancel is logged with its reason.
- Tests: `marshall/test/marshall/compute/resize_cancellation_test.exs`,
  `marshall/test/marshall/ssh/commands_test.exs` (resize command),
  `marshall/test/marshall_web/resize_live_test.exs` (page cancel),
  `protocol/test/ssh_command_test.exs` (resize parse).

## Implementation evidence

- [SSH command catalog](../../../protocol/lib/overalls_protocol/ssh_command.ex),
  [SSH commands](../../../marshall/lib/marshall/ssh/commands.ex)
  (`perform` for resize, `control_resize`, resize receipt refresh),
  [SSH request resource](../../../marshall/lib/marshall/ssh/request.ex),
  [control requests](../../../marshall/lib/marshall/ssh/control_requests.ex),
  [Porsche client](../../../porsche/lib/porsche/client.ex).
- [Resize coordinator](../../../marshall/lib/marshall/compute/resize.ex)
  (`cancel!`, `cancelled!`, the diskless stop clause, `vm.resize_refused`),
  [resize request](../../../marshall/lib/marshall/compute/resize_request.ex),
  [VM actions](../../../marshall/lib/marshall/compute/virtual_machine.ex),
  [resize page](../../../marshall/lib/marshall_web/live/resize_live.ex),
  [events](../../../marshall/lib/marshall/events.ex).
- Tests: [cancellation](../../../marshall/test/marshall/compute/resize_cancellation_test.exs),
  [SSH resize](../../../marshall/test/marshall/ssh/commands_test.exs),
  [page cancel](../../../marshall/test/marshall_web/resize_live_test.exs),
  [parser](../../../protocol/test/ssh_command_test.exs).
- Production acceptance through Porsche on overalls is recorded in the
  [resize hardening review](../reviews/2026-10-13-resize-hardening.md).

## Open questions

- Whether a resize fenced by `physical_state_unconfirmed` should become
  cancellable once a later outcome confirms the machine stopped.
- Whether `overalls` (the CLI) should expose resize as well.

## Related decisions

- [ADR-0051](0051-vm-resizing.md): the resize workflow; its out-of-scope
  clause for cancellation and an SSH command is superseded here.
- [ADR-0053](0053-vm-disk-limit.md): the disk limit the command enforces.
- [ADR-0126](0126-bounded-database-client-recovery.md): bounded client
  recovery around receipts.
- [ADR-0162](0162-clone-cleanup-liveness.md): the same investigation's clone
  decisions and reasoned refusals.
