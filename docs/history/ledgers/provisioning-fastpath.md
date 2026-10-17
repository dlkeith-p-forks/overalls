# Provisioning performance implementation ledger

> **Historical record:** This ledger preserves revision-specific implementation or verification evidence. It is not a current operational runbook, and its claims retain the original scope and execution gaps.

Worktree: `overalls-provisioning-fastpath`; branch: `codex/provisioning-fastpath`.
The compatible-reader release carries the fastpath decision
[ADR-0130](../../architecture/decisions/0130-verified-provisioning-fastpath.md),
because upstream assigned ADR-0129 to fleet telemetry. Original and
investigation checkouts are preserved. Direct sudo operations are read-only.
Git-driven deployment is authorized.

## Implemented

- Shared stripped kernel and load-image verifier for NixOS and Ubuntu.
- Rust copy helper, safe rustix APIs, seven Hegel properties, catalogued logging.
- Rust host-lock broker replacing the C helper: byte-identical wire protocol
  against the C implementation in differential sessions, three Hegel property
  classes and process-level protocol cases in the Nix sandbox, utility-parent
  death fencing via one reviewed unsafe `pre_exec` call site, C source removed.
- Rust KVM probe replacing the C helper: identical exit semantics and argv/env
  insensitivity, two Hegel properties plus a constants guard in the sandbox,
  real-device differential parity on this host, C source removed.
- Rust launch guard replacing the C helper: differentially identical across the
  success/71/74/75/64 lattice (`/tmp/provisioning-fastpath-launch-guard-differential.py`),
  shared intent lock proven carried across exec into the launched image by a
  contended-flock observation, Hegel oracles over the selector and intent frame,
  `deny(unsafe_code)` with no shims, C source removed.
- Rust boot-log drainer replacing the C helper: byte-identical retained logs and
  exit lattice across echo/failing/mixed-stream/flood/usage cases
  (`/tmp/provisioning-fastpath-boot-log-differential.py`), one reviewed unsafe
  signal re-raise shim, Hegel drain-prefix/selector oracles plus process custody
  cases (signal death propagation, exact 1 MiB bound under flood), C source
  removed.
- Rust namespace sweep replacing the C helper: the C classification self-test
  matrix reproduced verbatim plus Hegel properties over validators, octal
  decoding, mountinfo classification and sweep planning; the namespace scan
  pins open descriptors so referent exits cannot slip a pending unmount, and
  an in-process setns-and-restore preserves the host namespace (the C fork dance
  is retired, with the same silent-1 versus printed-outcome lattice preserved
  on the observable boundary). C source and its C self-test removed.
- Rust source-exporter: port-ABI fd 3/4 control and ack channels, bounded
  lease renewal, diagnostics caps and reaping proven over process fixtures;
  differential usage lattice identical. C source removed.
- Rust transfer stream: kernel-pipe custody, credit throttle, leaderboard
  progress frames with completion, role-failure distinction, revocation and
  deadline fences verified through real producer/consumer pipelines;
  differential sessions against the C helper match on exact bytes, artifacts,
  progress counters and the role/usage/contention lattice
  (`/tmp/provisioning-fastpath-transfer-stream-differential.py`). C source
  removed.
- Rust export channel: bridge+serve with exact 8456-byte records, SCM_RIGHTS
  stdout forwarding, peer-credential checks against the listener owner, and
  completion-byte freshness after reaping; the pair completes 0,0 identically
  to the C helper and the selector/refusal lattice matches
  (`/tmp/provisioning-fastpath-export-channel-differential.py`). C source
  removed.
