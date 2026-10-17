# ADR-0089: User relocation through Porsche SSH

- ID: ADR-0089
- Date: 2026-09-21
- Status: superseded
- Implementation: implemented
- Components: Porsche, Marshall, protocol, NixOS
- Supersedes: none
- Superseded by: ADR-0092

## Context

Marshall already exposes durable, automatically placed VM relocation through
its Compute domain. Porsche's accepted v1 SSH interface deliberately omitted
relocation when ADR-0046 was written. Users therefore had no SSH command for
moving a machine even when their current authorization permitted management.

Relocation selects and reserves two physical hosts, carries long-running copy
and activation state, and can require cancellation or explicit retry. Adding it
as a thin spelling of a lifecycle command would lose the durable receipt and
current-authority properties of the rest of Porsche's physical operations. A
destination selector would also move placement policy outside Marshall's
capacity transaction.

## Decision

Porsche v1 adds `relocate MACHINE`. It accepts the generic mutation and physical
wait options (`--request-id`, `--timeout`, `--no-wait`, and `--json`) and no
destination, host, placement, transfer-strategy or downtime input. Marshall
resolves the machine under the authenticated SSH session and calls the existing
Compute relocation action. Marshall alone selects the destination and performs
capacity admission atomically.

Current VM `manage` authorization governs admission, polling and controls. This
includes owners, shared managers, team administrators and elevated
administrators under the existing policy; viewers and operators cannot relocate.
Porsche does not duplicate that policy.

The accepted SSH request stores the durable relocation identity. `request show
REQUEST_ID` projects only the bounded relocation status fields already approved
for an authorized manager and never exposes source or destination host or
placement identifiers. Replaying the same request ID returns the same relocation.
`request cancel REQUEST_ID` requests cancellation before commit, and `request
retry REQUEST_ID` creates or returns the durable activation retry when the
existing relocation state permits it. Both controls name the original Porsche
request, not an internal relocation identifier, and establish their own durable
SSH receipts.

Relocation is a Porsche physical command. The client waits for terminal receipt
evidence for 120 seconds by default, honors a bounded `--timeout`, and returns
immediately with `--no-wait`. SSH disconnection or a local wait timeout does not
cancel accepted work. Deployment order is the additive database migration,
then all Marshall instances, then Porsche; old Porsche releases never send the
new command and the protocol remains version 1.

This decision extends ADR-0046 only where it states that relocation is not
exposed. Its shell exclusion, session authority, receipt, transport, logging and
deployment decisions remain unchanged.

## Alternatives

A destination flag was rejected because it would expose fleet topology and let
the edge bypass centralized capacity and maintenance policy. A new request-control
namespace was rejected because clone and relocation share the same user-facing
receipt lifecycle. Returning only the initial admission response was rejected
because it would make completion and lost-reply recovery weaker than other
physical Porsche commands. Direct Porsche database or Oban access was rejected
because Marshall's Ash domains remain authoritative.

## Consequences

SSH requests gain nullable relocation and relocation-retry references. Existing
receipts remain valid and the migration is additive. A relocation retry receipt
displays its retry identity while retaining the original relocation reference.
Current authorization is checked again for status, cancellation and retry, so
revocation prevents later control without undoing already accepted work.

Users can intentionally trigger physical movement but cannot influence its
destination. Capacity, workload stability, transfer occupancy and relocation
phase refusals become closed public Porsche conflict reasons. Application tests
can establish parsing, authorization routing and receipt semantics; complete
guest preservation still requires native multi-host acceptance.

## Invariants and verification

- No Porsche command or API envelope can carry placement-selection input.
- Exactly one durable relocation is admitted for an idempotent SSH request.
- Receipt status follows retained relocation/retry evidence and never inferred
  client timing; timeouts and disconnects do not cancel work.
- Poll, cancel and retry recheck current `manage` permission for the referenced
  machine and cannot be retargeted by later name reuse.
- Public results contain machine identity and bounded relocation status, never
  host, placement, credential, permit or transfer endpoint data.
- Parser, Marshall dispatch, Porsche runner/client and native SSH fleet tests
  cover the new command, closed errors, wait behavior and a real destination
  change with retained guest data.

## Implementation evidence

The shared [command catalog](../../../protocol/lib/overalls_protocol/ssh_command.ex)
defines the closed relocation grammar and physical-wait classification.
[Marshall SSH dispatch](../../../marshall/lib/marshall/ssh/commands.ex) routes
admission and receipt controls through Compute, while the [request resource](../../../marshall/lib/marshall/ssh/request.ex)
and [additive migration](../../../marshall/priv/repo/migrations/20260921173143_porsche_relocation_receipts.exs)
retain relocation identities. [Porsche's runner](../../../porsche/lib/porsche/runner.ex)
uses the existing receipt wait loop and [client](../../../porsche/lib/porsche/client.ex)
keeps conflict reasons closed. Focused [Marshall tests](../../../marshall/test/marshall/ssh/commands_test.exs),
[protocol tests](../../../protocol/test/ssh_command_test.exs), and [Porsche tests](../../../porsche/test/runner_test.exs)
exercise the application boundaries. The [Porsche fleet scenario](../../../nix/tests/machines/fleet/scenarios/porsche.py)
executes the real SSH command across two Lilly hosts and verifies idempotent
replay, automatic different-host placement, retained guest data and source ZFS
cleanup. The complete 20-case, nine-machine scenario passed on 2026-09-21 in
1,585.584 seconds with no failures, completing the implementation evidence.

## Open questions

None.

## Related decisions

- [ADR-0037](0037-workload-placement-and-relocation.md)
- [ADR-0046](0046-porsche-ssh-management.md)
- [ADR-0050](0050-usage-based-overcommit.md)
- [ADR-0077](0077-teams-and-shared-resources.md)
- [Implementation review](../reviews/2026-09-21-porsche-user-relocation.md)
