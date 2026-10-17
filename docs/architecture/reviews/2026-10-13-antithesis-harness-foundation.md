# Antithesis harness foundation

## Scope and architecture impact

This review examines the experimental `antithesis/` foundation at base
`c835eb1017d24a001215c319373fa4204d64269b`, the eight selected Mix
dependencies and application startup hooks, Lilly's compile-selected control
adapters, optional Nix source-built contexts, and the default Compose control
core. The [native prerequisite review](2026-10-13-antithesis-prerequisites.md)
keeps its own derivation-bound release, ZFS I/O and failed service-role evidence.
Concurrent changes require a final source-identity check before any run claim.

The harness adds a **build-selected test variant**, assertion transport and
disposable control topology. It does not revise PostgreSQL/Ash authority,
ADR-0017's physical ownership and receipts, ADR-0033's NixOS machine acceptance,
or ADR-0149's separation of diagnostics from control. Ordinary package imports
default `antithesisSdk = false` and `antithesisGuest = false`; the latter requires
the former. All eight applications select the SDK only under
`ANTITHESIS_HARNESS=1` while compiling, and their one startup `reachable`
callsite follows successful supervision and catalog declaration. These callsites
show startup reachability, not service readiness. The root flake exports optional
source-built context packages; it does not place this test graph on deployed
hosts or change their replica count. No replacement ADR or implementation-status
change follows from the foundation.

## Boundaries and findings

The default [Compose graph](../../../antithesis/config/docker-compose.yaml)
declares PostgreSQL 18, a separate migration process, two Marshall processes,
one Lilly, a reviewed-CLI enrollment operator and one workload owner. Database,
Marshall and Lilly state volumes are distinct. PostgreSQL creates disposable
database/TLS/signing secrets at runtime. The operator uses Marshall enrollment
and publishes a nonsecret fixture plus a separate read-only Control credential
copy for the workload. The workload's [bootstrap](../../../antithesis/workload/core/bootstrap.py)
checks the migrated primary through a TLS-verified SELECT-only
[oracle](../../../antithesis/workload/core/sql.py), every declared Marshall HTTPS
readiness endpoint, and an enrolled, connected v4 host with a fresh report before
calling `setup_complete` once. Unavailable observations delay setup; timeout or
early stop exits without signaling. A local unit test substitutes probe outcomes;
it does not show that this graph has started together.

The hosted [pool decoder](../../../antithesis/lilly/lib/overalls_antithesis/lilly/pool_config.ex)
accepts only an existing configured path and typed storage identity, labels its
backend `:controlled`, and does not inspect ZFS. The
[collector](../../../antithesis/lilly/lib/overalls_antithesis/lilly/collector.ex)
measures cgroup inventory but emits unavailable pools and `capacity: nil`.
Runtime forces `execution_ready: false` and local readiness false. Marshall
requires fresh pool credit and execution readiness for ordinary admission; this
graph cannot schedule a real placement. The
[controlled executor](../../../antithesis/lilly/lib/overalls_antithesis/lilly/controlled_executor.ex)
can durably publish requested operation identity but always retries as
`execution_unavailable`. Its initial implementation incorrectly synthesized
delete/stop completion from that marker; the [runtime review](../../../antithesis/verification/runtime-review.md)
records the correction. The selected
[guest executor](../../../antithesis/lilly/lib/overalls_antithesis/lilly/guest_executor.ex)
is compile-selected: the default controlled core retains unavailable guest
callbacks, while an optional integrated TCG host requires exact image, command
and boot identity, owned QEMU/backend processes and current port-1024 readiness
before an emulated running outcome. A separate inner host measures a real ZFS
member and uses TCG-specific ownership that retains host/pool binding and unit
fences without the native KVM probe. These paths are authored source, without
a passing composed guest journey or native lifecycle settlement.

The [fallback SDK](../../../antithesis/sdk/README.md) emits reviewed JSONL
assertions through a C writer. Its [independent review](../../../antithesis/verification/sdk-review.md)
found and verified local corrections for malformed JSON admission, disabled
status, undeclared dynamic evaluations and short-write poisoning across BEAM
and helper restarts. A private lock/inflight marker refuses another helper after
an uncertain partial write. A complete write with a lost reply remains ambiguous;
the workload owner must not retry setup automatically. Local append/readback
does not prove hosted capture, and the single-writer lock does not give separate
OS command processes a shared SDK endpoint.

