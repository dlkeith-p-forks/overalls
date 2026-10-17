# Lilly owns every socket it uses

## Scope and architecture impact

This review covers [ADR-0184](../decisions/0184-lilly-owns-every-socket.md).
It replaces the descriptor passing of
[ADR-0182](../decisions/0182-unprivileged-lilly-beam.md) step 2 with
connect-on-behalf and an ingress bridge. The change touches:

- the hostd protocol: ops 8 and 9 are removed; op 12 `ConnectUnix`,
  op 13 `BridgeNetnsTcp` and the `Connected` reply are added;
- hostd's datagram receipt, which now accepts at most one descriptor and
  only with ops 12 and 13;
- a new privilege-dropped helper, `lilly-ingress-bridge` (typed-only
  utility 31), in host tools;
- Lilly's socket layer, which adopts its own sockets under a custody
  process;
- a fleet machine-test assertion.

Domain boundaries, persistence and Marshall are unchanged. The isolation
boundary narrows: guest ingress bytes pass through an unprivileged helper,
never through hostd, and the BEAM never holds a descriptor it did not
create.

## Findings

1. **Every passed descriptor leaked.** On OTP 29.0.6, `gen_tcp.fdopen/2`
   (either backend), `socket:open/2` (`dup` true or false) and `{fd, In, Out}`
   ports never close a descriptor the BEAM did not create. A positive
   control (a socket the BEAM created) closes normally. In the fleet test,
   Firecracker's API stopped answering about ten connections in, so
   `API.running?` failed and trust and adoption never completed. Production
   hosts leaked one descriptor per jail and ingress dial. Fixed by
   ADR-0184.
2. **A queued request could send a reused descriptor number.** If a caller
   timed out and closed its socket while its request waited in the hostd
   session process, the number might name another file by the time it was
   sent. The session now reads the number from the caller's live socket
   immediately before `sendmsg`, and refuses a closed socket.
3. **ADR-0182's invariant was inaccurate.** It said descriptor requests are
   lease-gated. They never were: they are gated by peer authentication and
   path and namespace policy. Corrected in ADR-0182.
4. **Custody death.** If a custody process died while its port was live, the
   number would be freed under the port. Custody is one receive with no
   other code, and is killed only with the application.

## Execution record (2026-10-17, uncommitted worktree)

- hostd: `cargo test` 45 passed; fmt and `clippy -D warnings` clean.
- lilly-ingress-bridge: 2 unit and 5 integration tests passed. The
  integration tests were also run under sudo, where
  `root_bridge_runs_as_the_given_uid` exercises the privilege drop; that
  run also passed 5 tests. fmt and clippy are clean.
- Lilly `mix precommit`: 569 passed (111 properties, 458 tests); Dialyzer
  `--force-check` reported 0 errors; contracts passed. The custody property
  test failed, as expected, when custody was changed to never close the
  socket.
- Machine tests: see the fleet record below.

## Fleet machine record (2026-10-17)

The `fleet` check is the first native composition to run the unprivileged
Lilly (uid 377) past guest readiness. Successive runs found five defects
ahead of the socket-custody subtest; none was in the socket path.

1. **Race fixture outgrew its pool.** The plain fleet pool was a fixed
   16 GiB, sized when the guest rootfs was below 4 GiB. At 4.29 GiB the
   reservation is 6 GiB (5 GiB root plus the 1 GiB workload bundle) and
   two reservations no longer fit the pool's free space, so "capacity
   races spend pending startup headroom only once" waited for two slots
   forever (342 polls; main fails the same way). The pool is now derived
   from the guest manifest with Marshall's sizing, and an evaluation-time
   assertion (`fleet-race-pool-fits-reservation`) refuses any rootfs that
   would leave the race outside its two-to-three-slot window. The race
   then passed in three of four runs (96–105 s).
2. **Trust starved after every Lilly restart.** After the release upgrade
   and the credential-only update, each adopted guest logged
   `vm.execution_deferred trust_unconfirmed` 25–46 times per process and
   never recovered. Observation itself passed: the new
   `vm.observation_failed` named only the expected startup
   `vmm_process_ambiguous`. Naming the trust stages (now closed
   `trust_*` deferral reasons) showed `trust_lock_unavailable`, which
   alternated with `provisioning_busy`. The trust path was the only
   readiness step taking the placement lease and the journal audit-lock
   in a single zero-wait attempt, so the actor's per-tick boot probe and
   outcome journal writes, which queue for up to two seconds, always won.
   The trust path, provisioning mutations and the trust and
   workspace-source journal writers now wait up to two seconds in hostd's
   FIFO queue (`trust-queues-for-placement-lease`). The next run logged no
   `execution_deferred` at all, including after the upgrade on both hosts.
