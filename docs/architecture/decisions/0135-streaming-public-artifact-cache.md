# ADR-0135: Streaming public artifact cache

- ID: ADR-0135
- Date: 2026-10-02
- Status: superseded
- Implementation: partial
- Components: Brady, NixOS
- Supersedes: ADR-0069
- Superseded by: ADR-0153

## Context

[ADR-0153](0153-official-source-browser-editor.md) carries every cache and inherited
egress/isolation requirement forward unchanged. It adds only the authenticated,
fixed-port, exact-owner Customer editor ingress exception. This record retains
the cache rationale, evidence and outstanding acceptance obligations.

The user authorized automatic shared-cache reuse for every eligible object size
from empty through 256 MiB and real pinned nixpkgs flake fetches, with preferred
property/native evidence and structured logging, without a new configuration.
The size range is acceptance coverage, not a replacement object limit.
ADR-0069 supports large known-length objects, but only admits Content-Length
responses with explicit public freshness. An independently inspected pinned
GitHub archive is chunked, lacks Cache-Control and varies on Authorization and
Accept-Encoding. Successful forwarding therefore does not establish reuse.

## Decision

Carry forward every ADR-0069 interception, TLS, isolation, attribution, storage
custody, budget, pressure, privacy and monitoring requirement, with the following
additions. This accepted decision is authorized by the user's implementation plan.

Observe decoded payload separately from HTTP wire framing. Preserve backpressure
and the 64 KiB chunk bound. Admit both known-length and chunked eligible responses;
close-delimited responses remain uncached. Reserve declared lengths before writes
and unknown lengths incrementally before each append. Enforce quota, object size
and native headroom throughout. Publish only after valid framing completion,
successful synchronization and atomic rename. Any trailers prevent publication;
partial bodies, malformed termination, failures and abandoned owners cannot publish.
Stored representations retain encoding, validators and supported variants, with
hit framing derived from the complete payload length. Empty objects are valid.

Public pinned GitHub archives are a built-in provider policy, not an operator
setting or transport exception. Only anonymous HTTPS GETs on port 443 to
`codeload.github.com/<owner>/<repository>/{tar.gz,legacy.tar.gz}/<40-lowercase-hex-commit>`
with canonical paths and no query qualify. TLS verification and destination
guards still precede this policy. Credentials, cookies, Set-Cookie, private,
no-store and ambiguous semantics still refuse admission and reuse. Authorization
Vary is removable only on this anonymous provider path; retain all other variant
checks. Missing freshness becomes public max-age=3600; shorter compatible explicit
freshness is honored. Other sources retain explicit-public policy.

Keep one accounting/publication authority. Measure concurrent native transfer
responsiveness before replacing serialized bounded file operations. A blocking
coordinator finding requires bounded lease workers, not weakened ownership fences.

Separate capacity freshness from mount custody. Stale pressure cannot enable
writes or initialization; an already running store may retain complete reads only
after current boot/schema/local mount checks prove unchanged binding. Invalid or
changed custody still stops the store. Fresh pressure resumes writes. Bound the
one-second native sampler to one CPU so its ZFS queries can meet the unchanged
three-second freshness deadline under large transfers.

Add reviewed catalog events for write admission and successful or abandoned
publication. Request completion distinguishes published, abandoned and unattempted
writes. No per-chunk logs, URLs, headers, payloads or credentials are emitted.
Existing operator deployment and VM lifecycle audit paths remain authoritative.

## Alternatives

- Raising size limits alone cannot cache chunked responses or infer public archive
  policy; the existing production limits already permit 256 MiB.
- General heuristic caching without explicit public evidence is rejected because
  arbitrary anonymous responses may still be sensitive.
- A nixpkgs-only path or new Nix setting is unnecessary; the provider policy covers
  public full-commit GitHub archives and the user explicitly refused configuration.
- Whole-body buffering violates bounded-memory and backpressure requirements.
- Replacing interception or storage before measurement adds unproven complexity.

## Consequences

Pinned public archive responses can be reused across guests. Unknown-length fills
may abandon caching partway through while forwarding continues. Chunked storage
must account for every decoded byte and cannot adopt unconfirmed complete objects.
GitHub response-policy changes can cause safe bypass and fail acceptance. Existing
on-disk complete objects remain compatible; no persistent authority migration is
introduced. Provider-path public classification is a new reviewed privacy boundary.

## Invariants and verification

Preferred properties exercise framing partitions, independent reservation prefix
sums, complete publication/restart and provider/privacy near misses. Native HTTPS
and ZFS checks establish exact reuse from empty through 256 MiB, cross-peer reuse,
ranges and restart with origin stopped. Concurrency and sampled RSS distinguish
streaming from whole-object buffering. Live pinned archive and isolated-store flake
fetches must show exact bytes/NAR hash and current authoritative cache hits.
Unit/property evidence alone cannot establish physical isolation or live reuse.

