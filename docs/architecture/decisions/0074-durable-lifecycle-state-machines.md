# ADR-0074: Durable lifecycle state machines and audit

- ID: ADR-0074
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Marshall Web, Lilly Lifecycle, protocol
- Supersedes: none
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

Lifecycle coordinators previously assigned status fields directly or inferred
phases from nullable receipts. Lilly journal guards protected native ownership,
but the legal transition graphs were scattered across functions. Administrator
events and selected PaperTrail versions did not provide complete lifecycle history.

## Decision

The user authorized implementing explicit AshStateMachine lifecycles in both
applications, structured logging, durable audit with 90-day retention, property
and native tests, and no compatibility requirement. This decision refines the
existing execution/storage contracts rather than replacing their rationale.

Marshall owns PostgreSQL-backed desired VM intent, operations, clone/resize/
relocation phases, maintenance and delivery/cleanup obligations. Named actions
declare legal transitions. Metadata updates cannot accept the state attribute.
Desired state, observed physical state, workflow progress and independent cleanup
receipts remain distinct. Existing host-before-VM locks, fencing generations,
immutable descriptors, GUID checks and physical-evidence settlement remain
mandatory; passing a transition is not evidence of a physical effect.

Lilly owns Ash resources for placement execution, ZFS claims, snapshot creation
and retirement, snapshot pointers, receives, export permits and disk growth.
Native backup snapshots use a separate terminal producer per run, while the
Python backup coordinator remains independent under
[ADR-0070](0070-host-recovery-backups.md). Manual Ash persistence reloads under the native OS lock and atomically publishes
state and pending audit events in the same private, fsynced journal. The native
binary execution-intent format and lock-owned utility boundary remain intact.
Execution journals have a separate short-lived audit lock beneath the actor's
lifetime lock so acknowledgment can progress while an actor is alive.
Pool mutations use a bounded acquisition retry to avoid repeatedly losing to
periodic observation. Observations remain nonblocking and withhold capacity on
contention. Transfer-source retirement also uses a bounded per-VM acquisition
window so periodic stopped-source reconciliation cannot repeatedly win a single
cleanup attempt. Neither path retries a mutation callback or changes the lock inode.

Marshall inserts projected lifecycle events in the mutation transaction and
emits structured transition notifications after commit. Scoped human requester
identity survives trusted coordinator calls without becoming authorization.
Lilly records stable event IDs, monotonic revisions and the original correlation
fields at publication time. A separate bounded sender uses authenticated current
host sessions, retained placement/workflow checks, acknowledgment and replay.
Permanent compact producer cursors prevent expired history from being recreated.
Audit acceptance never changes physical authority or releases reservations.

Events contain closed states/actions and allowlisted identifiers, never payloads,
credentials, snapshots, command arguments or guest bytes. Lifecycle history is
administrator-only, cursor-paginated and immediately hides expired events.
An indexed maintenance job deletes at most 1000 expired lifecycle/PaperTrail rows
per transaction, continuing full batches. Operational receipts, replay cursors,
ownership tombstones and reservations are not audit history and do not expire.

Completed backup runs are archived by a lock-owned same-directory rename only
after native absence and the exact cleaned journal are confirmed. The unchanged
event envelope remains independently deliverable while a fresh producer starts
the next run. This avoids making recurring backups depend on Marshall draining
a single 64-event outbox. At each backup preparation, inspect at most sixteen
oldest expired archives and remove only valid cleaned envelopes older than ninety
days, syncing the directory. Active/current, corrupt and mismatched metadata is
retained. Expired archive names are immediately ineligible for export; physical
local expiry requires a later backup preparation. Local directory enumeration is
proportional to retained history. Archives never authorize physical effects.
The standalone backup CLI starts Ash dependencies, not the control-plane runtime.

Local pending audit is bounded to 64 events per journal and 64 KiB per file.
Publication fails without discarding events when full; delivery scans at most
128 metadata paths and sends at most 16 events per pass. Audit outages alone do
not stop guests or establish missing physical facts. Old journal formats fail
closed; this change supplies no migration or destructive reset for existing
host metadata. Deployment requires fresh compatible state, not deletion of data.
After production activation exposed exact pre-lifecycle version-3 VM execution
journals, [ADR-0088](0088-legacy-vm-journal-import.md) authorized one narrow
exception to this original rollout rule. All other old, malformed or mismatched
formats continue to fail closed, and destructive reset remains prohibited.

