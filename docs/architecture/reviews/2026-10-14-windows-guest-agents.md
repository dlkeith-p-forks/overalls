# Windows guest agents review

## Scope and impact

[ADR-0171](../decisions/0171-windows-guest-agents.md) takes the agentless
Windows guest of [ADR-0170](../decisions/0170-lilly-firmware-guest-launch.md)
towards a working developer machine: a third agent set `windows-v1` with a
pure capability table in the shared protocol, the vsock endpoint in firmware
jails exactly when the agent set uses it, driver branches on capabilities
rather than on the agent set name, a 600 s readiness budget, per-capability
facts in Marshall, Rust agents cross-built for Windows from the Lyra crate,
the virtio-win `viosock` driver and a transport probe in the image, per-image
standby eligibility with a size-only cacheability filter, a 48 GiB template
budget on both hosts, and a converged rollout that builds the image once and
stages it only after every host runs the new code.

Boundaries preserved: ADR-0011/0068 (Linux images and the version-4 shape are
untouched; the Linux capability row is everything and pinned), ADR-0113/0154
(trust and readiness stay guest proofs; `windows-v1` must earn both through
the same protocols), ADR-0130 (templates unchanged; cacheability is decided
from staged sizes), ADR-0146 (standby refill plans only eligible, cacheable
images), ADR-0159 (one configuration shape for images, no retained reader;
old Lillys fail closed on a `windows-v1` bundle, so the converged push
precedes any placement), ADR-0169/0170 (the agentless `none` row of the table
reproduces the previous refusals exactly). No database migration: the image
row's manifest already carried `guest_agents`.

## Findings

1. **Measurable creation-to-ready must not disappear for unknown images.** The
   first projection of `guest_ready_measurable?/1` onto the capability table
   returned `readiness: false` for an absent or unknown snapshot image, which
   silently dropped the `marshall_ready` attempt for SSH-created machines
   (`Marshall.SSH.CommandsTest` lost six cases). Fixed: only a known image
   whose agent set lacks `readiness` waives the measurement; the contract
   `creation-to-ready-waived-by-capability` records it.
2. **Shared Lyra modules were Unix-only.** `ssh_files` and `workspace_receiver`
   used `O_NOFOLLOW`, POSIX modes and process groups unconditionally, so no
   Windows bin could link the library. Fixed with `cfg` splits that keep the
   Linux behaviour byte for byte (Linux `cargo test` and clippy unchanged) and
   give Windows the reparse-point refusal, ACL inheritance and a direct child
   kill until Job Objects land in gate 5; the Lyra Nix check now type-checks
   the library and every Windows bin for `x86_64-pc-windows-gnu`.
3. **The Lyra Nix check lacked `git`.** `tests/workspace_object_format.rs`
   (added on main) drives a real repository and panicked with "git in the
   pinned shell" inside the sandbox, so the `lyra` flake check could not pass
   on main either. Fixed by adding `git` to the check's build inputs.
4. **viosock speaks indirect descriptors to a VMM that did not offer them.**
   The first probe image booted, the driver bound (control device answered
   address family 40, the probe listened on port 1024), but every host
   `CONNECT 1024` hung: Firecracker logged `vsock: RX queue error:
   UnwritableDescriptor` for each receive buffer. The virtio-win ring library
   (`virtqueue_add_buf_split`) uses the caller's indirect table whenever one is
   supplied and the buffer has more than one element, without consulting the
   negotiated features, and viosock supplies one for every RX and TX packet.
   Fixed with a ninth Firecracker patch that resolves indirect heads in the
   vsock packet parsers (with unit tests for RX, TX and the refusals) without
   offering the feature, so Linux guests are unchanged. Found with the operator
   launcher on bare KVM (debug log and metrics), not by the nested machine
   test, which only timed out.
5. **Win32-OpenSSH has no `AuthorizedKeysCommand`.** The project's sshd_config
   wiki lists `AuthorizedKeysCommand` and `AuthorizedKeysCommandUser` under "Not
   supported" and Microsoft's key-management guide states the same, so the
   gate 3 design in the plan (live authorization per connection, as on Linux)
   is not possible on Windows Server 2025's in-box OpenSSH. Replaced by a
   pull-based `AuthorizedKeysFile` per account fed by a new private route
   (`GET /ssh/v1/authorized-keys`, the roster's writers with their registered
   keys), recorded in ADR-0171 decision 8 with the security trade-off (inner
   acceptance is no longer bound to the live Audi session; identity binding
   and the write grant remain; port 22 is reachable only through Audi).
