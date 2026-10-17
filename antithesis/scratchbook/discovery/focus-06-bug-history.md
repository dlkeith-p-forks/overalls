---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Bug history and density

## Summary and scope examined

The strongest repository regression signals cluster around custody transitions,
recovery scheduling, classification of uncertain results, and the difference
between logical accounting and physical evidence. Marshall and Lilly dominate
reachable change history; quieter satellites share some of their highest-risk
transport and authority machinery. Quiet history therefore does not establish
correctness, especially for recently extracted libraries and recently introduced
browser features.

This independent pass examined root guidance/contracts, architecture overview,
current source and tests, architecture reviews, and Git history reachable from
the stated baseline. All eight releases were included: Marshall, Lilly, Audi,
Brady, Enrico, Galileo, Porsche and Ziggy. It also examined shared Protocol,
diagnostics/request accounting, Lyra, browser/guest paths, native helpers,
backups, updater custody and Nix verification. The staged retirement companions
were treated as scope changes, not as a research template. No retired Antithesis
catalog, discovery report, mutation patch or deleted-tree content was consulted.
No tracker, remote repository, production host or external reference was used.

This was source/history research, not a fresh test execution. Recorded passes and
counterexamples below are attributed to repository reviews and kept at their
documented scope. A commit title or incident narrative alone was insufficient:
selected mechanisms were checked against the production diff and a discriminating
regression, or explicitly retained as an unconfirmed operational lead.

## What the history can measure

For `git log HEAD --no-merges --since=2026-09-01`, there are **1,044 non-merge
commits**. Counting a commit once per source root it touches gives:

| Release | Commits touching root | Subjects containing fix/correct/repair |
| --- | ---: | ---: |
| Marshall | 569 | 97 |
| Lilly | 177 | 45 |
| Audi | 70 | 5 |
| Brady | 17 | 2 |
| Enrico | 15 | 3 |
| Galileo | 22 | 2 |
| Porsche | 36 | 6 |
| Ziggy | 33 | 5 |

Protocol has 74 touching commits and seven matching subjects; Lyra has 31/six;
Nix has 496/71, including 445/65 under `nix/tests`. Backups has nine/two and
auto-update 33/five. These are overlapping **change and attention indicators**,
not defect counts or comparable defect rates. Subjects include test repairs;
large checkpoint commits contain multiple features/fixes; source sizes and
component ages differ. No filed-issue density can be inferred without a tracker.
Commits from other branches after the baseline were excluded.

## Corroborated regression mechanisms

### 1. Retired durable identities must not look like replayable live objects

Commit `82763c15` changes Marshall's Galileo configuration history match from
any retained integration to a live, nonarchived integration. Archived names now
check management authority, then refuse `name_unavailable`. The competing
explanation would be intentional name reuse or a caller's malformed request;
the source contract explicitly closes removed names, and
`marshall/test/marshall/galileo_test.exs:179` exercises valid identical replay,
changed payload and changed-key attempts against an actually archived row. It
requires no new receipt, unchanged header/history state and nondisclosing refusal
to a foreign actor. Porsche's client adds the same closed reason rather than
creating atoms from server text. This is a confirmed historical mismatch between
retained history and live configuration, not evidence that current removal is
broken.

Useful variants are concurrent configure/remove, account retirement between
authorization and commit, delayed old responses, and retry after origin-node
loss. Preserve complete receipt/history inventories instead of checking only the
returned error. The separate
`2026-10-05-admission-lost-reply.md` review is test expansion, not a defect report:
real committed admission survives worker/BEAM result loss and cross-node replay,
but its witness is not HTTP response loss or physical VM dispatch.

### 2. Opening socket ownership had a real completion-window hole

The `2026-10-06-opening-socket-custody.md` review names a source ordering that
can be inspected: an opener transferred the socket before reporting completion.
Worker death in that window left a client-owned transport absent from retirement
state. The current registration callback in
`protocol/lib/overalls_protocol/control/client.ex:110` records passive socket
custody before handoff and binds both reference and worker. A gated actual-worker
loopback property at `protocol/test/control/opening_socket_property_test.exs:12`
observes closure before/after transfer, failed completion and stale registration;
Lilly has the parallel terminal property. A fixture merely timing out would not
discriminate; here the independently owned socket remains observable.

The review records an instrumented original-source counterexample and repaired
properties, while expressly withholding real TLS/native/hosted acceptance. A
close frame followed by EOF corrected an earlier erroneous immediate-EOF oracle.
Prior consumer passes predating the custody repair are not proof for that repair.
The regression family spans all control-socket consumers and terminal streams.