- The split derivations displaced `lilly-boot-log` from `lilly-launch-guard`'s
  bin directory, breaking a colocated-writer convention inside
  `Lilly.VM.Config`; the launcher and writer are now each resolved through
  their own trusted executable check rather than by physical adjacency, with
  identical ownership/ancestry standards. The release bundle adds a second
  Nix symlink layer: resolution now follows at most eight root-owned executable
  links and eight root-owned ancestor-directory links, and checks the final
  regular executable. The control configuration tests pass with both the
  current split `hostTools` package and a release-owned host-tools directory
  link prepended to `PATH`. Pass-2 native adoption still returned
  `invalid_driver_configuration`; pass-2 fleet repeatedly exited Lilly with
  `invalid LILLY_CONFIG_FILE` before enrollment. Both ran before this multi-link
  correction; the later ZFS-transfer VM passed and the later Porsche fleet
  reached clone relocation after both Lilly hosts enrolled, but did not pass.
- Reader gate capture `b52e9ee8` integrates upstream through `996f588e` with compatible
  readers and both producers disabled. Protocol precommit passes 221 checks
  (82 properties), Lilly 456 (69 properties), and Marshall 1,361 (177
  properties), all with zero forced Dialyzer errors. Pinned Python
  ruff/format/ty, contracts, ADR and HLDD gates pass. Both production host
  closures and the Porsche, NixOS/Ubuntu SSH, bootstrap, roster, clone and
  template test drivers build. These are project/driver checks, not native
  guest or deployment acceptance.
- One waitid-with-WNOWAIT in export-channel's reaping finish loop was an
  infinite-spin trap for adopted descendants; it now blocks waitid directly,
  proved by the channel (python worker → sleep child) reaping suite passing
  against the Nix-built binary.
- Guarded Ash provisioning journal, launch-time deadline, exact-boot readiness.
- Guarded Ash template journal, verified ZFS seals, GUID/nonce/file identities,
  shared readers, exclusive builders/retirement, conservative budgets and LRU.
- Independent root disks and portable boot artifacts copied outside the pool lock.
- Compatible pool-audit protocol/Marshall readers and additive database migration.
- Reader release `153db737` is healthy on Overalls and Dungarees with
  `compute_lifecycle_events.pool_id` installed; both new producers remain off
  pending separate native acceptance and activation.

## Evidence and remaining work

The stripped kernel is 66,089,744 bytes versus the original 371,451,944, with
verified load-image equivalence. On `b52e9ee8` both NixOS and Ubuntu guest
artifacts resolve to the same stripped store kernel, and their manifest sizes
and SHA-256 digests match its bytes. Seven Hegel properties, rustfmt and Clippy pass.
An unsafe-fallback mutant was detected. Protocol precommit passed 215 checks
(78 properties, 137 tests), with zero Dialyzer errors. Marshall's focused pool-audit
suite passed 11 tests. The final Rust template NixOS driver passed in 416.20s,
including crash recovery, GUID refusal, catalog bounds and no VM capacity credit.
Rust helper equivalence was verified differentially against the deleted C
implementation (`/tmp/provisioning-fastpath-host-lock-differential.py`: echo,
missing executable, nonzero exit, timeout, 64 KiB overflow, 4 MiB extended
limit and shared-mode replies/exit codes all byte-identical), and Lilly's
locked-command suite passed 10/10 against the Rust binary. Lilly's full suite
passed 420 checks (54 properties, 366 tests); forced Dialyzer passed
independently. Exact scope and logs are in the
[implementation review](../../architecture/reviews/2026-09-26-provisioning-fastpath.md).

Still required:

1. Complete native guest acceptance. Captured `b52e9ee8` passes all three
   project precommits; Python ruff/format/ty hooks pass. Earlier native copy/template/caller-death
   and ZFS lifecycle/transfer drivers passed in 2103s
   (`/tmp/provisioning-fastpath-native-rerun1.log`), but that predates the
   separately packaged Rust helpers and current main. The integrated
   zfs-transfer and Porsche fleet drivers build and type-check after merged
   fixture corrections. The integrated native ZFS-transfer VM passed in 450.34s,
   including two Hegel adoption/crash-recovery cases. Image-copy, image-template
   and ZFS-lifecycle also passed together (`native-rest=0`, VM scripts 21.74s,
   233.17s and 2527.86s). The revised reader-revision native image-template
   VM test passed in 205.65s with warm record/incarnation UUIDs and a source
   lease, while the verified uncached callback had none; VM-test cleanup took
   0.39s. Complete guest journeys have not all passed. Mutation markers still
   fire only after real storage effects.
