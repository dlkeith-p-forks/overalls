# Large-file egress cache review, 2026-10-02

## Scope and impact

The isolated worktree starts at `b96443ff`. The user authorized automatic reuse
for eligible objects from empty through 256 MiB and pinned nixpkgs archives,
preferred native/property testing, structured logs and normal production rollout.
No configuration option is added. ADR-0135 supersedes ADR-0069 while retaining
its transport, isolation, ownership, pressure and audit rationale.

Source inspection found that known-length bodies already stream in 64 KiB chunks,
but unknown lengths cannot enter cache storage. Actual pinned GitHub archive
headers showed chunked framing, absent Cache-Control and
`Vary: Authorization,Accept-Encoding`. The new provider classifier is deliberately
separate from destination/TLS admission and cannot authorize a socket.

## Implementation review

Decoded payload callbacks exclude framing. All trailers discard cache writes.
Chunked reservations use independent prefix accounting; declared-length writes
retain the original shrinking-object-limit refusal. Complete publication remains
sync/metadata/atomic rename; existing object layout is compatible. No guest or
management protocol changes are required. Native source and test contracts are
reviewed together; source inspection alone is not runtime acceptance.

Events are catalogued before emission. Admission and publication outcomes contain
only finite atoms and bounded chunk counts; completed request diagnostics add a
closed write outcome. Existing owner/generation-bound request attribution and
operator/VM mutation audit remain unchanged. No URLs, headers or payloads enter
ordinary logs, and no per-chunk events are introduced.

## Execution evidence and limits

The initial full Brady suite passed 69 checks (20 properties, 49 tests) after
restoring the shrinking-limit refusal and updating the formerly intentional
chunked-bypass test to retain close-delimited refusal. The first native large
fixture passed reuse through 8 MiB but failed at 32 MiB because its inherited
100 MiB quota constrained objects to 10 MiB. This failed evidence is retained;
the large fixture now uses the production upper bound and native pressure
observations. Native rerun, concurrency/RSS, production flake reuse and complete
fixture cleanup remain pending. No passing claim is made for those scopes yet.

The historical [production review](2026-10-02-https-egress-production.md) retains
the earlier unexplained provisioning and SSH failures. This cache change does not
establish their causes or fix them by assumption.

The initial large native check passed in 128.31 seconds. It established every
fixed/chunked size through 256 MiB, second-peer reuse, exact persisted full/range
bytes with origin stopped after proxy restart, bounded sampled RSS, four large
readers plus a slow reader without small-hit stalls, trailer/private/truncation
refusal and native reduced-quota streaming with pending reservations released.
The concurrency fixture first lacked curl on its transient service PATH, then
exhausted /run tmpfs with four output files; those failures are retained. Absolute
executables and a separate disposable client-output dataset corrected the fixture.
The original network and storage checks also passed; final rerun follows a source
review correction retaining newly reserved bytes when partial writes and removal
fail. That correction's focused real-file fault test passed with independent
pending accounting. No worker redesign is needed by the passing concurrency scope.

A subsequent final rerun failed at fixed 256 MiB after stale telemetry was treated
as lost custody. Recovery now separates stale capacity from independently
validated unchanged local mount custody: retain complete reads, deny writes,
resume only on fresh pressure, and still stop on invalid/changed binding. Focused
checks passed seven cases (one property, six tests). The next native run retained
reads but abandoned a 128 MiB chunked fill when its pressure deadline expired.
The sampler's 10% CPU quota was inadequate for its native ZFS query workload;
a bounded one-CPU budget is now under native verification, with the three-second
deadline preserved. These failed runs remain part of the evidence.

A real isolated-store pinned Nix fetch was killed in the 512 MiB production
fixture (exit 137). A temporary guest swap retry lost SSH transport; neither
attempt establishes cache reuse. The same fixture is retained for supported
resize and revalidation; no unrelated machine mutation is authorized.

