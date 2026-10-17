# Serial-console rendering

- Date: 2026-09-22
- Scope: Firecracker boot-log capture and fullscreen display in the Marsha terminal workspace
- Decisions: ADR-0011, ADR-0082, ADR-0083, ADR-0084

## Scope and evidence

A read-only production diagnostic traced one running customer-profile VM from
its Marshall placement through Lilly's boot-log path. The retained serial file
was 17,011 bytes and contained 838 ESC bytes plus CR/LF-delimited CSI, OSC and
DCS sequences. Lilly's bounded writer and stream return those bytes without
text decoding. The browser hook instead decoded each base64 chunk with
`TextDecoder` and appended it to a plain `<pre>` element.

No terminal payload, credential or login URL is retained in this review. The
live VM and production services were not modified.

## Findings and resolution

- **Medium — implementation violates ADR-0084 byte fidelity.** The plain text
  boot view exposed terminal-control syntax instead of interpreting it in the
  browser emulator. Marsha now passes decoded bytes to a dedicated read-only
  xterm instance, with clipboard and input capabilities absent and HTTP(S)-only
  confirmed links.
- **Medium — boot-log rewind stalled after restart.** When a restarted VM
  truncated the file below the browser cursor, the old view cleared but did not
  request the new file from zero. A rewind now resets xterm and immediately
  resumes at cursor zero.
- **Low — acceptance checked only non-empty text.** The native fleet assertion
  now requires the read-only xterm surface to expose the guest login prompt and
  rejects a representative raw SGR fragment.
- **Product — terminal display could not enter fullscreen.** The display toolbar
  now toggles the browser Fullscreen API, mirrors the actual state in its label
  and pressed state, and refits the visible live or boot-log xterm on transitions.

The Firecracker stdio writer, terminald, Lilly stream, shared protocol and
database registry require no change. Serial output remains read-only and capped
at one MiB; interactive PTYs continue to use the authenticated guest multiplexer.

## Architecture impact

This change reconciles Marsha with the accepted browser-emulator boundary in
ADR-0084 and preserves ADR-0011/0082/0083 isolation, byte retention and transport
contracts. Fullscreen resize uses the existing authorized geometry path for a
writable live attachment and does not let a read-only viewer resize the guest.
The change adds no API, protocol, persistence, authorization or deployment
decision. ADR statuses and the architecture overview remain unchanged.

## Verification

- Read-only production byte-profile and source-path inspection completed.
- `mix precommit` in `marshall/`: 840 Elixir tests/properties passed, 17
  terminal browser-state tests passed, monitoring browser tests passed and
  forced Dialyzer completed with zero errors.
- `mix assets.build` and the focused `TerminalLive` test passed.
- `prek run --all-files`: all logging checks, Ruff, Ruff format and ty passed.
- `elixir scripts/check_adrs.exs` and the pinned code-contract format/discovery
  checks passed.
- `nix build .#checks.x86_64-linux.terminal-fleet` passed in 503 seconds using
  a root-local Nix invocation that advertised the host's available nested KVM;
  the system daemon configuration did not advertise its `nested-kvm` feature.

## Follow-up

Production activation remains separate from this source change. No further
architecture decision is required.