2. Complete actual NixOS/Ubuntu SSH, restart, clone/relocation acceptance. An
   earlier NixOS Porsche fleet refused clone relocation during Marshall
   unavailability. The strict `153db737` rerun passed the **complete NixOS Porsche
   lifecycle subtest** (816.61s), including guest start/restart, cross-host
   relocation, independent clone and cleanup, but the full fleet failed later
   in the separate terminal/browser stage amid database checkout timeouts.
   The full Ubuntu authenticated SSH journey passed on `153db737`, including
   client login, revocation, renewal, relocation, reboot and clone, with
   VM-test cleanup. Its disposable hosts enable readiness and templates, but
   that run did not assert an actual template hit or exact readiness journal;
   production still has both flags off. Focused NixOS/Ubuntu Porsche lifecycle
   variants retain the unchanged native scenario and are present, not yet
   passed. Do not weaken measured capacity or retry uncertain effects under
   a replacement request ID. A further native user-SSH assertion is present
   but unexecuted: it compares the validated host readiness journal with the
   actual guest boot before and after restart, refusing stale boot or foreign
   host evidence.
3. Revalidate handbook/scenario receipts, generated references, contracts and
   Nix gates after any further implementation/evidence changes; current checks pass.
4. The first release deployed compatible readers healthy on both hosts with
   `pool_id` installed and producers disabled. Only a subsequent authorized
   Git-driven release may enable producers after native acceptance.
5. Persist benchmark creation/deletion request IDs before operations. Run ten
    sequential per distribution and four concurrent; record host/load/cache mode,
    phase timing, prewarm cost, actual SSH `ls` and confirmed run-owned cleanup.
    The first controlled readers-off attempt passed two prewarms and ten
   sequential samples per distribution, but failed two of four concurrent
   creations (`execution_failed`). NixOS/Ubuntu sequential medians were
   19.458s/12.825s; they are exploratory, not an accepted matched baseline.
   The two failed guests were deleted with their manifest-planned request IDs,
   with read-only reservation and ZFS absence confirmed. A complete concurrent
   campaign and matched enabled comparison are still required. The runner now
   binds terminal failed-create cleanup to the persisted request, exact owned
   VM and preplanned deletion ID; it also cleans a terminally succeeded original
   request when the client reply has no valid VM ID. Missing or active requests
   remain unconfirmed and no malformed reply is counted as a sample.
   A separate unshipped Lilly diagnostic binds bounded ZFS preparation
   observation failures to a validated placement and fixed stage/reason atoms;
   it does not alter capacity refusal or establish the prior failure's cause.
   An Oct 2 producers-off retry preflight also found different Ubuntu rootfs
   digests under the same derivation path on the two enrolled hosts. The
   sandboxed guest Nix DB retained build-time registration timestamps and
   transient SQLite sidecar bytes. A typed normalization step now produces
   identical databases from the two observed logical registries without
   changing their 90 registered paths or 455 references; three unit tests
   pass. A complete rootfs rebuild and cross-host identity comparison remain
   required before registering the new Ubuntu image ID or rerunning the
   controlled baseline. No production database or guest image was modified.
   The Ubuntu authenticated-SSH journey gains an unexecuted guest-local Nix
   registry query for the pinned development-tools closure. The unit and Nix
   evaluation gates cannot substitute for that native runtime result.
   The benchmark runner now also refuses before manifest creation
   unless both enrolled hosts agree on installed image store paths and NAR
   identities, match installed artifact digests/sizes to selected catalog IDs,
   advertise the selected enabled IDs with fresh reports, report quiet physical
   load, and expose the expected producer flags and 32 GiB per-pool enabled
   budget (zero when producers are off). Enabled invocations require a matching
   baseline summary with identical installed NAR identities. Twenty-four local
   custody/refusal tests pass; no new production campaign has passed.
   The runner now records a strict-SSH guest boot UUID and load from the selected
   physical host; its prewarm-tagged sample records VM-to-SSH time separately.
   A catalogued source event must bind a real template record/incarnation to the
   image/pool placement and exactly one staging→ready audit pair before a warm
   sample is counted. It reports that construction duration per observed
   image/pool/record and refuses a newly built template in a warm sequence.
   Live native cache identity and construction cost have not yet been observed.
