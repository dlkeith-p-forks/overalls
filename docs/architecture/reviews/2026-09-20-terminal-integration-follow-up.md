# Terminal integration follow-up

- Date: 2026-09-20
- Scope: merge of origin/main lifecycle work with terminal v2 and follow-up audit
- Decisions: ADR-0074, ADR-0082, ADR-0083, ADR-0084

## Corrected implementation gaps

Guest output previously bypassed WebSocket framing. The
[channel](../../../lilly/lib/lilly/terminal/channel.ex) now delivers output only
through the stream, waits for each delivery acknowledgement, and rearms guest
reads after pending replay/output is drained. Attachment socket ownership is
transferred from guest manager through stream to channel. Replay is delivered
before live bytes. The [socket regression tests](../../../lilly/test/terminal/channel_test.exs)
exercise actual masking, frame decoding, replay order and acknowledgement bounds.

Stream reconnect retains guest managers, and actor authority is revalidated
before their reuse. A fresh manager can recover a live attachment token over
the authenticated guest control connection; the token never crosses into
Marshall. Guest control sockets are retained after successful commands.

Read-only viewers cannot resize shared PTYs. Unanswered host-stream controls
expire after five seconds, with at most 256 pending requests. Successful guest
listings reconcile exited registry rows with one atomic closed receipt; failed
listings are not interpreted as empty inventories. Registry candidates are
captured before the guest listing so concurrent creation is not retired.

The daemon rejects entropy failure rather than generating predictable tokens,
atomically reserves ring capacity, and bounds concurrent viewers to eight per
session and 128 per daemon. Either attachment worker failing to spawn tears
down the attachment. OSC 52 selectors are restricted to the supported clipboard
and default selectors.

## Verification

- Lilly precommit: 356 passed (41 properties, 315 tests), zero Dialyzer errors.
- Marshall precommit: 740/742 passed (61/61 properties), with the two recorded
  Audi baseline failures; zero Dialyzer errors. Browser tests: six passed.
- Rust tests: 30 passed; Clippy with warnings denied passed.
- After host-local token recovery: all 12 focused Lilly terminal checks passed
  (two properties), forced Dialyzer passed, and Rust's 30 tests and Clippy passed.
- ADR structure and local links passed for 75 decisions.

## Post-publication code review

Checkpoint `51cfd017` includes origin/main through `139cd45d` and was pushed to
remote main. The terminal ADRs were renumbered to 0082–0084 to avoid upstream's
accepted guest-toolset, teams and certificate decisions. A migration timestamp
collision with the team-owner constraint was found by the merged database suite;
terminal registry minimization now uses `20260920120000`. Fresh-database Marshall
precommit reached 776/778 (64/64 properties), with the same two Audi failures and
zero Dialyzer errors. Both guest derivations evaluate with the merged toolset.

Subsequent direct review of `session_ended` found that it discarded queued output
before closing viewers, violating the original byte-fidelity requirement. The
writer now drains those queues on natural EOF. Reader and writer own separate
duplicated descriptors, preventing descriptor reuse while the other worker is
still using its socket. Socket sends have a five-second timeout; failed pump
startup cleans up the session and returns failure rather than publishing success.
Child processes are reaped after termination rather than left for an unimplemented
later reap. A real PTY/login-shell/Unix-socket test verifies final output arrives
before EOF. Rust tests reached 31 passing and Clippy passed, including after the
blocking-reap adjustment; the Nix native-check derivation also built successfully
before that final adjustment. ADR validation passes for 82 decisions.

## Outstanding implementation and acceptance

### Creation and Firecracker boundary review

Direct tracing of relay requests found a map update requiring a nonexistent
`channel` key, and reply-key matching that did not recognize `created`, `listed`
or `boot_log_data`. Synthetic stream fixtures had bypassed both defects. The
host stream now inserts its allocated channel correctly and matches these replies.
A frame-level create regression covers the actual relay request shape.

Creation also opened an invisible attachment with no browser consumer. Creation
now leaves the PTY detached, preserving idle semantics and viewer capacity;
only explicit browser attach creates a data channel. The per-owner cap now
matches the 64-session VM cap, allowing the original fifty-terminal target.
Database-backed tests exercise 64 sessions and refusal of the 65th; a native
daemon test creates fifty real PTYs and checks that all have zero viewers.

