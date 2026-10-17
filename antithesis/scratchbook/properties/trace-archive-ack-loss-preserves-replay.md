# trace-archive-ack-loss-preserves-replay

P1; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
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
`(partial: SIGKILL/reopen and delivery replay exist; media-level fault unproven)`

### Investigation Log

#### Which hosted persistence fault can exercise SQLite FULL WAL commit uncertainty beyond orderly process restart?

- Examined (2026-10-13): `elixir/diagnostics/native/spool/src/lib.rs:249-350,483-655,819-861`, `src/main.rs:680-711`, and `nix/tests/machines/trace-spool/default.nix:90-128`.
- Found: SQLite uses WAL with `synchronous=FULL`; intake ACK follows transaction commit. Unit/property tests cover duplicate intake, delivery ACK, reopen, retention-policy change, archive replay and poison after storage error. The NixOS machine test kills the spool and verifies persisted archive identity, then replays after Collector delivery. Those tests do not cut the SQLite transaction at an unknown commit result.
- Not found: a hosted storage fault with proven power-loss or torn-commit semantics, or a controllable commit-after-durable-before-return cut in the current spool. SIGKILL of a process and network ACK loss provide useful replay histories, but do not by themselves establish media power-loss behavior.
- Conclusion: partial. A supported disposable block-backed VM could cut power at the SQLite commit boundary and reopen after crash, or a source-built fault variant could cut after commit and before intake ACK to test acknowledgement uncertainty only. Classify the latter narrowly; require filesystem durability evidence for the former.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:269`. Reviewed OTLP, SQLite body/digest, discarded intake ACK/retry, and conditional production replay; no hosted outage/replay or native identity result. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