6. **The uncached Windows template copy can exceed Lilly's 300 s utility
   timeout under load.** The first `windows-lilly-guest-agents` run (2026-10-14
   22:1xZ to 22:45Z) failed in `Driver.start` with `disk_prepare_failed`:
   `lilly.utility_unconfirmed` reported `image_copy` at `command_timeout` after
   300 007 ms while the host also ran Dialyzer and several Nix builds; the same
   copy completed inside the budget on the idle host during the Phase 2 run.
   Not a code regression; the run is repeated on a quiet host. The 32 GiB
   logical copy is the cost ADR-0171 already names (hole-aware hashing and
   allocated-bytes accounting as follow-ups); a firmware-image-aware copy
   budget is a candidate fix if the quiet rerun is close to the limit.
7. **Pre-existing, unrelated:** the `inception` machine test does not evaluate
   on main or on this branch (`attribute 'vscodeWeb' missing` from
   `nix/modules/marshall.nix` through the storage fixture's package set). Not
   touched here; recorded so it is not mistaken for Phase 3 fallout.
8. **The Rust MMDS client parsed the wrong document shape.** Two
   `windows-lilly-guest-agents` runs ended with repeated `vm.trust_failed`.
   A local boot of the same image showed why: `kittens-readinessd` and
   `kittens-trustd-windows` started, then gave up after their 600 s identity
   budget with `identity_unavailable`, while the PowerShell bootstrap read the
   same MMDS fine. Firecracker answers `GET /lilly` with the `lilly` subtree
   itself, but `guest/mmds` expected the `{"lilly": {...}}` object Lilly seeds,
   and its test fixture repeated the mistake. The client now parses the
   subtree and refuses the envelope (a regression case in the unit test). A
   second fix in the same client stops reading at Content-Length, because MMDS
   keeps connections open after answering.
9. **The machine test committed provisioning through the wrong entry point.**
   With trust fixed, the third run installed trust (`vm.trust_installed`), and
   `Driver.ready` returned `ok` because readinessd answered. The fixture then
   expected provisioning in `ready`, but it was still `awaiting_trust`.
   `Driver.ready` only waits for the guest's line. The executor's completion
   path is `Driver.provisioned`, which commits the receipt, and the fixture
   now calls it. Lilly itself was correct.
10. **Agent tasks stopped after 72 hours.** `schtasks /Create` gives every
    task the default three-day execution limit, so every agent would have
    been stopped three days after boot. `SetupComplete.cmd` now applies one
    settings pass to all agent tasks: no execution limit, no second instance,
    and restart on failure requested. Whether Task Scheduler restarts a
    daemon that exits with an error is unproven, so ADR-0171 decision 8 now
    records crash supervision as a gap. The plan's SCM shim was never built,
    and the decision text now says so.
11. **terminald mirrors two small Lyra modules.** The Windows terminal daemon
    carries its own viosock listener and MMDS identity client, because
    terminald is a separate crate that depends on almost nothing. Both copies
    parse the MMDS subtree and share the same tests. Extracting a shared
    guest-platform crate is a follow-up.
12. **The Windows private HTTPS client would have failed against the deployed
    leaf.** The `ssh-private-tls-verification` note in `private_http` says
    rustls rejects the deployed private leaf's broad SAN, and native TLS is
    selected only on Linux. Windows agents therefore used rustls, so the roster
    agent and the host-certificate agent would likely fail in the fleet even
    though they link and pass unit tests. Windows now uses native TLS
    (schannel). That crate was already locked for every target, so the lock
    file and vendor hash are unchanged. A Windows guest against the real leaf
    is still a fleet proof.
13. **The agent executor lived only in the desktop CLI binary.** Porting the
    whole `kittens` CLI to Windows touches config, logging, proxy and update
    code that Windows guests do not need. The executor core moved into the
    Lyra library behind a `Host` trait instead. Linux keeps the same digest,
    telemetry, log and runtime markers through `guest_host`. Windows supplies
    its own host and a PowerShell runner in a job. Lyra's 61 CLI tests and the
    executor tests pass after the move.
14. **`Driver.unattested` did not refuse agent guests.** The fourth run, on
    2026-10-15, passed every readiness assertion: trust was `installed` for
    the boot, provisioning committed `ready` with the guest's boot UUID, and
    the deadline was the 600 s budget. It then failed where the fixture
    expected `Driver.unattested` to refuse a `windows-v1` guest. On a `ready`
    record the call is a harmless no-op, because `ready` sorts after
    `unattested`. Earlier in a boot, though, it would commit an agent guest as
    running without its ready line. The executor never makes that call, but
    `Driver.ready` already refuses the opposite case. `Driver.unattested` now
    refuses agent sets that prove readiness with `guest_agents_unavailable`,
    before any lock or write, and its contract says so.
15. **The image's runtime closure carried its build inputs.** Push 3b's
    pre-distribution found the `windows-v1` image's closure at 40.3 GiB across
    355 paths. It held the evaluation ISO, QEMU, OVMF, the boot media and the
    vendored crates of Lyra and terminald. Two sources caused it. Rust panic
    locations in the agent executables embedded vendored-crate store paths
    inside `disk.raw`. The installer's `timeline.jsonl` recorded the QEMU
    invocation with store paths. Every host would have kept all of that alive.
    Fixes:
    - Both Windows Rust builds remap the vendor and source prefixes.
    - The timeline scrubs store hashes at its single write point.
    - The agent derivations and the disk carry `allowedReferences = [ ]`.
    - The image may reference only its disk and firmware.
    - `windows-guest-unit` asserts all of these guards.

    The fix changes the disk, so the image must be rebuilt and its machine
    test rerun before any copy. Both happened on 2026-10-15: the rebuilt image `k5b3p0f4…` has a three-path closure (32.0 GiB logical) and passed the machine test before the copy.
16. **The fixture expected sshd on a guest that has no roster.** The fifth
    run, on 2026-10-15, passed the placement subtest in 1 039.7 s. That
    subtest covers the following:
    - trust `installed` for the boot;
    - provisioning `ready` with the guest's boot UUID and the 600 s budget;
    - the `Driver.unattested` refusal;
    - terminald's HELLO, `PING` and `USERS` with `root` listed first;
    - the refusal of an account the roster never created;
    - a root PowerShell session under ConPTY that printed the computed marker;
    - a workspace delivery recorded as settled for the boot.

    The run then stalled in the reachability step, which waited for port 22.
    On a `windows-v1` guest, sshd starts only after the roster agent applies a
    roster from Marshall, and this fixture has no Marshall. For agent guests
    the step now asserts that port 22 is closed.
17. **Windows guests sent the private endpoint on-link.** The first fleet VM
    (`win-accept-1` on `overalls`, created 2026-10-15 02:59Z) reached ready in
    27.9 s, but its roster agent failed every pass (`pass_failed`), its
    certificate agent never got a certificate and its executor never
    registered. A root ConPTY session opened through Lilly's terminal client
    showed why: TCP to 169.254.254.1:443 timed out. Lilly binds that address
    to the host side's loopback, and Linux guests reach it through their
    gateway. The Windows bootstrap had added an on-link host route, so the
    guest sent ARP requests on the tap that nothing answered.

    Replacing that route by hand with one through the gateway fixed all three
    within seconds:
    - the roster agent logged `roster_applied … accounts=1` and sshd started;
    - `u200000` became the only enabled account, so the Administrator was
      retired;
    - the executor logged `registered`.

    The bootstrap now routes 169.254.254.1 through the gateway and removes any
    other route. `windows-guest-unit` refuses an on-link route. The nested test
    cannot catch this, because it has no Audi.
18. **Atomic writes fsynced a directory, which Windows refuses.** On that VM
    the workspace receiver exited at startup (`state_unavailable`), and the
    certificate agent kept reporting `certificate_unavailable` even though it
    had written the certificate file. Both ended their atomic writes with
    `File::open(parent)?.sync_all()`. Windows rejects `FlushFileBuffers` on a
    directory handle, so the call failed after a successful rename.
    `lyra::durable::rename` now makes the rename durable on each platform: a
    parent fsync on Unix, and `MoveFileExW` with `MOVEFILE_WRITE_THROUGH` on
    Windows. `ssh_files::atomic`, the receiver's state writes and the checkout
    rename all use it, and the receiver logs the failing stage and error kind.
19. **Windows guests had no public DNS.** On `win-accept-src` (created
    2026-10-15 with `--source https://github.com/octocat/Hello-World`), Lilly
    delivered the source and the receiver accepted it and began cloning. Every
    attempt then failed with `Could not resolve host: github.com`, because the
    bootstrap configured only the `.internal` rule and no resolver. Setting the
    Linux guests' resolvers (1.1.1.1, 9.9.9.9) by hand let the next retry
    clone into `C:\workspace`, and the status became `done`. The bootstrap now
    sets those resolvers, and `windows-guest-unit` asserts them. The
    `.internal` rule still sends private names to 169.254.254.1.
20. **A relocated Windows guest deadlocked on a stale marker.** Relocating
    `win-accept-2` from `overalls` to `dungarees` (request
    `porsche-16da5108…`, 2026-10-15 04:21Z) launched the guest on the
    destination at 04:23:01. The guest applied its network, and its trust
    daemon installed the roots and sent the receipt. readinessd then logged
    only `probe_sshd_pending`, so readiness timed out after 600 s and the
    request ended `activation_failed` (retryable) after about 707 s of
    downtime. The `ssh-ready` marker from the source boot was still on disk:
    Linux keeps it in `/run`, which every boot clears, but `C:\kittens\run`
    persists. readinessd therefore demanded a running sshd. sshd starts only
    after this boot's first roster pass, and the destination could not get a
    roster before the relocation committed. The marker now holds the boot id
    that wrote it (`boot_id::write_marker`), and readinessd and the roster
    agent count it only for the current boot (`boot_id::marker_is_current`).
    `windows-guest-unit` asserts both uses. Guests built from earlier images
    keep the old agents, so the relocation proof needs a VM from the fixed
    image.
21. **The model was never told the guest runs Windows.** An approved agent turn
    on `win-accept-3` (2026-10-15 05:43Z) reached the Windows executor, which
    refused three `exec_command` calls with `invalid_arguments`. The model had
    sent Unix working directories (`/`, `/tmp`, `.`) and `pwsh`, because
    Marshall's system message and tool descriptions describe a generic
    machine. The turn then ended `provider_failed`.

    Marshall now resolves the guest platform from the image's validated agent
    set (`Images.guest_platform/1`). For `windows-v1` images, the system
    message and the `exec_command` and `read_file` descriptions name Windows
    PowerShell 5.1 and absolute Windows paths. `read_file` accepts drive-rooted
    paths, and the guest re-validates them. Unix requests are unchanged byte
    for byte (`model_protocol_test.exs`). A successful Windows agent turn is
    still to be recorded after deployment.

## Validation performed

Executed on 2026-10-14 from the worktree (uncommitted Phase 3 tree):

| Check | Result |
| --- | --- |
| `protocol`: `mix precommit` (format, compile, contracts, 271 tests including the `windows-v1` manifest and bundle vectors, Dialyzer) | pass |
| `lilly`: full suite after the driver, jail, provisioning, config and refill changes | pass |
| `lilly`: `jail_test`, `provisioning_test`, `config_test`, `image_template_cacheable_test` (new cases) | pass (cacheability test corrected to count the manifest, rerun pending) |
| `marshall`: `image_guest_agents_capability_test`, `editor_workspace_test`, `image_admission_test`, `ssh/commands_test`, `terminal/authority_test`, `machines_live_test`, `service_levels_test` on a fresh test database | 91/91 after finding 1; `image_admission_test` 5/5 and `machines_live_test` 32/32 after the later test fixes |
| `lyra`: `cargo fmt`, `cargo check --all-targets`, `cargo test`, `cargo clippy -D warnings` (Linux) | pass |
| `legacyPackages.lyraWindows` (gate 0, zig cross-build) | pass: `kittens-winprobe.exe`, 320 000 bytes, PE32+ console, manifest with digest; by gate 3 five agents including the rustls-linked roster and host-certificate agents |
| `checks.firecracker-patch-tests` (nine patches) | pass, 28 tests including the five indirect-descriptor tests |
| `marshall`: `ssh/guest_access_test` (authorized keys pull), `control/satellite_version_test` | pass (9/9) |
| `ziggy`: `provider_selection_test` (route refusals including `/ssh/v1/authorized-keys`) | pass (10/10) |
| `lyra`: `guest::ssh_roster`, `guest::trust`, `guest::mmds`, `guest::readiness` unit tests | pass |
| `lilly`: `mix precommit` (full suite, contracts, Dialyzer) alongside the nested machine test | 550/551, Dialyzer 0 errors; the one failure (`Lilly.ExecutionTest`, a 1 s `assert_receive`) passes in isolation (8/8) and is a load flake, not a regression |
| `checks.windows-guest-unit` | pass with the viosock, agents-directory, probe-task, manifest-argument and launcher-vsock assertions |
| `checks.lyra` | pass (Linux tests, clippy, Windows-target type check of the library and every Windows bin) |
| `checks.fleet`, `checks.windows-lilly-guest` evaluation with the `{ path; standby }` image shape | evaluate |
| `checks.windows-guest` (gate 1: installation with viosock and the probe, boot, `CONNECT 1099`, published log) | pass, 2026-10-14 22:14Z (318.8 s script time) under the nine-patch VMM |
| `lyra`: `guest::mmds` after finding 8 (subtree parsed, envelope refused) and all `guest::` tests | pass (12/12), 2026-10-15 |
| terminald (gate 4): `cargo test` on Linux after the platform split, including the new MMDS identity tests | pass (54/54, `TERMINALD_TEST_HEAD` pinned as in the Nix check) |
| terminald: `cargo clippy --all-targets -D warnings` (Linux) and `cargo check --all-targets --target x86_64-pc-windows-gnu` with Lyra's toolchain | pass, no warnings |
| `legacyPackages.terminaldWindows` (zig cross-build) | pass: `kittens-terminald.exe`, 532 480 bytes, PE32+ console, manifest with digest |
| `checks.windows-guest-unit` with the terminal-daemon, task and task-settings assertions | pass |

Two earlier Marshall runs are not evidence: one ran under the dev environment
(`mix do format, …, test` selects `MIX_ENV` from the first task) and one ran on
a test database polluted by committed rows from an interrupted run; both are
recorded in the session notes and the database was recreated.

## Recorded executions and production acceptance

- **Phase 2 push (ADR-0170) accepted in production.** `9715932aa` (merge of
  the Phase 2 branch with `main`) was pushed on 2026-10-14. `dungarees`
  reported `update.healthy` on `9715932aa` at 20:33Z; `overalls` followed and
  the watch recorded "both hosts healthy on 9715932aa" at about 20:45Z. No
  Windows image is staged, so the catalogs still advertise two images each.
- **Push 3a accepted in production.** `a649c2688` (gates 0 to 5), merged
  with `main` as `8cc96cf03`, was pushed on 2026-10-15. `dungarees` reported
  `update.healthy` on `8cc96cf03` at 01:28:54Z and `overalls` at 01:33:55Z.
  Lilly restarted on both hosts with the `{ path; standby }` configuration
  and logged `images_verified` with 2 verified and 0 rejected. Standby refill
  ran normally. On `dungarees`, 10 standbys were retired as `image_replaced`
  and refilled, because the push rebuilt the Linux guest images: the Lyra
  executor move and the terminald platform split change their binaries. No
  Windows image is staged.
- **Fleet proofs on the fixed image, 2026-10-15.** `edb1c8392` (findings 19
  and 20) reported healthy on `dungarees` at 05:09:14Z and on `overalls` at
  05:15:15Z, with image `y2lhdl18…` copied to both hosts beforehand.
  `win-accept-3` (created with `--source https://github.com/octocat/Hello-World`,
  placed on `dungarees`) passed every check without manual intervention,
  read through a root ConPTY session from Lilly's terminal client:
  - the workspace was `cloned` within seconds and the status read `done`,
    with `C:\workspace\Hello-World\README` present;
  - the roster agent applied a roster with 1 account;
  - the `ssh-ready` marker held this boot's id and sshd was Running;
  - the host certificate was installed and the executor registered;
  - `u200000` was the only enabled account.

  The nested `windows-lilly-guest-agents` run on `y2lhdl18…` passed end to end
  (04:37Z to 05:31Z, exit 0, script 2 791.1 s).
- **Relocation proved on the fixed image, 2026-10-15.** Moving `win-accept-3`
  from `dungarees` to `overalls` was first refused with
  `insufficient_capacity`. That happened while the nested test held about
  8 GiB on `overalls`, and the move was accepted once the test finished. The
  relocation completed at 05:34:25Z with 144 s of downtime:
  - the destination adopted the transfer at 05:33:18 and launched at 05:34:01;
  - trust was installed and provisioning committed `ready` 15.0 s after launch;
  - the guest booted with a new boot id (`e6e8bc22…`, the source boot had
    `7e004fb4…`), and the `ssh-ready` marker held the new id;
  - the cloned workspace survived with status `done`;
  - the roster agent applied a roster, sshd was Running and the executor
    re-registered.

  This is the scenario finding 20 deadlocked.
- **Roster SSH through Audi proved, 2026-10-15 05:38Z.** After the operator
  refreshed the client configuration with `kittens config-ssh`, which sets
  `User u200000`, a plain `ssh` to `win-accept-3` through the Kittens proxy and
  Audi logged in as `kittens 00`. Strict host key checking accepted the
  guest's per-boot host certificate, and the guest's sshd logged `Accepted
  publickey for u200000`. The roster agent reported each login (`login_recorded`)
  from sshd's log. The first attempt, with a stale client configuration
  (`User geoffrey.huntley`), was refused as an invalid user by Windows and Linux
  guests alike; that was a client configuration problem, not a Windows defect.
- **Findings 17 and 18 fixed and staged, 2026-10-15.** The image
  `lqlllkav…` carries the gateway route for the private endpoint and the
  durable rename. `checks.windows-lilly-guest-agents` passed on it end to end
  (03:12Z to 04:03Z, exit 0, script 2 580.1 s; placement 812.9 s, restart
  1 162.5 s). `nix copy` sent it to `dungarees` in 256 s, and both hosts
  report the same store path before the push that names it.
- **Image pre-distributed for push 3b, 2026-10-15.** The development
  session runs on `overalls`, so the tested build `k5b3p0f4…` was already in
  its store. `nix copy` sent the three-path closure to `dungarees` in 246 s.
  Both hosts report the same store path. `disk.raw` is 32 GiB logical and
  4.3 GiB allocated on each host, on lz4 datasets.
- **Gates 2, 4 and 5 recorded on nested KVM, 2026-10-15 01:58Z to 02:46Z
  (`checks.windows-lilly-guest-agents`, exit 0, test script 2 863.2 s).** The
  windows-v1 image `k5b3p0f4…` (closure: disk, firmware and the image
  directory only) passed end to end on the reference-guarded image:
  - Inception was refused before any host effect (299.1 s).
  - Placement took 936.2 s. In it, trust was `installed` with a guest boot
    UUID and provisioning committed `ready` with the same UUID and a 600 s
    deadline. The unattested commit was refused, terminald answered HELLO,
    `PING` and `USERS` with `root` first and refused `u200000`, and a root
    PowerShell session printed the computed marker. A workspace delivery was
    recorded settled for the boot.
  - The guest reached `SAC>` and configured its /32. It answered ICMP on it
    while port 22 stayed closed, because it has no roster.
  - Stop, a restart from the portable bundle with a new boot UUID, and delete
    took 1 330.2 s.
- **Gate 0 (toolchain)** recorded above.
- **Gate 1 (viosock transport) recorded on bare KVM, 2026-10-14 21:58Z.** With
  the ninth patch (alignment fixed), the probe image booted under the patched
  VMM through the scratch launcher; the guest's `kittens-winprobe` found address
  family 40 through the `\\.\Viosock` control device, listened on vsock port
  1024 (now 1099), and the host's `CONNECT` returned `OK 1073741832` followed by
  `{"probe":"kittens-winprobe","version":"0.1.0","address_family":40,"source":"ioctl","peer_cid":2,"peer_port":1073741832,"connection":9}`;
  Firecracker's log showed no descriptor errors (zero `UnwritableDescriptor` or
  `InvalidIndirectTable` lines against several hundred under the unpatched
  VMM). Replies were lost only when the dialling `printf | socat` half-closed
  after its request, which makes the muxer shut the guest connection before the
  reply; Lilly's poller keeps its socket open, and the machine-test dial now
  does too.
