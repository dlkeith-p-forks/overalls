# Enrico aggregate refresh admission

This review preserves chronological findings and intermediate failures. Earlier
pending statements describe those revisions; final verified scope appears below.

## Finding and architecture impact

Reviewed ADR-0097, root and Enrico contracts, Manager, supervision, HTTP, Git,
and Marshall's Enrico client/worker. The concurrent-refresh bound required by
`enrico-bounded-reads` was absent. HTTP connection limits bound connections,
not long-running Git owners. The 8 GiB memory limit can kill an overloaded
service; it does not establish admission control.

The initial repair caps active repository refreshes at eight inside the serialized
Manager admission path. This is an implementation of the existing bounded-work
requirement, with no new public configuration or durable account authority.
The fixed limit permits a small amount of parallel Git work (each runner already
limits pack work to two threads), while refusing additional work before spawning,
creating attempt state or issuing a measurement ticket. It is not a throughput
or physical memory acceptance claim.

Existing active/retained replay is checked before saturation. A different attempt
for an already active repository retains its busy response. New work at the cap
returns unavailable; HTTP now preserves that as 503 instead of calling it an
invalid request. Marshall's existing client classifies non-success transport
responses as service_unavailable; the durable worker retries transient failures.
The capacity cap introduces no separate remote retry protocol.

## Work in progress

The initial generated callback property checks exact refusal state, no measurement
outcome and unchanged fixture filesystem at and beyond the cap, together with
replay and same-repository busy precedence. A second property starts eight real supervised workers with controlled Git
executables held at clone. Fixed success/death release histories precede three
generated victim/refusal histories. At saturation, Manager and token-authenticated
Plug HTTP requests preserve exact state and refuse with 503; the target has no
clone call or temporary clone directory. Release of one actual worker permits
the previously refused attempt exactly once. Final settlement conserves nine
outcomes, including exactly one failure for the death case, and retires monitors
and generations. Focused execution passed one property, seed `751543`, in 1.1
seconds, exit 0. Log: `/tmp/overalls-enrico-real-saturation-focused.log`.
The callback refusal property separately passed in 0.4 seconds at that seed.

These tests exercise actual task ownership with controlled Git, and authenticated
Plug dispatch rather than TLS sockets. Full component and documentation gates
remain pending. An initial precommit refused two contiguous native contract
blocks; a blank line now separates the declarations. That failed invocation
provides no full-gate evidence. Packaged TLS, native Git resource consumption,
physical quota and Marshall durable overload retries remain separate.

## Restart and native ownership findings

Fresh review reproduced a supervision lifetime mismatch: Task.Supervisor preceded
Manager under the outer rest_for_one supervisor, so Manager death could leave
workers executing while its replacement admitted new work. The repair groups
Task.Supervisor and Manager under Enrico.RefreshSupervisor with one_for_all.
The task supervisor also caps live children at eight, including the interval
between sending a result and the process actually exiting.

A fixed six-case matrix (Manager or Task.Supervisor death, each with 1/7/8 held
workers) followed by three generated histories passed one focused property,
seed `751543`, in 1.4 seconds, exit 0. It independently monitors the old Manager,
task supervisor and all BEAM workers down before replacement admission.
Log: `/tmp/overalls-enrico-restart-fixed-matrix.log`. Expanded steady-state
success/Git-failure/death release and retained replay at saturation passed one
property at that seed in 1.3 seconds, exit 0. Log:
`/tmp/overalls-enrico-three-outcome-saturation.log`.

An independent native PID probe then failed the first fixed restart witness:
the controlled Git shell remained runnable after all old BEAM owners terminated.
The fixture records validated numeric native PIDs and checks their /proc states
before admitting replacement work. The regression failed after 5.7 seconds,
seed `751543`, exit 2. Log:
`/tmp/overalls-enrico-native-owner-retirement-probe.log`. BEAM retirement alone
therefore does not fence native Git writes. The new failing regression must remain
until native command ownership is repaired; this change is not ready to commit.
The superseded full component gate was deliberately cancelled for this repair;
its interrupted result is not passing evidence.

## Required native repair

The direct Port runner must delegate Git execution to a pinned native owner.
Caller EOF, timeout and output overflow must kill and reap the private Git
process group before releasing a stable repository lock. Native admission must
retain an eight-owner ceiling across Manager/service lifetimes. Lock descriptors
must remain held by surviving descendants so uncertain cleanup cannot grant a
successor competing write authority. Existing one-hour fetch, ten-second reads,
16 MiB blob and 64 MiB path-scan bounds must remain supported; Lilly's existing
locked-command protocol cannot be substituted unchanged because its timeout and
output limits are smaller. Inspect and reuse the reviewed native lock patterns
without coupling the production Enrico release to Lilly's Elixir application.
Add native caller-death, timeout, overflow, contention and successor histories,
plus packaged service wiring and precise recorded scope before full verification.

## Native owner prototype

The new `enrico/native/git-owner` prototype executes the existing Git argument
vector under a private process group with parent-death fencing, bounded polling
and at most one 64 KiB forwarding chunk. Caller EOF, timeout, overflow and normal
exit kill/reap the child group. Eight stable global slot files retain native
admission across BEAM lifetimes; exclusive stable per-repository locks retain
conflicting write authority until native cleanup. Lock descriptors survive exec
so uncertain surviving descendants retain refusal instead of granting a writer.
Reads use global admission without conflicting repository write locks, preserving
published-ref reads during a fetch. No production Elixir dependency on Lilly is
introduced; the native lock and parent-death patterns follow its reviewed helper.

