# Shared download cache history verification

## Scope and architecture impact

Campaign improvement 027 starts at `08ae4faa` on `verify/027-cache-histories`.
The user operation is an anonymous guest downloading a public artifact, resuming
with a byte range, and retrying after an interrupted cache write or proxy restart.
Current credentials, conditions and personalized responses must still bypass
shared reuse and publication. This work adds component properties and reconciles
source contract wording; it changes no executable production code, API, storage
format, limits, deployment, trust or authority decision.

[ADR-0069](../decisions/0069-brady-egress-cache.md) remains accepted/implemented.
Its complete-object range reuse is preserved. ADR-0113 continues to govern boot
trust and remains partial; these component histories do not establish that native
boundary. New Inception tests and validation are excluded as the user requested.

## Source review and existing evidence

The review traced `Proxy.exchange/5` authority verification and bodyless GET
selection through `Cache.lookup/3`, `Policy.eligible?/1`, `Range.select/3` and
`Store.open/3`. `Proxy.deliver/9` still uses independent full-response admission
and always aborts its owner lease after delivery. Store commit, reader/writer
ownership, monitor cleanup, pressure eviction and actual disk recovery were read
with root/Brady contracts. No runtime defect was established.

The old `brady-cache-anonymous-request` note incorrectly said ranges always bypass
lookup as well as admission. ADR-0069 explicitly permits ranges from complete
objects, and both current Cache source and existing fixed/native tests do so.
The note now states the admission predicate's scope and names the narrow lookup
exception. A Cache lookup contract requires original range/validator selection
and continued enforcement of every other privacy refusal. This corrects a
contradiction without changing or weakening the accepted public-cache policy.

Existing Policy key, Range, Budget, Head, Destination and logging properties,
fixed Store owner/short-write/pinning/restart examples, and proxy socket tests
remain credited. The [historical native review](2026-09-18-brady-egress-cache.md)
records the ZFS extension's **114.69 seconds** and Firecracker fleet scenario's
**248.82 seconds**, scoped to `8446a41`. The packaged network/ZFS checks already
cover real HTTP/TLS interception, offline-origin complete/range reads, restart,
credential/cookie/query bypass, quota/headroom/hysteresis and fail-closed outage.
The fleet separately covers actual execution/owner attribution and address reuse.
None of those historical runs was repeated for this comment/test-only change.

## Added independent properties

[Cache histories](../../../brady/test/brady/cache_history_test.exs) call the actual
Cache and Store APIs with real files and owner processes. The model never calls
Policy admission, key generation or Range selection to decide its expected result.

- Thirty generated publication histories each include complete, short,
  overflowing, explicitly aborted, owner-killed and Store-killed writes; then
  successful writes for seven origin/variant identities, abrupt restart,
  generated subsequent operations, expiry and pressure stop/resume. Full and
  matching-validator range bytes are streamed and compared to independently
  generated bodies after each step. Wrong validators miss. Missing, empty and
  gzip variants, scheme, host, port and target remain separate. Actual files,
  object counts and empty pending/read/write inventories accompany the byte oracle.
- Thirty privacy histories permute current credential/conditional requests,
  including case variation, duplicate headers and ranges, before publication,
  after publication and after restart. Their refusals preserve exact object and
  temporary file contents and Store accounting. Personalized/ambiguous response
  refusals and range/If-Range admission are checked on an otherwise empty key.
- Twenty reader histories exercise both explicit close and actual owner death
  in generated order. Foreign processes cannot read or close the lease; pressure
  evicts an unpinned neighbor while the owner still reads its exact bytes. A new
  pressure observation reclaims the released object, and restart finds no object.

Fixtures use private disposable directories and temporary supervised children.
Store/owner kills are monitored before reuse; bounded accounting polling handles
the independent monitor delivery. Cleanup stops the subtree before removing its
directory, including on assertion failure. Pressure observations are explicit
component inputs. There are no live origins, database resets or production paths.

## Execution record

