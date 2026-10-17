# Terminald byte histories

## Scope and architecture impact

Baseline `bee51d5b`. Reviewed ADR-0082, terminald directory and ancestor
contracts, the frame decoder, ring, session frame consumption and native/static
package factories. This extends verification within the accepted framing and
raw scrollback decisions. Runtime protocol, authority and session budgets are
unchanged. Test dependencies use the existing repository Hegel pin `0.28.8`;
locked sources feed both package factories through Nix's Cargo lock importer.

The old decoder contract said trailing bytes were rejected. Actual session
stream consumption decodes one prefix and drains only its consumed length.
The corrected contract requires partial input to remain incomplete and following
frames to remain available, preserving the accepted stream protocol.

## Properties and oracle

The generated ring history retains the original byte sequence independently of
the production deque, tracking a monotonically increasing first retained index.
Every append/resize prefix checks capacity, base, tail and replay at boundary and
generated cursors. Fixed shrink/grow/append witnesses prevent discarded bytes
from reappearing. Separate configured families exercise the actual default
1 MiB and maximum 8 MiB capacities around their boundaries.

The frame history checks encoded headers independently, splits concatenated
frames at generated chunk sizes and checks exact payload order, consumed length
and untouched following bytes. These are pure codec/ring checks; they do not
establish authenticated vsock, PTY backpressure, shared memory admission or
browser delivery.

A fifth property requires every partial invalid header to remain incomplete and
complete bad-magic/oversized headers to refuse without payload bytes, including
trailing generated data and a fixed u16 maximum witness.

## Recorded execution

The pinned local Cargo run passed four properties in 4.69 seconds, with 38 tests
filtered, exit 0. Compilation took 47.90 seconds. Log:
`/tmp/overalls-terminald-history-local-tests.log`.
Before adding explicit zero-capacity witnesses, the five-property sandboxed native gate passed Clippy with warnings as
errors and all 43 tests (five properties and 38 examples), zero failures,
in 4.90 seconds. Nix completed in 33 seconds, exit 0, archive
`1790997012191-195082-0.jsonl`. Log:
`/tmp/overalls-terminald-five-history-native-repaired.log`.
The static production factory built successfully from the same locked sources
in 21 seconds, exit 0, archive `1790997057393-228913-0.jsonl`. The expression
imports the actual factory with this worktree's pinned flake Nixpkgs input; it
does not add a new package export. Log:
`/tmp/overalls-terminald-five-history-static-build.log`. An earlier Nix invocation selected an unexported package
attribute and failed before compiling; it provides no build evidence.

## Remaining work

Research, ADR and handbook/scenario reconciliation is present. Pinned contract
format/discovery and coverage passed structurally; semantic review found no
blocking oracle or factory defect. The reviewer identified a zero-capacity
coverage hole: generated draws were normalized before reaching set_capacity.
The property now passes the raw draw and normalizes only the independent model,
with fixed new(0)/set_capacity(0) witnesses. Final documentation gates remain pending. The final native
gate including zero-capacity witnesses passed Clippy and all 43 tests in 4.09
seconds, with zero failures; Nix completed in 46 seconds, exit 0, archive
`1790997306664-319364-0.jsonl`. Log:
`/tmp/overalls-terminald-zero-capacity-final-native.log`. Earlier gates
retain their stated revision scope and do not establish physical delivery.
An initial fifth-property draft used an
unsupported generator method and failed compilation. That failure provides no
passing evidence for the fifth property.

The final static production factory including zero-capacity witnesses passed
in 34 seconds, exit 0, archive `1790997359789-359499-0.jsonl`. Log:
`/tmp/overalls-terminald-zero-capacity-final-static.log`.
