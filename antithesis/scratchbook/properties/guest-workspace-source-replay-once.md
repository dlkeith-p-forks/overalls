# guest-workspace-source-replay-once

P0; high confidence; safety. Planned SDK assertion **missing** per [fresh scan](../existing-assertions.md). `Always` **"Guest workspace source replay preserves one boot-bound source"**: within one boot binding, an accepted delivery is preceded by durable `source.json`; an identical redelivery accepts without replacing the source or re-cloning after `done`; a changed source or stale boot challenge does not replace it. `Always` checks every settled delivery. A lost reply is uncertain and must be reconciled with persisted source and checkout bytes.

Source: `lyra/src/workspace_receiver.rs:56-91,112-135` validates placement/epoch/challenge and nonce; `:466-490` writes with file sync, atomic rename and directory sync; `:533-595` refuses corruption, returns accepted on identical source and conflict on changed source; `:597-635` uses completed checkout/`done` marker to avoid replaying Git after crash or redelivery. `lyra/CONTRACTS` and ADR-0157 govern guest source custody; the source contract is a property target rather than proof.

History/oracle: use real Lilly delivery over jail vsock into a TCG guest with pinned kernel/source receiver and a local deterministic Git fixture. Observer records boot binding/nonce and attempted source identities outside guest, plus guest `source.json` hash, checkout commit/sentinel bytes, `done` marker and Git fixture fetch/clone count. Drop accepted reply, restart receiver before/after source fsync and after checkout rename/before `done`, send same source/new nonce, changed source/same nonce, and a previous boot's challenge. The clone may retry before completion; after `done`, identical replay must not execute new Git steps. Never use a fake GitRunner as the only effect oracle.

SUT guidance: `Reachable` **"Guest workspace redelivery accepted identical persisted source"** at `Receiver.deliver/1:578-581`; `Reachable` **"Guest workspace refused conflicting source replay"** at `:582-585`; `Reachable` **"Guest workspace recovered checkout before done marker"** at `Receiver.attempt:613-635`. All are meaningful positive paths. Keep source URLs, credentials and checkout content out of SDK metadata.

Value menu: delivery repetitions 1/2/8; same/changed source; same/changed nonce; epoch 1/2 and previous/current boot challenge; crash before source sync/after rename, after checkout rename/before done, after done; Git attempt 1/2/10 (configured guest retry cap) and delay 5/90 seconds. Hosted real Lilly plus TCG guest/vsock establishes guest replay/content; native Firecracker jail/vsock/physical durability remains native scope. A same-boot source is permanent for that boot, but a new boot may have separate binding.

Open questions: Which bounded guest observation path can return only the source digest, done/HEAD and an independent Git fixture effect count? `(partial: source and checkout paths exist, but the guest has no packaged sanitized clone counter or hosted observer)`

### Investigation Log

#### How can the guest effect be observed safely?

- Examined: `workspace_receiver.rs:597-635` and the fixture status paths `:219-238`. Found: `done`, status and checkout are separately observable; no persistent clone-attempt counter. Not found: a built-in sanitized guest clone count. Conclusion: instrument a local Git fixture request ledger and inspect checkout/marker through isolated guest observation.

#### Does Lilly redeliver the same reference?

- Examined: receiver's binding/decision flow and the [SUT synthesis](../sut-analysis.md). Found: duplicate source is explicitly accepted guest-side. Not found: the full Lilly source-delivery retry callsite in this pass. Conclusion: verify actual Lilly vsock resend before claiming integrated replay; direct receiver test alone is insufficient.

#### 2026-10-13 follow-up: What does Lilly resend after a lost receipt?

- Examined: `lilly/lib/lilly/vm/executor.ex:477-495`, `driver.ex:746-875`, `workspace_source.ex:68-126`, and `lyra/src/workspace_receiver.rs:570-635`.
- Found: a current boot's delivery task passes `spec.workspace_source` into each bounded exchange; a fresh nonce is drawn per attempt. `begin_workspace_source` retains the same boot/source digest and increments attempts after an unsettled record, while a settled record short-circuits redelivery. The guest accepts the identical persisted source and refuses a different source. After `done`, guest redelivery does not start another Git attempt; before `done`, retry is allowed.
- Not found: a hosted real-vsock lost-reply trace. The source path resolves which reference is resent, but does not prove integrated runtime behavior.
- Conclusion: the source-reference question is resolved at source level. The property must assert one accepted source per boot and no Git replay *after done*, not exactly one Git attempt before completion.

#### 2026-10-13 follow-up: How can clone effects be counted without disclosing source content?

- Examined: `nix/verification/tests/machines/repository-launch/guest.exs:35-57`, `lyra/src/workspace_receiver.rs:219-238,529-635`, and the local origin role in `../deployment-topology.md`.
- Found: owner-scoped guest inspection can return a digest of `source.json`, the closed status, done presence and HEAD equality without printing the reference. A controlled local Git origin can keep a bounded request ledger; counts may increase for legitimate pre-done retries and should be compared only after done for no-reclone.
- Not found: a packaged guest-side clone-attempt counter or hosted observer that correlates these with one physical boot.
- Conclusion: partial harness instrumentation, with the check narrowed to supported replay semantics.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
