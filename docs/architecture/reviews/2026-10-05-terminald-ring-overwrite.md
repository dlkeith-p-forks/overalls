# Terminald overwrite backing allocation

## Scope and finding

Baseline67de1f74, ADR-0082. The production Ring appended a whole chunk before
truncating old scrollback. An append to a full ring could make VecDeque grow;
truncation removed bytes while retaining the oversized backing allocation.
A source-derived Rust probe measured logical1MiB and allocated2MiB after one
overwrite. This is backing capacity, not allocator/RSS peak or VM acceptance.

The generated native Ring property failed its allocation bound; the other46
tests passed. Test duration11.01seconds, Nix71seconds, exit1, archive
`1791190116768-2228675-0.jsonl`. Log:
`/tmp/overalls-terminald-ring-allocation-baseline.log`.

## Repair and property

When full, Ring now removes the oldest byte and advances base before appending
the next byte. This reuses already sufficient backing without VecDeque growth.
The existing exact newest-suffix and cursor contract remains unchanged. Live
viewer output remains independent of the scrollback retention path.

Every generated draw includes the default1MiB ring with a one-byte overwrite
and maximum8MiB ring with a32KiB overwrite. Generated fresh positive capacities
cover1/2/3/7/8/9 and32767/32768/32769; chunks cover0/1/2 and32767/32768/32769.
An independent concatenation/suffix model checks exact raw byte order, base and
tail cursors without logging bytes. The oracle reads backing deque capacity,
not merely the logical ring limit. Fixed capacities remain unchanged throughout.
Zero initial capacity is excluded from this budget claim: production creates
positive reserved rings, and retirement's unallocated placeholder is not written.

Reviewed root, Nix/package/terminald contracts, Ring construction, push, resize
and replay, plus the pump's independent viewer queue and growth reservation.
The new contract prevents unnecessary growth when backing already satisfies
the logical limit. Existing larger allocations after resize are not silently
declared fixed; resize/growth and aggregate composition remain separate work.
The change repairs ADR-0082's allocation assumption without changing authority,
protocols or the accepted raw-byte retention decision.

## Execution and remaining evidence

The repaired generated native Ring gate passed47 tests in5.38seconds and
Clippy; Nix40seconds, exit0, archive `1791190304832-2301623-0.jsonl`. Log:
`/tmp/overalls-terminald-ring-allocation-fixed.log`. This result predates the
explanatory contract notes, with unchanged runtime/test logic.

The overwrite repair is integrated with the separate retired-ring repair in
the retired-ring worktree. Combined native/static, documentation and Marshall
verification remain pending. This is a pure Ring property executed by the native
Rust gate; it does not establish actual PTY growth, mixed-pressure aggregate
admission, arbitrary viewer-stream ordering, measured RSS, authenticated guest
composition or hosted faults. Native fixed-ring EOF/NUL-tail evidence belongs
to the separate retired-ring review.

## Final combined verification

After merging main `a03a606d`, the combined native gate passed all 50 tests
in 4.72 seconds and Clippy, with static production compilation; Nix 34 seconds,
archive `1791190829965-2601775-0.jsonl`. The complete Marshall gate passed
1451 checks (237 properties, 1214 tests), two exclusions, seed 931780, in
1585.0 seconds; forced Dialyzer passed 57.24 seconds with zero errors or skips.
Evaluated HLDD passed 19 seconds, archive `1791192580474-3694198-0.jsonl`.
Logs and review scope are recorded in the
[retired-ring final verification](2026-10-05-terminald-retired-ring.md#final-combined-verification).
Source/contract self-review found no blocker in the pre-append eviction or exact
suffix oracle. A fresh overwrite reviewer could not be spawned because the
agent thread limit was reached; the separate retirement repair had fresh review.