The final large native check passed in 133.30 seconds with the failure-reservation
correction, one-CPU pressure publisher and frozen-publisher outage scenario.
It confirmed fixed/chunked reuse at every selected size from empty through
256 MiB, including 200 MiB, and stale-pressure read retention/write refusal then
fresh resumption, as well as the complete earlier offline/range/concurrency/RSS
and quota/refusal matrix. Archive:
`1790966073603-1830627-0.jsonl` under the local Nix build-log directory.
Brady full precommit passed 74 checks (23 properties, 51 tests) with zero forced
Dialyzer errors. Marshall full precommit passed 1,410 checks (212 properties,
1,198 tests; two excluded) with zero forced Dialyzer errors.

The authorized owner-domain resize retained the original production NixOS fixture
UUID, recorded a durable resize request and completed at 2 GiB/generation 4.
Its isolated-store pinned flake fetch then passed with the expected revision and
NAR hash. This proves the prerequisite, not cache acceptance before deployment.

The merged upstream component checks passed: Lilly full precommit, 474 checks
(84 properties, 390 tests), zero forced Dialyzer errors; Marshall's changed SLO
scope passed six checks (two properties, four tests) and forced Dialyzer remained
clean. All-file prek (catalog logging, ruff format/lint, ty and HLDD), generated
handbook options/coverage/views and the evaluated Nix HLDD gate passed.
Upstream audit/channel/SLO and proc-less namespace repairs retain their separate
reviews and execution scopes.

Before cache deployment, the archive acceptance runner completed two downloads
matching an independent SHA-256
`6c932571e8f5da8e897da50c2dbb932bf760c8f51415187fb3db3c7e40cec41e`
and size 51,142,134 bytes for flake.lock revision
`c3eea5b2156db11c7eeeada3dc737711255b253e`. Its strict attributed-reuse
assertion failed as expected: current NixOS owner/generation responses were both
cache bypasses. Earlier silent-download SSH closures are retained; bounded fetch
phase markers aid diagnosis without changing byte or cache-hit proof requirements.
The implementation was pushed at `8d172891`; healthy activation/live reuse and
physical fixture cleanup remain pending.

## Final production acceptance

Overalls activated `8d172891` and reported matching candidate, activation and
lastHealthy in healthy phase. Later healthy descendants `fcb047fb` and `beb43239`
retained the same Brady implementation. The pinned nixpkgs phase passed NixOS
and Ubuntu. NixOS performed two real GitHub flake fetches with independent local
stores/download caches, returned the expected revision/NAR hash twice, and
recorded two exact-size current owner/generation HTTPS cache hits in a separate
request window. Nix 2.34 uses GitHub `/archive/REV.tar.gz`, redirecting to codeload
`/tar.gz/REV`: its independently hashed archive is 51,154,067 bytes, SHA-256
`d709bfaf611f804a7889c0aa5de349f05e03d7453e9166e9b87338bc7e51f5e0`.
The initial runner used the 51,142,134-byte legacy representation for this
assertion and correctly failed despite actual Nix hits; the route reference was
corrected, without relaxing identity, size, NAR or separate-window proof.

The live large-file phase passed both NixOS and Ubuntu with two exact downloads
each and current owner/generation-bound cache hits for a 318,532,502-byte
LLVM full-commit archive (303.776 MiB), SHA-256
`52516c8cfdab61937638ed35bb65d173812b0bd5ae2abbd89138ff326125242d`.
Commit: `1d07d16b78398848041e650d919d634c782e8309`. This exceeds 256 MiB;
exact 200/256 MiB synthetic cases passed natively. An independent read-only
production cache scan confirmed that all three complete stored public archive
representations match their independent byte digests, including Nix's representation.
The final ordinary probe passed NixOS, Ubuntu and Customer: system TLS trust,
repeat public bytes, redirects, shallow Git clone, protected destination refusal
and independently reachable pinned-IP Customer TCP refusal.