- **Gate 1 nested execution recorded, 2026-10-14 22:00Z to 22:14Z
  (`checks.windows-guest`, exit 0, test script 318.8 s).** The image was
  reinstalled with the viosock driver and the port-1099 probe (installation
  about 325 s of guest time), booted under the patched VMM on nested KVM to the
  SAC prompt, and the probe answered the host's `CONNECT 1099` 23.7 s after the
  prompt: `OK 1073741829` then
  `{"probe":"kittens-winprobe","version":"0.1.0","address_family":40,"source":"ioctl","peer_cid":2,"peer_port":1073741829,"connection":2}`;
  the probe log read from the EFI system partition showed `listening on vsock
  port 1099` and `answered connection 1 peer_cid=2 … sent=true`.
- **Gate 2 (readiness and trust daemons) implemented, execution pending.**
  `lyraWindows` builds `kittens-winprobe.exe` (414 720 bytes),
  `kittens-readinessd.exe` (509 440 bytes) and `kittens-trustd-windows.exe`
  (564 224 bytes); the Lyra check passes with the Windows-target type check and
  the shared MMDS, readiness and trust unit tests; the `windows-v1` image
  (`windowsGuestAgents`) and the `windows-lilly-guest-agents` machine test
  evaluate. Its execution (installed trust and ready provisioning with a guest
  boot UUID, new UUID after restart) is recorded here once run.
