# Provisioning performance implementation review

## Scope and authority

The user approved the fastpath decision (renumbered ADR-0130 after main allocated its earlier identifiers to the fleet log viewer and fleet telemetry), implementation in a new worktree, Ash state machines,
property/native tests, structured event audit and Git-driven deployment through
main/origin. Subsequent direction requires Rust and Hegel for the copy helper.
All direct sudo use remains read-only. Worktree `kittens-provisioning-fastpath`,
branch `codex/provisioning-fastpath`, includes main through `186a1ea4` and preserves
its clone-restart recovery change. This review is in progress, without deployment
or a claim that the full plan is complete.

## Architecture and implementation

Both image builders consume a stripped kernel with separate debug output. The
actual 6.12.104 build compares ELF entry point, PT_LOAD addresses, flags,
alignment, sizes and loaded-byte SHA-256. Its output is 66,089,744 bytes versus
371,451,944 in the investigation. This is an artifact reduction, not a measured
provisioning speedup.

The Rust copy helper forbids unsafe code and uses safe rustix APIs. Exclusive
creation prevents overwrite and leaf symlinks. Source shape, owner, bounded size
and nanosecond identity are checked; the destination is flushed before success.
Only EXDEV, ENOTTY and EOPNOTSUPP permit sparse fallback. Source opens are
nonblocking so FIFO refusal cannot hang. Stdout is a fixed private protocol;
Lilly.Events owns operational metadata and its reviewed formatter allowlist.
Paths, arguments, errors and guest bytes never become diagnostics. The C copy
prototype was removed.

The lock broker itself was then ported from C to Rust (lilly/native/host-lock):
the nonce handshake, inode refusal, exclusive/shared acquisition, distinct
contention exit, frame bounds, status mapping, output/timeout limits and
caller-death fencing are preserved exactly. Utility children are spawned through
std::process with a separate process group and one reviewed unsafe `pre_exec`
call site that pins parent-death signalling and verifies the recorded parent
before exec; the non-CLOEXEC lock descriptor survives exec into the utility.

Two more helpers followed the same recipe under `lilly/native/`: the KVM probe
(byte-identical verdicts on the real device, argv/environment insensitivity and
determinism properties, one reviewed ioctl shim) and the launch guard (selector
and intent-frame Hegel oracles, custody-refusal matrix, and an exclusive-flock
probe proving the shared intent lock is carried across exec). The C sources
(`host_lock.c`, `kvm_probe.c`, `launch_guard.c`) were removed and the host tools
assembler (now `nix/domains/artifacts/hosts/host-tools.nix`) symlinks the Rust binaries from
their independently gated derivations; remaining C helpers are unchanged.

ImageTemplate is an Ash resource separating staging, verification, sealing,
ready, quarantine, retirement and deletion. Native children bind host/pool/image,
incarnation, nonce and GUID. Hashes and precise file identities precede sealing.
Warm use rechecks ownership, GUID, seal and identities under a shared native
lease. Exclusive builders and retirement exclude readers and their utilities.
Bulk staging and VM copying run outside the pool lock. Disks and portable boot
bundles are independent of template lifetime.

The default 32 GiB per-pool budget charges artifact lengths. Native template
allocation reduces headroom and earns no VM credit. Up to sixteen unused LRU
candidates are considered per allocation. Readers and uncertain ownership defer
reclamation. Budget reduction rejects oversized warm use; no-budget images use
fresh verification without caching. Up to 4,096 record directories are retained,
including tombstones and interrupted empty publications; the bound triggers
uncached allocation. Missing journals grant no ownership. Quarantined incarnations
require confirmed retirement and a freshly verified replacement. Unknown content,
foreign owners and GUID changes never authorize recursive cleanup.

The provisioning Ash resource records progress and exact-boot readiness. Its
120-second budget starts at launch after materialization; Inception keeps forty
minutes. Recovery preserves the deadline. Physical authority is checked around
the unlocked guest exchange and before cached receipt reuse. Stop/delete cancel
progress after physical cleanup and reject foreign or stale journals. State and
pending audit publish atomically; boot challenges never enter the audit wire.

Template events add pool_id to the closed schema, with nil placement/workflow/
execution fields. Marshall validates the current host and enrolled pool before
deduplication. The database column is additive. All consumers need compatible
readers before either default-off producer is enabled. Audit grants no authority.

## Recorded validation

- Actual shared kernel derivation passed load-image equivalence.
- Seven Rust/Hegel properties, rustfmt and Clippy passed locally and in Nix.
  Local property execution took 3.28s. A scratch classifier changed to accept
  every errno failed `only_recognized_unsupported_errors_can_copy` as intended.
- Protocol precommit: 215 passed (78 properties, 137 tests), Dialyzer zero errors.
- Marshall focused pool audit: 11 passed, including foreign pool and fake
  placement refusal before deduplication.
- Marshall full suite before main integration: 1,141 passed (124 properties,
  1,017 tests), two excluded; forced Dialyzer passed with zero errors or skips.
  Main integration preserves newer receive-staging recovery, guest CLI recovery,
  maintenance/terminal/secret verification and configured Hegel recognition.
  The integrated Marshall run passed 1,172 checks with forced Dialyzer green.
