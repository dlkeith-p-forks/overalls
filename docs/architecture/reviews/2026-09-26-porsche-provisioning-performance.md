# Porsche provisioning performance on Overalls

## Result and scope

One default Porsche creation completed in **17.400945 seconds** on 2026-09-26.
The first probe using the advertised guest hostname successfully executed `ls`
in **0.466812 seconds**, with exit status 0 and an empty home-directory listing.
These are separate measurements: that probe finished **53.527672 seconds after
creation began**, including an investigator error and correction. Initial probes
guessed `NAME.apps.overalls.dev`; the proxy rejected that non-authoritative name.
Those failures establish nothing about guest readiness. An uninterrupted
creation-to-first-success latency was not measured.

Image verification, a full sparse root-disk copy and guest boot dominate this
case. The dispatch job completed within 64 ms of insertion. This investigation
performed no optimization, service restart, deployment, cache flush, privileged
mutation or cleanup.
Every sudo operation was read-only, including guest systemd inspection. SQL used
`BEGIN READ ONLY` and bounded statement timeouts.

The new worktree is `/home/ghuntley/src/kittens-porsche-provisioning-performance`,
branch `codex/porsche-provisioning-performance`, based on
`73a3a96c73d4d464d2f55258837446b32f2a9bee`; existing checkout changes were preserved.
The deployed updater reported healthy revision
`08ae4faa087abfd6707c69713f03c470577f1f73` and system
`/nix/store/hy5zhc0iyjrhkssv69nrrli1ckf29fkc-nixos-system-overalls-26.05.20260914.c3eea5b`
before and after the experiment. Porsche, Marshall SSH/Compute, Lilly host/VM
and guest-package sources have no diff between these two revisions.

Measured machine: `perf-20260926-025946`, VM
`9ad7c7cf-933b-4061-ab7b-bc2b3667899f`, placement
`52726719-252f-4eea-8836-2d016b35bad8`, on **Overalls**. Omitted-option defaults
resolved to NixOS, OSS, 1 vCPU, 512 MiB RAM, 4 GiB disk and image
`sha256:7f0fe92f40d501bdd32cff6fc4907a3c37bf1f534ecdee25b3b2a6459d88506d`.
Request `9340fccd-aee3-491c-bf56-70e27530f562` completed operation
`665a7c4a-8acd-45af-a77b-936a03ea189c`. Its advertised SSH hostname is
`v-perf-20260926-025946-9ad7c7cf933b4061ab7bbc2b3667899f.apps.overalls.dev`.

At final inspection, a **separate deletion request**, submitted at
03:10:11.883245 UTC after the measurements, had stopped the VM. This investigation
did not submit it. Marshall reported desired `deleted`, observed `unknown`,
`cleanup_failed`, generation 2, and an acknowledged delete operation; the ZFS
dataset remained and the VM unit was absent. The intended running retention was
therefore interrupted by activity outside this experiment. No retry, repair or
replacement VM was submitted. The measured creation and successful SSH precede
that deletion; the fixture is no longer available for live guest inspection.

## Timing evidence

Creation began at **03:01:29.158389 UTC**. Client durations use monotonic clocks;
host events use journal and database occurrence timestamps. Samples have roughly
250 ms resolution, not exact function-duration precision.

| Milestone | UTC | Elapsed | Evidence |
| --- | --- | ---: | --- |
| VM allocated | 03:01:29.296107 | 0.138 s | Lifecycle occurrence |
| Operation enqueued | 03:01:29.321498 | 0.163 s | Lifecycle occurrence |
| Dispatch job completed | 03:01:29.333434 | 0.175 s | Oban attempt 1; inserted 29.269167, attempted 29.330279 |
| Lilly marks execution starting | 03:01:30.198395 | 1.040 s | Host lifecycle occurrence |
| Image-read burst | approximately 03:01:30.2–34.7 | approximately 1.0–5.5 s | Process I/O plus source order |
| Dataset creation begins | 03:01:34.796231 | 5.638 s | Host lifecycle occurrence |
| Dataset bound | 03:01:35.024894 | 5.867 s | Host lifecycle occurrence |
| Root copy and publication | approximately 03:01:35.0–38.5 | approximately 5.9–9.3 s | Child descriptors and pending/published file sizes |
| Complete disk/bundle ready | 03:01:39.291184 | 10.133 s | Host lifecycle occurrence |
| VM launched | 03:01:39.632 | 10.474 s | Lilly event |
| Platform trust delivery begins | 03:01:40.053 | 10.895 s | Lilly event |
| Platform trust installed | 03:01:45.981 | 16.823 s | Lilly event; interval 5.928 s |
| Operation completed in Marshall | 03:01:46.213080 | 17.055 s | Lifecycle occurrence |
| Porsche returned succeeded | 03:01:46.559346 | 17.401 s | Client recorder |
| Guest reports SSH service started | 03:01:46.947935 | nominally 17.790 s | Guest journal; cross-clock comparison approximate |
| Correct-host SSH `ls` begins/ends | 03:02:22.219273 / 22.686076 | 53.061 / 53.528 s | Client recorder, exit 0 |

