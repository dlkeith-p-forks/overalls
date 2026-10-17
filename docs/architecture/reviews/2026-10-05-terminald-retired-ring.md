# Terminald retired scrollback allocation

## Architecture and finding

Baseline `7e2b20df6ddfa193a1805801d497fa8b1be65d02`. ADR-0082 requires
scrollback within the VM-wide reservation budget. Natural PTY EOF removed the
session and returned its reservation while viewer threads retained the session
and its allocated scrollback. A stalled peer could therefore pin retired rings
after that capacity became available for new sessions.

The native counterexample reached registry absence, zero ring reservation and
one remaining viewer permit. A weak inspector reference upgraded only because
SUT viewer threads still held the retired session. Its backing deque retained
1,048,576 bytes of allocation. The regression failed that exact allocation
assertion; the other46 tests passed. Native test duration4.34seconds, Nix40seconds,
terminal exit1, archive `1791188361047-1115718-0.jsonl`. Log:
`/tmp/overalls-terminald-retired-ring-baseline2.log`.

The initial draft used an unavailable external helper and failed to reach viewer
pressure. The corrected fixture uses Bash's own printf and counts NUL bytes;
neither terminal payloads nor random attachment tokens enter failure diagnostics.

## Repair and oracles

`session_ended` captures the old logical reservation and replaces the retired
ring with an empty, unallocated backing deque under the session mutex, before
returning quota. Queued output chunks remain owned by the independent viewer
queue, preserving natural EOF draining. Live-session replay and growth are
unchanged; the retired session is no longer attachable.

Generated native histories draw initial rings from1MiB and8MiB and finite tails
from8192/32767/32768/32769/131072 bytes. Every draw includes fixed1MiB/131072-byte
and8MiB/8192-byte witnesses. Actual Linux PTYs and reduced-send-buffer Unix sockets
hold a healthy peer open without read credit. After EOF, the property requires
zero backing allocation before resuming the peer; it then independently counts
the exact emitted NUL bytes to socket EOF and requires the viewer permit to return.
This detects a clear or logical resize that retains backing allocation.

Reviewed root, Nix, package and terminald contracts, Ring construction/replay,
the pump, retirement, viewer writer and reader references. No terminal bytes or
tokens are logged. Production authority, protocol and session lifetime decisions
are preserved. The capacity bug is repaired within ADR-0082; no replacement
decision is required.

## Execution and limits

The corrected generated native/Clippy gate passed47 tests in4.72seconds; Nix
passed36seconds, archive `1791188532516-1236826-0.jsonl`. The static production
factory build passed22seconds, archive `1791188556071-1253503-0.jsonl`. Logs:
`/tmp/overalls-terminald-retired-ring-fixed2.log` and
`/tmp/overalls-terminald-retired-ring-static.log`.

These runs precede adding the oracle's explanatory contract; final structural
and documentation verification remain pending. This is local Linux allocation
and drain evidence, not measured RSS, allocator peak, dynamic growth, aggregate
mixed-pressure admission, authenticated vsock/VM/browser composition or hosted
Antithesis execution. Those boundaries remain separate.

## Documentation review

Fresh read-only source/contracts review found no blocker in the repair or oracle.
The new scenario field was corrected to the established preferred_gap schema
after validation rejected the draft. Coverage generation, ADR/reference/view
checks and all static hooks passed. Evaluated HLDD passed22seconds, archive
`1791188940720-1500238-0.jsonl`. The first hook wrapper reported a concurrent
index update as a modified-file failure while the logging checker itself passed;
a stable rerun passed every hook. Logs:
`/tmp/overalls-terminald-retired-ring-docs3.log`,
`/tmp/overalls-terminald-retired-ring-final-hooks.log` and
`/tmp/overalls-terminald-retired-ring-hldd.log`.

Main67de1f74 was merged, preserving its corrected native Lilly recovery evidence.
Terminald runtime and this property are unchanged by that merge; final integrated
Marshall verification and publication remain pending.

## Final combined verification

Main `a03a606d0e71183f913cee946dd59b600d4963c4` was merged, preserving
the shared admission and neighbor-pressure properties. Combined native execution
passed all 50 tests in 4.72 seconds and Clippy; the static production build also
passed. Nix completed in 34 seconds, archive `1791190829965-2601775-0.jsonl`;
log `/tmp/overalls-terminald-four-properties-native.log`.

The complete Marshall gate passed 1451 checks (237 properties, 1214 tests), two
exclusions, seed 931780, in 1585.0 seconds. Forced Dialyzer passed in 57.24 seconds
with zero errors, skips or unnecessary skips; its PLT rebuild took 3m39.3s.
Log `/tmp/overalls-terminald-allocation-fixes-marshall.log`.
Evaluated HLDD passed in 19 seconds, archive `1791192580474-3694198-0.jsonl`;
log `/tmp/overalls-terminald-allocation-fixes-evaluated-hldd.log`.
Final source review preserves the retirement ordering and independent queued-tail
drain. No authenticated guest or dynamic-growth claim is added by these gates.