- **Gate 3 linking proof.** `kittens-ssh-sync-windows.exe` (2 405 376 bytes),
  which constructs the shared private HTTPS client (`reqwest` with rustls and
  `ring`) against the trust daemon's bundle, links for `x86_64-pc-windows-gnu`
  through the zig toolchain, so the mingw fallback of the plan is not needed.
  Gate 3 then landed as a pull design (finding 5): the Marshall authority
  `GuestAccess.authorized_keys/2` with its control route and Ziggy's
  `GET /ssh/v1/authorized-keys` relay (Marshall and Ziggy tests pass), the
  shared roster rules (`guest/ssh_roster`, fake-backend tests), Net API
  accounts, the roster agent that writes per-account key files and starts
  `sshd`, the per-boot host certificate agent, the shipped public-key-only
  `sshd_config` and their `SetupComplete.cmd` wiring, plus login receipts from
  sshd's file log (`guest/ssh_login`, fingerprint-matched to the pulled keys,
  parser tests) and the bootstrap Administrator rotation (random unrecorded
  password, account disabled, once a roster account is active). Unexecuted: no
  NixOS test places a Windows guest behind Audi, so a roster login, its receipt
  and the rotation are manual fleet proofs.
- Gates 3 to 5, push 3a convergence and push 3b acceptance: pending.

