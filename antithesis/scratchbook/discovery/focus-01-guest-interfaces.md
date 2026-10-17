---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Architecture and data flow: guest and native boundaries

Scope answer, verbatim: "Repository only (Recommended)".

Read-only source discovery. The citations below describe implementation paths and
their checks; contract comments and deployment modules express requirements to
test, not proof that those requirements hold. No executable verification was run
for this artifact. The repository was not changed. This temporary research
artifact has no production architecture impact.

## Component and request map

| Component | Inputs and outgoing flow | Local authority/state boundary |
| --- | --- | --- |
| Lyra desktop/user CLI (`overalls`) | Verified public HTTPS obtains exact current Audi route/key; child `ssh` performs opaque outer relay | Selected local private key and installed public CA policy; neither SSH relay bytes nor commands are parsed/persisted by proxy |
| Lyra guest agent | `https://llm.internal/agent/v1/` register → heartbeat/claim → started transition → local tool → terminal transition | Server fence epoch and executor ID; local stop/ready markers and supervisor identity; tools run inside guest |
| Guest account helper | Private HTTPS roster/authorize; root reconciliation updates passwd/group/sudo and retained account journal | Fresh authority before terminal/editor creation; offered SSH key equality before emitting authorized key |
| Guest trust receiver | Host CID 2 vsock port 1030, boot-bound public root set | NixOS current bundle or Ubuntu public CA store, digest and installation receipt |
| Guest workspace receiver | Host CID 2 vsock port 1031, closed provider source reference; guest performs HTTPS Git fetch | Durable source, partial checkout → rename → done marker; reference acceptance is separate from checkout completion |
| terminald | Host CID 2 vsock port 1075; per-connection boot HMAC hello then control/attachment frames | Guest root resolves current authorized account, creates PTY under account credentials; per-session token and raw replay ring |
| vscode web broker | TCP guest eth0 address:4444 from exact profile gateway; bounded account/image preface | Root broker ensures current account, checks per-account Unix socket custody/peer UID, launches or reuses independent systemd Node worker |
| Lilly executor/driver | Durable v4 command selects placement-owned disk, jail, network, systemd unit and boot challenge | Existing claim + generation intent + launch-attempt before guarded Firecracker launch; physical observation/readiness before running outcome |
| Lilly clone/transfer effects | Authenticated control exchange gives bounded expiring closed command; source capture → local copy or SSH/ZFS stream → adopt/revoke/prune | Local current placement intent, source/export/receive locks and journals; data receipt/adoption do not independently authorize guest execution |
| Inception guest | Parent boot-bound vsock configuration/publication exchange, separate credentials, nested local services | Independent inner identities, verified localhost control TLS, local PostgreSQL and nested Lilly/KVM/ZFS; parent retains public namespace authority |

## User CLI and guest agent

1. Lyra proxy refuses before SSH on failed current-key lookup, then loads local
   trust and derives the gateway certificate principal; it passes the exact
   temporary known-hosts file and selected identity to SSH. stdin/stdout/stderr
   are inherited directly (`lyra/src/proxy.rs:208`, `:221`, `:228`, `:249`). The
   generated outer command disables agent forwarding, mux reuse and forwarding,
   enforces `StrictHostKeyChecking=yes`, uses certificate host keys and ignores
   global known-hosts (`lyra/src/proxy.rs:277`, `:309`, `:315`, `:319`). This is
   an opaque transport boundary, not guest command execution by the CLI.
2. The real guest agent origin is fixed to `llm.internal`; registration and
   command responses have `deny_unknown_fields` typed envelopes
   (`lyra/src/agent.rs:12`, `:20`, `:28`, `:34`). It registers with the installed
   binary digest, publishes a ready marker, opens a session and re-registers
   after a fixed five-second delay on failure (`:76`). Heartbeat/claim failures
   leave the session; a fresh heartbeat precedes each command (`:110`).
3. The `started` RPC completes before the local tool call; the terminal RPC
   precedes telemetry (`lyra/src/agent.rs:135`, `:140`, `:152`, `:159`, `:169`).
   This separation is important under crashes: a workload should observe durable
   transitions and actual synthetic effects, rather than treating a claim or
   submitted started request as execution proof.
4. `exec_command` intentionally executes a user tool command through guest
   `/bin/sh -lc`, bounded to 20 seconds plus a two-second kill-after; command
   input is at most 8192 bytes and output capture is at most 4096 bytes per
   stdout/stderr (`lyra/src/agent.rs:173`, `:181`, `:234`). This authorized
   guest tool shell is distinct from the prohibited conversion of peer data to
   host shell programs. `read_file` accepts absolute bounded path text and
   bounds contents; `web_fetch` is a separate module (`:152`, `:218`).
