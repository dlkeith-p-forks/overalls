# Terminald neighboring session under viewer pressure

## Scope and architecture impact

Baseline `52cd07f1`. Reviewed ADR-0082, root/native/package contracts and actual
PTY, attachment, writer and pump implementations. Distinct sessions already own
separate PTYs and attachment streams; pressure remains scoped to the affected
session. Production behavior, authentication, wire protocol and deployment are
unchanged. The test module is compiled only under `cfg(test)`. The pump's existing
shared-drain lock obligation is backfilled as an explicit contract. ADR-0082
remains accepted and partial.

## Valuable boundary and independent oracle

The explicit-kill histories cover a single stalled terminal. They do not prove
that the daemon's shared drain condition permits a neighboring session to keep
delivering output. The new property opens two actual Linux PTYs and Unix-socket
viewers. The first viewer stops reading after attachment, with a small kernel
send buffer and actual output above its queue watermark. The witness requires
the session to be live and its queue open and unaborted.

The neighbor executes two to four successive commands while pressure is observed
before and after every execution. Each command contains only octal escapes for
its fresh literal output marker, so echoed input cannot satisfy the output
oracle. Detection is bounded and never prints terminal bytes on failure.

Explicit kill of the stalled owner must leave the exact neighbor identity, one
viewer permit and only the neighbor's default ring reservation. Two additional
fresh commands must execute afterward. Both client descriptors remain open
through registration, reservation and permit checks; final kill must return all
allocations. A cleanup guard kills fixture-owned sessions on early failure.

The strengthened value menu includes zero credit and the pump's 32 KiB read
boundaries. Every draw also carries fixed zero and default 1 MiB watermark minus
one, exact and plus one witnesses. Pressure is observed at checkpoints; this
does not prove it remained continuously above the threshold between them.

## Verification

The first sandboxed native check passed all 47 tests in 4.16 seconds and Clippy
with warnings as errors. Nix completed in 32 seconds, exit zero; archive
`1791031818706-3928551-0.jsonl`. Log:
`/tmp/overalls-terminald-neighbor-native.log`.
That execution precedes the zero/configured/pump-boundary extension and explicit
callee contract. The final sandboxed native check passed all 47 tests in 4.66 seconds and Clippy
with warnings as errors. Nix completed in48seconds, exit zero; archive
`1791031945713-4008487-0.jsonl`. Log:
`/tmp/overalls-terminald-neighbor-final-native.log`.
Contract format and callee declaration/ancestor discovery passed. Fresh source review found no
blocking oracle defect and prompted the expanded value menu. Fresh combined source and documentation review found no blocker. The combined
budget/neighbor suite passed all48tests in5.94seconds and Clippy; Nix40seconds,
exit zero, archive `1791032206546-18334-0.jsonl`. The independent fixture daemons
preserve each property's scope. Combined handbook references, generated reference/views/coverage, repository
hooks (including Python formatting/lint/types) and evaluated HLDD passed;
Nix25seconds, archive `1791032486182-211198-0.jsonl`. Log:
`/tmp/overalls-terminald-budget-neighbor-combined-hldd.log`.
Marshall integrated gate and publication remain pending.

## Remaining gaps

Authenticated vsock/Firecracker/browser composition, complete byte fidelity,
aggregate admission, general throughput, arbitrary shell programs, escaped
descendants, host recovery and hosted Antithesis reach remain separate. This is
local Linux PTY/socket evidence, not a NixOS guest integration test.

## Final main integration

Main67de1f74 was merged, preserving corrected native Lilly recovery and main
telemetry changes. These advances leave terminald runtime and this property
unchanged. The complete merged Marshall gate passed1451 checks (237 properties
and1214 tests), two exclusions, seed26636, in1666.1seconds. Forced Dialyzer
passed48.09seconds with zero errors or skips. Log:
`/tmp/overalls-terminald-a5b6-marshall.log`.

The a5b6c891 terminald check succeeded through cache reuse in7seconds, archive
`1791184669364-2936262-0.jsonl`; the authoritative executed combined48-test
result remains the earlier5.94-second run. Post-merge evaluated HLDD passed
29seconds, archive `1791184848551-3078514-0.jsonl`. Reference, options, views,
coverage, ADR and all static hooks passed. Fresh source/contract review found
no blocker and confirmed main boot-adoption scenarios were preserved.
Final recorded-receipt verification and commit hooks follow the67de1f74 merge.