The researched [property catalog](../../../antithesis/scratchbook/property-catalog.md)
has 104 primary properties. The static
[roster scanner](../../../antithesis/verification/assertions.py) now finds
153 authored SDK callsites and 26 matching primary catalog messages, leaving
78 missing primaries, with no duplicate callsite or mismatched primary
messages. None of the
104 properties has complete workload, independent oracle, fault and hosted
execution evidence here. The scanner checks literal declarations and records
catalog gaps; it is not source coverage. The BEAM fallback supplies no BEAM
branch coverage. The C SDK writer is assertion transport, not instrumentation
of the SUT. Rust native coverage instrumentation and symbols remain pending.

The optional guest and storage-router contexts provide separate TCG/QEMU
emulation source. The [guest boot record](../../../antithesis/verification/guest-boot.md)
now captures one local serialized TCG placement with the production NixOS guest
adapted to q35. The first image reached multi-user and port 1026 flush but not
readiness because its NIC was `enp0s3`; the repaired `net.ifnames=0` image
returned exact port 1024 readiness at epochs 3, 4 and 5. Epoch 4 reused the
same qcow2 overlay, and an offline `debugfs` read after a clean stop confirmed
the retained `/etc/machine-id` bytes matched the first ready boot. `qemu-img
check` found zero errors. The final formatted runner at epoch 5 also reached
readiness, and owned QEMU/backend processes and TAP were cleaned up. The local
TCG guest boot record passed exact port 1024 readiness at epochs 3, 4 and 5.
The [JSON record](../../../antithesis/verification/guest-boot.json) binds image,
runner, tool configuration, manifest and source SHA-256 identities; current
guest source hashes match that record. This is a passing **local software
emulator** result, not a composed Lilly `GuestExecutor` run, a hosted
guest baseline, native Firecracker/KVM/ZFS proof, workspace delivery or physical
host isolation. The separate
[storage-router record](../../../antithesis/verification/storage-boot.md) now
captures a passing direct local TCG smoke: real Linux ZFS mirror and Brady,
HTTP/HTTPS interception and origin-off replay, acknowledged QMP reset, retained
pool/parent GUIDs and a 41-byte marker, plus reapplied 64 MiB cache quota and
refquota. It does not exercise its container entrypoint, hosted graph, strict
production source validation, real guest attribution or physical power-loss
durability.
The storage-router TCG smoke passed with retained GUIDs and a 41-byte marker after reset.
The [integrated-host boot record](../../../antithesis/verification/integrated-host-boot.json)
separately identifies two stopped TCG attempts with unavailable health, then
an exact third Nix image that booted and sampled real ZFS GUID/capacity and
kernel cgroup CPU/memory values. A fourth, private-service image
`mk3rk6hwwqvc9gy7wm5yz4gcga0hxr88` also built and booted, sampled real
ZFS/cgroups, completed runtime PKI preparation and returned a private guest
image witness with workspace source v2. The third TCG inner-host boot recorded real
ZFS and cgroup measurements with `execution_ready: false`. Its sample also
reports `connected: false`; the fourth remains disconnected and unready too.
Enrollment, authenticated Control, admission,
nested guest readiness, terminal accounts and crash recovery remain unverified.
The private 9p witness observed the first three image identities; a working
witness transport does not establish guest execution. The optional private
host/guest source selects inner Audi, Ziggy and Galileo with runtime PKI. Its
bootstrap CA has no retained signing key; public roots require boot-bound
GuestTrust delivery and a durable exact-boot receipt. The private host image
has the separate built-and-measured fourth-boot scope above; private service
credentials and serving health remain pending. Twelve adapter tests and forced
Dialyzer passed; nine focused crash-actuator tests passed without a QEMU crash.
The full integrated-mode native suite attempt failed at 7/559; it is not a
full-suite pass. These
component checks do not establish private-service startup, terminal behavior
or a hosted result.
Keep both emulator scopes distinct from the KVM NixOS suites in ADR-0033 and
the control-only hosted core.

## Verification and gaps

