# Porsche user relocation

## Scope and architecture impact

This review covers the new user-facing relocation command across the shared SSH
protocol, Porsche's HTTPS client and wait runner, Marshall's SSH receipts and
Compute dispatch, PostgreSQL persistence, public documentation and native fleet
acceptance. It changes an API/protocol, authorization entry point and durable
receipt schema, so ADR-0089 records the decision. It does not change relocation
placement, fencing, transfer, capacity or recovery algorithms.

Affected decisions are ADR-0037, ADR-0046, ADR-0050, ADR-0077 and ADR-0089.
ADR-0089 explicitly replaces only ADR-0046's original interface exclusion; no
accepted relocation rationale is rewritten.

## Findings and implementation

### Edge placement input would violate the existing authority boundary

Severity: high. Marshall's relocation admission already locks and selects an
eligible destination using current capacity and maintenance state. Accepting a
host or strategy through Porsche would expose topology and split admission
authority. The shared parser therefore accepts exactly one machine reference and
generic receipt/wait options. Marshall passes no placement input to Compute.

### Generic operation IDs were insufficient for relocation controls

Severity: high. Lifecycle operation receipts and clone receipts already retain
their authoritative domain identity, but relocation is a multi-stage aggregate
rather than one physical operation. The SSH request resource now has nullable
relocation and relocation-retry relationships. Admission, replay, poll, cancel
and retry remain atomic with their own SSH receipt creation.

### Status and control must use current authorization

Severity: high. An accepted relocation may outlive a key, session or sharing
grant. Receipt refresh and controls resolve the pinned VM and recheck current
`manage` permission through the existing Compute policy. Owners, shared managers,
team administrators and elevated administrators retain existing rights; operator
and viewer grants do not gain relocation authority. Status uses the bounded
relocation projection and does not reveal physical placement.

### Existing wait semantics are sufficient

Severity: low. Relocation joins the shared physical command catalog, so Porsche
submits once and polls `request show` with the same session. The standard
120-second default, bounded override, no-wait behavior and terminal receipt
validation apply without a second state machine.

## Decisions and open questions

ADR-0089 is accepted and implemented. There are no open design questions. The
native multi-host fleet scenario proves guest preservation through the Porsche
command without exposing or accepting destination selection.

## Verification performed

All affected Elixir precommit gates pass. Protocol reports 193 tests (72
properties), Porsche reports 81 tests (11 properties), Marshall reports 837
tests (64 properties) plus its browser terminal and dashboard checks, and the
required second protocol consumer Lilly reports 380 tests (43 properties). Each
gate passes the pinned toolchain check, ADR validation, code-contract validation,
warnings-as-errors compilation, formatting and Dialyzer; all applicable
structured-logging checks also pass. The focused Marshall SSH suite passes 14
tests, including relocation admission, replay, polling and cancellation.

`mix ash_postgres.generate_migrations --check` reports no schema drift. The full
Python `prek run --all-files` gate passes all application logging checks, Ruff
format/lint and ty type checking for the updated native scenario. The complete
20-case, nine-machine `porsche-fleet` scenario passes in 1,585.584 seconds. Its
real SSH relocation asserts durable request replay, scheduler-selected movement
to the other Lilly host, retained guest data and removal of the source ZFS data.

## Follow-up work

Roll out the additive migration before Marshall and Porsche application versions
that expose the command.