The private campaign is `large-egress-20261002`. Final stages are
`after-large-cache-final` (archive/flake and ordinary probe) and
`after-large-cache-complete` (LLVM), with append-only commands, atomic guest-job
receipts, public references and selected closed request events. Failed
foreground SSH fetches and a later temporary admission refusal remain recorded.
Long checks now use bounded private guest jobs and collect original atomic
receipts; retries do not relax SSH authority or rerun an already claimed job.
An Ubuntu `/tmp` write failure was a tmpfs-sized client-output fixture limit;
large downloads now use the guest home filesystem. A separate native/pinned
fixture retry recorded an unresolved attribution request; the final live windows
met the strict two-current-attributed-completion requirement. These passes do
not establish universal SSH or attribution availability.

A disposable exe.dev origin could not be published because the team's documented
public-sharing policy denied it. The created VM was deleted and independently
absent from the later inventory. Public pinned LLVM supplied the large live
case; no shared production service/storage faults were injected.

Final fixture cleanup completed through the original durable delete requests.
The NixOS deletion initially returned namespace-cleanup unconfirmed; normal
fenced retries subsequently confirmed deletion without forced unmount, direct
dataset destruction or database correction. Independent read-only checks verified
all three exact fixture identities as deleted, compute/disk reservations released,
ZFS datasets absent and VM units inactive. The private campaign retains
`physical-fixtures-after-cleanup.json` and command evidence.


## Overlapping chunked boundary draft

The generated `overlapping unknown-length owners preserve exact object quota and headroom
boundaries` property in `brady/test/brady/chunked_boundary_history_test.exs`
uses two supervised Task lease owners against the real local Store and files.
It independently sums both metadata reservations and accepted prefixes, reverses
append order, rejects foreign append/commit/abort without state changes, and
requires one-byte overflow to discard only the offending lease. Object overflow
has spare quota; quota overflow remains below the object bound. Surviving exact
bytes publish while the refused object remains unavailable. Fixed witnesses
include an empty survivor with explicit EOF behavior.

Architecture impact: evidence only under ADR0135, with no production behavior,
privacy policy, native custody or decision-status change. Formatting, compilation,
execution, final review and HLDD gates are pending. Native pressure validation, unconfirmed
removal combinations, crash/restart and parser/custody/provider composition remain
useful open property work. This draft cannot establish native TLS, ZFS or guest
isolation. Existing upstream execution records retain their original scope.

Synthetic pool and guest-parent observations add exact headroom limits to the
local draft. Pool retains15% and parent20%, with both lease overheads and
accepted prefixes independently counted. One-byte overflow isolates each limit
with spare object/quota space. These integers do not prove native sampling or
mount custody; formatting/execution remain pending.

The existing `decoded chunk payload is independent of wire partition and framing`
property now has an unexecuted draft that varies socket-write fragments and
explicit initial parser buffers. TCP can coalesce writes; only the supplied
initial buffer boundary is deterministic. Exact decoded bytes/count and trailer
markers remain checked. This corrects its previous one-send-only seam, while
actual parser-to-cache publication and fault composition remain open.


The new unexecuted `unknown-length process loss preserves only completed payloads`
property uses real owner/Store death at post-begin, post-prefix and post-commit
boundaries with0/1/65535/65536/65537-byte payloads. Fixed witnesses include empty
prefix loss and committed/recovered neighbors. Monitored abrupt death, actual
Store initialization, exact independently supplied bytes, zero incomplete leases,
empty temporary directories and stale-reference refusal form the oracle.
Owner-loss histories inspect lease/pending cleanup before Store restart. A
committed unrelated neighbor must survive every interruption. No mid-sync/rename
hook, unconfirmed deletion failure, parser completion, ZFS, power loss or native
custody is established. Architecture remains ADR0135; production code is unchanged.
Formatting, execution and final review remain pending.