The first focused run on the initial test candidate passed 13/14 checks and found
a fixture error: refreshing unknown post-restart write pressure with an explicit
low-pressure observation correctly evicted retained entries while the model
expected retention. The fixture now leaves unknown pressure unknown and only
refreshes an already-safe observation. The corrected focused run passed **14
checks (4 properties, 10 tests)**, seed `27001`, in **2.0 seconds**. This is not a
production defect or a failed cache recovery. Initial/corrected logs are
`/tmp/verify027-focused.log` and `/tmp/verify027-focused2.log`.

After review, every lifetime history was strengthened to complete all seven
identities before restart and again before pressure. Owner reply/identity types
were narrowed, fixture paths gained random 128-bit suffixes, and refusal
inventories gained exact metadata and temporary-file contents.

- The final focused scope passed **14 checks (4 properties, 10 tests)**, seed
  `27002`, in **3.9 seconds**. A bounded production mutant then discarded
  Authorization only while normalizing a range request. The privacy property
  failed at its intended `:miss` oracle when a cached `206` was returned; the
  other two properties passed. The minimal counterexample retained two-byte
  public content, duplicate authorization fields and a range. The mutation was
  restored, and all **3 new properties** passed again in **3.9 seconds** with
  the same seed. The worktree's production diff contains comments only.
- Final Brady `mix precommit` passed **58 checks (12 properties, 46 tests)**,
  seed `589620`, in **10.4 seconds**, including the three new properties.
  Forced Dialyzer reported **zero errors, zero skips and zero unnecessary
  skips**, in **4.67 seconds**. Toolchain, compiler warnings, formatting,
  ADR, contracts and catalog logging gates passed. The captured source tree is
  `4b0a86b4203ee0c833e03355f90beecf9e055111`, based on `08ae4faa`; subsequent
  changes record documentation/results only. The test file SHA-256 is
  `2b096e241049e6deb4e6ce24e294730452da946f650af781ce4e2bad7f0e7766`.
- The final application gate and mutation/restoration wrapper drained with zero
  final status; earlier failed attempts retain their distinct outcomes. An independent
  temporary-directory scan after the successful and failing mutation runs found
  no `brady-history-*` fixture directories. Every fixture's cleanup synchronously
  stops its supervised Store/owner subtree before removing its private directory.
- ADR structure/links, reviewed HLDD receipts, generated coverage/options/views,
  contract format and discovery, and all-file `prek` passed. The latter includes
  the required Ruff format/lint, ty, catalog logging and HLDD checks. These
  structural/static checks do not establish native isolation or runtime acceptance.
- The packaged Nix `checks.x86_64-linux.hldd` gate passed in **8 seconds** after
  the corrected receipt bookkeeping. Its archive is
  `/home/ghuntley/.local/state/nix/build-logs/1790392543507-4160632-0.jsonl`;
  `/tmp/verify027-nix-hldd2.log` records the successful wrapper result.

A final receipt command initially requested `updated` after evidence-only edits
without another chapter change. The checker correctly rejected it; the final
bookkeeping was reviewed and recorded as `no-impact`. No Nix build was launched
by that failed wrapper. Its log is `/tmp/verify027-nix-hldd.log`.

Logs: `/tmp/verify027-mutate.log`, `/tmp/verify027-mutant.log` and
`/tmp/verify027-final-gate.log` and `/tmp/verify027-maintenance.log`; the temporary mutant patch is
`/tmp/verify027-range-privacy-mutant.patch`. The earlier full gate also passed
58 checks, seed `613871`, before the final type/path refinements; its log is
`/tmp/verify027-gate.log`. All runs used the pinned development shell and private
build/dependency caches, with the final run also using a private Mix home.

The final semantic review covered the changed Cache/Policy notes, their Proxy
caller, Store/Range obligations and new fixture/model contracts. No remaining
contract mismatch was found in that scope. There are no architectural boundary,
protocol, persistence-format or deployment changes, and no native runtime was
started for this improvement.

## Remaining limits

These properties establish component cache behavior and real local file/process
lifetimes. They do not establish kernel interception, authenticated original
destination, TLS, conntrack attribution, native ZFS custody, power-loss durability,
disk-full/deletion failure, all parser inputs or all HTTP policy combinations.
The generated payloads are bounded and do not measure streaming throughput or
large-object backpressure. Existing native evidence retains its exact revision;
production rollout and independent physical hosts remain separate acceptance.