- Rust copy driver passed in 30.34s; actual cross-dataset method remained copy.
- Rust template crash driver passed in 416.20s, including interrupted native
  create/copy/seal/destroy, safe quarantine replacement, foreign nonce retention
  and replacement GUID refusal, the 4,096-record catalog limit, interrupted empty
  publication and the explicit no-VM-credit assertion. It also covers warm
  process restart, sealing, reader exclusion, LRU retirement, independent VM data
  and changed-artifact refusal through production template/Disk/WorkloadBundle
  paths. Synthetic artifacts establish storage behavior, not guest boot. Earlier
  drivers took 79.46s and 174.49s with narrower scope; timings under concurrent
  build load are test durations, not performance comparisons.
- Final Lilly suite rerun with four concurrent cases passed all 420 checks
  (54 properties, 366 tests) in 23.2s. The preceding default-concurrency run
  passed every property but an existing Inception deadline test took 748ms
  against its 500ms wall-clock bound under load (654ms seen again under parallel
  gate load). No bound was weakened. Forced Dialyzer independently passed with
  zero errors or skips.
- Corrected native fixtures now pass end to end: image-copy + image-template +
  zfs-lifecycle + zfs-transfer completed successfully in 2103s
  (`/tmp/provisioning-fastpath-native-rerun1.log`), including the
  caller-death-holds-both-locks template subtest and the ZFS lifecycle
  interrupted-create/copy recovery boundaries. The lifecycle driver pause-marker
  waits span manifest hashing; markers still fire only after real mutations.