## Alternatives

Keeping inferred phases retains hidden transition rules and bypasses resource
validation. A single VM status cannot represent desired state, uncertain physical
effects and concurrent cleanup. A second independently written audit file leaves
a crash gap. Logging alone loses history and attribution. Unbounded local audit
risks exhausting the host filesystem. Replacing native GUID/nonce/epoch guards
with state names would weaken ownership and recovery safety.

## Consequences

Graphs and audit make orchestration inspectable, at the cost of more database
writes, larger local journals, a new host exchange and explicit backpressure.
Operators must restore audit delivery before a full local outbox can accept more
transitions. Retention needs its scheduled job; logical lifecycle expiry remains
effective even while deletion is delayed. This is a coordinated deployment of
both applications and the shared protocol.

## Invariants and verification

- Illegal shortcuts and terminal resurrection fail through resource actions.
- Failed transactions produce neither a durable event nor a committed log.
- A crash cannot confirm a journal transition without its pending event.
- Retries preserve event identity; delayed acknowledgments preserve newer events.
- Corrupt/mismatched local metadata is retained and rejected, never regenerated.
- Current credentials, session and retained ownership are required for ingestion.
- Audit expiry never changes authority, physical evidence or capacity.
- Independent StreamData models exercise transition histories; database tests
  cover rollback, authorization, replay and retention. Real NixOS ZFS/KVM and
  fleet tests remain necessary to establish physical recovery and data survival.

## Implementation evidence

The [scan-boundary fairness review](../reviews/2026-10-05-audit-scan-fairness.md)
adds a local real-journal sender property through257placements with fixed
129-placement coverage. It exercises existing bounded traversal with zero ACKs
and exact final drain. The focused run passed two properties in155.3seconds, seed937797. Final gates
remain pending; native fleet
fairness and authenticated Marshall acceptance are not established.

The [dirty sender recovery property](../../../lilly/test/lifecycle/recovery_history_test.exs)
is present for real locked execution journals, partial audit acknowledgements,
local sender/task death and paused actors. Direct production connection/readiness
callbacks use synthetic session results and a local HTTP fixture. Full Lilly
and Marshall gates passed; this is not full Runtime bootstrap, authentic Marshall/TLS or native
VMM survival evidence. The [property audit](../reviews/2026-09-29-antithesis-property-audit.md)
records this boundary. Decision and partial implementation status are unchanged.

The [pending-roster oracle correction](../reviews/2026-10-03-audit-pending-roster-oracle.md)
fixes the dirty-sender property's required offers after one journal is completely
acknowledged. The completion target is the independently remaining event inventory,
with a fixed small boundary witness. Final Lilly precommit passed475 checks in
98.0 seconds, seed279043; forced Dialyzer passed12.83 seconds with zero errors
or skips. Standalone test-module typing also passed without warnings. Production audit behavior and accepted rationale are unchanged.


[VM intent](../../../marshall/lib/marshall/compute/virtual_machine.ex),
[relocation](../../../marshall/lib/marshall/compute/relocation.ex),
[cloning](../../../marshall/lib/marshall/compute/clone_request.ex) and
[resize](../../../marshall/lib/marshall/compute/resize_request.ex) declare graphs.
[Lilly journal](../../../lilly/lib/lilly/lifecycle/journal.ex) and
[manual persistence](../../../lilly/lib/lilly/lifecycle/persist.ex) implement
locked state/audit publication. [Ingestion](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/compute/lifecycle_ingestion.ex)
and [delivery](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/lilly/lib/lilly/lifecycle/audit_runtime.ex) implement replay.
Refusals emit `lifecycle.audit_refused` with closed reasons, and the bounded
retention job emits `lifecycle.retention_deleted` with its deleted count after commit.
The retention inventory now includes every current PaperTrail version table and
the retained terminal-writer history. Every current version resource stores
nullable actor kind/identifier metadata and ignores sensitive attributes; no
historical actor is inferred. The inventory is protected by an introspection test.
[Database audit tests](../../../marshall/test/marshall/compute/lifecycle_audit_test.exs)
have passed; [journal properties](../../../lilly/test/lifecycle/journal_test.exs)
exercise idempotency, corruption and an independent dataset model.
[Native crash driver](../../../nix/verification/tests/machines/zfs-lifecycle/driver.py) checks
audit envelopes alongside actual ZFS recovery.
The [execution journal threshold regression](../../../lilly/test/vm/journal_test.exs)
checks that a 48-event backlog warning uses the closed resource atom and allows
the next transition to persist. This closes the production actor crash described
in the [backlog recovery review](../reviews/2026-09-23-lilly-audit-backlog-recovery.md).
Marshall's [lifecycle log projection](../../../marshall/lib/marshall/compute/lifecycle_log.ex)
also avoids raising after a committed host event when the action or state has
no preexisting Marshall atom; the original strings remain durable.