## Remaining gaps

- Gates 4 and 5 are implemented. The machine test asserts the root ConPTY
  session and the workspace receiver's boot-bound acceptance. A roster-user
  terminal (an S4U logon inside ConPTY), a workspace clone (the nested test
  has no egress) and an agent turn (registration needs Marshall) are fleet
  proofs of push 3b.
- Gate 3 is implemented end to end in code, but a roster login through Audi,
  its login receipt and the Administrator rotation have no NixOS test for
  Windows and are manual fleet proofs. The private HTTPS client now uses
  schannel (finding 12), and its verification against the deployed leaf is
  part of the same fleet proof.
- Agents run as scheduled tasks. Whether Task Scheduler restarts an agent
  that exits with an error is unproven (finding 10); an SCM service host is
  the replacement if it proves necessary.
- ConPTY re-renders the screen through conhost, so terminal output differs
  byte for byte from the program's own output. terminald still passes
  through exactly what it receives.
- Windows helpers (Git, PowerShell) join their kill-on-close job just after
  they spawn, because the standard library cannot start a child suspended. A
  grandchild started in that instant would escape cancellation.
- terminald mirrors Lyra's viosock and MMDS clients (finding 11); a shared
  guest-platform crate is a follow-up.
- `StandbyRefill`'s pass itself is exercised only through its pure
  `eligible_images/3` helper; the pool-level refill with an uncacheable image
  configured is not covered by a machine test.
- Self-update does not exist on Windows (image rebuild), Windows guests send
  no telemetry (tool results are closed log lines), and host key material
  lives on disk; all are recorded gaps of the ADR.
