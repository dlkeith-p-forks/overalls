# guest-workspace-source-replay-once

P0; high confidence; safety. Planned SDK assertion **missing** per [fresh scan](../../existing-assertions.md). `Always` **"Guest workspace source replay preserves one boot-bound source"**: within one boot binding, an accepted delivery is preceded by durable `source.json`; an identical redelivery accepts without replacing the source or re-cloning after `done`; a changed source or stale boot challenge does not replace it. `Always` checks every settled delivery. A lost reply is uncertain and must be reconciled with persisted source and checkout bytes.

Source: `lyra/src/workspace_receiver.rs:56-91,112-135` validates placement/epoch/challenge and nonce; `:466-490` writes with file sync, atomic rename and directory sync; `:533-595` refuses corruption, returns accepted on identical source and conflict on changed source; `:597-635` uses completed checkout/`done` marker to avoid replaying Git after crash or redelivery. `lyra/CONTRACTS` and ADR-0157 govern guest source custody; the source contract is a property target rather than proof.

History/oracle: use real Lilly delivery over jail vsock into a TCG guest with pinned kernel/source receiver and a local deterministic Git fixture. Observer records boot binding/nonce and attempted source identities outside guest, plus guest `source.json` hash, checkout commit/sentinel bytes, `done` marker and Git fixture fetch/clone count. Drop accepted reply, restart receiver before/after source fsync and after checkout rename/before `done`, send same source/new nonce, changed source/same nonce, and a previous boot's challenge. The clone may retry before completion; after `done`, identical replay must not execute new Git steps. Never use a fake GitRunner as the only effect oracle.

SUT guidance: `Reachable` **"Guest workspace redelivery accepted identical persisted source"** at `Receiver.deliver/1:578-581`; `Reachable` **"Guest workspace refused conflicting source replay"** at `:582-585`; `Reachable` **"Guest workspace recovered checkout before done marker"** at `Receiver.attempt:613-635`. All are meaningful positive paths. Keep source URLs, credentials and checkout content out of SDK metadata.

Value menu: delivery repetitions 1/2/8; same/changed source; same/changed nonce; epoch 1/2 and previous/current boot challenge; crash before source sync/after rename, after checkout rename/before done, after done; Git attempt 1/2/10 (configured guest retry cap) and delay 5/90 seconds. Hosted real Lilly plus TCG guest/vsock establishes guest replay/content; native Firecracker jail/vsock/physical durability remains native scope. A same-boot source is permanent for that boot, but a new boot may have separate binding.

Open questions: Which guest inspection channel can report Git clone count and source hash without exposing the source itself? Does Lilly redelivery reuse the exact source reference after its receipt reply is lost?

### Investigation Log

#### How can the guest effect be observed safely?

- Examined: `workspace_receiver.rs:597-635` and the fixture status paths `:219-238`. Found: `done`, status and checkout are separately observable; no persistent clone-attempt counter. Not found: a built-in sanitized guest clone count. Conclusion: instrument a local Git fixture request ledger and inspect checkout/marker through isolated guest observation.

#### Does Lilly redeliver the same reference?

- Examined: receiver's binding/decision flow and the [SUT synthesis](../../sut-analysis.md). Found: duplicate source is explicitly accepted guest-side. Not found: the full Lilly source-delivery retry callsite in this pass. Conclusion: verify actual Lilly vsock resend before claiming integrated replay; direct receiver test alone is insufficient.