- Later Rust split-package pass-2 validation is **not green**: Marshall precommit
  and Nix HLDD passed, but native zfs-transfer adoption rejected VM configuration
  and fleet Lilly services failed startup before enrollment. The release adds
  multiple Nix symlink layers, while the config validator resolved only one.
  The validator now follows a bounded root-owned chain; targeted control tests
  passed with the Nix-built two-link hostTools path. Native adoption and fleet
  must be rerun on this corrected revision before claiming release acceptance.
  Lilly pass-2 also found an export-channel descendant-reaping spin (fixed and
  seven packaged-helper process tests passing) and the existing load-sensitive
  Inception wall-clock assertion. A full green Lilly rerun was pending at that point.
  A later pass with the rebuilt helper passed the export-channel case but again
  exceeded Inception's 500ms wall-clock assertion under VM load, and once found
  a transfer-stream descendant still in `/proc` immediately after return. The
  transfer-stream case passed in isolation; full-suite reaping certainty remains
  open until a fresh quiet-load run and any necessary process-custody diagnosis.
  After integrating current main (through `4eccdfb8`), the corrected suite
  passed 447/447 checks (61 properties, 386 tests), with zero forced Dialyzer
  errors or skips (`/tmp/opencode/fastpath-merge-lilly-precommit-pass3.log`).
   The earlier reaping failure was not waived: at that revision its assertion
   checked immediate descendant absence, and 12 focused repetitions passed. Protocol
  precommit passed 221/221 (82 properties), with zero Dialyzer errors; the
  pinned Python ruff, format and ty hooks, ADR checker, generated HLDD
  references and Nix HLDD gate passed on the integrated tree. Native adoption,
   full Marshall and fleet acceptance still require integrated results.
   On the later `6b9330c0` primary, Lilly precommit passed 455/456 checks
   (69 properties) and forced Dialyzer with zero errors, but the owner-death
   transfer-stream fixture saw an exited child briefly in `/proc` as a zombie
   reparented to PID 1 immediately after native lock release. Its PID was absent
   on read-only reinspection. The test now waits at most five seconds for every
   observed PID to disappear and still rejects any live or zombie PID after the
   bound; it does not reinterpret a zombie as reaped. The focused native-helper
   file passed nine tests at the failing full-suite seed `554193` and again at
   seeds 0, 1 and 554193 (`/tmp/opencode/fastpath-stream-reap-focused.log`,
   `/tmp/opencode/fastpath-stream-reap-multiseed.log`). This is test-observation
   timing, not a production helper, execution-fence or cleanup change. Full
   precommit on the revised source and native guest acceptance remain open.
  Subsequent merged fixture fixes restored the adoption placement's explicit
  received dataset, disk and claim paths; the composed ZFS-transfer Nix driver
  built and type-checked (`/tmp/opencode/fastpath-zfs-driver-fixed.log`). The
  composed Porsche fleet driver also built after narrowing parsed VM IDs to
  strings at scenario boundaries
  (`/tmp/opencode/fastpath-porsche-fleet-driver-pass4.log`). These are driver
  builds, not machine execution. Marshall's merged ingress history fixture
  corrected two Dialyzer contract errors; its forced Dialyzer run passed with
  zero errors (`/tmp/opencode/fastpath-marshall-dialyzer-fixed.log`). On the
  later merged revision, Marshall's full precommit passed 1,329 checks
  (163 properties, 1,166 tests; two excluded) with zero forced Dialyzer errors
  or skips (`/tmp/opencode/fastpath-marshall-precommit-final2.log`). The first
  integrated full suite exposed a generated-agent oracle mismatch and a
  terminal fixture machine-identity mismatch; both focused checks passed after
  preserving current actor authority and matching the chosen test host.
  A subsequent run passed every test but failed warnings-as-errors on an unused
  test alias; removing the alias yielded the recorded green gate.
  The typed private-evidence benchmark runner and its unprivileged custody
  suite are present in `scripts/provisioning_benchmark.py` and
  `scripts/test/test_provisioning_benchmark.py`. Seven dry-run tests passed;
  ruff format/check and ty for Python 3.13 passed
  (`/tmp/opencode/fastpath-benchmark-integrated-checks.log` plus the final
  seven-case `/tmp/opencode/fastpath-benchmark-tests.log`). They prove the
  planned request IDs precede mutation, refusals block foreign cleanup, lost
   replies reuse the same identity and only the matching catalogued native
   method is retained. They do not measure or exercise live VMs.
   On the later fleet-telemetry integration candidate, the runner's verified
   boot-ID and physical-host load observations plus refusal-and-cleanup tests
   passed nine unprivileged cases with ruff format/check and ty
   (`/tmp/opencode/fastpath-benchmark-evidence-static.log`). Its
   `prewarm_probe_ssh_seconds` is the separate tagged VM sample, **not** the
   image/pool template construction cost; native template identity and prewarm
   duration still require run-specific evidence before a warm speedup claim.
   A further candidate requires an exact catalogued `template`/`verified`
   source for each materialization, binds template record/incarnation UUIDs to
   the owned placement, and demands exactly one host/pool-scoped staging and
   ready audit pair before counting a warm hit. It reports template construction
   by observed image/pool/record and refuses a template created during a warm
   sample. The unprivileged runner suite passed **12 cases** with ruff and ty
   (`/tmp/opencode/fastpath-benchmark-template-static.log`); Lilly's focused
   event/template/disk suite passed **7 checks**
   (`/tmp/opencode/fastpath-source-evidence-focused2.log`). Neither test proves
   a live production cache hit or prewarming cost; native guest and rollout
   evidence remain mandatory.
   A later read-only preflight exposed an actual durable guest username with an
   internal dot, allowed by Marshall's account grammar but refused by the
   initial benchmark argument validator. The corrected runner validates that
   grammar and requires a fresh authenticated Porsche `whoami` with the exact
   selected guest account **before** writing the intent manifest. Wrong-account
   refusal adds no fixture. The suite passes **14 unprivileged cases** with ruff
   and ty (`/tmp/opencode/fastpath-benchmark-account-static.log`); the strict
   read-only production `whoami`/configuration proof succeeded without creating
   a run directory. It did not create a guest or establish SSH readiness.
   The disposable ZFS template probe now asserts that the warm callback holds
   both native template UUIDs and a source lease while an uncached callback
   holds neither. This extension is present but has not yet been executed on
   the correlation-metadata revision; earlier machine passes retain their
   original source scope.
  A later strictly read-only live probe exercised the runner's Porsche
  `whoami --json` transport, bounded PostgreSQL lifecycle/placement queries
  (the absent fixture ID was refused), and its cleanup oracle against the
  already deleted run-owned VM `01937f7d-913b-4bd7-ab2c-da9da8ec04db`;
  the cleanup predicate returned true. It performed no creation, deletion,
  terminal-data capture or speed measurement and cannot substitute for a
  complete fresh benchmark or guest-SSH acceptance.
  The corrected integrated ZFS-transfer **VM** check subsequently passed in
  450.34 seconds (`/tmp/opencode/fastpath-zfs-transfer-integrated-run.log`),
  including `AdoptionCrashRecovery: PASSED (2 test cases)` against native ZFS.
  This proves the storage adoption and crash-recovery assertions in that driver,
  not an authenticated guest SSH journey.
  On the same primary fastpath source before the newer-main integration, the
  image-copy, image-template and ZFS-lifecycle NixOS machine checks all passed
  as a single `native-rest=0` build
  (`/tmp/opencode/fastpath-native-rest-integrated.result` and
  `/tmp/opencode/fastpath-native-rest-integrated.log`): their VM scripts finished
  in 21.74, 233.17 and 2527.86 seconds respectively. The image-template run
  includes bounded-catalog publication recovery. These native results establish
  storage/custody behavior, not full NixOS/Ubuntu guest SSH or deployed readers.
  The following Porsche fleet VM run was **not green**
  (`/tmp/opencode/fastpath-porsche-fleet-integrated-run.log`,
  `/tmp/opencode/fastpath-porsche-fleet-integrated-run.result`: `fleet=1`).
  Both Lilly provisioners started, and the authenticated host enrollment stage
  completed in 170.86 seconds, correcting the earlier packaged-helper startup
  failure. The real browser-key/guest lifecycle reached clone relocation before
  a Porsche command refused `temporarily_unavailable`: all three Marshall
  backends briefly failed readiness, HAProxy returned 503 with no healthy
  server, and Postgrex client timeouts appeared. The fixture correctly did not
  reissue an uncertain mutation under a new request ID or reinterpret it as an
  `insufficient_capacity` refusal. Complete guest SSH/cleanup acceptance and
  a quiet-window rerun remain necessary; this result cannot prove a speedup.
