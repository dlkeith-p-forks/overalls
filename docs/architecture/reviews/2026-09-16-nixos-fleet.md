# NixOS fleet coordination and independent execution

Date: 2026-09-16

## Scope and architecture impact

This checkpoint exercises the accepted ADR-0003 coordination, ADR-0030 deployment,
ADR-0031 sparse-storage and ADR-0033 machine-verification requirements. It also
tests existing reservation and independent-VM-lifetime contracts in ADRs 0005,
0006, 0010, 0013 and 0017. The user authorized implementation; no decision is replaced.
All affected partial implementation statuses remain partial.

The [fleet module](../../../nix/tests/machines/fleet/default.nix) boots three distinct Marshall
machines, two Lilly machines, a separate PostgreSQL server, HAProxy, a local
egress/DNS fixture and a browser client. Services use the actual source-built
releases and production modules. TLS peer/name checks, Cedar, authenticated host
reports, AshOban execution and native ZFS identities remain active.

## Fixture boundaries

- [Storage preparation](../../../nix/tests/machines/fleet/storage.nix) builds actual
  mirrored ZFS disks, reads their pool/dataset GUIDs and cleanly exports the pool.
  Each Lilly gets independent persistent overlays. The public identity metadata
  binds immutable module options; capacity is measured at runtime.
- [Credential preparation](../../../nix/tests/support/fleet-credentials.py) generates
  the CA, separate endpoint keys, database password, signing keys and fixture
  sentinel inside the disposable database VM. Private transfer files remain
  outside the test's retained output directory.
- The [trusted operator helper](../../../nix/tests/machines/fleet/operator.exs) validates
  the private database sentinel before acting. Enrollment uses the actual request
  parser and Ash enrollment actions, with fixed fixture host/pool UUIDs solely
  to match immutable NixOS options. Actual credential issuance follows. Hosts
  remain disabled with zero/unknown capacity until their real Lilly reports.
  This does **not** test normal `enroll_file` UUID allocation or its atomic
  file-publication workflow. Existing enrollment tests cover that separate path.
- Capacity admission uses real user actors and domain actions on separate release
  processes in each Marshall VM. A shared barrier holds all three processes until
  they are ready, preventing sequential execution from masquerading as a race.
  These calls are trusted fixture invocations; they do not establish browser/API
  session sharing by themselves.
- [Process observations](../../../nix/tests/support/vm-processes.py) compare actual
  Firecracker process trees by PID and kernel start time. Unit readiness alone
  does not establish uninterrupted execution.

## Checks and execution status

