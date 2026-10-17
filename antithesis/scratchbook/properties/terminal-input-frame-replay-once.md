# terminal-input-frame-replay-once

P0; medium-high confidence; safety. Proposed SDK assertion **missing** per [fresh scan](../existing-assertions.md). `Always` **"Terminal replayed input sequence reaches guest once"**: on one authenticated terminal channel, each accepted positive input sequence advances once and the same sequence resent after lost ACK does not write a second copy to the guest PTY. A gap or over-credit frame fences/closes the channel rather than skipping order. `Always` applies to each settled frame history; a network ACK alone is not proof of guest consumption.

Source: `marshall/lib/marshall/terminal/host_stream.ex:100-110` issues strictly increasing sequences and tracks input window; `:336-344` accepts bounded cumulative ACKs. `lilly/lib/lilly/terminal/stream.ex:34-40,427-445` checks `sequence > last` and exactly `last+1`, passes one frame to Channel or fences a gap; `lilly/lib/lilly/terminal/channel.ex:102-113` writes to the actual guest vsock and only then sends ACK. `marshall/lib/marshall/terminal/CONTRACTS:12-15` requires this ordering. The source shows intended handling; it does not establish PTY effect uniqueness under real faults.

History/oracle: create a real registered session via Marshall, attach over browser/host stream, run a deterministic guest program that records framed input tokens to a file with fsync and echoes them. An external injector repeats an identical encoded frame/sequence on the same authorized stream after suppressing the ACK, sends next contiguous sequence, then tries a gap and over-credit frame. Compare independent guest file token count/order to captured outbound frame IDs and ACK histories; use unique harmless tokens, never user terminal bytes or secrets in diagnostic logs. After connection loss, reattach may create a new channel and is a separate namespace; do not assert cross-channel deduplication without a durable protocol identity.

SUT guidance: `Reachable` **"Lilly ignored duplicate terminal input sequence"** at `Stream.data/4:444-445` with an older/equal sequence; `Reachable` **"Lilly fenced gapped terminal input sequence"** at `:438-441` is a positive protocol-guard branch. A `Sometimes(guest_recorded_two_contiguous_tokens_in_order)` **"Terminal guest observed ordered input after ACK loss"** is meaningful conditional progress when the workload deliberately provides a fault-free tail and live PTY. SDK metadata: channel ID/sequence/count only, never input bytes.

Value menu: sequence 1/1 duplicate/2/4 gap and maximum accepted boundary; frame lengths 1/65536/configured window limit; ACK loss 0/1/2; per-channel credit exact fit/over by one; reconnect before/after ACK. Hosted real Marshall/Lilly stream plus TCG guest terminald establishes byte effect; native Firecracker/vsock isolation requires native machine evidence. Preserve real supervisor/channel ownership; do not directly invoke `Stream.data/4` as the only test.

Open questions: Which in-path fault seam can duplicate an already authorized Marshall→Lilly data frame on the same authenticated channel? `(partial: public viewer input is renumbered and cannot request replay; no hosted transport seam exists)` Which controlled guest program can fsync a bounded token ledger through the real PTY? `(partial: no such packaged program exists; ACK follows host vsock write, not guest fsync)`

### Investigation Log

#### How can a same-channel replay be injected?

- Examined: `host_stream.ex:100-110`, `stream.ex:427-445`. Found: Marshall normally allocates unique sequences; Lilly explicitly discards equal/older sequences. Not found: a live stream frame replay seam in this pass. Conclusion: use transport-level frame duplication in test harness, preserving authenticated hello and channel state.

#### How can guest bytes be witnessed?

- Examined: `channel.ex:102-113` and [SUT environment analysis](../sut-analysis.md#antithesis-environments-and-independent-oracles). Found: ACK follows Vsock.write, not a guest program fsync. Not found: a currently packaged receipt program. Conclusion: use controlled guest program and report TCG/native execution separately.

#### 2026-10-13 follow-up: Where can a same-channel replay occur without bypassing authorization?

- Examined: `marshall/lib/marshall/terminal/peer_socket.ex:88-104`, `host_stream.ex:100-110`, `lilly/lib/lilly/terminal/stream.ex:427-445`, and `channel.ex:102-113`.
- Found: the public viewer peer requires a newer sequence and forwards only bytes; Marshall's host stream allocates its own increasing data-frame sequence. The replay point is therefore the already authenticated host-to-Lilly WebSocket frame after Marshall encoding, before Lilly's `data/4`. Lilly drops a repeated sequence before `Channel.input`; accepted contiguous frames are sent asynchronously to Channel, and its ACK follows `Vsock.write`, not guest program consumption.
- Not found: an existing in-path hosted duplicate-frame fault seam or guest fsynced token program.
- Conclusion: partial harness work. The safety check should assert at-most-once guest effect for duplicated same-channel sequence; progress/guest consumption needs an independent guest ledger and must not be inferred from an ACK.

#### 2026-10-13 follow-up: What is a safe guest effect probe?

- Examined: the native terminal guest path in `nix/packages/terminald/src/main.rs` and the terminal channel write/ACK path above.
- Found: a fixed, typed, guest-owned program can accept only bounded synthetic frame IDs, fsync a count/order ledger, and emit a fixed acknowledgement to the PTY. Run it as the controlled terminal command, not an arbitrary shell payload. The ledger, not host ACK, is the byte-effect oracle.
- Not found: a packaged implementation or composed TCG measurement of its timing effect.
- Conclusion: partial; establish baseline latency before using a deadline, and keep this fixture's coverage separate from normal interactive shell behavior.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Supporting assertion snapshot

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/terminal/scenarios.py:226`, `antithesis/workload/terminal/scenarios.py:249`. Authenticated HostStream duplication, Lilly cumulative ACK, and a stable guest daemon fsynced digest ledger cover one same-channel duplicate. The planned gap/order branch is absent and no integrated VM or hosted execution exists. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.
