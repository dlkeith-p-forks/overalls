---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# trace-spool-physical-quota-with-retained-custody

**Claim, priority, confidence.** P1 safety, medium-high confidence in the logical and SQLite bound. Saturation must refuse a new trace batch without deleting any unexpired accepted batch, including one already acknowledged by the exporter; physical ENOSPC must poison intake rather than erase accepted custody. Proposed unique assertion: Always("trace spool saturation preserves accepted archive bytes and refuses on exhausted backing", refused_new_id_implies_retained_digest_set_unchanged && physical_enospc_implies_no_new_ingress_ack_until_recovery). Missing per ../existing-assertions.md. Measure SQLite/WAL/journal allocation independently; the exact transient footprint bound is an open question.

**Source and history.** elixir/diagnostics/native/spool/src/lib.rs:18 sets 262144-byte body max; Store::open at :249-350 validates quota at least 4 MiB, configures WAL FULL synchronous and max_page_count; accept at :483-546 reserves body+512 plus 2 MiB fixed overhead, applies pending quota and commits immutable bytes; replay at :606-625 reinserts pending references without rewriting bodies; expire at :627-661 deletes only expired rows in four-row transactions. nix/modules/otel-fleet/trace-spool.nix:50-76 defaults 2 GiB retained and 256 MiB pending per producer, with 90-day retention and aggregate host budget assertion. The archive differs from the delivery queue: upstream ACK does not erase retained bytes. focus03's trace replay candidate covers ack loss; this property focuses on quota and actual DB backing under pressure.

**Workload and oracle.** Use real Unix ingress, SQLite database and exporter fixture. Fill with unique bounded bodies until pending or retained quota refuses; ACK selected exports, replay, restart and change pending quota while preserving original expiries. An external SQLite read-only connection verifies every accepted digest, bytes and expires_ns; stat database, WAL and any journal plus filesystem allocation independently. At ENOSPC, intake may poison and refuse, but accepted unexpired rows remain recoverable after space restoration. Do not treat filesystem sparse blocks as logical byte length; record both. Faults around SQLite commit require uncertainty reconciliation before classifying an ID as refused.

**Limit menu.** 4 MiB minimum and modest 8/16 MiB test quotas, pending quota 262144 bytes and larger, 262143/262144/262145-byte body boundaries, one slot before/exact/over budget, retention one day and default 90 days. Host budget must exceed number of producers times per-producer quota.

**SUT guidance and limits.** Mark capacity refusal, commit success, WAL checkpoint and poison; retain an independent accepted-ID ledger outside the spool. Hosted filesystem permits real SQLite stress but may not model quota-enforced ZFS and power-loss atomicity. Open questions: What precise physical envelope includes transient SQLite WAL/checkpoint bytes at quota? `(partial: one native 8 MiB run measured below 12 MiB; no general bound)` Can the hosted filesystem enforce a small real disk quota with recoverable ENOSPC? `(partial: no hosted trace ENOSPC fixture found)`

**Architecture/HLDD impact.** No implementation or handbook change; ADR-0149 keeps diagnostics outside lifecycle authority.

### Investigation Log

#### What precise physical envelope includes transient SQLite WAL/checkpoint bytes at quota?

- Examined (2026-10-13): `elixir/diagnostics/native/spool/src/lib.rs:249-350,483-546,605-661`, `nix/modules/otel-fleet/trace-spool.nix:50-77`, and `nix/tests/machines/trace-spool/default.nix:113-137`.
- Found: the application reserves 512 bytes per body plus 2 MiB and applies a SQLite `max_page_count` to the main database. WAL auto-checkpoints at 64 pages; replay inserts up to 128 pending references per statement, and expiry deletes four rows per transaction. The native test measured one 8 MiB-quota stress run below 12 MiB (`du -sb`), while the Nix option calls the quota a logical archive/SQLite budget.
- Not found: a proof that main DB plus WAL, temporary journal and checkpoint allocation always fits the configured `quotaBytes`, especially at the 4 MiB minimum or during ENOSPC. `max_page_count` applies to the main DB, so treating the 2 MiB reserve as a proven total physical cap would overstate the source.
- Conclusion: partial. The property should assert logical refusal and retained accepted custody; a separate measured physical-footprint envelope needs bounded SQLite stress at minimum/default quotas, replay, expiry and restart, sampling allocated blocks for DB/WAL/journal at each boundary. Do not assert physical bytes <= `quotaBytes` yet.

#### Can the hosted filesystem enforce a small real disk quota with recoverable ENOSPC?

- Examined (2026-10-13): the trace-spool Nix service and machine fixture above, and `src/lib.rs:477-546`.
- Found: the spool poisons itself on SQLite write errors and refuses later admissions; the NixOS trace fixture exercises logical quota saturation with real ingress and checks retained rows. The repository has other disposable NixOS/ZFS quota tests, but this spool fixture does not mount its state on a small quota-enforced dataset.
- Not found: a hosted trace-spool real-ENOSPC fixture or evidence that Antithesis storage faults leave the SQLite database reopenable after space is restored.
- Conclusion: partial. Put only the disposable spool `StateDirectory` on a quota-limited filesystem in a native VM, fill it through real ingress, capture accepted IDs before ENOSPC, restore space, reopen, and verify exact rows. Require a separate hosted capability probe before claiming the same fault there.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:494`. Retained SQLite bytes, logical 429 and guarded physical ENOSPC branch; dedicated bounded archive filesystem and hosted/native exhaustion run remain absent. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