### 3. Permanent refusals and recoverable outages need different histories

`ea7235b2` repairs shared Control.Client requests that returned `:disconnected`
after credential/version refusal. Current requests retain `:refused` or
`:unsupported_version`; Audi, Lilly, Galileo, Porsche and Ziggy map these through
their closed adapters. The loopback test serves real 401/426 upgrade responses
and separately exercises a fenced close, so an ordinary connection outage is not
mistaken for the same case. `b6496b73` changes ordinary reconnect cap from 30 to
four seconds: its test repeatedly fails dials, then restores the listener and
requires timely reach. The old cap's interaction with host-report freshness is
a source-supported regression lead, not a newly measured fleet outage.

Audi `5f8093da` addresses the opposite classification error: a single transport,
HTTP or already-expired renewal result killed an otherwise valid stream before
its existing deadline. Its three-second owner/guard test survives the first
unreachable renewal but still dies at expiry. Definite denials, identity/binding
changes and invalid messages remain immediate refusals. Generate recovery,
revocation and expiry concurrently; do not let retries extend old authority or
turn a permanent refusal into an availability measurement.

### 4. Storage cleanup can strand availability without violating ownership

Lilly commits `dd802f42`, `e203bbc7`, `e08f5d74`, `50021c04`, `db88cb48` and
`c4732a35` form a concentrated October 9–10 template/standby recovery cluster.
The production narrative says a three-second `zfs set` timed out during remount,
leaving an owned unmounted standby that withheld pool accounting. That narrative
is not independently verified here. The discriminating source mechanism is
present: current `StandbyDisk.remount/2` validates one of the recorded owner
shapes before remount, mutations use a 120-second bound, and sweep prioritizes
claiming records while continuing after another record fails. The earlier diff
halted the entire sweep on its first failure.

`lilly/test/lifecycle/standby_disk_test.exs` covers durable state/binding histories;
`nix/tests/machines/image-template/probe.exs` and driver supply native standby
seams. The observability source review explicitly qualifies the newly modified
slow-claim/interrupted-unmount fixture's author-reported pass and missing exact
capture. Target interruption before/after owner-property change, rename and
journal write; mix a poisoned record with recoverable neighbors; verify pool
freshness returns only after actual native inventory becomes confirmable.

### 5. A direct child exit is not descendant completion

Enrico `9a71e12a` replaces `waitpid(None, ...)` with the all-child `wait(...)`
path. Its real-helper history creates a separately witnessed `setsid` descendant,
checks actual process group/session and inherited repository/admission lock FDs,
then tests caller EOF, deadline and ordinary leader completion. Unresolved cleanup
must return failure and refuse successors until actual descendant death; neighbor
owners remain unchanged. This excludes the competing explanation that only the
fixture's direct child or shell still exists.

Current Lilly host-lock, source-export and transfer-stream helpers have the same
all-adopted-child completion concern (`lilly/native/*/src/lib.rs`), with separate
native histories. Backup `f26e0d47` fixes another variant: direct leader exit
previously skipped group retirement. It pins unreaped PID/PGID identity, signals
the group, and scans every thread before permitting snapshot cleanup.
`nix/tests/evaluation/backup-workflow.py` independently verifies leader-exited
readers and a zombie leader with live worker threads. Same-group backup evidence
must not be promoted to cleanup of escaped sessions or whole service cgroups.
This is the strongest cross-language recurring failure pattern in the sample.

### 6. Counted release is not physical buffer release

Native terminald `c4b1a727` fixes two observable allocation mismatches. Pushing
onto a full deque before truncation could allocate beyond the retention limit;
pop-before-push avoids that growth. Natural EOF returned a ring reservation while
a stalled viewer still retained backing through its Session reference; current
retirement explicitly empties backing. The property independently checks deque
allocation and the retained weak Session, then drains and counts every queued
NUL byte. It does not mistake a zero accounting counter for released memory or
claim process RSS/native guest isolation. Relevant files are `ring.rs`,
`session.rs` and `retired_ring_tests.rs` under `nix/packages/terminald/src`.

Combine overwrite, ring growth, natural EOF, explicit kill and viewer reconnection
with concurrent neighboring PTYs. At browser level, `27f4f748` separately fixes
a selected detached pane losing its reattach attempt; browser-state and fleet
fixtures exercise it. An attached UI indicator alone should never establish
physical terminal ownership or byte delivery.

### 7. Valid success replies and progress rates need exact protocol evidence