5. Agent RPC uses the generic verified Rustls HTTPS client, no proxy, no redirect,
   ten-second timeout and 16 KiB response cap (`lyra/src/agent.rs:260`,
   `lyra/src/http.rs:63`). Its root loading is not the SSH private-client path:
   Cargo enables `rustls-tls-native-roots` (`lyra/Cargo.toml:25`), and agent
   routing uses guest DNS. A container fixture must install the synthetic root
   into the native store and supply `llm.internal` DNS; setting only
   `OVERALLS_SSH_CA_BUNDLE` does not reproduce this client.
6. The SSH/telemetry private client explicitly reads a bounded public bundle,
   disables built-in roots, and resolves its exact hostname to
   `169.254.254.1:443` (`lyra/src/private_http.rs:5`, `:35`, `:58`, `:64`). On
   Linux it selects native TLS; other platforms use Rustls (`:54`). This creates
   a second transport/trust configuration that the harness must preserve.

## Accounts, SSH certificates, and trust bootstrapping

1. The on-demand terminal/editor account helper takes a stable account lock,
   fetches a fresh verified roster, validates membership, then reconciles the
   account using the same code as SSH (`lyra/src/bin/overalls-ssh-authorize.rs:481`).
   The persistent roster journal rejects older versions and conflicting same
   versions (`:353`, `:370`). Ordinary home contents are retained when accounts
   are removed. Per-key authorization prints only the exact offered key after
   a private authority response matches it (`:530`, `:542`).
2. Guest images configure OpenSSH with runtime-only certified host keys,
   `AuthorizedKeysCommand`, a guest-account login PAM hook and public-key-only
   authority; roster synchronization precedes sshd startup, a two-second timer
   refreshes it, and certificate changes reload the listener
   (`nix/domains/artifacts/guest/default.nix:10`, `:13`, `:17`, `:28`, `:37`, `:71`,
   `:77`, `:87`). The helper certificate installation path verifies the
   received certificate before publishing it
   (`lyra/src/bin/overalls-host-certificate.rs:228`, `:237`).
3. The public-root receiver uses vsock port 1030 and checks boot identity,
   supplied digest, and kernel peer CID before installation and receipt
   (`lyra/src/bin/overalls-trustd.rs:13`, `:127`, `:152`, `:489`, `:500`).
   NixOS installs a content-addressed bundle and atomically changes current
   state; Ubuntu reconciles the native CA store (`:171`, `:197`, `:292`, `:375`).
   Lilly also bounds and verifies the corresponding boot-bound receipt
   (`lilly/lib/lilly/vm/guest_trust.ex:5`, `:10`, `:72`).
4. NixOS private services force the guest CA bundle to the receiver's current
   bundle, start trust before network, and start workspace receiving after
   trust (`nix/domains/artifacts/guest/private-services.nix:39`, `:43`, `:62`, `:92`).
   A fake TLS server with verification disabled would bypass the system's trust
   boundary and is unsuitable evidence for these flows.

## Guest terminal and editor

1. The terminal daemon parses a kernel boot identity, derives a boot key from
   challenge plus `overalls-terminald-v1`, and listens on AF_VSOCK
   (`nix/domains/artifacts/terminald/src/main.rs:18`, `:24`, `:32`). The kernel-observed
   peer CID must be 2 before reading bytes (`:55`), and every connection must
   begin with a valid HMAC hello (`:74`, `:85`, `:122`). Hello proof includes
   nonce, placement and epoch (`nix/domains/artifacts/terminald/src/session.rs:192`).
2. Control creates/queries/kills/resizes sessions; attaching has a separate
   connection with its own hello before token-bearing attach
   (`nix/domains/artifacts/terminald/src/main.rs:98`, `:151`). Session creation resolves
   the account before fork; PTY code resolves passwd data and supplementary
   groups (`nix/domains/artifacts/terminald/src/pty.rs:112`, `:132`). Session lifetime
   is owned by terminald in the guest, while outer connection lifetime is
   separate (`nix/domains/artifacts/terminald/CONTRACTS`, contract
   `sessions-outlive-connections`). The latter is an explicit requirement to
   test, not established by reading source.
3. terminald starts after guest readiness as a guest-root systemd service with
   512 MiB bound and guest login shells under resolved identities; the module
   deliberately retains child guest powers, relying on VM and host networking
   isolation (`nix/domains/artifacts/guest/terminald.nix:23`, `:31`, `:40`). Ubuntu
   ships the same vsock/account helper service (`nix/domains/artifacts/guest/ubuntu/units/lilly-terminals.service:12`).