Source and contract inspection covered the staged and unstaged selection diff,
new adapters, Compose and entrypoints, workload bootstrap/oracle, SDK review,
and researched roster. A fresh static scan returned 104 catalog entries,
153 authored callsites, 26 matching and 78 missing primary entries, with no
duplicate callsite or primary-kind mismatch; the earlier
18/102/no-duplicate snapshot is superseded.
The SDK reviewer independently compiled/probed the C writer and reported eight
local SDK tests passing after correction. The runtime reviewer recorded the
integration owner's two focused controlled-adapter tests, three ordinary
readiness checks, guest-selector compile and harness Lilly forced Dialyzer; that
review did not independently run them. These are local source/component scopes.
The four `antithesis-{pg,workload,marshall,lilly}-context` Nix exports passed
in 853 seconds, captured by wrapper log
`1791885795567-1011564-0.jsonl` (completion status 0). That build snapshot
predates later source and runner edits; it establishes those four selected
closures at its captured derivations, not current Compose startup or a final
all-context build. The guest result above has its separate exact source and
artifact identities; the router has its own captured direct-run identity. The
final ordinary Protocol gate passed 262 checks with forced Dialyzer, and the
final ordinary Lilly gate passed 559 checks with forced Dialyzer at runtime
source `90572c59…`. Focused integrated guest checks passed seven tests and
forced Dialyzer; controlled-adapter checks passed eight tests and compilation.
These component gates do not verify Compose or a hosted run. No first remote
baseline, hosted assertion ingestion, mutation sweep, composed guest bridge
or complete catalog implementation is recorded.
The local container policy rejected the original public PostgreSQL image. A
pinned Nix PostgreSQL 18 replacement passed direct startup, verified-TLS oracle
read, non-TLS refusal and retained restart. A clean Compose diagnostic then
started PostgreSQL/migration, both Marshall replicas, enrollment and Lilly
healthy. The non-serving operator completed a real three-account/three-passkey
fixture, with exactly three rows of each by read-only SQL and no listening
socket. The local Compose diagnostic created exactly three users and three passkeys.
That diagnostic still waited at `host_connection_or_report`: SQL showed a
connected v4 host session but `report_sequence` 0 and no `reported_at`. It
did not emit setup. A subsequent fresh diagnostic4 Compose project reached a
connected, fresh Control v4 report at sequence 44 before serial commands, and
the workload journal recorded `INFO Antithesis setup complete` at 14:33:49 UTC.
Six packaged Control serial commands exited zero and emitted 13 true SDK
assertion records; a later read-only SQL observation found a connected, fresh
v4 report at sequence 392. This is a monotonically increasing report sequence,
not a command count or physical capacity. The command outputs and image IDs are
recorded historically in `antithesis/runtime/diagnostic4-control-commands/README.md`
and summarized in the tracked [local Compose acceptance record](../../../antithesis/verification/compose-local-acceptance.md);
the Compose startup log is
`/tmp/overalls-antithesis-diagnostic4-up-20261013.log`. Four selected-manifest
runtime dependency hashes differ from the actual workload image, so this is a
passing local control-core execution of identified image bytes, not a frozen
manifest baseline or hosted SDK ingestion. Its report demonstrates that the
actual controlled container published a current observation, but the controlled
pool still provides no native capacity or execution readiness. The captured
workload image was `e5700675b9121be9f523503247120c62a6f3745a9e41f2e94a1909130e9cd18d`,
Marshall was `cf6a56e6880cd95fa1070a2e7d9ac96b46822c57b2013c9b54c0a7e1aec8b00b`,
and Lilly was `668b56e6e3ed4bfcf86626ad02043572242d79a9e0ec056f5606ac17faa5c2ca`.
The selected manifest hashed to
`828855c860b225be317d5bdf951ed1bb26b95fa2166b438084be47f92be5c3f1`;
the mismatched dependencies were `core/bootstrap.py`,
`core/profile_readiness.py`, `repository/client.py` and
`repository/runtime.py`. Earlier logs are
`/tmp/overalls-antithesis-diagnostic3-up-20261013.log`,
`/tmp/overalls-antithesis-lilly3-rootjournal-20261013.log`,
`/tmp/overalls-antithesis-marshall-context3-20261013.log` and
`/tmp/overalls-marshall-corrected-build3-20261013.log`.

Before a baseline, verify all selected source-built contexts, Compose config
and a full local `compose build`/`up`: real migration, two HTTPS endpoints,
operator enrollment, authenticated Lilly Control/report and single workload
setup. Freeze image/source/command/assertion identity before a remote run.
Separately implement measured native pool and guest effects, bounded recovery
inventory, source-specific Rust instrumentation, and property workloads with
independent oracles. Any hosted result must retain the exact image, source,
assertion and execution receipts; a local SDK or static check is not a substitute.

Architecture impact is limited to optional harness build variants and an
experimental isolated runtime graph. ADR-0017, ADR-0033 and ADR-0149 keep their
existing accepted rationale and implementation statuses. The ADR-0153–0158
guest/editor/source/identity chain gains no acceptance from this foundation.