- Rust lock broker: `cargo test` in and out of the Nix sandbox passed 3 Hegel
  property classes plus 12 process-level protocol cases; `cargo fmt --check` and
  clippy `-D warnings` pass inside the package gate. Differential sessions
  against the C helper matched byte for byte across echo, missing-executable,
  nonzero-exit, timeout, 64 KiB overflow, 4 MiB extended limit and shared-mode
  cases (`/tmp/provisioning-fastpath-host-lock-differential.py`). Lilly's
  locked-command suite passed 10/10 (1 property, 9 tests) against the Rust
  binary.
- Rust KVM probe: sandbox gates passed (1 constants unit test, 2 Hegel
  properties); on this host `/dev/kvm` the C and Rust binaries agree on success
  and on argument noise. Rust launch guard: sandbox gates passed (3 unit
  property/deterministic tests plus 5 process custody cases), with differential
  parity across the 0/64/71/74/75 edge lattice
  (`/tmp/provisioning-fastpath-launch-guard-differential.py`).

An initial Hegel identity test incorrectly assumed rapid writes always advance
timestamps; the corrected test establishes an actual mtime change. Timestamps
alone do not prove absence of arbitrary privileged tampering; trusted ownership
and the native read-only seal are the independent boundary.

Recorded logs:

- Rust/template: `/home/ghuntley/.local/state/nix/build-logs/1790397808997-1248276-0.jsonl`.
- Historical copy: `/home/ghuntley/.local/state/nix/build-logs/1790395041878-594749-0.jsonl`.
- Mutant: `/tmp/provisioning-fastpath-rust-mutant.log`.
- Latest Rust/Lilly: `/tmp/provisioning-fastpath-lilly-final.log`.
- Protocol: `/tmp/provisioning-fastpath-protocol3.log`.
- Pool audit: `/tmp/provisioning-fastpath-pool-audit-test2.log`.
- Native crash/copy rerun: `/tmp/provisioning-fastpath-template-crashes.log`.
- Native crash/copy result: `/home/ghuntley/.local/state/nix/build-logs/1790398801164-1575633-0.jsonl`.
- Native catalog/crash result: `/home/ghuntley/.local/state/nix/build-logs/1790399537586-1785245-0.jsonl`.
- Lilly test rerun: `/tmp/provisioning-fastpath-lilly-tests-final.log`.
- Guest rerun: `/tmp/provisioning-fastpath-fleet2.log`.
- Marshall full suite and Dialyzer: `/tmp/provisioning-fastpath-marshall-final.log`.
- NixOS Porsche journey: `/home/ghuntley/.local/state/nix/build-logs/1790399536378-1785034-0.jsonl`.

## Compatible-reader release candidate (2026-09-29)

The integrated primary `b52e9ee8` includes upstream `996f588e`, the
accepted/partial fastpath [ADR-0130](../decisions/0130-verified-provisioning-fastpath.md)
and fleet telemetry ADR-0129 without changing either decision's authority.
Production Nix evaluation keeps both `services.lilly.provisioningReadiness`
and `services.lilly.imageTemplates.enable` false on Overalls and Dungarees.
Protocol precommit passed **221 checks** (82 properties), Lilly **456** (69
properties) and Marshall **1,361** (177 properties, two excluded), all with
zero forced Dialyzer errors (`/tmp/opencode/fastpath-protocol-b52.log`,
`/tmp/opencode/fastpath-lilly-b52.log`,
`/tmp/opencode/fastpath-marshall-b52.log`). The prior transient native-stream
reaping assertion is retained with bounded PID-absence observation, not waived.
Reviewed contracts, ADR, Python/logging hooks, generated handbook references
and the Nix HLDD gate passed on the integrated source.

Both production host closures and the NixOS Porsche, Ubuntu user-SSH and
template drivers built on `b52e9ee8`
(`/tmp/opencode/fastpath-release-b52-closures.log`); the Ubuntu bootstrap,
roster and clone recovery drivers also built
(`/tmp/opencode/fastpath-b52-extra-drivers.log`). These are construction and
typing gates, **not** VM acceptance. The current NixOS and Ubuntu guest
artifacts share the same 66,089,744-byte stripped kernel store object; each
manifest's kernel size and SHA-256 matched the object
(`/tmp/opencode/fastpath-kernel-artifacts-b52.log`). The build-time load-image
verifier retains the earlier equivalence proof.

Strict read-only admin SSH observed both hosts healthy on upstream
`996f588e`, their active systems and required Marshall/Porsche/Lilly roles
matching status, and `compute_lifecycle_events.pool_id` still absent
(`/tmp/opencode/fastpath-reader-verifier-upstream996.log`). No reader commit was
pushed at this checkpoint. The revised native template UUID assertion,
complete NixOS/Ubuntu guest SSH/restart/clone/relocation journeys, two-stage
rollout and controlled speedup measurement remain unrecorded.