4. The editor broker runs as root, reads `/proc/cmdline`, binds only the guest
   address:4444 and eth0 device, checks exact profile gateway peer IP and bounds
   concurrent connections (`nix/domains/artifacts/vscode-web-broker/src/main.rs:747`,
   `:753`, `:755`, `:776`, `:780`). Its boot parser derives gateway from profile
   address and binds placement/physical execution epoch; logical generation
   updates deliberately do not redefine physical boot
   (`nix/domains/artifacts/vscode-web-broker/src/lib.rs:232`).
5. Editor admission reads one four-byte-length-prefixed JSON preface with max
   2048-byte payload, denies unknown fields, and validates exact account and
   package binding (`nix/domains/artifacts/vscode-web-broker/src/lib.rs:9`, `:20`,
   `:213`, `:311`; `src/main.rs:707`). Fields include VM, host, placement,
   session, user/account IDs, epoch/generation, UID/name, protocol, source
   commit, immutable release and canonical HTTPS origin (`src/lib.rs:29`).
6. Per-account single-flight precedes fresh `ensure` roster reconciliation;
   existing worker readiness and root systemd metadata determine reuse or
   recreation (`nix/domains/artifacts/vscode-web-broker/src/main.rs:575`, `:591`,
   `:605`, `:617`). Worker connects verify kernel SO_PEERCRED UID (`:484`).
   Workers are independent units with explicit UID/GID, private runtime socket,
   personal server data and direct executable argv (`:645`). They disable
   workspace trust/telemetry and use upstream idle shutdown (`:560`). Broker
   restart preserves runtime directories (`nix/domains/artifacts/guest/vscode-web.nix:23`,
   `:36`, `:38`). HTTP/WS bytes relay only after account/package admission and
   successful readiness (`src/main.rs:725`, `:734`, `:742`).

## Lilly launch, guest effects, and clone/transfer

1. Physical resources are named by placement, not logical VM ID. Executor
   ingress checks binding identity and derives the guest target from trusted
   profile/slot; terminal options require a running observation and the exact
   persisted boot before revealing jailed vsock path
   (`lilly/lib/lilly/vm/executor.ex:82`, `:104`, `:225`).
2. Native launch order under the placement lock is claim → running intent →
   verify stopped unit/not already attempted → provisioning journal → disk →
   boot record → jail/network → launch-attempt file → systemd start
   (`lilly/lib/lilly/vm/driver.ex:378`). A durable intent is not physical launch
   success, and the separately persisted launch-attempt makes replay after
   uncertain systemd reply a meaningful failure window.
3. The systemd tree lives in `lilly.slice`, with independent control-group kill,
   memory/swap limits, boot log writer, PID/mount namespace, shared-lock launch
   guard, Firecracker jailer, per-guest UID/GID, cgroup2 and owned netns
   (`lilly/lib/lilly/vm/unit.ex:36`, `:50`). The jail binds kernel/initrd and
   persistent drives; Firecracker config passes placement, epoch and random boot
   challenge, guest CID3 and jail Unix `v.sock`; drive flushes use Sync I/O with
   Writeback cache (`lilly/lib/lilly/vm/jail.ex:22`, `:68`, `:84`, `:92`).
4. Dedicated host-to-guest channels have distinct responsibilities: readiness
   1024, Inception SMTP credentials 1025, guest flush 1026, Inception
   configuration/publication 1028, trust 1030, workspace 1031, terminal 1075
   (`lilly/lib/lilly/vm/readiness.ex:74`, `credentials.ex:113`, `flush.ex:25`,
   `inception_exchange.ex:8`, `guest_trust.ex:5`, `workspace_source.ex:12`,
   `nix/domains/artifacts/guest/terminald.nix:13`). Guest Python readiness/flush and
   Inception ingress independently reject non-host peers
   (`nix/domains/artifacts/guest/readiness.py:193`, `flush.py:61`,
   `inception/ingress.py:337`). Flush is diagnostic/best-effort, not authority
   to stop/activate the guest (`lilly/lib/lilly/vm/flush.ex:7`).
5. Workspace delivery is a supervised task outside executor lifetime, with
   per-placement single-flight and an independent delivery journal; current
   boot fences are checked before attempts and after acceptance
   (`lilly/lib/lilly/vm/workspace_source.ex:46`, `:86`,
   `lilly/lib/lilly/vm/driver.ex:773`). Guest receiving validates a bounded
   closed JSON line against kernel placement/epoch/challenge and nonce
   (`lyra/src/workspace_receiver.rs:117`); source persistence precedes
   acceptance; clone completion follows Git, directory rename/sync and a done
   marker (`:576`, `:598`). Parent acceptance must not be equated with completed
   checkout. Guest Git performs source resolution; Lilly never runs Git here.