**The complete fleet at this checkpoint passed in 1108.23 seconds** for the execution
scope (1108.96 seconds on the framework's overall script timer). The successful
immutable derivation is `b9l8ldi07mlakv9lnfc9yim9hkqp55ax-vm-test-run-kittens-fleet`;
the later [Nix refactor review](2026-09-16-nix-layout-and-test-refactor.md) records
the reorganized suite's derivation and regression results. All nine machines
used their source-built releases and immutable service units, with no diagnostic
service overrides or injected capacity. Both Lilly hosts reported four effective
cores, 3 GiB guest memory, native ZFS capacity and logical-pool I/O provenance.

| Fleet case | Result |
| --- | --- |
| Runtime credentials, explicit migration and verified TLS | Passed, 39.10 seconds |
| Disabled-host defaults and real authenticated observations | Passed, 131.39 seconds |
| Three synchronized requests converge on one real VM/reservation/operation | Passed, 34.91 seconds |
| Browser login, sharing, terminal effects, recovery, writer handoff and revocation | Passed, 161.45 seconds; deliberate abandoned transaction and all recorded lost-node connections met the 20/35-second deadlines |
| Final three-request race admits exactly two slots; six guests run across both hosts | Passed, 188.74 seconds |
| Actual egress, all 30 directed peer denials, protected-host and spoofing guards | Passed, 231.84 seconds |
| Marshall machine loss plus PostgreSQL outage/recovery preserve all VMM identities | Passed, 114.39 seconds |
| Lilly daemon death/restart preserves all VMM identities | Passed, 24.22 seconds |
| Stop/start retains disk GUID; deleting older guests releases storage without restarting survivors | Passed, 59.03 seconds |
| Partitioned provisioners reject new work despite free resources, then recover admission | Passed, 47.97 seconds |

The partition case first frees sufficient CPU, memory and disk on both hosts,
then verifies rejection after reports become stale. Once the partition heals,
real reports restore eligibility and replacements reach running state on both
hosts. Cleanup precedes reservation release and observed allocation removal.

| Other completed validation | Evidence boundary |
| --- | --- |
| Lilly precommit: 24 properties, 72 tests, compiler/runtime/ADR/contracts and forced Dialyzer with zero errors | Collection/dispatch, bounded diagnostics, launcher composition and guarded deletion recovery. |
| Marshall precommit: 25 properties, 202 tests, four host cases excluded; compiler/runtime/ADR/contracts and forced Dialyzer | Production connection parameters, three-BEAM coordination and six browser-state checks; one existing upstream typespec exclusion. |
| Marshall authenticated runtime regression: all four tests passed | Actual ext4 collection, TLS exchange, durable receipt, restart and revocation. |
| Native ZFS machine suite: 256.75 seconds | Final-package reader regression, persistent partition aliases and real between-read usage/quota/child-identity changes. |
| Owned ZFS lifecycle machine suite: 797.35 seconds | Complete reuse/ownership/interrupted-create/copy/delete regression, including unmount recovery, unexpected host files, unsafe policy and unmounted replacement-GUID rejection. |
| Service-role machine suite: 104.32 seconds | Final-package cookie alphabets, TLS/name rejection, three colocated Marshall instances with Lilly, effective limits and independent restart/proxy failover. See the [completion audit](2026-09-16-plan-completion-audit.md). |
| Native I/O machine suite: 73.84 seconds | Final-package overlapping collector; actual workload, malformed output, timeout and pool-reimport handling. |
| ACME/Route 53 machine suite: 144.00 seconds | Final-package real client/local provider, renewal, failure handling and validated publication. |
| Secret custody machine suite: 135.90 seconds | Actual application delivery, publication/permission failures, recipient rotation and separately keyed replacement recovery. |

All fourteen original exported checks were re-evaluated against the final
application packages. Their successful outputs include both source-release
checks, module/storage evaluation, roles, fleet, custody, ACME, native ZFS,
lifecycle, guests, I/O, mirrored installation and exact exported images. Checks
whose source/package derivations changed were rerun; unchanged successful
derivations were reused. The additional coordinated credential-rotation suite
also passed in 249.75 seconds, bringing the total to fifteen successful exported
checks; it has its own [review](2026-09-16-fleet-credential-rotation.md).

The focused two-guest cleanup regression also passed in **696.22 seconds**,
including unchanged survivor process identity and continued disk reads/writes.
Earlier retained-machine
browser/network/recovery results were diagnostic evidence; they are superseded
for complete fleet acceptance by the successful immutable run above. Prior failures
and unresolved causes are preserved below. The initial fleet invocation lacked
an advertised `nested-kvm` builder feature; later runs used enabled nested
virtualization and actual `/dev/kvm`. No KVM scenario was skipped.

## Findings and corrections

1. **Resolved implementation defect, medium: launch-cookie alphabet.**
   Both service modules generated base64 release cookies. A random leading `+`
   was interpreted by the Erlang launcher as a VM option, causing startup failure
   and echoing the ephemeral cookie in usage diagnostics. The
   [Marshall](../../../nix/modules/marshall.nix) and
   [Lilly](../../../nix/modules/lilly.nix) wrappers now encode all 32 random bytes
   as hexadecimal. The [role regression](../../../nix/tests/machines/service-roles/driver.py) checks the
   actual process environment for exactly 64 hexadecimal digits without printing
   the cookie. This preserves entropy and existing distribution-disabled behavior;
   it fixes ADR-0030 startup and secret-diagnostic obligations.
2. **Resolved fixture defect: unreadable SMTP CA.** The fleet environment named
   the root-only fixture CA as its SMTP trust file. Dynamic Marshall users could
   not read it, so production configuration correctly rejected startup. The
   unused SMTP fixture configuration now uses the readable system CA bundle.
   PostgreSQL and serving TLS still verify the runtime-generated test CA through
   their proper credential delivery. This suite makes no SMTP delivery claim.
3. **Resolved fixture defect: backend address family.** The test framework adds
   both IPv4 and IPv6 host records, while this fixture configures IPv4 Marshall
   listeners. HAProxy now uses the explicit management IPv4 addresses and keeps
   each backend's certificate hostname for verification. The corrected run passed
   direct backend TLS and the public proxy readiness path. No TLS verification
   was disabled; this correction is confined to the fixture topology.
4. **Resolved implementation defect, medium: native device aliases.**
   The prepared disko mirror has valid LZ4, zero reservations and a canonical
   mounted parent, but `zpool status -jLPp` omitted mandatory leaf identity and
   health fields. OpenZFS 2.4.4's
   [JSON metadata lookup](https://github.com/openzfs/zfs/blob/zfs-2.4.4/cmd/zpool/zpool_main.c#L1099)
   resolves metadata using the displayed device name; the observed `-L` spelling
   differs from the stored device alias. The
   [reader](../../../lilly/lib/lilly/host/zfs.ex) now requests `-jPp` and retains
   its own canonicalization and plain-block-extent checks. Mandatory fields are
   still required. [Parser regressions](../../../lilly/test/host/zfs_test.exs)
   explicitly reject missing leaf identity/health fields, and the
   [native suite](../../../nix/tests/machines/native-zfs/driver.py) adds export/import through persistent
   partition aliases. That complete native machine suite and the fleet's actual
   imported-disk preflight passed. The incomplete fleet run is not acceptance of
   its later guest scenarios.

5. **Resolved implementation defect, medium: avoidable sample latency.**
   The native I/O interval ran after capacity reads, and the completed report
   waited for another one-second tick before dispatch. Even the idle fixture
   alternated between eligible and stale hosts. The
   [collector](../../../lilly/lib/lilly/host/collector.ex) now overlaps one bounded
   native I/O task with capacity reads and reaps it on all normal/error returns.
   The report retains the start-of-observation timestamp; failed I/O stays
   unknown. The [runtime](../../../lilly/lib/lilly/control/runtime.ex) attempts
   dispatch when sampling completes while retaining one in-flight request,
   backoff, sequence suppression and fencing. The five-second admission limit
   and storage ownership/identity checks remain unchanged. The fleet now samples
   idle report age repeatedly and requires every observation to remain fresh.
   That idle-age check and initial real admission/execution passed; this is not a
   representative host-density or 100-replica throughput measurement.
6. **Usage-race correction verified; original differing properties unrecorded.**
   The final capacity race admitted exactly two of three requests for the two
   remaining slots. Five guests eventually ran; one returned a failed physical
   outcome. The retained-machine reproduction localized that failure to initial
   ZFS dataset preparation, before a dataset claim, child dataset or VMM launch attempt
   existed. That path hid observation errors behind a generic permanent failure.
   The exact differing properties from that run were not captured.

   Source review identified a recoverable case: guest writes can change usage
   between consecutive property reads. The [reader](../../../lilly/lib/lilly/host/zfs.ex)
   now returns `storage_busy` only when both trees independently satisfy accounting,
   all non-usage properties and dataset identities match, and the bracketing
   backing identities match. It still withholds the observation. Changed quota,
   identity, unsafe properties or malformed accounting remain permanent errors.
   [Dataset preparation](../../../lilly/lib/lilly/host/zfs_dataset.ex) and
   [disk preparation](../../../lilly/lib/lilly/vm/disk.ex) preserve that retryable
   result through the existing executor, before any launch attempt. They retain
   durable ownership and initialized-disk checks.

   New [reader cases](../../../nix/tests/machines/native-zfs/driver.py) mutate actual usage, quota and
   child GUIDs between reads; the [lifecycle case](../../../nix/tests/machines/zfs-lifecycle/driver.py)
   requires a usage race to leave the initial claim/dataset absent and permits a
   later normal preparation. The complete native reader suite passed, including
   all three between-read mutations. The complete lifecycle regression also passed.
   The final complete fleet run passed concurrent admission and all six launches.
   The test is not serialized, failed generations are not
   reset, and capacity observations are not injected.

7. **Resolved fixture defect: procfs magic links.**
   A jailed VMM's `/proc/PID/exe` link names `/firecracker` in its own mount
   namespace. The fixture incorrectly applied host-path `realpath` resolution,
   which failed before the browser began. The process helper now reads the link
   label and asks the kernel to stat the procfs link directly. Survival comparisons
   include executable device/inode as well as PID/start time, and still require
   the actual Firecracker process in the VM-owned cgroup. No production process
   observation or confinement checks changed. Actual running-VM snapshots passed
   in two subsequent runs; the retained-machine browser scenario also verified
   unchanged VMM identity across Marshall loss and recovery.

8. **Fixture coordination correction from source review.** The browser unit is
   `Type=oneshot` and waits for test-driver rendezvous replies. Its launcher must
   use `--no-block` so the driver can service those requests while the unit runs
   (see [systemd-run semantics](https://github.com/systemd/systemd/blob/v260/man/systemd-run.xml)).
   The in-progress run was explicitly interrupted before this known coordination
   deadlock; it is an interrupted attempt, not acceptance evidence.

9. **Resolved fixture permission failure.**
   The browser's first coordination-file write raised `PermissionError` through
   the framework's shared filesystem, before attempting login. Adding traversal
   permissions to the transport root did not resolve the failure. Coordination
   now uses an atomically replaced JSON state file inside the client VM, owned by
   the browser user in a private directory. The root test driver reads that file
   and acknowledges bounded sequence numbers locally. Shared transport permissions
   remain unchanged. Worker-failure detection reads only the sanitized public log.
   The local mailbox worked in the subsequent interactive run, which reached
   actual HTTPS login and sharing. Complete browser acceptance subsequently
   passed in the immutable fleet.

10. **Fixture listener correction from source review.** The network fixture's
    `cat` echo service requires a connected socket, while the original transient
    socket passed a listening socket. It now installs an `Accept=yes` socket and
    matching service template in the guest's `/run` directory, following
    [systemd socket semantics](https://github.com/systemd/systemd/blob/v260/man/systemd.socket.xml).
    An actual echoed response remains mandatory before peer-denial probes. The
    corrected listener and packet cases passed on all six retained guests and
    in the complete immutable fleet.

11. **Verified fixture database budget correction.** The first local-mailbox run timed out
    during member sign-in. The same unconsumed token subsequently signed in after
    an explicit wait for the form's LiveView connection. That wait is now in the
    fixture, but retained-machine reruns still encountered intermittent sign-in
    and unshared-terminal redirect failures. A navigation trace captured HTTP
    503; HAProxy observed repeated readiness failures returning 503 in 12 ms.
    The fixture had reduced each Repo pool to two connections, while readiness
    explicitly disables queueing. It now uses the module's production default
    of ten connections and the corresponding 43-connection deployment budget.
    This preserves the 500 ms readiness timeout, disabled queueing and every
    TLS/health check. The complete browser scenario then passed on retained
    machines with those pool settings. Backend selection also waits for verified
    public readiness before acknowledging a routing change. Bounded diagnostics
    retain only route categories and status codes, without URLs, tokens or page/
    terminal contents. Debug reruns mint fresh fixture links through the actual
    authentication library; they are not full-suite acceptance runs.
    The complete immutable fleet subsequently passed with the same pool settings.

12. **Recovery bounds verified; original blocker unproven.** The earlier fresh
    flake run passed enrollment, fresh native reports, idempotent guest execution,
    three browser logins, sharing and real terminal effects. After the driver
    abruptly stopped m1, the owner terminal did not return to watching within
    45 seconds. Other Marshalls logged database requests waiting beyond their
    15-second client timeout, and the proxy returned 503s. A dead client's open
    transaction retaining locks is a hypothesis; the run did not record the
    database blocker graph. The retained rerun passed browser recovery and its
    end-of-browser snapshot showed no old blocker. The observed failure's exact
    lock owner therefore remains unproven.

    Source review confirmed that client timeouts do not bound a dead client's
    open transaction on PostgreSQL. Runtime Repo parameters now request the
    server's 15-second idle-transaction timeout. The fixture deliberately takes
    a real VM row lock through the source-built release, publishes its backend
    PID, and abruptly stops its machine. It requires that backend to disappear
    within 20 seconds before continuing the existing browser assertions.
    This adds a deterministic failure case without changing the browser deadline,
    overriding fixture database timeouts or asserting that a timed-out commit
    rolled back. The negative baseline on the previous release reproduced an
    orphan backend still `idle in transaction`/`ClientRead` 85 seconds after
    machine loss; a separate `FOR UPDATE NOWAIT` probe confirmed its row remained
    locked. The driver explicitly terminated only that fixture backend for
    cleanup. Repeating the same isolated crash with the source-built corrected
    release caused PostgreSQL to log idle-transaction termination; the backend
    disappeared after 14.97 seconds and a new connection acquired the VM row.
    This verifies the parameter's real server effect; the complete immutable
    fleet's new deterministic case and complete browser scenario subsequently
    passed; that run later failed at the admission-count assertion. The initial
    transient-worker attempt exited before opening a transaction because its
    systemd PATH lacked the wrapper's utilities; the fixture now supplies the
    normal system profile PATH. See [PostgreSQL's session timeout semantics](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-IDLE-IN-TRANSACTION-SESSION-TIMEOUT).

13. **Open execution finding: later disk materialization.** The latest retained
    fleet passed browser recovery, then the third initial guest failed before the
    final capacity race. Its dataset claim was bound, and an owned single-link
    `.rootfs.pending` file had the requested logical size; no published disk or
    launch attempt existed. This differs from the earlier absent-claim failure.
    The [disk implementation](../../../lilly/lib/lilly/vm/disk.ex) now logs the
    fixed materialization utility and local error atom on failure, preserving
    existing results and deadlines. Investigation must distinguish copy/resize/
    flush/publication failures before changing retry or timeout behavior.

14. **Connection-capacity correction verified in the fleet browser case.** Repeated baseline
    crashes left 36 idle `marshall:m1` connections plus three idle operator
    connections while the two other Marshalls retained eleven each. New operator
    requests then failed with PostgreSQL `too_many_connections`. The idle-
    transaction limit correctly releases locks but does not cover idle sessions.
    Runtime TCP parameters now request 15-second keepalive idle, 5-second retries,
    three missed probes and a 30-second unacknowledged-data limit. The notifier
    inherits Repo configuration. The deterministic fleet case records all PIDs
    belonging to the doomed node and requires their disappearance within 35
    seconds, in addition to the transaction's 20-second check. Both checks passed
    for all 14 recorded backends in the immutable run's completed browser case.
    For baseline cleanup only, the retained fixture
    stops m1's live service before terminating its remaining sessions; it does
    not increase database capacity or count manual cleanup as recovery evidence.
    See [PostgreSQL TCP settings](https://www.postgresql.org/docs/18/runtime-config-connection.html#RUNTIME-CONFIG-CONNECTION-SETTINGS).

15. **Resolved implementation defect, high: unrelated guests pinned a
    deleted VM's dataset.** The retained stop/start case passed, including the
    same dataset GUID and retained disk commitment. Deleting the oldest guest
    then left its claim `deleting`, dataset present but unmounted, and Marshall's
    outcome `unknown`/`cleanup_failed`; its reservation was correctly retained.
    `/proc/PID/mountinfo` showed that the waiting `unshare` parents of two later
    guests still held that dataset's mount. The jailed VMMs had separate mount
    namespaces. The production launcher used `unshare --fork --pid --mount-proc`,
    which left the waiting parent in a private copy of all existing host mounts.

    [Unit arguments](../../../lilly/lib/lilly/vm/unit.ex) now fork into the PID
    namespace first, then let only the child create the temporary mount namespace
    before the generation guard and jailer. The waiting parent stays in the host
    mount namespace. Jailer still creates its own namespace and detaches its old
    root; PID isolation, launch fencing and control-group lifetime remain intact.
    The [fleet lifecycle case](../../../nix/tests/machines/fleet/driver.py) requires deletion of
    an older VM on each host while comparing all surviving VMM identities.
    The focused [nested guest regression](../../../nix/tests/machines/zfs-guest/driver.py) now
    defines the same older/later-VM case plus continued survivor disk access.
    Lilly's complete precommit and the full fleet lifecycle case passed after
    the change. The focused guest regression also passed in 696.22 seconds. No unrelated VM
    was stopped to make deletion pass. Existing helpers
    are not retroactively changed by restarting Lilly; they need their normal
    VM lifecycle to receive new launch arguments.

    Source references: [util-linux unshare](https://github.com/util-linux/util-linux/blob/v2.42.2/sys-utils/unshare.c)
    and [Firecracker jail root](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/src/jailer/src/chroot.rs).
    Recovery from an interrupted destroy is now implemented in
    [dataset deletion](../../../lilly/lib/lilly/host/zfs_dataset.ex). Only an
    already-deleting claim with a matching GUID and ownership can remount its
    child, and only at an empty canonical mountpoint without aliases. A separate
    [read-only check](../../../lilly/lib/lilly/host/zfs.ex) verifies the child's
    policy, identity and absence of descendants across two reads; it returns no
    capacity. Normal observation, content and destruction checks then run again.
    A new native lifecycle fixture interrupts the actual unmount phase and tests
    recovery plus rejection of unexpected files, changed ownership, unsafe
    compression and a replaced GUID with copied tags. The new gate passes;
    the complete native lifecycle machine rerun passed in 797.35 seconds. The
    first launcher fleet run predates this additional recovery path; the next
    complete successful fleet run includes it.

16. **Native fixture retry correction.** The new native lifecycle run passed
    sparse reuse, unknown-content/mount-alias refusal, interrupted create/copy
    and missing-initialized-disk refusal, then received `storage_busy` on normal
    preparation of the fourth fixture disk. The fixture asserted immediate
    success, although the accepted API now exposes this transient result to its
    production executor. Normal fixture preparation now retries only
    `storage_busy` within 60 seconds, preserving the same spec and retained state.
    Deliberate busy and rejection cases remain single attempts. The complete
    native rerun passed, including both new unmounted deletion scenarios. The
    original failure occurred before either new scenario.

17. **Open admission-count finding.** After the current immutable browser pass,
    four actual guests reached running state. The final three-request race did
    not return exactly two acceptances. No execution failure was reported in this
    attempt; the assertion did not retain returned counts or report ages. The
    next fixture records bounded host/pool ages and budget values before releasing
    the barrier and includes results plus a new snapshot on count mismatch.
    Admission and freshness rules remain unchanged pending that evidence.
    The next run admitted exactly two requests and reached six running guests.
    Before its final barrier the available host's report age was 1.88 seconds;
    the full host's was 2.94 seconds. The earlier failure's cause remains unknown.

## Remaining obligations

The [browser fixture](../../../nix/tests/machines/fleet/browser.py) verifies real
single-origin login, owner/member/stranger access, terminal effects, Marshall
machine loss, writer handoff, grant revocation and login revocation. Its driver
imports the runtime CA into the test user's NSS database and uses Chromium's
normal TLS verification. Public file rendezvous commands control backend routing
and machine loss; tokens stay in private client-VM files. Browser acceptance
passed in the complete immutable fleet. The
[network fixture](../../../nix/tests/machines/fleet/network.exs) verifies actual
serial-console probes in all six guests, local TCP listener positive controls,
controlled DNS/HTTP egress, all 30 directed guest-pair denials, host/protected
address denial and source-IP/MAC/VLAN/IPv6 ingress-drop counter checks. The Lilly
fixture explicitly protects its peer host's egress address and the controlled
protected destination. These packet cases passed in the complete immutable run. Direct privileged
console access in this network-only helper does not establish UI authorization;
that remains the separate browser fixture's obligation.
Other required machine suites retain their separately recorded results.

All QEMU machines share one physical failure domain. This fixture cannot establish
physical power-loss durability, live AWS/CA availability, PostgreSQL production
HA, representative IOPS or 100-replica load. The exact existing reference-host
configuration and external disko boot test remain unavailable. No production
host was activated or reformatted.