## Reader deployment and live canaries (2026-09-29)

The compatible-reader `153db737` commit was pushed to `origin/main` and the
remote SHA independently matched. At 04:52 UTC strict read-only admin SSH
found both enrolled hosts healthy on that exact revision with
`lastHealthySystem` equal to each active system, required running
Marshall/Porsche/Lilly roles, and the additive `compute_lifecycle_events.pool_id`
column installed (`/tmp/opencode/fastpath-reader-rollout.result`, `.log`). Both
Nix-evaluated fastpath producer flags remained **off**. A later read-only check
found both hosts healthy on upstream `04a448fb`, still with `pool_id`; that
subsequent commit did not enable the fastpath producers. This is verified
reader deployment, not native template or SSH-ready producer acceptance.

The enabled NixOS and Ubuntu rows on Marshall matched all three artifact
digests and sizes in the **fleet host package** manifests, including the shared
66,089,744-byte stripped kernel (`/tmp/opencode/fastpath-reader-images-153.json.log`).
Both hosts reported fresh, enabled inventories advertising both image IDs.
The direct flake guest packages omit the fleet's private-service public CA
roots and have different rootfs digests; those packages are not the deployed
image identities (`/tmp/opencode/fastpath-reader-baseline-latest-20260929.json`).

The first run-owned NixOS canary received a Porsche creation receipt in 16.36s
but did **not** reach the client's authenticated SSH probe: the initial runner
selected `-F /dev/null` and omitted the installed Audi `ProxyCommand`. Its
already-persisted deletion request stayed accepted longer than the runner's
120-second observation window. No replacement request was submitted. The same
request later projected `succeeded`; read-only SQL found the VM deleted and
reservations released, and a host ZFS listing found the run-owned dataset
absent (`/tmp/opencode/fastpath-reader-canary-reconciliation.json`). The
initial canary is a failed SSH sample despite eventual physical cleanup.

The corrected runner explicitly selects the installed guest SSH profile,
retains strict host-CA checking and the selected account key, and keeps
control/admin SSH isolated from ambient configuration. Uncertain deletion
polls only its persisted ID for a bounded 1,200 seconds; neither an accepted
request nor a closed SSH command response is cleanup proof.
Fifteen local custody/refusal tests, ruff and ty pass
(`/tmp/opencode/fastpath-benchmark-proxy-static.log`). Through that Audi route,
one NixOS and one Ubuntu canary then each passed actual authenticated SSH `ls`,
observed a guest boot ID and the verified **uncached** native source, received a
successful deletion receipt, and independently proved `deleted`/zero held
reservations/absent ZFS dataset (`/tmp/opencode/fastpath-reader-canary-second-evidence.json`,
`/tmp/opencode/fastpath-reader-canary-ubuntu-evidence.json`). Their uncontrolled
creation-to-SSH times were 21.57s and 12.72s. They are not ten-sample medians,
warm template hits, clone/relocation acceptance, or a 30%/<10s result.

Architecture impact: the runner now uses ADR-0110/0124's existing Audi and
host-CA transport instead of bypassing it; ADR-0130 remains accepted/partial.
No production authorization, shared protocol or cleanup decision changed.
Native NixOS/Ubuntu acceptance, the separate producer release and the matched
baseline/enabled campaign remain required.

## Scoped NixOS Porsche lifecycle capture (reader revision)

The strict `porsche-fleet` VM run on `153db737` started at recorded local load
10.30 and finished **red** (`/tmp/opencode/fastpath-porsche-fleet-quiet-v2.meta`,
`.result`, `.log`). The complete existing **Porsche lifecycle subtest passed in 816.61 seconds**:
real NixOS guest creation, SSH-facing admission, stop/start,
cross-host relocation, independent cloned ZFS datasets, retained guest marker
checks, clone request replay, and original/copy/browser cleanup. Capacity-race
and release-upgrade stages also passed. The full fleet run failed later at
`verified terminal v2 sessions, sharing and reconnect across three Marshall
machines`: Marshall replicas recorded PostgreSQL connection checkout timeouts
and the separate browser worker returned `AssertionError`. That terminal-stage
failure is not a passing fleet verdict or Ubuntu acceptance; no uncertain
Porsche mutation was retried with a new identity.

The new `porsche-lifecycle-fleet` and `porsche-lifecycle-ubuntu-fleet` test
variants include the unchanged Porsche lifecycle scenario and its real two-host
bootstrap, enrollment, storage and trust prerequisites. They exclude only the
unrelated legacy terminal/browser stages after the Porsche fragment. Both are
**present, not executed** on the revised source; a driver build or the scoped
passing subtest cannot substitute for a green native journey. No production
code, capacity bound, cleanup authority, accepted ADR or Porsche refusal was
relaxed to construct these focused checks.

## Ubuntu authenticated SSH journey (reader revision)