The vsock dialer was missing Firecracker's `CONNECT 1075` handshake, sending
terminald frames directly to the VMM's Unix socket instead. It now requires a
bounded valid `OK` line before terminal authentication. Socket tests cover
both control/attach negotiation and rejection without sending terminal authority.

Validation for this follow-up: Marshall precommit passed 818 checks (64
properties); Lilly precommit passed 373 (43 properties); both forced Dialyzer
runs reported zero errors. Rust passed 32 tests and Clippy. A channel test's
100 ms receive window failed under the concurrent full suites; bounded waits
now use the same one-second budget as the socket operations, and the rerun
passed. These are component/native tests, not a full Firecracker/browser run.

### Browser authority follow-up

Following publication of the guest teardown changes, direct endpoint-to-handler
review found `Viewer.init/1` accessed `options.vm`, although `TerminalSocket`
never supplied it. Tests had supplied this extra field and concealed the actual
browser-path crash. The viewer now accepts the endpoint's real option shape.

The same review found no ongoing login or Cedar checks after attachment. The
upgrade now verifies the stored browser login and passes only its JTI to the
viewer. Input and resize revalidate authority, and idle/output-only viewers
revalidate every second. Login or sharing revocation closes the existing viewer.
Database-backed regressions exercise both revocation paths and initialize without
the obsolete `vm` option. These implement the existing live-authority obligations
of ADR-0083/0084; they do not establish browser/KVM acceptance.

On the subsequently merged upstream code, Marshall's full precommit passed with
816 checks (64 properties, two excluded); upstream fixed the previously recorded
Audi failures. A stale unused terminal alias in `customer_isolation_test.exs` was
removed before this successful rerun. Forced Dialyzer reported zero errors.

This is an integration checkpoint, not milestone completion. Lost create replies
still need end-to-end idempotent recovery. Registry retirement currently happens
on successful listings/open attempts rather than a background guest-exit feed.
Worker-spawn failure injection and teardown stress still require adversarial
verification beyond the implemented cleanup and final-output regression. The real
KVM/browser suite, 50-session acceptance, clipboard UI, resize, truncation and
reconnect acceptance have not been executed for this revision. All three terminal
ADRs remain partial until their required behavior and evidence are complete.

## Implementation-first continuation (not yet validated)

The user explicitly deferred testing/builds until implementation is complete.
The additions below have only been reviewed from source; previous green counts
do not cover them. There is still no complete passing terminal-fleet run.

- Durable create intent precedes side effects, binds actor and parameters, and
  counts pending/cancelling intent against the 64-session VM budget. Guest
  create-once/status/cancel operations and host/peer routing now exist. Duplicate
  in-flight requests no longer overwrite the first caller's pending reply.
- AshOban reconciliation captures registry candidates before successful guest
  listings, recovers an orphaned create by request ID, and retains cancellation
  intent until guest acknowledgement or retirement of its placement/epoch.
  Database read errors are not treated as VM absence. System-observed closure
  uses a nullable audit actor rather than inventing human attribution.
- The browser retains create identity through retry/reconnect, gates input and
  resize on acknowledged rw attachment, removes retired panes, preserves local
  titles, handles kill clicks before selection and retrieves bounded boot logs
  with UTF-8 continuity. Recovery and idempotency regression cases were added.
- Host streams monitor attached viewers, cap channels, and check current
  execution/credential authority at hello and renewal. Peer requests reject
  reuse of an occupied one-owner relay. Partial WebSocket frame handling and
  failed-handshake socket cleanup were tightened.
- Failed Lilly guest controls now retain or explicitly dispose newly started
  managers in returned stream state instead of leaking untracked linked managers.
  Guest diagnostic creation events no longer include the guest username.
- Further browser implementation preserves binary xterm input, disposes a lost
  WebGL renderer, reconnects previously selected panes rather than every listed
  session, and scopes connection-status updates to the active pane.
- Moving the network client into `protocol/` contradicted its pure-boundary
  contract. Transport now stays in each independent application, with explicit
  SSL runtime dependencies. This preserves the accepted shared-codec boundary.
- Overalls declares the existing private fleet HTTPS origin/CA for peer routing;
  configuration is source-only and has not been activated or evaluated here.

