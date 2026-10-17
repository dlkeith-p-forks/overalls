---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# brady-cache-physical-headroom-and-leases

**Claim, priority, confidence.** P0 safety, high confidence in the intended pressure/refusal contract. A cache write may begin or grow only with fresh native pool and guest-parent headroom after all pending writes; pressure loss makes writes read-only without deleting complete leased content. Proposed unique assertion: Always("brady cache writes fit fresh physical headroom and retain leased objects on uncertainty", every_write_has_fresh_pressure_and_reserved_bytes && no_live_read_object_deleted_on_stale_pressure). It is missing per ../existing-assertions.md. A separate Reachable("brady cache bypasses a valid write at native headroom floor") guides the intended refusal branch.

**Source and history.** brady/lib/brady/cache/store.ex:104-145 computes quota high/low, 15% pool and 20% guest-parent floors, subtracts pending writes and checks observation deadline. Store.handle_call begin at :153-202 enforces entry/lease ceilings (defaults 8192/256 at :63-64), per-object and global quota, and reserves bytes before file creation. append at :207-238 reserves unknown-length chunks before disk write. open at :305-338 obtains a monitored read lease and validates body inode/size. discard_write at :428-450 retains a write reservation if temporary deletion is uncertain. writable? at :523-530 expires pressure after 5 s. brady/lib/brady/cache/budget.ex:22-44 defines 15/20% hysteresis and pending-inclusive quota. The local source contract is a claim; focus-12-wildcard.md:66-68 notes cross-service guest growth and backup snapshots share pool headroom. No current production failure has been established.

**Workload and oracle.** Run Brady's real intercepted HTTP path in the storage/router TCG scope with a local origin fixture and real ZFS/guest-parent datasets. Fill cache with known body digests, keep one read FD open, start declared and chunked writes, then grow guest data and introduce snapshot/backup use while native pressure samples delay or disappear. Inspect ZFS available/refquota and actual object and temporary file allocations from outside Store. Verify every admitted append had sufficient sampled independent headroom after reservations; new writes bypass when evidence is stale or below floor, while an already opened reader returns its original complete digest. After pressure recovers and old leases end, a fitting new object may publish. Do not infer bytes from Store.used alone.

**Limit menu.** Floor transitions at 14.9/15/19.9/20.1% free, quota exact-fit and one-byte-over, 90/80% eviction hysteresis, 255/256/257 lease attempts, 8191/8192/8193 entries, pressure age 4999/5000 ms; use smaller test-only quota with the same algorithm for repeated runs.

**SUT guidance and limits.** Mark native observation freshness, reserve/append refusal, owner DOWN cleanup and object publication. The existing Nix router exposes real ZFS pool and parent observations, but a sample can be up to three seconds old; the assertion must compare admission to its accepted sample and pending reservations, then test refusal when evidence expires. It cannot promise instantaneous free bytes against unrelated concurrent writers. TCG can establish real ZFS bytes; ordinary containers lacking ZFS cannot prove physical headroom. No property promises cache writes will resume while guest growth consumes shared disk. Open question: Which native fault yields uncertain temporary deletion without corrupting the whole pool?

**Architecture/HLDD impact.** No source/handbook status change; existing cache capacity decisions remain unverified.

### Investigation Log

#### Can the hosted TCG router expose independent pool and guest-parent snapshots at each append?

- Examined: `nix/verification/tests/machines/brady-network/default.nix:1-34`, `nix/verification/tests/machines/brady-network/storage.py:110-185`, `nix/domains/system/brady/storage.py:197-292`, `brady/lib/brady/cache/pressure.ex:30-79`, and `brady/lib/brady/cache/store.ex:108-145,207-238`.
- Found: the storage machine uses a real ZFS router VM and direct pool/parent pressure observations. The root producer publishes a bounded sample; Brady accepts it for at most three seconds and deducts pending reservations on each append. An outside witness can snapshot `zpool`/`zfs` and the fixture's allocated bytes around a controlled append.
- Not found: atomic observation of unrelated writers and Store admission in the same instant. That is not the contract; freshness is bounded, not instantaneous.
- Conclusion: resolved as a sampled-headroom property. Assert the accepted native sample, deadline, quota, and pending accounting at each append; separately observe physical ZFS behavior in controlled histories.

#### Which native fault yields uncertain temporary deletion without corrupting the whole pool?

- Examined: `brady/lib/brady/cache/store.ex:423-450`, `nix/verification/tests/machines/brady-network/storage.py`, and `large-storage.py`.
- Found: `discard_write/2` retains its reservation and pauses writes when `File.rm_rf/1` fails. Existing native tests cover pressure and stale observation, not a targeted temp-directory removal failure.
- Not found: an existing native deletion-failure injector that leaves the cache mount and other objects healthy. A broad read-only remount would also change write custody and confound the intended branch.
- Conclusion: partial. First prove the branch with a scoped filesystem fault seam or a controlled single-temp-path permission fault; verify that the fault does not invalidate the whole cache mount before claiming native coverage.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. hosted-tcg-router-limited; independent witness: real TPROXY/origin count, cache object digest, ZFS pressure and socket inode. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