The Rust prototype passed compilation and all-target Clippy with warnings as
errors. The formerly failing native PID restart probe passed the same seed
`751543`, one property in 2.0 seconds, exit 0, across the fixed six-case matrix
and three generated histories. Log:
`/tmp/overalls-enrico-native-owner-repaired-restart.log`. This result precedes the
read-lock refinement and does not establish final source or packaged acceptance.
Helper-specific properties, native read/write coexistence, packaging, final
component/Dialyzer and documentation gates remain required. No commit is ready.

The initial five native histories now passed in 5.57 seconds, zero failures:
caller EOF with actual PID retirement and stable-inode successor; eight-slot
saturation with one-slot recovery; write contention with retained read access;
timeout and exact/overflow output; linked/nonprivate lock refusal before child
execution. All-target Clippy passed with warnings as errors. Logs:
`/tmp/overalls-enrico-native-owner-final-five-tests.log` and
`/tmp/overalls-enrico-native-owner-final-five-clippy.log`. An earlier fixture run
assumed absent `/bin/bash` and failed before useful witnesses; the shell now
requires an explicit existing pinned path. An earlier Clippy run also rejected
two unused fixture items. Neither failure is passing evidence.

The source-built Nix package runs the same native tests, rustfmt and Clippy with
locked dependencies and a supplied store-owned Bash. The Enrico service PATH
includes that package. Its build is pending. Additional helper-death/descendant,
blocked-output caller death and configured large-output families remain to be
verified, together with final Elixir/component and handbook gates.

## Fresh native review and final local histories

Fresh read-only review found filesystem cleanup, publication and administrative
removal outside the native writer lock. These now delegate fixed `rm` and `mv`
argument vectors through the same repository/admission gate. An occupied owner
must refuse before deleting a clone directory. A new application property holds
an independently started native writer and inspects exact retained clone bytes,
refused refresh/removal and eventual cleanup after owner retirement.

Reads do not conflict with the repository writer lock, but share the eight native
command slots. At full native saturation reads also refuse; the saturation
property now witnesses that refusal without child execution. Read availability
claims are limited to remaining command capacity.

The final local ten native properties passed in 10.41 seconds, zero failures.
All-target Clippy passed with warnings as errors in 0.38 seconds. Logs:
`/tmp/overalls-enrico-native-owner-ten-tests-repaired.log` and
`/tmp/overalls-enrico-native-owner-ten-clippy.log`. These add exact/overflow
16 MiB and 64 MiB production output families with concurrent byte checking, and
helper SIGKILL with independently witnessed surviving-descendant lock retention,
refusal and explicit retirement/recovery. An initial SIGKILL fixture falsely
treated the previous child's PID file as evidence of successor execution; clearing
that already-recorded witness fixed the oracle. The failure is not passing evidence.

Helper SIGKILL does not automatically retire grandchildren. Inherited descriptors
retain authority until the remaining descendants die; service-cgroup recovery and
escaping-descendant acceptance remain separate. Native package, final application,
Dialyzer and handbook gates are still pending. No commit is ready.

The final source-built helper package passed in 44 seconds, archive
`1790999826195-1977084-0.jsonl`, running all ten properties, rustfmt and all-target
Clippy with locked dependencies. Its first run used parallel Rust test threads
and Hegel reported nondeterministic saturation/SIGKILL histories; the package now
serializes fork-based histories, matching the local execution. The initial build
failure does not establish a production defect or passing evidence.

The existing packaged `enrico-service` NixOS machine check passed in 106 seconds,
archive `1790999929442-2076193-0.jsonl`. It exercises the changed release and
native helper service PATH against an isolated authenticated HTTPS Git fixture:
clone, published reads, refresh, preserved history after force-push, source-outage
refusal with retained published bytes, and recovery. This establishes packaged
normal/failure composition in one local QEMU/KVM machine; it does not establish
saturated restart, uncertain descendant/cgroup cleanup or physical availability.

The fresh follow-up reviewer inspected native source/tests, fixed Git mutation
delegation and package wiring and found no remaining concrete blocker. The
reviewer performed no extra execution; passing evidence is recorded above.

Final focused application execution against the source-built native helper passed
all eight Manager history properties, seed `751543`, in 254.6 seconds, exit 0.
Log: `/tmp/overalls-enrico-native-final-focused.log`. This includes exact native
writer refusal before clone cleanup/removal effects, the Manager/Tasks restart
matrix, fixed success/Git-failure/death saturation release and prior generation
histories. Complete component precommit and final documentation gates follow.

## Final gates

Complete Enrico precommit passed fourteen checks (eleven properties, three tests),
seed `775108`, in 358.0 seconds. Forced Dialyzer passed in 5.03 seconds with zero
errors, skips or unnecessary skips. Compiler, formatting, contracts and catalogued
logging passed. Log: `/tmp/overalls-enrico-native-final-precommit.log`.

All-file prek, Ruff format/lint and ty, ADR structure, handbook receipts,
generated options/coverage/views and Nix HLDD passed. The Nix handbook archive is
`1791000283360-2308548-0.jsonl` (27 seconds). These structural/static results do
not expand the runtime scope above. ADR-0097 remains partial: saturated packaged
restart/cgroup recovery, escaping descendants, physical quota and durable Marshall
retry composition remain open. Final architecture and semantic contract review
preserve public-source-only Git, stable ownership, bounded work and explicit
uncertain-cleanup refusal. No credential or raw command diagnostic was added.
