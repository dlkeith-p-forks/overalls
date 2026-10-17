# terminal-input-frame-replay-once

P0; medium-high confidence; safety. Proposed SDK assertion **missing** per [fresh scan](../../existing-assertions.md). `Always` **"Terminal replayed input sequence reaches guest once"**: on one authenticated terminal channel, each accepted positive input sequence advances once and the same sequence resent after lost ACK does not write a second copy to the guest PTY. A gap or over-credit frame fences/closes the channel rather than skipping order. `Always` applies to each settled frame history; a network ACK alone is not proof of guest consumption.

Source: `marshall/lib/marshall/terminal/host_stream.ex:100-110` issues strictly increasing sequences and tracks input window; `:336-344` accepts bounded cumulative ACKs. `lilly/lib/lilly/terminal/stream.ex:34-40,427-445` checks `sequence > last` and exactly `last+1`, passes one frame to Channel or fences a gap; `lilly/lib/lilly/terminal/channel.ex:102-113` writes to the actual guest vsock and only then sends ACK. `marshall/lib/marshall/terminal/CONTRACTS:12-15` requires this ordering. The source shows intended handling; it does not establish PTY effect uniqueness under real faults.

History/oracle: create a real registered session via Marshall, attach over browser/host stream, run a deterministic guest program that records framed input tokens to a file with fsync and echoes them. An external injector repeats an identical encoded frame/sequence on the same authorized stream after suppressing the ACK, sends next contiguous sequence, then tries a gap and over-credit frame. Compare independent guest file token count/order to captured outbound frame IDs and ACK histories; use unique harmless tokens, never user terminal bytes or secrets in diagnostic logs. After connection loss, reattach may create a new channel and is a separate namespace; do not assert cross-channel deduplication without a durable protocol identity.

SUT guidance: `Reachable` **"Lilly ignored duplicate terminal input sequence"** at `Stream.data/4:444-445` with an older/equal sequence; `Reachable` **"Lilly fenced gapped terminal input sequence"** at `:438-441` is a positive protocol-guard branch. A `Sometimes(guest_recorded_two_contiguous_tokens_in_order)` **"Terminal guest observed ordered input after ACK loss"** is meaningful conditional progress when the workload deliberately provides a fault-free tail and live PTY. SDK metadata: channel ID/sequence/count only, never input bytes.

Value menu: sequence 1/1 duplicate/2/4 gap and maximum accepted boundary; frame lengths 1/65536/configured window limit; ACK loss 0/1/2; per-channel credit exact fit/over by one; reconnect before/after ACK. Hosted real Marshall/Lilly stream plus TCG guest terminald establishes byte effect; native Firecracker/vsock isolation requires native machine evidence. Preserve real supervisor/channel ownership; do not directly invoke `Stream.data/4` as the only test.

Open questions: What protocol-level fault seam can repeat a frame on an authenticated same channel without bypassing Marshall's authorization? Which guest test program can fsync a receipt per input token without altering terminal protocol timing enough to hide the race?

### Investigation Log

#### How can a same-channel replay be injected?

- Examined: `host_stream.ex:100-110`, `stream.ex:427-445`. Found: Marshall normally allocates unique sequences; Lilly explicitly discards equal/older sequences. Not found: a live stream frame replay seam in this pass. Conclusion: use transport-level frame duplication in test harness, preserving authenticated hello and channel state.

#### How can guest bytes be witnessed?

- Examined: `channel.ex:102-113` and [SUT environment analysis](../../sut-analysis.md#antithesis-environments-and-independent-oracles). Found: ACK follows Vsock.write, not a guest program fsync. Not found: a currently packaged receipt program. Conclusion: use controlled guest program and report TCG/native execution separately.