The disposable `user-ssh-journey-ubuntu-fleet` VM test **passed** on exact
reader revision `153db737f01d27c9121277f3e4c6114c26c4e517` (started at
load 11.68; `/tmp/opencode/fastpath-ubuntu-journey-quiet.meta`, `.result`,
`.log`). The complete script finished in 1013.25s, including current
authenticated interactive login and guest home, zero-key onboarding, account
key revocation and re-registration, agent-only SSH, certificate renewal and
reload, Porsche relocation retaining login/home (278.49s), and reboot/clone
distinct keys under unchanged client CA trust (259.05s). VM-test cleanup
finished in 3.93s. The disposable fixture explicitly sets
`services.lilly.provisioningReadiness = true` and enables image templates for
`userSshJourney`; production hosts still have both producers **off**. This
passes an Ubuntu guest transport/lifecycle journey with enabled fixture
configuration, but the test does not inspect a native template hit, the exact
boot-readiness journal or a delayed-readiness refusal. It is not the full
Ubuntu Porsche lifecycle variant or a controlled benchmark result. The
focused Porsche NixOS/Ubuntu variants still require executed verdicts.

## Revised native image-template correlation (reader revision)

The `image-template` NixOS machine check passed on exact reader revision
`153db737f01d27c9121277f3e4c6114c26c4e517` after starting at local load
11.66 (`/tmp/opencode/fastpath-template-quiet.meta`, `.result`, `.log`). The
revised UUID-correlation template driver passed in 205.65 seconds, with VM-test
cleanup in 0.39 seconds. Its disposable native ZFS fixture ran fifteen
subtests covering verified staging/seal, independent disk copies, LRU and
active-reader exclusion, foreign nonce/GUID refusal, interrupted create/copy/
set/destroy recovery, caller-death leases and the 4,096-record catalog bound.
The warm callback checked a validated record UUID, incarnation UUID and native
source lease; the verified uncached callback checked that all three were
absent. This is actual ZFS and production Ash/storage adapter evidence using
synthetic artifacts. It does not establish a real guest boot, a production
template hit or a warm creation-to-SSH median.

The revised NixOS/Ubuntu user-SSH journey drivers add a **present, not yet
executed** native check after authenticated guest SSH and after source VM
restart. The real guest boot UUID is compared through a digest against Lilly's
validated durable `Provisioning` journal; the fixture also checks the current
host/placement, running intent, execution epoch/generation, boot challenge and
the ordinary 120,000-ms launch deadline. It refuses a stale boot digest and a
foreign host without emitting the journal payload or boot challenge. This
would establish exact-boot receipt custody in a disposable guest, not a warm
template hit, arbitrary-client access or production producer activation.
Both composed NixOS/Ubuntu driver builds pass and their packaged scripts
contain the new initial and post-restart proof/refusal assertions
(`/tmp/opencode/fastpath-readiness-proof-current-drivers.log`); the revised
VM-test execution is still absent. Architecture impact: ADR-0017/0130
authorization, persistence and transport are unchanged; only an existing
native verification path gains direct journal/refusal assertions.

## Findings and remaining acceptance

### Cross-host Ubuntu guest image identity drift (2026-10-02)

The producers-off benchmark preflight refused the current enrolled hosts
before any new creation: Overalls and Dungarees both reported healthy readers,
but Dungarees did not advertise the exact Ubuntu ID selected from the enabled
catalog. Read-only inspection found that both Lilly runtime configurations
refer to the **same Nix-store image path and derivation**, yet their registered
NAR hashes and `manifest.json` rootfs SHA-256 descriptors differ. The shared
66,089,744-byte kernel and initrd descriptors match. This is a reproducibility
defect in the guest artifact, not permission to substitute one host's image ID
or fabricate an offer. It prevents a matched two-host baseline and any
template-enabled comparison.

The guest rootfs contains an offline Nix SQLite registration database. Read-only
`debugfs` observations found 90 `ValidPaths` and 455 `Refs` on each host, with
identical logical rows except that all `registrationTime` values reflected the
respective build times (nine seconds apart). The `db.sqlite-shm` bytes differed;
both `db.sqlite-wal` files were empty. Fixed ext4 UUID, creation/check/write
times, inode count, free blocks and directory hash seed matched. Normalizing
**in-memory copies** of both real guest databases to a fixed registration time,
checkpointing WAL, removing sidecars and vacuuming yielded identical SQLite
bytes; no production host Nix database, guest artifact or Marshall database was
written during this investigation
(`/tmp/opencode/fastpath-ubuntu-db-real-normalization.json`).