### Remaining implementation findings

1. Authenticated peer publication now takes the execution host lock across its
   authority check and directory publication, closing the identified delayed-hello
   race in source. Incoming/outgoing peers now share a process-owned 512-slot
   budget, monitor budget loss, and accept one control or attachment. Pending/idle
   connections expire, and data/resize are scoped to their acknowledged mode and
   binding. These changes remain unverified.
2. Kill recovery now persists an Ash state-machine request before dispatch and
   requires a scoped guest acknowledgement or authoritative absence before
   atomic confirmation/archival/audit. Background jobs retry pending kills.
   Listing observers reload kill state under the archive lock to handle a kill
   requested after their registry snapshot. Obsolete placement retirement does
   not claim a physical kill. Regression cases cover lost replies, the listing
   race and retirement attribution; none has been executed yet.
3. Four Ash snapshots have now been generated for events, opening intents,
   sessions and stream locations. Source comparison reconciles their fields,
   defaults and constraints with the terminal migrations. Applying those
   migrations and validating retention remain deferred. Reconciliation schedules ten VM jobs per scan
   batch, and each VM job attempts one kill and one opening before advancing
   durable ID cursors. Bounded-work and retry-fairness acceptance remain pending.
4. New create controls require coordinated consumer support. Creation now probes
   authenticated guest recovery support before reserving a slot. Unsupported
   commands are distinct from unknown request IDs, report a guest-upgrade notice,
   and never fall back to non-idempotent creation. A missing/incompatible host
   response fails closed. Native rollout and daemon-restart acceptance remain open.
5. Complete typing/format/contracts checks, regression execution, real Firecracker
   and Chromium terminal acceptance, and the full fleet run remain deferred.
   The earlier full-fleet guest-network positive-control failure is unresolved.

Architecture impact: recovery/persistence, live stream authority and independent
frontend routing under ADR-0082–0084; lifecycle-state modeling follows ADR-0074.
All affected implementation statuses remain partial. No new completion claim is
made from source inspection or added test code.

### Artifact generation and guest-boundary continuation

`devenv shell -- env -u PGHOST -C marshall MARSHALL_TEST_PORT=55601 MIX_ENV=test mix ash_postgres.generate_migrations --snapshots-only --domains Marshall.Terminal`
generated the four terminal snapshots, compiling Elixir modules as a prerequisite.
The domain-limited generator printed removal prompts for unrelated snapshot
tables; inspection afterward showed only the four new terminal snapshot files
and the already-intended terminal migrations under `marshall/priv`. No migrations
were generated or applied by this snapshot-only command. This is artifact
generation, not application tests, Dialyzer, migration execution or fleet acceptance.

Further source changes close newly dialed guest sockets on failed authentication
or attachment negotiation, normalize transport failures to the declared error
type, and raise the bounded guest-control payload ceiling to 8192 bytes so all
64 maximum-length usernames fit a listing. Guest listings validate counts,
geometry, identity and UTF-8 before entering the shared stream. New regression
cases cover unsupported recovery, handshake cleanup and full listings.

Manager reuse now includes the actor-authorized boot challenge fingerprint,
preventing an ordinary reboot with unchanged placement/epoch from indefinitely
reusing stale authentication. Successful listings prune cached tokens for ended
sessions. These later lifecycle edits have not been compiled or tested yet.

## Published checkpoint and resumed testing

Implementation commit `8423f42a` was merged with the latest upstream logging
changes as `e7a030ec` and pushed to `origin/main`. Required commit hooks passed
after adding catalogued cancellation, directory and closure diagnostics; outcome
events remain outside their owning transaction.

Resumed validation found and corrected a nullable strict-boolean condition that
rejected every first create, an obsolete actor-lookup test, and a Rust oversize
fixture still encoding the previous 4096-byte limit. The next pass produced:

- Protocol precommit: 192 passing checks (72 properties), zero Dialyzer errors.
- Lilly precommit: 376 passing checks (43 properties), zero Dialyzer errors.
- Rust: 35 passing tests and Clippy with warnings denied.
- Repository-wide prek: all logging, Ruff formatting/lint and ty hooks passed.
- Focused Marshall terminal/LiveView/transport suite: 45 passed.
- Full Marshall: 830/833 passed, 64/64 properties; eight terminal browser and
  four dashboard browser tests passed. The run was interrupted during Dialyzer.

