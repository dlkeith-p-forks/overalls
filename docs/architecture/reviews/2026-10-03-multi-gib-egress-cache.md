# Multi-GiB HTTPS cache acceptance, 2026-10-03

## Scope and architecture impact

The user authorized extending verified reuse from 256 MiB to a larger target;
the accepted plan selects 4 GiB plus one byte. The worktree starts at `ef8e997f`.
ADR-0135's capacity-derived policy remains authoritative: 10% cache pool share,
10% per-object share capped at 16 GiB, parent/pool headroom, bounded 64 KiB
payload chunks and complete atomic publication. No runtime option, provider
exception, protocol or persistent-state migration is introduced.

Code contracts and the called Store/Budget/pressure/admission interfaces were
reviewed. The native source-built fixture uses two sparse 512 GiB mirror disks,
64 GiB parent quota, 24 GiB client-output quota and unchanged 2 GiB RAM/ARC limits.
The matrix retains small sizes and adds 512 MiB, 1/2/4 GiB and one-byte signed/
unsigned 32-bit boundary witnesses. Restart/offline ranges cross 2^31, reach the
2^32 boundary, and retain suffix/empty-object refusal. Four 4 GiB readers plus a
slow reader retain small-hit responsiveness and unchanged RSS bounds.

## Tests and failed evidence

The first expanded native run passed through 1 GiB and refused admission at
2 GiB because the inherited fixture parent quota was only 2 GiB. Capacity
telemetry independently confirmed its correct parent-headroom refusal. The
fixture parent quota was raised to 64 GiB; production headroom was not weakened.
Failed archive: `1790992896626-2777481-0.jsonl` in the local Nix build-log directory.

The new generated accounting and actual Store admission properties exercise
2^31/2^32 plus nearby byte/chunk boundaries, exact overlapping reservations,
object/quota refusal and incomplete commit/abort accounting. Sparse declared
admission is not complete large-body proof. The focused run passed eight checks
(six properties, two tests) in 10.7 seconds. The initial fourteen runner checks passed;
ruff format/lint and ty passed for the changed runner/test boundaries. These
units establish neither native custody nor production cache reuse.

The final `brady-large-storage` check passed in 1768 seconds, archive
`1790993907746-3057600-0.jsonl`. It completed the full fixed/chunked matrix through
4 GiB + 1 byte, offline restart/ranges, concurrent readers, bounded RSS,
large sensitive/incomplete forwarding refusals and native quota/headroom cases.
This is packaged TLS/ZFS with veth peers, not Firecracker attribution or a
resolution of the unexplained earlier abandonment.

Marshall's full gate passed 1423 checks (222 properties, 1201 tests), two excluded,
with forced Dialyzer reporting zero errors/skips. The latest acceptance runner
safety suite passed 18 tests with ruff format/lint and ty. Brady's final full
gate passed 83 checks (31 properties, 52 tests) with forced Dialyzer reporting
zero errors/skips. The `complete-4gib` production stage passed on NixOS and Ubuntu at `ef8e997f`: two
7,487,562,572-byte downloads per guest matched the independent SHA-256, and each
original request window contained two current-owner/generation resolved HTTPS
200 completions with at least one cache hit. The independent post-reference
matched the pre-reference. This establishes actual shared-cache reuse, not only
successful forwarding.

## Production workflow

The private campaign is `egress-4gib-20261003`, with distinct current-owner
NixOS/Ubuntu/Customer fixtures and original durable create/delete IDs. OSS guest
logical disks are at least 16 GiB; independent-store Nix requires 2 GiB RAM.
A private 3,000-second guest job bounds two 1,200-second transfers and digest
checks, with atomic receipts and exact timeout/script identity. Reference reads
are streaming, size-bounded and deadline-bounded; references before and after
acceptance must match. Missing current owner/generation cache-hit evidence fails.