The unexecuted `chunked proxy histories reuse only complete public parser results`
property in `brady/test/brady/proxy_chunked_history_test.exs` composes actual
Proxy.serve, HTTP parser callbacks, Cache and Store across real loopback TCP.
Generated payload chunks and write fragments cover complete, trailer, truncated,
malformed, private-policy and append-overflow outcomes, with fixed refusal/empty
success witnesses. Complete success must reuse independently supplied exact bytes
and avoid a second origin request. Refusals must leave zero objects/reservations,
empty temporary files and make another origin request on retry. The loopback
policy override does not establish production destination filtering or TLS.
TCP writes may coalesce; no exact recv partition claim follows. Client-disconnect,
mid-commit, provider-inferred archive and native interception faults remain open.
Architecture and ADR0135 status are unchanged; formatting/verification pending.


## Archive policy and repeated pressure histories

Two additional unexecuted properties extend ADR-0135 evidence:
`brady/test/brady/archive_policy_history_test.exs` checks inferred/explicit
freshness and exact variant identity against independent directive/Vary menus,
fixed privacy/ambiguity refusals, canonical path length limits and age expiry
boundaries. `brady/test/brady/pressure_history_test.exs` repeats stale/fresh
observations with completed readers and incomplete leases, checking exact costs,
refused-write cleanup, resumed bytes and missing/changed custody shutdown.
Fixed pressure witnesses include 1, 65,536 and 65,537 byte payloads.
Fresh source review found no blocker; formatting, compilation, execution and
final governance gates remain pending. Pressure proof is synthetic and shutdown
survival is immediate; eventual recovery, native custody, TLS, interception and
hosted faults remain separate. Architecture impact is verification evidence only;
production behavior, accepted rationale and decision status are unchanged.


## Native generated pinned archive draft

The unexecuted `nix/verification/tests/machines/brady-network/large-storage.py` extension
adds fifteen reproducible fixed/generated full-commit archive histories over
actual port-443 upstream TLS and packaged proxy/ZFS storage. Two veth clients
check independent digests and exact origin-count increments for complete reuse
versus private, trailer and truncated refusal. A closed fixture URL encodes
bounded size/mode; ordinary production policy has no test override. Fresh review
found and prompted repair of a one-chunk truncation fixture bug; explicit small
truncated witnesses now require terminal omission. Static and native execution
remain pending. Veth clients do not establish Firecracker attribution or fleet
acceptance. This changes verification evidence only under ADR-0135.

Draft validation: standalone formatting succeeded for the five changed/new Brady
Elixir test files. Standalone Ruff format/check passed for the native origin and
large-storage driver. ADR structure/local-link checking passed (133 decisions),
and the source/evaluated Ash/deployment view check passed. Scenario coverage was
regenerated. The full handbook checker reported stale system/Marshall/Lilly/
services/deployment/governance receipts; those remain pending explicit review
after integration. These checks do not establish compilation, typing, property
execution, native execution or the required pinned precommit gates.

The integrated focused Brady history suite passed nine checks (six properties,
three tests), seed `223798`, in 0.9 seconds. Log:
`/tmp/kittens-brady-histories-focused-ready.log`. The first attempt failed
compilation because a private check/1 helper collided with ExUnitProperties;
it was renamed sync_pressure/1. The next attempt passed five of six properties
but exposed a fully-buffered parser fixture race: the listener closed before
sender accept. Explicit sender readiness repaired that fixture without changing
production code or payload/refusal oracles. Both failed logs are retained:
`/tmp/kittens-brady-histories-focused.log` and
`/tmp/kittens-brady-histories-focused-fixed.log`. Full static/component gates,
reviewed handbook receipts and native generated archive execution remain pending.


## Unconfirmed removal histories

The unexecuted `brady/test/brady/removal_history_test.exs` property generates
prefix and attempted-append sizes with repeated aborts while local directory
permissions prevent removal. Independent reservation sums must remain charged,
writes stay disabled, and an unrelated pinned reader retains exact bytes.
Restored permissions must reclaim the reservation once and fresh pressure must
permit exact new publication. Fresh review found no source blocker; execution
must verify that the fixture process lacks permission bypass. The IO handle is
injected inside its real Store owner. This does not establish native ZFS failure,
mid-publication interruption or power-loss acceptance. Architecture remains
ADR-0135; accepted rationale, production code and authority are unchanged.