6. Convert every maintained C helper to Rust with Hegel properties and the
   same structured-event/equivalence evidence. COMPLETED: the ten remaining
   helpers — `host_lock.c`, `kvm_probe.c`, `launch_guard.c`, `boot_log.c`,
   `zfs_namespace_unmount.c`, `source_export.c`, `transfer_stream.c`,
   `export_channel.c`, `resume_token.c`, `flow_label.c` — after the earlier
   image-copy port (whose C prototype was already removed). `lilly/c_src` is
   removed; the assembly now relies only on eleven separately gated Rust
   derivations (lilly-boot-log, lilly-export-channel, lilly-flow-label,
   lilly-host-lock, lilly-image-copy, lilly-kvm-probe, lilly-launch-guard,
   lilly-resume-token, lilly-source-export, lilly-transfer-stream,
   lilly-zfs-namespace-unmount). `nix/domains/artifacts/hosts/host-tools.nix` is now a pure
   symlink assembly that fails loudly if any set drifts.

   | Helper | Lines | Role | Conversion notes |
   |---|---|---|---|
   | `resume_token.c` | 115 | Resume-token validation, never sends disk data | Links libzfs (nvlist); port needs typed lzc/nvlist FFI or a pure-Rust re-derivation review. Decide explicitly. → Decision: typed FFI (offline cache has no XDR/lz4/nvlist stack). |
   | `flow_label.c` | 112 | Read-only conntrack flow lookup | Links libnetfilter_conntrack; port needs a netlink/conntrack crate or reviewed FFI. Decide explicitly. → Decision: typed FFI (offline cache has no netlink/conntrack crate). |


   Shared constraints for all ports: no setuid/capabilities, fixed absolute argv,
   framed private protocols or empty stdout, `deny(unsafe_code)` with any
   reviewed shim confined and documented, Hegel properties in the crate gates,
   and differential byte-level equivalence runs before removing each C source.

Four preliminary NixOS samples passed SSH but are uncontrolled due to concurrent
builds and automatic placement. The fourth fixture's prior cleanup failure is now
confirmed deleted by read-only database inspection. No deployment or candidate
 speedup is claimed at this checkpoint; the full plan remains active.

## Compatible-reader rollout boundary (historical)

