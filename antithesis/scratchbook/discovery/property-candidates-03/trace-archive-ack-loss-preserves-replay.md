# trace-archive-ack-loss-preserves-replay

P1; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(accepted sanitized batch retains identical bytes/digest and original
expiry through intake ACK loss, delivery ACK and restart until that expiry)`;
message **"Trace archive recovery preserves accepted immutable custody through acknowledgment loss"**.

Evidence: `elixir/diagnostics/native/spool/src/lib.rs:249-346` (`Store.open`)
exclusive custody and SQLite FULL WAL; `:483-552` (`accept`) digest deduplication
and atomic batch/pending transaction; `:582-602` (`delivered`) removes pending
index, never archive body; `:605-623` (`replay`) bounded idempotent insert restores
pending index; `:626-655` expiry is based on retained batch deadline.
`src/main.rs:171-176` forwarding requires complete OTLP ACK, `:324-352`
drains pending without holding storage lock during network I/O. ADR-0149 and
native CONTRACTS require independent custody and forbid telemetry blocking
business recovery. Export is at least once; duplicate downstream delivery is allowed.

History: accepted body loses local ACK; resend exactly same sanitized body;
Collector takes batch but reply drops; restart spool, shorten new retention
configuration, replay archive, interrupt replay after one 128-row chunk, restart
again. Force capacity/ENOSPC/SQLite error, then reopen. Preserve original bytes
for comparison; do not assume sanitization of a newly bound producer is identical.

Oracle: independent capture of accepted sanitized protobuf bytes and digest,
read-only consistent SQLite snapshot with real custody preserved, retained
accepted_ns/expires_ns, downstream batch ledger. Every accepted unexpired digest
must exist byte-for-byte regardless of pending/delivered status. Only original
expiry permits deletion; refusals cannot evict accepted bodies. Missing Collector
reply is not confirmed failure and archive replay need not produce new identity.

Guidance: `Reachable` **"Trace spool reopened accepted custody after intake acknowledgment loss"**;
**"Trace spool resumed partially completed archive replay without rewriting bytes"**.
Replay anchors at transaction commit/pre-local ACK, forward success/pre-pending
delete, and between bounded index replay chunks. `AlwaysOrUnreachable`
**"Trace spool uncertain storage refuses later admission without evicting custody"**
at optional poisoned path. No payload bytes enter assertion metadata.

Values: 1/127/128/129/256 batches, body sizes 1/limit-1/limit (valid sanitized
messages), archive/pending quota just below/equal/above row-plus-reserve boundary;
expiry before/equal/after original deadline and changed future retention policy.
Hosted real Rust SQLite/Unix/Collector fixture covers custody; actual systemd
producer authentication and power-loss fsync semantics need their selected native
or supported filesystem environment. Quota refusal is expected, not failure.

Open questions: Which hosted persistence fault can exercise SQLite FULL WAL
commit uncertainty beyond orderly process restart?