## Implementation evidence

- [Payload observer](../../../brady/lib/brady/http/stream.ex) separates framing.
- [Cache boundary](../../../brady/lib/brady/cache.ex) and
  [store](../../../brady/lib/brady/cache/store.ex) support incremental reservations.
- [Archive classifier](../../../brady/lib/brady/cache/archive.ex) supplies provider policy.
- [Native matrix](../../../nix/tests/machines/brady-network/large-storage.py) and
  [property tests](../../../brady/test/brady/chunked_store_property_test.exs) exist.
- [Review](../reviews/2026-10-02-large-egress-cache.md) records execution separately;
  native matrix, component gates and live nixpkgs/LLVM reuse passed.

## Open questions

The streaming additions have recorded native and live execution, including
real independent-store Nix fetches. Overall implementation remains partial for
inherited fleet fault/availability obligations. Earlier SSH/provisioning and
unresolved-attribution failures remain separate; sampled concurrency is not
universal capacity or power-loss acceptance.

## Related decisions

[ADR-0069](0069-brady-egress-cache.md) retains inherited rationale and historical
implementation evidence. [ADR-0113](0113-guest-trust-at-boot.md) governs guest trust.

## Streaming cache history verification

The integrated Brady precommit passed 80 checks (29 properties, 51 tests), seed
`219616`, in 117.4 seconds; forced Dialyzer passed with zero errors, skips or
unnecessary skips in 6.14 seconds. Six new local properties cover:

- Overlapping unknown-length owners: independent reservation sums, object/quota
  and synthetic pool/parent headroom boundaries, foreign-owner refusal and exact
  surviving bytes, including an empty object.
- Owner/Store process loss after begin, prefix and completed commit: exact
  recovered bytes, retained neighbor, cleared incomplete leases and stale refs.
- Actual loopback Proxy/Stream/Cache/Store composition: exact forwarded framing
  and payload, cache reuse and origin counts for complete, trailer, truncated,
  malformed, private and append-overflow histories.
- Repeated synthetic stale/fresh custody observations: exact pending/used costs,
  pinned reads, refused-write cleanup, resumed bytes and changed/missing shutdown.
- Pinned archive policy combinations: independent freshness/Vary menus, fixed
  privacy/ambiguity refusals, canonical path limits and exact variant identity.
- Unconfirmed removal under injected IO/local permission refusal: exact charged
  reservations across repeated aborts, unchanged neighbor, one-time reclamation
  and resumed publication. The focused fixture passed under UID 1000.

The existing parser property now varies initial buffers and socket writes,
checks exact decoded payload/count and trailer cardinality, and synchronizes
sender readiness. TCP write boundaries do not imply recv boundaries. The
pressure helper rename and fully-buffered listener race repairs changed fixtures
only; failed runs and precise evidence remain in the
[history review](../reviews/2026-10-02-large-egress-cache.md).

Fifteen generated/fixed native full-commit archive histories use actual upstream
TLS on port 443, packaged proxy/ZFS storage and two veth clients. Independent
payload digests and origin counts distinguish complete anonymous reuse from
private, trailer and truncated refusal. Fixed small truncation witnesses require
terminal omission. The first native run failed in the inherited 64 MiB reuse
matrix before these histories. The final native capture
`1790971037510-767403-0.jsonl` passed the full test in 300.02 seconds,
including all fifteen archive histories, restart, concurrent readers and reduced
quota. Earlier intermittent abandonments remain unexplained and retained as
failed evidence. This fixture establishes packaged TLS/ZFS and veth scope only.

Architecture impact is verification evidence under ADR-0135 only. Accepted
rationale, decision status, production behavior and authority are unchanged.
Local properties do not establish native custody, interception, TLS, ZFS failure,
Firecracker attribution or hosted faults. Mid-sync/rename interruption, client
disconnect, eventual custody recovery and native storage failures remain open.
Pinned all-file static checks and evaluated Nix HLDD passed; evidence
summary corrections were followed by another passing all-file check. Existing native/live acceptance
records retain their original revisions and scopes.

## Multi-GiB acceptance extension

The 2026-10-03 authorized plan extends native acceptance to 4 GiB plus one byte,
including signed/unsigned 32-bit accounting and range boundaries. Existing
capacity-derived limits and privacy policy are retained; no option is added.
The [extension review](../reviews/2026-10-03-multi-gib-egress-cache.md) distinguishes
passing properties, native execution through 4 GiB + 1 byte, and baseline
and post-deployment NixOS/Ubuntu 7,487,562,572-byte attributed reuse from
inherited gaps. In-flight transfer survival across proxy restart remains separate.
