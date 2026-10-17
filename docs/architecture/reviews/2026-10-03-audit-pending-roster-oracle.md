# Pending audit journal roster oracle

## Scope and architecture

Baseline `ecfb2ba3`. Verification correction under ADR-0074, within the existing
dirty-sender restart property. Production AuditRuntime, Outbox, Runtime and
Actor behavior is unchanged. Real local journals, audit HTTP client/sender and
paused actors remain the tested boundary; authenticated Marshall exchange,
complete host/runtime startup and native survival remain separate.

## Discovery and correction

The native worker extension's ordinary Lilly gate ran 475 checks with seed267831
in 69.4 seconds: 474 passed and one property failed. The failing generated
schedule had one event per journal, two actors, acknowledgment prefix one and
graceful sender shutdown. The zero-acknowledgment fairness oracle used the total
actor count as its completion target even after one journal's sole event had
been acknowledged. A legitimate repeated offer from the remaining journal
therefore failed the disjointness assertion. The failure is retained in
`/tmp/kittens-native-beam-lilly-precommit.log`; its forced Dialyzer subsequently
passed in 13.34 seconds with zero errors or skips, which does not make that
precommit successful (terminal exit two).

The oracle now derives its target from resource IDs in the independently read
remaining-event inventory. Every offered event must still match that inventory;
the set already seen must be a subset of the remaining resources. Complete
coverage is set equality, not actor count. The no-duplicate-before-roster and
paused-actor checks remain. Exact drain, current-sender activation, stale-sender
refusal and stable event identity checks are retained.

Every generated draw now includes the discovered `(1, 2, 1, stop)` schedule as a
fixed witness alongside the existing full-journal and single-event witnesses.
An explicit assertion requires only one event remain after that acknowledgment,
so the witness cannot silently miss the fully acknowledged journal boundary.

## Contracts and execution

Reviewed root, Lilly/test, journal and AuditRuntime/Outbox contracts. The helper's
new contract states the remaining stored-event target; it cannot require an
already drained journal to offer a nonexistent event. Tests use isolated native
lock helpers and temporary local journals, without root or KVM.

The initial corrected file passed one property in 26.4 seconds, seed267831.
That result precedes the explicit fixed-witness remaining-event assertion.
The final focused file passed one property in 25.1 seconds, seed267831, including
the explicit assertion that the fixed witness leaves exactly one event. The
final typed-list representation passed the complete Lilly precommit: 475 checks
(85 properties and 390 tests), seed279043, in 98.0 seconds. The final forced
Dialyzer passed in 12.83 seconds with zero errors or skips; wrapper exit zero.
Log: `/tmp/kittens-audit-roster-precommit-final.log`. Standalone test-module Dialyzer now reports zero warnings
using an isolated copy of the dependency PLT extended with pinned ExUnit modules.
The initial analysis omitted ExUnit and reported unknown framework functions;
after adding them, MapSet opaque-representation warnings remained. The helper
now stores at most three unique resource IDs as a typed list and validates
resource IDs as strings before collection. Membership, equality, disjointness
and uniqueness requirements are unchanged. No warning exclusion was added.
Log: `/tmp/kittens-audit-roster-types-list.log`.
Logs:
`/tmp/kittens-audit-roster-focused.log` and
`/tmp/kittens-audit-roster-final-focused.log`.

The handbook already requires exact pending-event drain before actor activation
and distinguishes this local sender fixture from Runtime/native/authenticated
recovery. Correcting the oracle's completion target and adding a fixed witness
preserves those documented facts and the historical execution records; no
handbook chapter or scenario claim is broadened by this correction.

## Remaining gaps

This correction does not add complete Runtime/global host-ownership startup,
authenticated transport, real Marshall ingestion/outcome acknowledgment,
multi-process host restart, Firecracker survival or hosted fault evidence.