Google's published CC-BY 4.0 SigLIP 2 g-opt/16 checkpoint is selected:
`https://storage.googleapis.com/big_vision/siglip2/siglip2_g-opt16_384.npz`.
Its independently inspected response is 7,487,562,572 bytes with explicit
`public, max-age=3600`, ETag `c81fadddb2f5905afb2d277e5b099258` and generation
`1739813170682525`. It needs no query, credentials or new cache exception.
Source: [published checkpoint/license](https://github.com/google-research/big_vision/blob/main/big_vision/configs/proj/image_text/README_siglip2.md).
Other inspected large ISO mirrors lacked public freshness and were not used to
justify weaker admission. The completed baseline establishes live exact digest/hits. The separate
`flake-4gib-regression` stage passed exact pinned nixpkgs tarball downloads on
NixOS/Ubuntu and two independent NixOS flake stores with the locked revision/NAR
hash and their own attributed hit window. The `current-4gib-probes` stage passed
ordinary/refusal checks on all three profiles. Post-deployment validation and
independently confirmed cleanup passed as recorded below. Inherited intermittent SSH,
attribution and native abandonment gaps remain explicit.

The second native run published and reused exact 4 GiB fixed responses, then
abandoned a 4 GiB+1 fill after 13,552 payload chunks despite full forwarding.
Archive `1790993183854-2838608-0.jsonl` retains this failure. The original log
provided no cause, so a reviewed `brady.cache_write_refused` catalog event now
records a finite append-refusal class and bounded observation-age/capacity-deadline
durations. This diagnostic addition does not change admission or deadlines and
is not itself a fix for the earlier abandonment. The largest case now runs first
for bounded feedback; all smaller cases remain in the matrix.

The first two live attempts failed during public SSH trust-document GETs; every
failed attempt remains recorded and neither stage proves full live acceptance.
The runner now retries only transient GET failure classes at most three times,
with each attempt durably recorded. Certificate validation refusal remains an
immediate failure, and successful bytes still pass exact CA/route trust checks.
The independently hashed checkpoint is SHA-256
`64be5a1a0bbdc503903ce6a822809782bb78665c77397d123bb3db49ef2cb050`.

Further live stages retained failures: public trust documents returned 404 after
SSH admission refusals; an owned restart succeeded for NixOS/Ubuntu while Customer
start refused `host_unavailable`; an Ubuntu receipt channel returned 254; another
NixOS job completed but cleanup was unconfirmed. These are readiness/channel
failures, not cache proof. Exit codes 254/255 may trigger a bounded receipt read,
but only the original atomic receipt establishes job outcome. Cleanup retries
the exact owned private path at most five times. Retained receipts validate the
script fingerprint and never relaunch a completed job; retained per-guest
request windows prevent resumed cleanup from substituting unrelated hits.
Legacy receipts without fingerprints are not adopted. No Lilly trust guard
was weakened and no root-cause readiness repair is claimed.

Customer start later succeeded by replaying its original durable `trust-recovery`
request; the earlier `host_unavailable` refusal is retained. The supported restart
was fixture recovery, not a fix for the wider trust/readiness instability.

The generated option-reference gate exposed a pre-existing omitted fleet firewall
default (Brandon Leafman). Regeneration matches current origin/main; no cache
option or deployed firewall change is introduced by this work.

Final all-file prek passed, including logging catalogs, ruff format/lint and ty.
ADR, generated options/coverage/views and the evaluated Nix HLDD gate passed.
The first evaluated HLDD attempt omitted the untracked new review from the Nix
Git source; staging the reviewed record resolved the missing-evidence failure.
The pinned cc-check CLI discovered the Python contracts; Elixir uses the
repository native-comment validator and manual semantic review, as documented
in the contract guide. No contract violation was found for the changed scope.

## Publication and rollout

Implementation commit `86dbe44b` merged current main as `b4519b2b`; the merged
ADR, options, coverage, views, all-file hooks and evaluated Nix HLDD gates passed.
Marshall runtime changes from concurrent main retain their separate complete
passing gate in the telemetry review; this report does not label the earlier
1423-check cache-worktree run as a rerun of that merged runtime. A later main
merge also contains the cache implementation without changing its runtime.

The preceding `dc97de0d` activation failed and timed out Git secret preparation.
Starting that service through its existing preparation path succeeded; the normal
updater then activated `b4519b2b` healthy with zero failures and matching
activated/last-healthy revisions. No credentials, handoff or readiness checks
were bypassed. A generic nonexistent Marshall unit initially produced a
misleading inactive observation; the actual `marshall-overalls.service` remained
active and the documented `/health/ready` endpoint returned `ok`. The prior
activation failure is retained, not relabeled as cache failure or root-cause fix.

Post-deployment exact reuse, fresh flake/profile checks and independently
confirmed fixture deletion passed as recorded below. Existing Porsche lifecycle request
receipts and committed audit outcomes provide mutation evidence; disposable
cache append refusals use diagnostic events, not new authority-bearing audit
records. The private local test PostgreSQL server was stopped normally.

The first post-deployment stage, `post-deploy-4gib`, verified two exact NixOS
7,487,562,572-byte downloads: a miss followed by a current attributed hit.
Ubuntu verified one complete download, then curl exited 18 during the next
main activation. A management transport failure initially interrupted receipt
collection; replay preserved the original window and recovered that failed
atomic receipt. This stage remains failed and is not counted as full acceptance.
A new `stable-post-4gib` stage initially failed before guest launch during
management SSH validation; it was resumed after `b7e29b8f` reported healthy and
all three current ownership checks passed. In-flight connection survival across
a proxy restart is a separate unimplemented boundary.

The `stable-post-4gib` production stage passed on NixOS and Ubuntu at `b7e29b8f`.
Each guest completed two 7,487,562,572-byte downloads with exact independent
SHA-256. NixOS recorded a miss with `cache_write=published` followed by a hit;
Ubuntu recorded two hits on that shared object. All four completions were
resolved HTTPS 200s bound to the current owner and execution generation in their
original request windows. The independent post-reference matched the pre-reference.
This verifies a new multi-GiB publication and cross-guest reuse after deployment.
The earlier interrupted post-deployment stage remains failed evidence.

The `post-deploy-flake` stage passed exact pinned nixpkgs archive downloads on
NixOS and Ubuntu, plus two independent NixOS flake stores with the locked
revision/NAR hash and their separate attributed cache-hit window. Successful
local store reuse was not counted as proxy evidence.

The `post-deploy-probes` stage passed ordinary HTTPS, redirects, shallow Git,
shared public caching and protected/Customer refusals on all three fixtures.
All three original fixture deletion requests completed through Porsche. The
independent `physical-fixtures-after-cleanup.json` record verified exactly those
VM IDs deleted, compute/disk reservations released, all three placement datasets
absent with the parent present, and their VM units inactive. No forced unmount,
direct dataset destruction or database correction was used. The after-cleanup
snapshot retained `b7e29b8f` as the activated and last-healthy revision with zero
failures while the next concurrent main candidate, `570393cc`, was building.

Final impact remains verification and bounded diagnostics under ADR-0135, whose
implementation stays partial. No new cache policy, Nix option, protocol, custody
or capacity authority is introduced. Remaining gaps include unexplained earlier
fill abandonment, intermittent trust/attribution availability, in-flight proxy
restart interruption, mid-publication power loss and native storage failures.
The passing stable stage does not close those failure boundaries.