The integrated Brady full precommit passed 79 checks (28 properties, 51 tests),
seed `531891`, in 127.1 seconds. Forced Dialyzer passed in 5.18 seconds with
zero errors, skips or unnecessary skips. This capture excludes the subsequently
added removal property. That property passed separately (seed `225096`, 0.2
seconds) under UID 1000, confirming the local permission-refusal fixture executes
without privileged bypass. Logs: `/tmp/kittens-brady-histories-full.log` and
`/tmp/kittens-brady-removal-focused.log`. A final combined component capture,
static/handbook gates and native archive execution remain pending.

The first expanded native run failed before the generated archive histories:
archive `1790970362013-379724-0.jsonl`, inherited fixed 67,108,864-byte case.
The first response delivered exact bytes but abandoned its cache write after
91 payload chunks; retry published 1,024 chunks, and the following peer hit.
Thus the unchanged strict no-new-origin assertion failed. Lines 2111–2137 retain
this sequence. No generated archive pass is claimed. The combined Brady gate
was concurrently active; that observation alone does not establish causation.
Investigation and isolated native rerun remain pending.


The final combined Brady precommit passed 80 checks (29 properties, 51 tests),
seed `219616`, in 117.4 seconds, including the removal history. Forced Dialyzer
passed in 6.14 seconds with zero errors, skips or unnecessary skips. Log:
`/tmp/kittens-brady-histories-combined-full.log`. The failed native first run is
retained; a serial rerun now includes fixture pressure/counter diagnostics without
relaxing the exact reuse assertion. Native and final handbook/static gates remain
pending. This records local component verification, not hosted acceptance.

The serial native run also failed before generated archives, at the inherited
209,715,200-byte chunked reuse case: archive `1790970550880-522711-0.jsonl`,
132 seconds. The failure retained metrics with one writer and 120,348,672 pending
bytes when the origin-count oracle ran. Last-body-byte receipt precedes Store
sync/rename; the fixture now requires exactly one new object and zero pending
bytes/writers before reuse, with unchanged digest and origin-count assertions.
Metrics update every five seconds; a fifteen-second bound spans multiple cycles.
Fresh review found the equivalent inherited 8 MiB archive race, now corrected
with the same barrier. The earlier 64 MiB abandonment remains separately
unexplained. The currently running capture predates the 8 MiB correction; a final
native capture remains necessary.

Pinned all-file prek passed catalog logging, handbook receipts, Ruff formatting/
lint and ty. ADR structural/local-link checks, generated options/coverage and
source/evaluated Ash/deployment views also passed. Log:
`/tmp/kittens-brady-histories-static.log`. These checks include the latest 8 MiB
publication barrier; the live native capture predates that final barrier. Native
verification and final evaluated HLDD publication gate remain pending.

The third native capture (`1790970753103-615133-0.jsonl`) failed the inherited
fixed 134,217,728-byte publication barrier. Lines 2105–2112 show admission,
abandonment after 584 payload chunks, and successful exact response delivery;
the fifteen-second barrier then timed out. This is an abandoned write, not
evidence of slow publication. No generated archive execution is claimed. The
next capture adds bounded cache counters, native pressure proof, uptime and
pressure-unit journal diagnostics on publication failure without changing the
publication, digest, origin-count or timeout requirements. This diagnostic
change preserves existing architecture and capacity contracts.

The final expanded native run passed: archive
`1790971037510-767403-0.jsonl`, 300.02 seconds, command
`nix build .#checks.x86_64-linux.brady-large-storage --no-link`.
It includes all fifteen fixed/generated pinned archive histories, the fixed
and chunked size matrices through 256 MiB, publication barriers, restart,
concurrent readers and reduced native quota. Actual packaged TLS and ZFS
execution establishes this fixture scope only; no Firecracker attribution or
hosted Antithesis acceptance is claimed. Earlier intermittent abandonments
remain unexplained and retained as failures; this pass does not erase them.