3. **Stale terminal title acceptance.** Since 2026-10-13 the guest's OSC 2
   title moves to the session detail line and the page title keeps the
   generated session name (HLDD chapter 08). The browser test still
   expected the guest title as the page title. It now asserts the detail
   line and that the guest cannot set the page title.
4. **Empty boot-log pane.** The root boot-log writer created `boot.log`
   0600 owned by root, so the unprivileged BEAM's read failed and the
   terminal's boot-log pane silently stayed empty (stage "terminal boot
   log"). This was ADR-0182's open boot-log question, unanswered. hostd now
   passes the service uid as `--reader-uid`; the writer keeps every custody
   check and hands the verified file to that uid through its descriptor
   (`boot-log-private-to-its-reader`). The writer's tests cover the CLI
   grammar (Hegel oracle) and the hand-over as root and as a user; hostd's
   tests pin `--reader-uid` and `--owner-uid` to a non-root service uid.
   The root ownership was read from the writer's custody check (owner equal
   to its euid); a `terminal-fleet` diagnostic then showed the handed-over
   log as uid 377, mode 0600, holding the whole retained console.
5. **Stale boot-log marker.** The same diagnostic showed about 30 bounded
   boot-report lines (ADR-0154, since 2026-10-10) after
   `lilly-guest boot complete`. xterm's accessibility tree holds only the
   viewport, so the marker had scrolled out of the autoscrolled pane. The
   report may not be ordered before any unit
   (`guest-boot-report-observation-only`), so the console no longer ends
   with the boot-complete line; the test now expects the report's fixed
   final `lilly-boot-report: end`.

One run also failed a race launch on `vm.dataset_identity_probe_failed`
`parent_accounting` at `identity_after`, while the other race guest's
block-cloning `image_copy` ran on the same pool (183.04 s against a copy
ending at 183.35 s). This is the first native observation that ties the
previously unproven rejection to a concurrent copy. The strict check is
unchanged: the [browser-launcher review](2026-10-10-browser-launcher.md)
records that the rejection does not authorize a retry, and a retry window
needs measured evidence of how long the decomposition stays inconsistent.

### Passing fleet run (2026-10-17, local, `df94ad026`)

The full `fleet` machine test passed: all 20 subtests, test script finished
in 1893.48 s, exit 0. Among them:

- capacity races spend pending startup headroom only once (95.09 s) and
  generated races re-spend confirmed releases exactly once (354.19 s);
- actual Lilly release upgrades preserve running guests and authenticated
  control (226.20 s), and an encrypted credential-only update reconnects
  without replacing guests (208.51 s);
- verified terminal v2 sessions, sharing and reconnect across three Marshall
  machines (318.79 s), including the guest title and the boot-log pane;
- unprivileged Lilly releases every socket it uses (120.62 s);
- Marshall machine loss and database outage, Lilly daemon death, stop and
  confirmed deletion, isolation and revoked authority all retain or fence
  physical guests as specified.

The run emitted no `vm.execution_deferred`. It emitted 17
`vm.observation_failed` events, all `vmm_process_ambiguous` and at most two
per placement: each followed `lilly.unit_started` by about 20 ms, before the
jailer had executed Firecracker, or came from a unit being stopped. The
readiness poll retried and every guest confirmed; the event names a
transient launch state, not a fault.

### Passing user-SSH journey run (2026-10-17, local, `b55b4e1ad`)

user-ssh-journey-fleet passed all 15 subtests (test script 759.26 s,
exit 0). With Audi deployed, guest SSH reaches the guest only through Lilly's
ingress socket: `Executor.open_ingress`, `Sockets.connect_netns`, hostd op 13
and `lilly-ingress-bridge` in the VM namespace. The unprivileged BEAM has no
other route into the namespace. Audi recorded 47 opened guest SSH sessions,
including "Overalls CLI opens an interactive Firecracker Bash shell with
Starship and its home" (54.55 s), relocation (176.46 s) and reboot and
cloning (181.91 s). Its five `audi.ssh_denied` events are the zero-key and
revocation refusals the journey expects. Lilly emits no per-connection
ingress event, so the bridge's use is established by the code path and the
successful sessions, not by a log line.

## Remaining gaps

- `parent_accounting` rejections under a concurrent block-cloning copy
  remain unmeasured; the strict identity check still refuses them.

- The namespace dial and the bridge inside a real VM namespace are covered
  only by machine tests (fleet and user-SSH journey, both passing above).
- A hostd restart drops live ingress bridges. The user-SSH journey subtest
  that restarts hostd under a live session is present but not yet run.
