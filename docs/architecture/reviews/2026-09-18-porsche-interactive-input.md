# Porsche interactive input review — 2026-09-18

## Scope and architecture impact

ADR-0046 remains accepted and implemented. This change repairs interactive SSH
packet handling and adds bounded transient editing/history and a static banner.
It does not change domain ownership, management commands, durable state, session
authority, exec framing or cancellation. PTY window dimensions affect display
only; the ADR's historical VM-resizing restriction is unrelated.

Before implementation, the input decoder rejected Escape immediately and handled
UTF-8 deletion by codepoint. The channel ignored window changes and only echoed
append/backspace bytes. Incremental decoding and a separate display module keep
transport parsing separate from the existing management runner.

## Contract review

Reviewed root/Porsche/documentation contracts, input and output framing, channel
worker cleanup, runner parsing and connection authority. Pending lines are
separate from the editable draft, so cursor edits cannot reach submitted commands.
History belongs to each channel, never shared connection state or persistence;
existing protected channel/worker diagnostics remain in force. Recall requires
Enter, including when EOF follows a recall. Typed final text retains legacy EOF
submission. Ctrl-C/Ctrl-D retain channel-close semantics.

Pending text is bounded to 8192 bytes, escape state to 64 bytes, and history to
100 entries/65536 bytes. The saved draft adds at most one bounded line. A PTY
viewport follows the cursor without exceeding the reported terminal height. Unsupported
CSI/SS3 sequences are consumed, and UTF-8 terminal controls are rejected before
PTY echo. Progress/results clear and restore an unfinished PTY draft; non-PTY
output does not receive redraw codes. Commands still execute serially through
fresh Marshall session authority.

## Verification

Porsche's full `mix precommit` passed inside `devenv shell` with pinned Elixir
1.20.4/OTP 29.0.6: toolchain, ADR, contract syntax/coverage and adapter regression
checks, warnings-as-errors compilation/tests, formatting, and forced Dialyzer.
The standalone ADR checker (66 decisions) and contract discovery also passed.
The final suite passed 73 tests, including 10 properties; forced Dialyzer reported
zero errors. No contract violations were found in the changed input/display
modules, their channel consumer and the related tests. The suite includes real SSH fragmented
arrows, editing/Enter-only recall, per-channel history, queued commands, PTY
CRLF/wrapping/resize/draft preservation and exec/non-PTY regressions. Unit and
StreamData coverage includes arbitrary packet bytes, Unicode combining/emoji
graphemes, EOF and memory limits; viewport tests bound long-line redraws by
terminal height.

## Remaining limits

Real SSH tests use OTP/OpenSSH against Porsche and a scripted HTTP backend; they
do not claim new fleet or production acceptance. Conventional CJK/emoji widths
are supported, but terminal fonts and ambiguous-width settings can differ.
No deployment is included in this change. Existing automatic delivery may run
when main is pushed.