`a2d9e6e1` fixes diagnostics spool interpretation of the pinned Collector's valid
HTTP 200 protobuf `0a00` reply. The official decoder now accepts absent/zero
rejected-span counts and retains custody for malformed/partial failures. Current
`elixir/diagnostics/native/spool/src/main.rs:804` tests the exact reply over Unix
transport; the file's eager-drain property at line 575 checks 32 accepted batches
against a two-second deadline. Previously every successful batch incurred a
250-millisecond sleep. The repository review records a discriminating independent
64-at-eight-per-second experiment: 32 pending before correction versus zero
afterward, while preserving the difference between sampled health and SQL.

These mechanisms rule out a blanket “Collector outage” explanation for those
specific reproductions. The review also rejects invalid diagnostic fields caused
by a Nix driver `check_output=False` helper; those fields prove no root cause.
Test ACK loss, poison delivery storage, archive replay/expiry and producer
independence together. Keep diagnostic fail-open behavior separate from request
accounting's explicit measurement-gap custody: their extracted libraries have
different contracts.

### 8. Software identity and runtime material differ during updates

Updater `4981f99f` repairs an equal-Nix-closure fast path that only verified live
roles, skipping changed secret bundles. Current runtime stages every bundle and
compares file names/bytes; only exact equality keeps verify-only behavior.
Independent secret preparation units stop together after their consumers stop,
while dependent consumers retain individual checked stops. Unit tests distinguish
changed/added/missing secret files and stuck active units. They do not establish
successful physical rotation under all service dependency graphs.

Lyra `b93abe8b` fixes a candidate spawn failure returning before rollback.
`start_candidate` restores the saved executable for failed spawn/unregistered
candidates; successfully registered candidates retain identity. Real supervisor
tests cover spawn boundaries and original-inode restoration. The native guest
review leaves Ubuntu failure recovery, real-command drain and I/O/power-loss
open. Ziggy `38eb208c` similarly changes failed/partial discovery from waiting
the fifteen-minute healthy interval to a five-second initial retry. Its real
unreachable-origin test observes repeated failures within eight seconds; it does
not demonstrate successful provider recovery. Exercise the updater→Ziggy→Lilly
readiness chain with secret-only rotation and staggered service recovery.

## Quiet areas and strong testing leads

The diagnostics and accounting roots each have only one touching extraction
commit. Their quiet history reflects an October 10 move, not absence of prior
bugs; account for predecessor paths such as `observability/native/spool`.
Current accounting tests already distinguish foreign completion tuples, actual
worker death, once-only settlement and uncertain ACK gaps. Extend those histories
through the real recorder socket rather than recopying the pure arithmetic model.

Brady's relatively quiet history contains a confirmed admission policy mismatch
(`04392b0c`): rotating resolver views were required to agree for intercepted
HTTPS. The regression generates agreeing/disagreeing/error DNS views while
current upstream code still requires peer/certificate/hostname verification.
Plain HTTP and unverified TLS exceptions keep DNS matching. Retest divergent DNS
with cache reuse, origin identity changes, unknown-length bodies and interrupted
publication; do not call a benign DNS difference a provider defect.

Browser distribution, personal editor, durable guest identities and stopped-only
relocation are recent material changes, not automatically bug fixes. Their
extensive review histories contain fixture/capacity/startup failures with bounded
or unresolved attribution. Use captured successful family/provider scenarios as
reachability seeds, then perturb authority, reconnect and storage boundaries.
Low bug counts in Enrico/Galileo/Porsche/Ziggy also say little about shared
transport regressions or production use frequency.

## Assumptions

- Reachable Git history and checked-in tests are the available historical record;
  commit naming is incomplete and cannot supply real defect density.
- Documented captures describe their recorded revision, not an automatic pass
  at this baseline. Source/test presence is not execution evidence.
- Timing/partial-failure variants above are regression research leads, not claims
  of current defects. Real VM isolation, physical storage and independent-host
  availability require their own native witnesses.
- This temporary report changes no component contracts or architecture. No source
  edit, harness creation, test run or hosted launch occurred during this pass.

## Open Questions

- Which socket/refusal/custody properties have current merged all-consumer and
  authenticated native TLS evidence? `(partial: local properties and historical
  consumer gates are separately documented; this pass did not execute them)`
- Can recoverable standby records progress beside poisoned records under sustained
  pool load and interrupted journal/mount writes? `(partial: recovery ordering is
  source-supported; modified native fixture evidence has attribution limits)`
- Which escaped-process cleanup paths have a bounded production service-cgroup
  guarantee rather than local adopted-child/same-group evidence?
- How should legitimate unknown measurement gaps be bounded when recorder/trace
  custody and application recovery fail together?
- What incident frequency and workload exposure explain quiet satellites? No
  repository-only evidence establishes a comparable defect-rate denominator.