Ash notification warnings prompted use of Ash-managed transactions. The three
full-suite failures then identified rollback atoms wrapped as unknown Ash errors;
the coordinators now use the existing Ledger transaction/rollback pair to retain
their public error contracts and post-commit notification behavior. That final
normalization change still needs its rerun.

The native terminal-fleet build reached machine startup/enrollment before the
user's new publication request interrupted it. No terminal-fleet or full-fleet
success is claimed. Architecture impact remains a correction to the accepted
recovery and notification contracts of ADR-0082–0084, not a new decision.

### Further validation and native fixes

Commit `e813ba7e` published the admission/transaction fixes. The full Marshall
suite subsequently passed all 833 cases; its remaining Dialyzer finding was a
redundant nil comparison behind a binary guard and was corrected. With the added
system-authorized reconciliation action regression, Marshall now passes 834
cases (64 properties, two excluded) and forced Dialyzer. Protocol passes 192
cases (72 properties) and Dialyzer. Lilly passes 378 cases (43 properties) and
forced Dialyzer, including the new hello-deadline tests. One earlier concurrent
run exceeded an existing credential test's 500 ms wall-clock assertion; the
isolated full rerun passed without weakening the assertion. Rust passes 35 tests
and Clippy. Ten terminal browser-state tests and the configured repository-wide
prek hooks pass. A direct `ty check` used an incomplete Python environment and
reported missing imports; the prescribed prek invocation passed with its pinned
dependency environment.

Native investigation produced three substantive corrections:

1. **Guest capability inheritance (ADR-0082).** Root PTY shells inherited
   `RestrictAddressFamilies=AF_VSOCK AF_UNIX`, blocking ordinary IPv4 connections.
   Guest service mount/device restrictions also affected child shells. Both
   guest units now preserve guest-user capabilities while retaining resource
   limits, restart policy and host-authenticated vsock admission. Profile egress,
   cross-guest denial and spoofing checks passed on both hosts, including after
   a real Lilly upgrade. This reconciles the service implementation with the
   accepted guest-terminal requirement; it does not weaken physical host guards.
2. **Input bursts and attachment lifecycle (ADR-0083/0084).** Payload-free browser
   counters showed a socket closing during a typed command. Bounded input batches
   reduce per-character mailbox pressure and discard unsent input on disconnect.
   Duplicate tickets cannot replace live/in-flight attachments, and incomplete
   attachment attempts expire. A queue/drain mutex inversion was independently
   found and fixed; fixing it alone did not resolve the observed browser failure.
3. **Hard machine-loss detection (ADR-0083).** Machine power loss leaves half-open
   TCP connections. Sequenced one-second host heartbeats have a five-second
   acknowledgement deadline; initial hello also expires. Peers monitor directory
   incarnation/expiry, and LiveView heartbeat intervals are five seconds.

The dedicated `terminal-fleet` run passed in **337.37 seconds**, including real
guest typing, view-only sharing for operator collaborators, serving-machine loss,
reconnect, grant revocation and login revocation. The later initial-hello timeout
edge case is additionally covered by Lilly's unit gate. The broad `fleet` run
passed network/profile checks and Lilly upgrade preservation but exceeded the
30-minute command budget later. The longer rerun then found that the final
partition fixture still blocked browser port 443 instead of the private fleet
listener on 5443. Correcting that fixture preserved its stale-capacity and guest
survival assertions.

The complete **`fleet` check now passes in 1089.57 seconds**, including terminal
sharing/failover/revocation, profile networking, real release and credential-only
updates, database outage, provisioner daemon loss, storage cleanup, isolated-host
admission denial and credential revocation. Logs were captured privately in
`/tmp/opencode/terminal-full-fleet-partition-fix.log`; the passing terminal-only
run is in `/tmp/opencode/terminal-fleet-heartbeat.log`. These are local execution
artifacts, not checked-in terminal captures.

No production activation, exhaustive escape-sequence support or 50-pane browser
acceptance is claimed. ADR-0082–0084 remain partial despite the passing named
component and native fleet suites.
