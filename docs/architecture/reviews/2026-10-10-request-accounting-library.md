# Shared request-accounting library (2026-10-10)

## Decision and architecture impact

The durable request producer remains a shared library because admission custody,
bounded Unix recorder I/O, private quality markers, worker ownership and
uncertain-acknowledgment recovery are one security- and reliability-sensitive
boundary. Duplicating that implementation in each source would make recorder
identity, gap handling and terminal-once behavior drift. This is a breaking
internal rename; no compatibility modules are retained.

The library is now the internal Mix package at `elixir/request_accounting/`,
named `:overalls_request_accounting` under `Overalls.RequestAccounting`. The public
producer surface is `Overalls.RequestAccounting.Producer`; marker and RPC
modules are implementation-facing. The shared `Aggregate` value model owns
fixed duration buckets, outcome conservation, optional duration observations
and the validated snapshot shape. It does not own application eligibility,
outcome classification, storage, concurrency or publication.

Diagnostics remains separate. Its fail-open telemetry and privacy/redaction
contracts must not become a dependency of durable SLO accounting, and durable
measurement gaps must not change application authorization or execution.

## Compatibility and preserved boundaries

Recorder protocol v1, peer/unit authentication, marker values and fsync order,
source identity and admission sequence, bounded pending state, snapshot field
names and service identities are unchanged. Application adapters continue to
decide which work is eligible, how outcomes are classified, which storage or
atomics strategy is used, and when snapshots are published. The aggregate
model only removes duplicated arithmetic and validates its closed shape.

The Nix source closure and the isolated request-recorder fixture consume the
renamed path. Historical reviews retain their original execution revisions and
log names; current source links point to the renamed library so handbook and
ADR evidence remains navigable.

## Verification scope

Producer history tests cover worker custody, uncertain acknowledgments, marker
recovery and preservation of work return/error/throw/exit behavior. Aggregate
properties cover bucket boundaries, success/failure/exclusion conservation,
missing durations, privacy and snapshot compatibility. Existing recorder native
tests continue to exercise real Unix peer/cgroup attribution and SIGKILL
recovery. Component gates, consumer precommits, ADR checks and HLDD checks must
pass at the merged revision before implementation status changes beyond ADR-0136's
current `partial` state. These tests do not establish seven-day production
history or physical-host failure independence.

## Affected decision

[ADR-0136](../decisions/0136-durable-application-request-accounting.md) retains
its accepted rationale and partial implementation status, now naming the
request-accounting producer and aggregate boundaries. [ADR-0149](../decisions/0149-independent-observability.md)
continues to govern the separate diagnostics boundary.
