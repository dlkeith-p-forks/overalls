# host-session-successor-fences-old-exchanges

P0; high confidence; safety. Proposed `Always` message **"Superseded Lilly host session cannot change exchange state or dispatch work"**. Instrumentation is **missing** in the [fresh scan](../existing-assertions.md). This is a host **connection** session and connection epoch, not a VM execution epoch.

Source: `marshall/lib/marshall/compute/host_session.ex:1-5,25-48` retains nonce/host/epoch history and one ID per host epoch. `marshall/lib/marshall/compute/provisioner_control.ex:97-151` opens a fresh session under the host lock, but accepts a repeated nonce only while it remains exactly current; `:154-231` checks session and epoch before outcomes, reports, acknowledgements and command selection in the same authenticated transaction. `marshall/lib/marshall/compute/credentials.ex:100-131` serializes authentication under the host row lock. `marshall/lib/marshall/compute/relocation_receives.ex:21-61` gives the transfer lane the same session check. ADR-0003 makes PostgreSQL the cross-node authority; ADR-0142's Control service (`marshall/lib/marshall/control/services/lilly.ex:36-54`) retains the document fence. Existing focused tests include `marshall/test/marshall/compute/enrollment_history_test.exs:772-805` and `host_reports_test.exs:91-153`; their presence is not hosted execution evidence.

History: run at least two independent Marshall processes with separate Repo pools on one PostgreSQL primary. Open session A, send a valid report and command/outcome exchange, then open B through the other node. Replay A's exact open and exchanges on both nodes while B reports and accepts an independently witnessed physical command. Reorder response loss, connection close, and B's first exchange. Include a host-command hint sent to the old socket; it is only a wakeup.

Independent oracle: read the committed host row, `compute_host_sessions`, report sequence/time, physical-outcome and operation rows in one fresh database snapshot, and observe the host's actual operation/guest identity separately. A's post-B requests must be refused and produce no new committed effects. B's valid request proves this is a live fence rather than blanket outage. Do not count response codes alone or treat an in-flight A transaction serialized *before* B as a violation.

SUT guidance: a proposed `AlwaysOrUnreachable` at the optional stale branch with unique message **"Stale host exchange rolled back before outcome or report mutation"** would inspect transaction result, while the workload `Always` checks effects. Proposed `Reachable` **"Successor host session made progress after old nonce replay"** marks meaningful recovery.

Values: session A/B/C; open replay before and after successor; exchange report absent/present; report sequence 0/1/maximum accepted; 0/1/max protocol command and outcome counts; process cut before/after commit and response; configured exchange cadence 1000 ms. This tests one PostgreSQL primary and independent Marshall app processes, not database HA/quorum. A real Lilly/native witness is needed for physical execution; service-only observation proves the durable fence.

Open questions: None for the safe fixture choice. Native physical evidence for B remains a separate verification layer.

### Investigation Log (2026-10-13)

#### Single-owner session succession

- Examined: `ProvisionerControl.open/exchange_execution`, `HostSession`, Lilly `Control.Client.open/2` and execution exchange, and Lilly host-owner guidance. Found: Marshall sessions are wire nonces under one host credential and checked against the current host row inside exchange; the stale A side need only replay a valid old wire document. Not found: a need for two physical Lilly owners to test the database fence. Conclusion: use protocol-level A and B sockets on separate real Marshall listeners for the bounded durable fence; physical Lilly progress requires a separate witness.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

### Workload implementation (2026-10-13)

`antithesis/test/v1/host_sessions/singleton_driver_successor_fence.py` opens A on one Marshall Control listener and B on the other with the same issued credential. It confirms B's committed session ID and greater epoch, replays A's exact nonce and empty v4 exchange on A's still-open socket, and checks one-statement PostgreSQL snapshots of host/session, report, operation, outcome and reservation rows. B's accepted exchange is a live positive control. A concurrent Lilly session C makes a B-specific comparison inconclusive, rather than an apparent stale-side effect. Lilly permanently fences itself on a superseded connection, so this template is terminal and cannot be repeated on the live host. The controlled pool is unavailable, so the exchange reports no invented capacity and carries no physical outcome. Native physical command execution, report mutation, process cuts and response-loss races remain unexercised. Static checks are not a hosted baseline.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/host_sessions.py:272`. Current Lilly host-session/successor route only; physical guest/execution authority is separate. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