Remaining milestone gates and exact executed results are tracked in the
[implementation ledger](../../history/ledgers/lifecycle-implementation.md). Final native,
distributed, contract and Dialyzer verification is still in progress.

## Open questions

None in the authorized design; verification findings must be resolved before
marking the implementation complete.

## Related decisions

- [Lifecycle review](../reviews/2026-09-18-lifecycle-state-machines.md)
- [AshStateMachine documentation](https://ash-state-machine.hexdocs.pm/readme.html)

- [ADR-0002](0002-elixir-ash-and-types.md)
- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
- [ADR-0037](0037-workload-placement-and-relocation.md)
- [ADR-0053](0053-vm-disk-limit.md)
- [ADR-0055](0055-queued-machine-cloning.md)
- [ADR-0070](0070-host-recovery-backups.md)
- [ADR-0088](0088-legacy-vm-journal-import.md)

Audit delivery preserves traversal progress between bounded offers and records whether the complete pass offered any events. Only a complete pass without offers establishes drain; an empty suffix after an earlier delivery cannot establish readiness. The dirty-restart property reproduced premature readiness before repair. The final focused run passed with zero-ACK fairness checks across restored actors (seed `310553`, 23.9 seconds, one property and nine related tests). Full component gates passed; merged publication checks follow. Native and hosted recovery limits above remain open.

The generated `expired audit histories retain fences and atomic future prefixes`
property in [lifecycle audit tests](../../../marshall/test/marshall/compute/lifecycle_audit_test.exs)
adds a local retention/reoffer oracle: raw physical event-ID inventories prove deletion while permanent
cursors survive prefix, alternating and full expiry; valid obsolete reoffers
cannot recreate rows; ownership, conflicting replay and future gaps roll back
earlier valid writes in the exchange. VM, reservation, operation and placement
records remain unchanged. The focused execution passed; it does not establish Oban
cron scheduling, Marshall restart, concurrent processes, independently deployed transport/outbox
or native/hosted fault behavior.

The property sends these exchanges through the real Lilly Client to the
actual Marshall provisioner API over verified loopback HTTPS using disposable
fixture trust. Client session opening and request/response validation are composed
with the database oracle. It still does not run a Lilly outbox, restart Marshall,
schedule Oban or establish native/hosted faults; focused compilation and execution passed.

Each history also withholds one to three successful audit acknowledgements by
replacing the real API's reply with HTTP503 in a test-only before-send hook.
Ingestion has completed its transaction boundary within the SQL sandbox;
the Client observes temporary unavailability. This does not establish durable
commit outside the sandbox. Exact physical rows, cursor and operational records are checked
after every attempt before a successful replay returns the original IDs. This
is an accepted-but-unobserved reply fixture over real TLS, not a socket drop,
server crash or independent-service partition. The focused run passed 14 checks (three properties and eleven tests), seed `461284`, in 13.0 seconds; log `/tmp/overalls-audit-expiry-focused.log`. Full Marshall precommit passed 1412 checks (213 properties, 1199 tests), two exclusions, seed `367039`, in 1130.3 seconds; forced Dialyzer passed with zero errors/skips in 38.72 seconds. Structural/generated/reference and evaluated Nix HLDD gates passed before and after upstream integration.

Ownership refusal uses an existing foreign host and an actual allocated retained
placement for the same VM on that host, alongside an invented placement. The
foreign placement is metadata-only fixture state, not an admission, launch or
physical copy. It catches removal of the host filter before cursor suppression,
which an unknown placement alone would miss. All VM placements enter the
operational snapshot before audit exchange.

The scan-boundary review also records the direct exact128path suffix oracle
(two focused properties in0.9seconds, seed820551) and a queue-reset mutant caught
by the new real-journal fairness property. Full gates and native authenticated
fairness remain outstanding; ADR status and rationale are unchanged.