Deferred audit delivery inserted some lifecycle rows 5–12 seconds after their
`occurred_at` timestamps. These ingestion delays are **not** provisioning work.
Execution also began before Marshall received its acknowledgement. The table
uses physical occurrence times, not audit insertion order.

The observation window had 32 logical CPUs, approximately 53.3% aggregate idle,
28.7% user, 16.5% system and 0.55% I/O-wait time. Other workloads were active.
Memory PSI was effectively zero and I/O PSI low. ZFS reported a healthy mirrored
NVMe pool, LZ4 compression, 128 KiB recordsize and encryption off for this dataset.
This does not rule out transient/per-core contention, but does not establish
host-wide CPU, memory or storage saturation. The matched dispatch job's 61 ms
wait and 3 ms execution do not support a provisioning-queue bottleneck.

## Findings and ranked improvements

**High performance opportunity: verification and copying read the image twice.**
[Disk preparation](../../../lilly/lib/lilly/vm/disk.ex) calls
[Image.load](../../../lilly/lib/lilly/host/image.ex), which checks ancestry,
identity, lengths and SHA-256 with 64 KiB reads. It then invokes
`cp --reflink=never --sparse=always`, extends and flushes the disk before
publication. [Bundle materialization](../../../lilly/lib/lilly/vm/workload_bundle.ex)
also copies and flushes the kernel and initrd.

The manifest describes 3,244,294,144 rootfs bytes, 371,451,944 kernel bytes and
29,199,190 initrd bytes: **3,644,945,278 bytes** checked per fresh creation.
Lilly read counters rose about 3.65 GB during the approximately 4.4-second
verification burst, including about 2.62 GB of accounted physical reads.
Background Lilly work shares those counters; this is source-backed attribution,
not exclusive function profiling. The root-copy child was sampled at elapsed
6.041–8.795 seconds, sync at 9.042 seconds and the published file at 9.297 seconds.
Copying costs roughly three seconds; flush/publication is not separately resolved
below the sampling interval.

The entire `Disk.prepare` callback, including verification and copying, holds
the [pool-wide storage lock](../../../lilly/lib/lilly/host/storage.ex). Other
mutations have a bounded acquisition window and can return `storage_busy`;
observations use zero wait. This is a source-established serialization point,
not measured contention in this single-create run. A template/single-pass design
should also minimize lock duration while retaining ownership and publication
atomicity; concurrent-create tests are needed to quantify the throughput effect.

| Priority | Recommendation | Expected benefit and boundary |
| --- | --- | --- |
| 1, architectural | Stage an immutable, verified image template per digest and create private copy-on-write disks | Targets much of the roughly eight-second verification/materialization interval; this is a ceiling, not a measured saving. Preserve placement identity, reservations, boot bundles, durable publication, template retention and GC. |
| 2, bounded redesign | Benchmark digest verification while streaming into an unpublished temporary destination | Avoids two full rootfs read passes; hashing and writing still cost time. Verify digest and source identity before publication/launch; reject corruption and interrupted copies. |
| 3, concrete image change | Package a stripped uncompressed boot ELF while retaining separate symbols | Both builders link a 371 MB development `vmlinux`; `.debug_info` alone is about 228 MB. Reduces hashing, bundle copies and retained/transfer bytes; end-to-end savings unmeasured. |
| 4, guest boot | Profile/simplify initrd and move Nix database registration off the SSH critical path where safe | Targets portions of 2.782 s initrd and 4.094 s userspace; preserve trust, certificate, roster and Nix-client prerequisites. |
| 5, latency polish | Event-driven completion/control wakeups with durable polling fallback | This run's complete-to-client-return interval was only 346 ms; cannot eliminate image or boot work. |

ZFS `feature@block_cloning` is active, but that is not proof that the required
cross-dataset reflink/clone operation works or preserves accounting. Native
support, mutation independence, template ownership, deletion and GC require tests.
Caching verification requires a reviewed immutable-provenance design and updated
contracts/ADRs; the current cheap availability check cannot authorize launch.
Single-pass verification likewise must reconcile the current verify-before-use
contract, not silently bypass it. Keep all required flushes.

The [NixOS builder](../../../nix/domains/artifacts/guest/default.nix) and
[Ubuntu builder](../../../nix/domains/artifacts/guest/ubuntu/default.nix) link kernel.dev's
`vmlinux`. A stripped candidate must remain the supported uncompressed ELF, preserve
load segments, regenerate exact manifest digests and pass real Firecracker boot.
No candidate was built or substituted during this investigation.