6. Clone effects validate closed current-host commands and 1–300 second
   expiry, then select prepare/probe/connect/capture/copy/adopt/revoke/discard/
   prune (`lilly/lib/lilly/clone/effects.ex:25`, `:65`). Two runtime modes keep
   bulk `copy` separate from control/permit polling. The runtime keeps at most
   16 pending results and retries acknowledgements before re-executing a
   pending effect (`lilly/lib/lilly/clone/runtime.ex:17`, `:33`, `:35`).
7. Same-host/same-pool clone uses a verified read-only capture snapshot and
   image-copy offload into an ordinary independently owned destination,
   preserving copy journal mode on retry; other pools/hosts use ZFS
   send/receive (`lilly/lib/lilly/transfer/clone_copy.ex:18`, `:25`, `:38`).
   Destination adoption checks copy nonce/GUID/files and boot bundle (`:77`).
   Bulk copies run outside the pool lock. Source snapshot and stream effects
   still require stopped current local authority
   (`lilly/lib/lilly/vm/driver.ex:25`, `:42`, `:65`).
8. SSH pulls feed producer stdout directly into receiver stdin through the
   native stream, not through BEAM buffers
   (`lilly/lib/lilly/transfer/ssh.ex:72`, `stream.ex:20`, `:58`). Actual sender
   and receiver select `zfs send -c` and `zfs receive -u -s` from verified
   local descriptors (`source_snapshots.ex:156`, `received_dataset.ex:139`,
   `:179`); resume validates actual token lineage before `zfs send -t`
   (`source_export.ex:82`, `resume_token.ex:19`). Retire-source operations
   persist deletion intent/tombstone before storage cleanup and require a
   confirmed stopped unit, empty jail/network and revoked exports
   (`lilly/lib/lilly/vm/driver.ex:108`, `:127`).

## Native helper boundaries and container implications

| Helper or effect | Source evidence | Feasible container evidence and required native evidence |
| --- | --- | --- |
| KVM startup proof | `lilly/native/kvm-probe/src/lib.rs:61` opens `/dev/kvm`, checks API12 and creates an empty VM | Parser/stub outcomes alone cannot establish KVM. Actual device/VM creation and Firecracker boot require kernel capability. |
| Stable host/placement lock and child death | `lilly/native/host-lock/src/lib.rs:258`, `:331`, `:448` use flock, inherited lock, process-group kill/reap and caller EOF | Real files/processes can exercise helper lock/caller-death custody without root; real Lilly ownership/host identity and VM crash claims need NixOS. |
| Launch guard | `lilly/native/launch-guard/src/lib.rs:23`, `:103`, `:173`, `:191` validates exact53-byte intent, holds shared stable lock across exec | Real file refusal and exec/lock race can run in Linux containers; confinement/jailer/cgroup relationship needs the native fixture. |
| VMM death watcher | `lilly/native/vm-watch/src/lib.rs:121`, `:122`, `:130`, `:145` bind pidfd and cgroup2 inotify | Child-process/pidfd tests are possible if the actual kernel exposes cgroup2; a fake cgroup file establishes parser semantics only. |
| Image/snapshot copy | `lilly/native/image-copy/src/lib.rs:193`, `:241`, `:261`, `:321` use FICLONE, copy_file_range and source lease | Real regular files can test independent bytes/fallback/partial-progress refusal. ZFS read-only capture/UID custody, crash durability and cleanup require native storage. |
| Transfer stream and source export | `lilly/native/transfer-stream/src/lib.rs:203`, `:256`; `source-export/src/lib.rs:162`, `:416` use stable ownership, pipes/splice and kill/reap | Real synthetic producer/consumer processes can test byte custody, deadline/revocation/blocked progress and independent exits; actual ZFS stream/resume/import lineage still native. |
| Export descriptor bridge | `lilly/native/export-channel/src/lib.rs:11`, `:27`, `:476` and its `CONTRACTS` use kernel peer credentials and descriptor forwarding | Real AF_UNIX sockets/SCM_RIGHTS can exercise transport custody; dedicated SSH account and real transfer server integration stay native unless represented explicitly. |
| Cross-namespace ZFS unmount | `lilly/native/zfs-namespace-unmount/src/lib.rs:223`, `:279`, `:395`, `:421` use namespace entry and current mount inventories | Pure mountinfo parsers and refusal models can run in containers. Actual authority, foreign namespace scanning, ZFS exact roots and unmount races need CAP_SYS_ADMIN in initial user namespace and native fixture. |
| terminald / editor worker | AF_VSOCK (`terminald/src/vsock.rs:64`); UID/PTY; systemd/SO_PEERCRED (`vscode-web-broker/src/main.rs:484`, `:645`) | Protocol/ring/session logic and actual Unix/PTYS can run separately. Replacing CID/boot files/systemd/user state is explicitly emulated evidence; native full path validates guest/host isolation and worker identity. |

