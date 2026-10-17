# runtime-restart-requires-fresh-readiness

Priority: P1. Confidence: high for source and native test; faulted hosted reproduction pending.

## Claim and assertion

After Lilly Runtime incarnation restart, restored local commands and surviving VMMs must not establish host readiness until the new authenticated session delivers a fresh host report; once database/control service recovers, the same guests should remain alive and readiness should return. Proposed missing `Always`: **`lifecycle.restored_journal_cannot_authorize_fresh_runtime_readiness`**. This is safety whenever a new incarnation exposes readiness. Proposed missing `Sometimes(cond)`: **`lifecycle.surviving_guests_rejoin_after_runtime_reauthentication`**, with `cond` requiring unchanged independently observed VMM process identities and a new authenticated report followed by true readiness. This is meaningful recovery progress after healed outage.

## Evidence and failure history

`lilly/lib/lilly/application.ex:14-55` starts execution view before Runtime under `rest_for_one`, then connector/status children. `lilly/lib/lilly/control/runtime.ex:149-213` opens durable store, restores commands and actors, but begins in `:connecting` with fresh session ID and `delivered_report_at=nil`; `:845-859` opens or exchanges asynchronously. `:1017-1056` publishes readiness only for connected, terminal-ready, error-free state with a report delivered within 15,000 ms and a reconciled actor for each current command. `:863-885` says delivery acknowledgement follows rereading durable intent. `lilly/lib/lilly/vm/actor.ex:345-391` requires current physical reconciliation before outcome publication. `nix/verification/tests/machines/fleet/scenarios/runtime-readiness.py:13-58` kills the Lilly main process during PostgreSQL outage, checks false readiness on each restart while VMM snapshots stay identical, then restores PostgreSQL and checks new connection epochs and true readiness. This is recorded native-test structure, not an Antithesis assertion. The independent VMM owner must remain outside Lilly release lifetime per `lilly/AGENTS.md`.

Failure history: kill Lilly process once or twice with PostgreSQL stopped, preserve native VMMs and durable store, then restore database. A stale journal could make host appear ready before new authenticated authority, while a destructive restart could kill healthy guests.

## Independent oracle and workload

Run real Lilly release, status socket, Marshall/PostgreSQL and independently supervised VMMs. Capture Lilly PID/incarnation, Marshall connection epoch, fresh report acceptance, host readiness response, and VMM PID/start-time/cgroup plus guest response. During outage/restarts, every true readiness must have a report accepted from the current authenticated incarnation; after healing, require true readiness and identical guest process identities. Do not use old journal rows or diagnostic events as proof of current readiness. Preserve actual `rest_for_one` supervision tree.

Configured limit menu: one and two Lilly SIGKILL restarts as in native test, zero/one delayed report, PostgreSQL outage just below/above the 15,000 ms delivered-report window (`runtime.ex:1040-1048`), one versus two hosts. A permanently unavailable database makes the progress claim inapplicable.

## Branch/replay guidance and scope

SUT-side missing assertions at Runtime initialization, authenticated session change, delivery of first fresh report and readiness publication; report a closed phase, incarnation token hash and report epoch. `Reachable` for a stale-journal refusal is a useful replay marker but not a substitute for `Always`. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`. Hosted service mode can check authority and status; real native/TCG process custody is needed for the unchanged-guest claim.

Open questions: None after the source inspection above.