**Medium: most of the trust interval waits for guest boot.** Guest systemd
measured 0.369 s kernel, 2.782 s initrd and 4.094 s userspace: **7.244680 seconds**.
The trust service starts at guest monotonic 6.070 s and completes at 6.231 s:
about 161 ms, not the entire 5.928-second host wait. Network and private DNS follow;
initial certificate/account reconciliation takes 6.442–7.223 s, and SSH starts at
7.244 s. These guest durations overlap the host timeline and must not be added
to it. Large device durations in `systemd-analyze blame` overlap each other too.

[Guest configuration](../../../nix/domains/artifacts/guest/configuration.nix) orders Nix
path registration before `sysinit.target`; this took 377 ms on the critical path.
`initrd-switch-root.service` accounted for 1.498 s. Test a smaller initrd and
build-time Nix DB registration, or narrower ordering that still blocks every Nix
client until registration completes. Preserve trust → network/private DNS → fresh
host certificate/current roster → SSH. Do not optimize away those guarantees.

**Medium observability distinction: Porsche success is not SSH readiness.** The
[ordinary OSS executor path](../../../lilly/lib/lilly/vm/executor.ex) returns
running after platform trust installation. Full `Driver.ready` is selected for
other workflows such as clone/resize, not ordinary creation. Guest timestamps
nominally place the listener 389 ms after the client receipt; guest/host clocks
were not calibrated to submillisecond precision. Source independently establishes
that Porsche does not await the listener. Expose/measure separate admission,
launch, trust and SSH-ready milestones. A new public readiness guarantee needs a
deliberate interface decision retaining exact boot/epoch binding.

**Low: polling overhead.** [Porsche.Runner](../../../porsche/lib/porsche/runner.ex)
sleeps one second per receipt poll. The measured 346 ms completion-to-return
interval includes polling, request and SSH-channel overhead. Admission to Lilly's
starting transition was about 877 ms, consistent with periodic control delivery;
the trace does not isolate one timer as its sole cause. Reducing authorization,
ownership, durability or acknowledgement checks is not justified by these results.

## Reproduction, architecture and validation

Private typed recorders and sanitized observations are retained at
`/home/ghuntley/porsche-performance-20260926-025946/`: creation intent/receipt,
monotonic timestamps, 250 ms process/file/PSI samples, bounded read-only SQL,
lifecycle occurrences, scoped Oban fields, filtered events and guest unit timings.
Terminal contents and credentials are excluded. The 180-second observer exited.
Instrument overhead was not measured against an unobserved control. Caches and
background load were not reset; this is not a controlled cold run or distribution.

For a repeat, start observers first, assign a unique name/request ID and run
`ssh overalls.dev 'new --name NAME --request-id ID --timeout 900 --json'` with
existing verified credentials. Immediately fetch `show NAME --json` and probe
its **`ssh_host` field** with bounded authenticated SSH `ls`. Do not derive the
hostname from the name. On timeout inspect the same receipt, never issue another
creation. Record guest/host/client clocks separately. A repeat is a separate
experiment. This run's evidence and incompletely reclaimed dataset were left
untouched after the independently submitted deletion.

Architecture impact: evidence and recommendations only; no public API, protocol,
implementation, accepted decision or status changed. Relevant decisions are
[ADR-0046](../decisions/0046-porsche-ssh-management.md),
[ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md),
[ADR-0074](../decisions/0074-durable-lifecycle-state-machines.md),
[ADR-0092](../decisions/0092-portable-workload-bundles.md),
[ADR-0113](../decisions/0113-guest-trust-at-boot.md) and
[ADR-0124](../decisions/0124-unified-ssh-host-ca.md). Image-verification, disk-reuse,
receipt and boot-trust contracts remain requirements. This report does not
approve a replacement architecture or claim native isolation was retested.

Preferred follow-up is native NixOS benchmarking plus properties for corrupted
sources, partial copies, template independence/GC, interrupted publication, stale
boot receipts and duplicate requests. Exercise both guest distributions and
delayed certificate/roster services. Optimizations, repeated/cold/load experiments
and remote-client journeys were not executed here.

The three private Python files passed Ruff formatting, E/F/I/ANN checks and
`ty check --python-version 3.13`; execution used available Python 3.14.7.

Validation in `devenv shell` (Elixir 1.20.4 / OTP 29):

- `elixir scripts/check_adrs.exs`: passed, 124 decisions, structure/local links only.
- `elixir scripts/check_hldd.exs`: passed after reviewing the changed evidence and
  refreshing each affected receipt with its specific rationale.
- `hldd_coverage.exs --check`, `hldd_options.exs --check` and
  `hldd_views.exs --check`: passed; generated scenarios and Ash/deployment views current.
- `nix build .#checks.x86_64-linux.hldd --no-link`: passed, including evaluated placement.
- `git diff --check`: passed.

The final diff is documentation, scenario evidence and review receipts only.
Application regression/property/native suites were not rerun; no implementation
or governance-tool code changed. Structural gates do not validate timing claims.