Several Rust tests deliberately pass by skipping environment-dependent native
work: vsock checks return when unavailable
(`nix/domains/artifacts/terminald/src/vsock.rs:118`), and vm-watch child tests document
similar cgroup unavailability (`lilly/native/vm-watch/src/tests.rs:96`). A green
test aggregate therefore must record skipped reachability separately.

## Guest image and Inception topology

NixOS guest assembly evaluates pinned NixOS modules and ships an uncompressed
Firecracker kernel ELF, matching initrd and writable-template ext4 image. The
manifest is v4 with exact hashes/lengths, workspace source protocol2 only when the
boot service is enabled, and optional immutable editor descriptor plus 2 GiB
headroom (`nix/domains/artifacts/guest/default.nix:6`, `:138`, `:199`, `:209`, `:220`,
`:232`). The Ubuntu build similarly assembles rootfs in a Nix Linux VM, installs
the same Rust guest helpers, enables trust/workspace/editor/agent units only by
capability and emits the same manifest schema
(`nix/domains/artifacts/guest/ubuntu/default.nix:172`, `:259`, `:284`, `:372`, `:415`,
`:441`). No hosted result for either distro exists from this discovery.

Inception is not merely another standard guest: it imports inner Marshall,
Porsche, Audi/DNS, private services, Ziggy and control modules, disables ordinary
guest sshd, loads KVM and ZFS, and configures one inner Marshall replica plus
verified-TLS local PostgreSQL18 with synchronous commits
(`nix/domains/artifacts/guest/inception/default.nix:33`, `:38`, `:50`, `:68`, `:100`).
Its early identity stage checks virtualization flags, loads the corresponding
KVM module, and then starts inner storage/namespace bootstrap (`:129`).
Inner Porsche talks to fixed verified `https://localhost:5443`; Audi has a paired
10.41 address at its control 10.40 slot and root-owned inner Lilly connector
(`nix/domains/artifacts/guest/inception/roles.py:71`, `:101`). The parent publication poll
checks ownership/current confined boot both before and after vsock exchange,
and uses one deadline and exact request/boot binding
(`lilly/lib/lilly/vm/driver.ex:998`, `:1015`, `:1030`,
`lilly/lib/lilly/vm/inception_exchange.ex:13`, `:76`). Public readiness is kept
independent of core namespace/execution readiness in the inner deployment
(`nix/domains/artifacts/guest/inception/default.nix:173`).

## Adaptation recommendations and explicit gaps

1. Preserve real control transport, command codecs, durable stores/journals,
   actor reconciliation, Marshall authority, delivery receipts and application
   service behavior. Place any emulated physical state behind a harness-only
   typed executor/effect boundary and name the modeled states/effects explicitly.
   A modeled running receipt is evidence about reconciliation logic, not a
   physical guest boot or isolation claim.
2. Execute real unprivileged native helper binaries against synthetic
   files/processes/sockets where their actual operating-system interfaces are
   available. Do not replace a supported process/lock/pipe boundary solely to
   make the harness simpler; these are valuable crash-sensitive surfaces.
3. Keep boot identity and network authority explicit in guest emulation. For
   software guests, separate guest process lifetime from Lilly worker/container
   lifetime, and exercise delayed readiness/trust/publication, lost replies,
   guest restart and superseded boot. Otherwise the central independent-lifetime
   and fenced-boot failure windows disappear.
4. Direct real Lyra agent/SSH-private clients to verified synthetic HTTPS with
   their actual root-loading and DNS/address rules. Harness-specific fixtures
   may supply synthetic authority; production must not acquire a runtime
   disable-verification or host-ownership bypass.
5. A complete repository setup needs distinct native machine validation for
   KVM/Firecracker, ZFS/GUID/real stream tokens, jail mounts, initial-user-namespace
   unmount authority, real guest CID/UID, nftables/conntrack and nested Inception.
   Hosted container properties must carry an explicit emulation/native scope
   label and list the remaining machine checks.
6. This helper did not inspect every terminal frame/input-dedup branch, every
   filesystem fsync sequence, agent-supervisor update path, editor upstream patch,
   transfer cleanup path or all native regression tests. Those remain leads for
   state/concurrency/security/test focus agents; no defect is claimed here.