The proposed build correction in
[`normalize_nix_db.py`](../../../nix/domains/artifacts/guest/ubuntu/normalize_nix_db.py)
operates only on the sandboxed Ubuntu guest tree, immediately after offline
`nix-store --load-db`. It preserves registered paths and references, fixes the
registration timestamp, checkpoints and verifies SQLite, and removes the
transient sidecars. Three typed unit tests pass for different build timestamps,
preserved references, and refusal of empty or symlinked databases. This is
**present, not yet a passing rebuilt image**: independently rebuild and compare
the complete rootfs/manifest/NAR identities before attributing the entire
cross-host mismatch to those database bytes. A new digest means a new immutable
catalog image ID, which must be deployed, enabled and observed on both hosts
before a new controlled baseline. Production fastpath producers remain off.
Architecture impact: ADR-0014/0098's exact-byte image identity and ADR-0130's
pool-scoped templates are preserved. The correction changes the artifact bytes
of future Ubuntu builds, not guest registration authority or existing VM disks;
no accepted decision is replaced. The unreconciled cross-host output is an
acceptance blocker, not a waived capacity or image-integrity check.
The exported `ubuntu-guest-unit` Nix check passed on this local source: it
inspects the real rootfs build command for the sandboxed normalization call
and reruns all three typed database cases. This structural and unit gate
does not read the resulting full image or establish two-build reproducibility.
A revised Ubuntu native SSH journey now also contains a **present, unexecuted**
guest command that queries its installed pinned development-tools closure from
the guest-local Nix registry after authenticated login. It returns only a
fixed success marker. This will test runtime usability of the normalized DB
after a real boot, but cannot establish cross-host artifact reproducibility;
the complete rootfs build and native journey are still outstanding.

The producers-off campaign on reader descendant `073eb8b4` began at local load
9.95 and ended **red** (`/tmp/opencode/fastpath-baseline-quiet.meta`, `.result`,
`.log`; manifest and phases in
`/tmp/opencode/fastpath-baseline-20260929-061014/`). Both distribution prewarms
and all ten sequential authenticated SSH `ls`/boot observations per
distribution have confirmed cleanup. Their exploratory sequential medians
were 19.458s NixOS and 12.825s Ubuntu; they are **not an accepted matched
baseline**, since two of four concurrent creations failed with
`execution_failed` and never yielded authenticated SSH samples. The other two
concurrent guests were deleted by the campaign. The two failed creates were
looked up by their original persisted IDs, and their exact run-owned VM names,
VM IDs and `owner: true` Porsche observations were checked before using their
*preplanned*, not replacement, deletion IDs. Both deletion receipts succeeded;
the VMs are observed `deleted`, reservations released and the two exact
Overalls placement datasets absent (`/tmp/opencode/fastpath-baseline-reconciliation.jsonl`
and read-only ZFS observations). Do not count or replay the failed samples.
An additional read-only audit joined all 26 manifest names to VM state and
reservation rows: 26 `deleted`, zero held reservations; it matched all 26
placement IDs to the native ZFS inventories of both hosts, with zero remaining
run-owned datasets (`/tmp/opencode/fastpath-baseline-physical-cleanup.json`).
This establishes campaign cleanup, not a passing campaign.
This failure blocks the matched enabled comparison and producer release;
diagnose the concurrent execution failures without changing capacity fences.
Read-only Lilly journal inspection for 06:49:20–06:49:34 UTC narrows both
NixOS failures to `vm.dataset_preparation_failed` with
`incoherent_zfs_observation`, followed by `disk_prepare_failed`; their physical
outcomes were `failed`/`execution_failed` with no disk present. One cleanup
path also emitted `network_unavailable` while the failure was being reconciled.
The dataset preparation path uses bounded whole-pool observations and must
withhold credit on policy/identity drift. These events do **not** establish
whether a concurrent non-usage property change, failed identity read or
another incoherence caused the rejection. Keep the capacity/ownership checks
intact and gather discriminating native evidence before any behavior change.
The follow-up Lilly change threads the already validated placement UUID into
the existing whole-pool observation at dataset preparation. It preserves the
same three-attempt bound, identity/policy checks, storage-busy distinction and
capacity refusal; the already catalogued `vm.dataset_observation_failed`
event can now include only fixed failure stage/reason atoms and the placement
UUID for this path. The code is present but **not deployed**; it cannot explain
the past failure retroactively. A future same-ID concurrent run must establish
the emitted stage before any attempt to change storage behavior. Architecture
impact: ADR-0017/0130's storage authority and audit boundary are unchanged;
the diagnostic only narrows the observed refusal, without granting credit.
The diagnostic branch's focused ZFS suite passed 16 checks (four properties)
and all-file Python/static, ADR, contract, logging, HLDD and Nix HLDD gates
passed. Its first full Lilly precommit attempt stopped at formatting, then a
second ran **455/456** tests and all 69 properties with zero forced Dialyzer
findings. The sole red test was an unrelated Inception round deadline wall
assertion: 2568ms against a strict <1800ms under local load; it passed when
re-run at the recorded seed by itself. The full gate is **not green** and needs
re-execution without contention before this branch can serve as release
evidence. Neither a focused pass nor Dialyzer repairs the failed full verdict.
The runner previously tried only read-only `request show` after a failed
creation; because Porsche exits nonzero for a terminally failed request, that
path timed out without cleaning a VM that had held reservations. It now reads
the exact original request ID from the database after uncertain failure, and
deletes only a terminally failed request's validated VM ID after Porsche proves
the manifest name and current owner. The deletion uses the preplanned ID and
requires both its receipt and released reservations. Missing/running request
rows and foreign owners remain unconfirmed rather than granting cleanup.
Seventeen local custody/refusal tests pass, including failed-create cleanup
and denial cases; this mock-based result is not physical recovery proof.
The follow-up runner also reconciles an authenticated success receipt with a
missing or malformed VM identity, or a lost reply whose same-ID request later
committed successfully. It reads only that original terminal request, binds
the validated VM ID to the manifest name and current Porsche owner, submits
only the preplanned deletion ID, and withholds the sample even after cleanup.
Running or unreadable requests and foreign owners still authorize no deletion.
Nineteen local custody/refusal tests pass, including the new terminal-success
and malformed-receipt cases; this is mock custody evidence, not a native
failure-recovery result. Architecture impact: accepted ADR-0130's request,
audit and cleanup authority are unchanged; the benchmark observer now fails
closed over one additional uncertain reply shape.
The benchmark runner now also reads both enrolled hosts' exact installed
NixOS/Ubuntu store paths and NAR identities, installed manifest artifact
digests/sizes matched to selected enabled catalog IDs, fresh image offers,
enabled catalog rows, physical load and per-pool producer flags/budgets
**before constructing a run manifest**. It refuses a same-path/different-NAR
offer, a stale or foreign image, and an enabled campaign without a baseline
summary, changed baseline NAR identities or disabled producers.
Twenty-four local custody/refusal tests pass, including same-path/different-NAR,
catalog-manifest mismatch and wrong-mode negative cases; these
are mocked SSH/SQL boundaries, not a passing two-host campaign. The separate
read-only live preflight on Oct 2 refused the currently divergent Ubuntu
output. A read-only call of the direct-runner guard independently
refused Dungarees' incomplete matching image offer before creating a campaign
directory. Neither refusal is live performance evidence. Architecture impact:
ADR-0130's exact image identity and producer
stage constraints are enforced earlier in the measurement tool; neither its
control-plane admission nor its host execution/cleanup authority changes.
ADR, contract, full-file Python ruff/format/ty, HLDD references/views/options,
and the Nix HLDD check pass on this runner change. Marshall's broader
`mix precommit` passed structural/code-contract and logging checks, then
stopped during AshPostgres setup because its ephemeral devenv PostgreSQL
socket was absent (`/tmp/opencode/fastpath-runner-marshall-precommit.log`).
Its test suite and forced Dialyzer were **not** established on this revision;
the prior reader-revision gate remains separate evidence.


