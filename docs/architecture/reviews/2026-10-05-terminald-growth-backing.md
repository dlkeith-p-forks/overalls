# Terminald actual growth and aggregate backing

## Scope and architecture impact

Baseline `a03a606d0e71183f913cee946dd59b600d4963c4`, with the pending
retired-ring release and overwrite allocation repairs. ADR-0082 remains accepted
and partial. This batch adds test-only Linux PTY/Unix-socket histories and a
pinned output helper; it preserves protocol, identity and deployment authority.
The growth contract records the existing requirement to reserve an increase
before changing the retention limit. No new architectural decision is required.

## Independent workload and oracle

Every draw includes the default 8 MiB maximum and a generated 2/4/8 MiB maximum,
with generated 32767/32768/32769-byte boundary offsets. Initial rings remain
1 MiB. The session limit exceeds the number needed to exhaust the 64 MiB ring
budget, isolating memory admission from the session-count refusal.

Real PTY programs emit finite NUL output and an octal-encoded completion marker
that command echo cannot satisfy. The streaming reader checks exact byte counts
without retaining or reporting terminal payloads. A first phase reaches the
configured maximum; a second emits more than that maximum after growth, forcing
each final retained ring full. Independent IDs and snapshots check live logical
limits, actual deque backing, exact retention and aggregate reservation.

At full quota, three creates must fail without changing survivors. Retiring one
session returns exactly its quota, drops its retained backing, and permits a
replacement to grow. Final retirement requires empty inventory and zero quota
with the viewer descriptors still open. Cleanup kills owned sessions and waits
for permit retirement on early failure.

## Verification and workload correction

The initial one-phase property passed but a disposable original-append mutant
survived: one targeted test passed in 4.93 seconds, with 50 filtered out; Nix
completed in 37 seconds, archive `1791191798285-3179898-0.jsonl`.
Inspection confirmed the intended mutation in the built source. Intermediate
growth discarded older bytes, so total emitted bytes did not establish a full
final ring. This was a workload gap.

The corrected two-phase baseline passed all 51 native tests in 11.15 seconds
and Clippy with warnings as errors. Nix completed in 45 seconds, archive
`1791192168763-3425135-0.jsonl`; log
`/tmp/kittens-terminald-growth-budget-two-phase-native.log`.
The subsequent targeted control failed with Hegel's inconsistent-outcome
diagnostic, not a stable allocation counterexample: one failure, 50 filtered,
291.04 seconds; Nix 320 seconds, archive `1791192323567-3528926-0.jsonl`.
The half-target first phase did not account for bytes discarded at intermediate
full rings before the next read triggered growth. Arbitrary PTY read chunking
could therefore miss the last growth step. Both phases now emit a full target
plus the boundary offset. At that stage a fresh baseline, stable negative control
and integrated governance gates remained pending; that failure was not credited.

The full-target two-phase baseline passed all 51 native tests in 15.35 seconds
and Clippy. Nix completed in 49 seconds, archive
`1791192715031-3769030-0.jsonl`; log
`/tmp/kittens-terminald-growth-full-phases-native.log`.
The rerun used the same original-append mutation, SHA256
`bf9df7d7881148c69ce534ac8f16a0a0584048d25bd37949ff59d99b05465a3c`,
in the disposable worktree, with only this property selected.

The full-target original-append control then failed the intended aggregate
backing assertion: 134217728 bytes allocated against 67108864 bytes reserved.
The generated counterexample shrank to target 2097152 and boundary 32767; the
fixed default witness is included before that generated family. One targeted
test failed, 50 were filtered out, in 210.16 seconds; Nix failed in 259 seconds.
Archive
`1791192797878-3816768-0.jsonl`; log
`/tmp/kittens-terminald-growth-full-phases-original-append-mutant.log`.
This is local sensitivity to the actual backing regression, not a hosted sweep.
Main `c4b1a7277d1b67c50397bef52d9e27defd70dc2a` was subsequently merged;
the duplicated allocation repairs disappear from this batch's diff. The only
source overlap was the test-module insertion, resolved by retaining both modules.
The disposable mutant worktree was removed after preserving its mutation patch
and logs. Production worktrees contain the repaired append behavior.

## Final main integration

After merging main `c4b1a727`, the complete Marshall gate passed1451 checks
(237 properties,1214 tests), two exclusions, seed342919, in1667.9seconds.
Forced Dialyzer passed46.44seconds with zero errors, skips or unnecessary skips;
its PLT rebuild took3m25.43s. Log `/tmp/kittens-terminald-growth-marshall2.log`.
The initial precommit attempt stopped before testing because the new worktree
lacked the pinned contract checker. Lockfile installation corrected the tooling
gap before this complete rerun; no gate was bypassed.

All repository hooks passed, including Ruff, formatting and ty. The combined
native/evaluated-HLDD check passed17seconds, archive
`1791193311230-4134882-0.jsonl`; log
`/tmp/kittens-terminald-growth-integrated-hooks.log`. Its native result reused
the cache; the authoritative executed51-test baseline remains15.35seconds above.
Source/contract self-review found no blocker in exact retention/backing snapshots,
reservation ordering or joined cleanup. Final report/receipt and commit hooks
follow this recorded integration result.

## Remaining gaps

These histories serialize output phases across live sessions. Simultaneous
growth/admission with mixed stalled and healthy viewers, authenticated vsock,
Firecracker/browser composition, native machine pressure and hosted Antithesis
faults remain separate. This sandboxed native property does not establish guest
isolation or production capacity acceptance.