> **Historical record, not current instructions.** The switches named below no
> longer exist: [ADR-0159](../../architecture/decisions/0159-remove-legacy-compatibility.md)
> removed them and made readiness and templates unconditional (see
> [Switch removal](#switch-removal-2026-10-11)). Nothing in this section applies
> to a current deployment.

The first Git-driven release kept `services.lilly.provisioningReadiness` and
`services.lilly.imageTemplates.enable` false on both enrolled hosts. Before
activating either producer, inspect each host's root-owned
`/var/lib/overalls-auto-update/status.json` read-only: `phase` must be `healthy`,
`lastHealthy.revision` must equal the reader release commit, and
`lastHealthySystem` must equal the active `/run/current-system` target. Verify
the additive `pool_id` database column is installed and the running Marshall,
Lilly and Porsche roles are healthy on every host that consumes the release;
exercise existing v3 lifecycle audit acceptance and pool-bound template audit
refusal against the compatible readers. A built closure, fetched commit or
single healthy host is not a complete rollout. Only after those checks and
fresh native guest acceptance may a second release enable producers. Preserve
the exact revisions and the per-host observations in the deployment record;
do not infer feature activation from an ADR or test fixture.

## Controlled Porsche-to-SSH benchmark protocol

The typed [runner](../../../scripts/provisioning_benchmark.py) executes this protocol
with a new private directory per release; its [custody tests](../../../scripts/test/test_provisioning_benchmark.py)
exercise lost replies, invalid boot identity, physical-host load parsing,
native source correlation, cold-template refusal and exact durable guest
account proof without live effects (fifteen passing cases on the integration
candidate). The parser admits the same internal-dot account grammar as Marshall
and checks the selected username against a fresh authenticated Porsche
`whoami` before creating the run manifest or submitting any mutation.
No production campaign
or speedup has been established by installing the runner. Its Porsche read-only
`whoami`, lifecycle SQL and old-deleted-VM cleanup oracle have been probed over
strict authenticated management SSH; that is transport verification only.
Guest SSH selects an explicit installed Audi `ProxyCommand` profile while
retaining strict host-CA verification; control and admin observations still use
`-F /dev/null`. On an uncertain deletion reply, only the persisted request ID
is polled for up to 1,200 seconds before declaring cleanup unconfirmed.

The first run-owned NixOS canary created successfully but its direct guest SSH
failed because the former runner suppressed the Audi profile; its exact deletion
request later succeeded, and read-only checks found the VM deleted, reservations
released and its dataset absent. Corrected one-off NixOS and Ubuntu canaries
then passed authenticated SSH `ls`, boot-ID observation and independent cleanup
verification. Their uncontrolled creation-to-SSH times (21.57s and 12.72s)
cannot serve as ten-sample baseline medians or a speedup claim. The corresponding
private custody records are linked from the implementation review.

Use separate baseline (compatible readers, producers disabled) and enabled
releases with the same NixOS and Ubuntu images, VM shape, client key and
verified host-CA trust. Record release revision, distribution/image ID, selected
host and pool, load/available capacity, template cache mode and guest boot ID
for each attempt. Measure and report template prewarm separately for each
image/pool; exclude it from the warm sample median, but retain its wall time
and artifacts in the evidence.

Before **each** mutation, durably write a run-owned name and unique creation or
deletion request ID to a private journal. Create ten sequential machines per
distribution and four additional concurrent machines (two per distribution)
for each release. Never issue a replacement creation ID after a timeout: read
the same request receipt and reconcile its effect. Time the start, accepted
receipt, materialization, launch, trust and SSH-readiness transitions and first
authenticated guest SSH `ls` using both monotonic client times and the bounded
durable lifecycle event timestamps. Use the receipt/show result's `ssh_host` and
strict verified host trust; do not derive a hostname from the requested name or
write terminal bytes, key material, arguments or tokens into the evidence.

Submit deletion with its already persisted ID, wait for the same operation's
confirmed outcome, then verify read-only that the VM is observed deleted and
its compute/disk reservations are released. Stop the campaign on uncertain
cleanup and retain the run-owned identities for reconciliation. Compare the ten
creation-to-SSH medians per distribution between releases at comparable load;
report the four-way run separately. Neither a successful create receipt nor a
driver build substitutes for authenticated SSH, confirmed cleanup, or a measured
≥30% warm median improvement and sub-10-second warm creation-to-SSH result.

## Readiness-only activation (2026-10-02)

The [durable SLO review](../../architecture/reviews/2026-10-02-durable-physical-slos.md)
records healthy compatible readers on both hosts, installed pool-audit schema,
native NixOS and scoped Ubuntu fresh readiness, and passive boot-bound checks
for 20 Overalls and five Dungarees retained legacy boots. Both enrolled host
configurations now enable `services.lilly.provisioningReadiness`; template
producers remain disabled. Both hosts activated `c98a375c` healthy; the passive
post-switch probe verified ready journals for all 22 current retained boots
(17 Overalls, five Dungarees). Three deletions preceded this activation. The
terminal-measurement digest is unchanged. No production progress journal,
deadline or immutable SLO failure is reset, and no template speedup or complete
performance matrix is claimed.

## Resumed integration (2026-10-05)

The plan originated in Codex session `01a0dba2-1b67-7d70-bee1-0d0c35f198b0` and
continued in OpenCode session `ses_f2397728dffe1x12Od080D629Q`, which stopped at
its auto-continue limit on 2026-10-02 with the work below unpushed. This ledger,
not agent session storage, is now the plan of record.

Branch `fastpath/resume` starts from `origin/main` `a5b6c891`, which already
contains checkpoint `3b38f5e0`, the eleven Rust host helpers, ADR-0130, the
compatible readers and the readiness-only activation above. It merges the
unpushed `codex/provisioning-fastpath` tip `dc7f1e59`: offline Ubuntu guest Nix
registration normalization and its typed tests, the guest-registry and
exact-boot native assertions (including the post-restart current-boot proof),
scoped `porsche-lifecycle` fleet variants, benchmark image-identity guards and
original-request reconciliation, ZFS preparation diagnostics, and the failed
concurrent-baseline record. The separate producer candidate
(`codex/provisioning-fastpath-producers-v2`) is deliberately not merged.

Remaining, in order:

1. Build the normalized Ubuntu image and independently `--rebuild` its rootfs;
   both registered NAR hashes, the manifest and the guest database must match
   before any producers-off image rollout. Matching normalized SQLite bytes
   alone does not prove rootfs reproducibility.
2. Execute the committed but never-run exact-boot, guest-registry and
   NixOS/Ubuntu SSH journey assertions in a memory-safe window. Overalls has
   previously OOM-killed this driver build.
3. Release through `main` with template producers off, verify each host's
   healthy revision and fresh image offers read-only, then run the complete
   ten-sequential-plus-four-concurrent baseline with confirmed run-owned cleanup.
4. Only then enable template producers (32 GiB per-pool budget) in a separate
   authorized release and run the matched enabled campaign.

Neither speed target has been demonstrated. The first campaign's 19.458 s
NixOS and 12.825 s Ubuntu medians remain exploratory, not a baseline.

On 2026-10-06 the normalized Ubuntu image built at `7fec9895` during a quiet
window, and `nix build --rebuild` of its rootfs derivation
(`657p6asj…-lilly-ubuntu-26.04-x86_64-rootfs.drv`) reproduced the existing output
`zv4nzw73…-lilly-ubuntu-26.04-x86_64-rootfs` bit for bit. This establishes local
rootfs determinism only. Cross-host NAR and manifest equality, and matching fresh
image offers, must still be observed on both enrolled hosts after they build the
deployed revision, before the template-producer release.

## Controlled templates-off baseline (2026-10-07)

Run `fastpath-baseline-20261007-154834` at `fcba03e3`, started after both hosts
were healthy on the current revision and under load 12. Preflights all passed:
producers were off, readiness was on, both hosts advertised the exact images
(NixOS `dc87cba1…`, Ubuntu `5a9479b2…`), and installed NARs were recorded.
Results:
- 26 creates, all reaching authenticated SSH;
- all 26 deletes confirmed;
- every materialization `method: offload`;
- create to authenticated SSH:

| Distribution | Sequential (n=10) | Concurrent (n=2) | Prewarm probe |
|---|---|---|---|
| NixOS | median **28.5 s** (11.7–37.0) | 33.0, 42.1 s | 25.9 s |
| Ubuntu | median **14.8 s** (13.7–23.8) | 13.9, 18.9 s | 12.8 s |

Two earlier attempts were interrupted, and each reconciled its run-owned VMs
under their original request IDs:
- a delete stalled by a Nix build sandbox (fixed by ADR-0144);
- a Porsche restart from another session's deploy.

Enabled-campaign targets: a warm median at least 30% lower (NixOS ≤ 20.0 s,
Ubuntu ≤ 10.4 s) and under 10 s.

## Template-producer release (2026-10-07)

After `7106dd24` deployed, both enrolled hosts advertised the identical Ubuntu
image `sha256:5a9479b2…` (and NixOS `sha256:dc87cba1…`), satisfying the
cross-host image-equality precondition. Live creates still spent about 29 s
materializing with `source: verified` and `method: offload`: per-create SHA-256
verification, not copying, dominates creation. This release enables
`services.lilly.imageTemplates` with a 32 GiB per-pool budget on Overalls and
Dungarees, so warm creates should report `source: template`. It follows the
controlled templates-off baseline; the matched enabled campaign and the
warm-create medians against the ≥30% and under-10-second targets are recorded
after activation.

## Matched templates-on campaign (2026-10-09)

Run `fastpath-enabled-20261009-095428` at `adc188da` (includes template
release `70cac56c`), started with both hosts healthy and under load 12.
Conditions matched the baseline: same images and NARs, producers enabled with
the 32 GiB budget, readiness on, every VM on Overalls. Results:
- 26 creates, all reaching authenticated SSH;
- all 26 deletes confirmed;
- templates constructed once per image and pool (NixOS 25.7 s, Ubuntu 17.4 s);
- create to authenticated SSH:

| | Baseline | Templates on | Target | Result |
|---|---|---|---|---|
| NixOS sequential median | 28.5 s | **17.9 s (−37%)** | ≥30% faster | **met** |
| Ubuntu sequential median | 14.8 s | 13.7 s (−7%) | ≥30% faster | **missed** |
| Warm under 10 s | – | NixOS min 16.8 s, Ubuntu min 10.6 s | <10 s | **missed** |
| Concurrent (n=2 each) | NixOS 37.5 s, Ubuntu 16.4 s | NixOS 39.4 s, Ubuntu 31.4 s | – | worse; load 15.7 vs 11.5, too few samples |

A traced templated Ubuntu create (12.8 s to ready) spent:
- ~1.1 s on dataset create;
- **5.6 s** on template materialization (`source: template, method: offload`);
- 0.6 s on launch;
- **4.6 s** on guest boot and trust;
- 0.5 s on SSH readiness.

Templates removed per-create verification (NixOS materialize 20.5 s → ~9 s).
The next create levers are the remaining materialization work under the pool
lock and guest boot time. The concurrent regression needs a larger controlled
sample before any conclusion.

## Materialization step timing (2026-10-09)

With `vm.disk_materialization_step` deployed (`0a3a9921`), templated creates on
Overalls (load about 20–30) measured:
- template `image_copy` (offload) took 7.6 s for Ubuntu and 20.9 s for NixOS;
- `truncate`, `sync`, `mv` and `chown` took 1–4 ms each.

Pool `bcloneused` 4.4 GB / `bclonesaved` 37.6 GB confirms real block cloning,
whose per-block reference-count cost scales with disk size and pool load.

Two concurrent Ubuntu creates cloned in 3.0 s and 6.1 s, the second queued
behind the first: clones from one template serialize, explaining the earlier
concurrent regression.

Launch to readiness (boot and trust) adds about 5–8 s.

Getting under 10 s therefore requires removing the clone from the create path:
[ADR-0146](../../architecture/decisions/0146-standby-guest-disks.md) (proposed).

## Switch removal (2026-10-11)

[ADR-0159](../../architecture/decisions/0159-remove-legacy-compatibility.md) removed
`services.lilly.provisioningReadiness`, `services.lilly.imageTemplates.enable`
and `services.lilly.blockCloneCopies` together with their off paths, and the
zero value of `services.lilly.standbyDisks.perImage`. Durable boot-bound
readiness, sealed templates, same-pool block copies and at least one standby per
pool and image are unconditional; rollback is a revert. The sections above are
historical records of the staged rollout. A templates-off baseline can now only
be measured on a historical deployment; the
[benchmark runner](../../../scripts/provisioning_benchmark.py) no longer reads the
removed readiness key.