1. An active ZFS block-cloning feature did not establish cross-dataset reflinks.
   Independent placement lifetime remains the decision; sparse-copy performance
   must be measured without claiming CoW acceleration.
2. The combined native run passed the complete template test but failed the
   older ZFS lifecycle fixture before its intended observation fault. Its fixed
   3 GiB root was below the current image's 3,244,294,144-byte minimum. The fixture
   now derives aligned disk/memory dimensions from the actual manifest and
   checks the portable kernel/initrd/metadata bundle as well as the root disk.
   The corrected lifecycle and transfer runs have since passed: the four-check
   native suite succeeded in 2103s
   (`/tmp/provisioning-fastpath-native-rerun1.log`).
3. Complete both distributions' readiness, delayed bootstrap, supersession,
   restart, clone/relocation and cleanup. The earlier NixOS fleet refused
   insufficient_capacity before provisioning. Its rerun adds a public-field-only
   admission snapshot; measured capacity must not be fabricated. The third run
   admitted a fresh VM and passed interactive guest SSH and agent-only access;
   a later OpenSSH agent-token case failed with closed connection, around
   database checkout timeouts under load. This is partial native evidence, not
   a passing full journey. The fixture now permits a bounded sixty-second retry
   of only explicit insufficient_capacity refusal, preserving request identity.
4. Final consumer, Python/types, logging, contracts, architecture, handbook and
   native gates remain. Structural validation alone is not physical acceptance.
5. Every maintained C helper is now Rust: `lilly/c_src` is removed and the
   host tools assemble from eleven separately gated Rust derivations. The
   last conversions carried typed FFI shims — resume-token to libzfs+libnvpair
   (a pure-Rust XDR/lz4/nvlist re-derivation was rejected for unavailable
   offline crates and unverifiable format drift) and flow-label to
   libnetfilter_conntrack (same reason for the netlink stack). Others landed
   with differential lattice and pair-completing runs: source-export (fd 3/4
   protocol, lease renewal, diagnostics caps), transfer-stream (full pipeline,
   progress frames with completion), export-channel (SCM_RIGHTS forwarding,
   peercred ownership, pair complete 0,0 identical).
6. Four preliminary live NixOS fixtures passed actual SSH `ls`. The fourth,
   `01937f7d-913b-4bd7-ab2c-da9da8ec04db`, previously cleanup_failed, is now
   desired/observed deleted, generation 2, by read-only database inspection.
   No privileged repair occurred. Creation/SSH seconds were Overalls
   21.436/27.369, 22.567/29.359, 32.876/39.054 and Dungarees 12.296/18.426.
   Concurrent builds and automatic placement prevent controlled comparison.
   Persist deletion request IDs before submission in the next benchmark runner.

Architecture impact: ADR-0130 extends ADR-0017/0074/0092/0098/0113/0124 with
sealed-template verification and durable readiness. Existing execution, storage,
capacity and cleanup authority remain. No feature activation, production
deployment, 30% speedup or completed benchmark is claimed.
