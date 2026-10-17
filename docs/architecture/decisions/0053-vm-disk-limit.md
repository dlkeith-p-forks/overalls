# ADR-0053: Maximum VM disk capacity

- ID: ADR-0053
- Date: 2026-09-18
- Status: superseded
- Implementation: implemented
- Components: Marshall Compute, Marshall Web, Lilly VM, protocol, Porsche
- Supersedes: ADR-0051
- Superseded by: ADR-0126

## Context

[ADR-0126](0126-bounded-database-client-recovery.md) replaces only inherited
database client-loss detection settings. It carries forward the disk limit,
resize, capacity and other deployment decisions and rationale below.

The operator requested a 500 GiB maximum VM disk size in the UI, API and Porsche,
explicitly choosing binary units and rejecting compatibility exceptions for old
oversized workloads. The previous shared execution limit was 16 TiB.

## Decision

Limit configured per-VM disk capacity to 536,870,912,000 bytes, inclusive. Define
this limit in the shared VM shape validator used by admission, resize, execution
and relocation validation. Preserve the 2 GiB minimum and 4096-byte alignment.
Marshall's Ash provision and resize arguments enforce the same maximum. Both
browser forms expose a maximum of 500 GiB, and server validation remains authoritative.
Porsche's shared command parser rejects explicit disk options above 500 GiB;
Marshall independently validates structured requests and image-derived defaults.

Carry forward all other ADR-0051 decisions and rationale, including durable
stop/resize/restart, immutable command snapshots, retained provisioning payloads,
no disk shrinking, capacity accounting and inherited deployment boundaries.
There is no grandfathering, disk migration or protocol negotiation. Deploy the
shared validator and consumers together. No running disk is automatically shrunk.

## Alternatives

Decimal 500 GB was rejected in favor of the existing GiB UI and command units.
Client-only validation permits API bypass. Separate constants can drift across
consumers. Grandfathering oversized workloads was explicitly rejected.

## Consequences

Oversized creation and resize requests fail before resource allocation or
scheduling. Oversized execution and relocation descriptors are invalid, including
previously accepted workloads. Host aggregate capacity and physical usage policy
are unchanged. Image metadata may describe larger requirements, but such images
cannot produce an admissible VM shape.

## Invariants and verification

Accept exactly 500 GiB and reject the next aligned size and 501 GiB. Exercise
browser submission bypass, structured SSH API requests, Porsche preflight,
image-derived defaults and domain side effects. Run all four application gates,
contract checks and architecture validation. These tests do not claim deployment
or physical guest acceptance.

## Implementation evidence

[Shared limits](../../../protocol/lib/overalls_protocol/vm_shape.ex) and
[execution validation](../../../protocol/lib/overalls_protocol/execution.ex)
enforce the byte boundary for consumers. [Ash arguments](../../../marshall/lib/marshall/compute/virtual_machine.ex)
validate admission and resize. [Creation UI](../../../marshall/lib/marshall_web/live/machines_live.ex)
and [resize UI](../../../marshall/lib/marshall_web/live/resize_live.ex) expose the cap.
[SSH grammar](../../../protocol/lib/overalls_protocol/ssh_command.ex) is shared by
Porsche and Marshall. [Boundary tests](../../../protocol/test/execution_test.exs),
[API tests](../../../marshall/test/marshall_web/ssh_api_test.exs) and
[Porsche tests](../../../porsche/test/runner_test.exs) cover rejection paths.
Actual verification results are recorded in the [review](../reviews/2026-09-18-vm-disk-limit.md).
Inherited platform deployment gaps retain their existing status.

The [resize verification review](../reviews/2026-09-25-resize-verification.md)
extends inherited coordinator and browser evidence. Its generated histories use
real Ash/PostgreSQL actions, include fixed Inception allocation costs and current
manager authority, and keep synthetic physical receipts separate from native
execution. The resize page now shows exact aligned fractional confirmed disk
sizes, matching its existing draft and pending-target values. The separate
[native browser journey](../../../nix/tests/machines/resize/driver.py) retains
explicit recorded-execution and platform limits in that review.

## Open questions

None for the size policy. Deployment is outside this change.

## Related decisions

[ADR-0051](0051-vm-resizing.md), [ADR-0046](0046-porsche-ssh-management.md).
