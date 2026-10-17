# Guest CLI supervisor recovery verification

## Scope and architecture impact

Campaign improvement 028 preserves ADR-0104's accepted recovery decision and
ADR-0100's private execution fences. One branch and worktree add real supervisor
process histories and a bounded NixOS guest failure journey. The production change
repairs candidate spawn failure during activation and boot reconciliation; no
protocol, authorization, storage authority or deployment policy changes.
ADR-0104 remains accepted with partial implementation. No production deployment
or new Inception testing/validation is included.

## Reviewed failure and correction

On base `bb83bfc2fed99e9f0a6d2bccc263d3f671561c8c`, the real packaged immutable
supervisor exits before rollback when the installed candidate cannot execute.
The isolated baseline used
`/nix/store/cd0kknv9zpgk4c1yvaqj9blkiy618r66-lyra-0.1.0/bin/linux-amd64`, SHA-256
`348eccf57caa49b221ffafe09fa49802cf7cb63d563d932e7b561a289c81c699`.
An invalid ELF had its actual digest recorded, a previous executable remained
saved, and `applied` identified the previous executable. The supervisor exited
with status 1, leaving the candidate installed and the previous inode untouched.
This reproduces an implementation violation of ADR-0104 and
`guest-seed-supervisor`; a normal restart alone cannot recover it.

`start_candidate` now handles spawn failure through the same restore-and-restart
path as an unsuccessful registration result. Both initial reconciliation and
live activation use it. Successful registration still records `applied`; a
subsequent restart of that applied executable does not select its predecessor.
Registration/status I/O errors retain their previous propagation behavior.
The ninety-second registration deadline, graceful command drain, immutable seed,
verified private transport, digest/100 MiB limits, rejection cooldown and Marshall
fences are unchanged. No semantic rollback after registration is added.

Contract review traced `supervise`'s two candidate starts and normal restart path,
`spawn_executor`, `registered`, `mark_applied`, `restore_previous_at`, activation,
seed installation and `agent::run`'s actual ready-file write after registration.
The CLI entry point and both guest systemd units retain their existing authority
and lifecycle boundaries. Contract formatting checks syntax only.

## Generated process histories

[The Rust integration fixture](../../../lyra/tests/guest_supervisor.rs) executes
the actual source-built supervisor in private user, mount, PID and network
namespaces with a temporary chroot. Only its Nix store is read-only bound; guest
sentinels and fixed managed/runtime paths belong to the disposable root. A killed
namespace init terminates fixture children; the fixture drains its controller
and checks captured PID/start identities are absent or nonlive before removing
its root. The registration-timeout test separately observes the failed candidate
process and requires it to be dead after restored registration.

Two Hegel properties generate executable revision identities and failure/boot
histories. Eight recovery examples are configured; four active-drain examples
are configured. Candidate format errors, missing interpreters and early exit
cover live activation and crash-after-rename startup, restoring the exact prior
bytes and inode. Each recovery allows a fresh valid candidate after restarting.
The active-drain property retains the installed bytes until the fixture command
finishes. Three additional Rust tests enumerate all six failure/boundary controls,
exercise the real ninety-second no-registration deadline, and retain a registered
candidate across supervisor restart. These are **five test-runner tests**, not
five generated properties or eighteen independent tests.

The fake candidate's ready file is explicitly a synthetic registration receipt.
This fixture does not prove Marshall authority, private TLS, Firecracker isolation
or real guest tool execution. Existing Hegel digest/path/size/staging/corruption
and desktop installer-base properties retain their narrower helper scope.

## Native journey and evidence boundaries

[The strict native driver](../../../nix/tests/machines/guest-cli-recovery/driver.py)
uses nine NixOS machines on one physical KVM host and a real NixOS Firecracker
guest. An ordinary owner shares the VM with an ordinary operator; that operator
completes a deterministic-provider model/tool round trip. Fixed console actions
then inject an invalid executable and an executable that never registers, each
at the crash-after-rename boundary. They measure candidate and prior digests and
prior inode before restarting the real immutable supervisor.

Recovery assertions require exact prior bytes/inode, rejected/applied state and
unchanged supervisor PID. Actual Marshall records must show a distinct executor,
increased fence and invalidated predecessor. A subsequent completed `read_file`
command must join its real executor with the same fresh fence. The owner then
requests normal deletion and the driver checks archival plus service/dataset
absence. No ready receipts, bindings, fences or tool results are manufactured.
The deterministic model provider and direct file injection remain fixture seams.
This journey does not test private artifact authorization or delivery.

The [2026-09-23 review](2026-09-23-private-guest-cli-updates.md), introduced in
`c18073a07a9ba6395f359e0d86bfc0e47315e82e`, retains its recorded successful
NixOS/Ubuntu private periodic replacement and continued fenced tool-work scope.
It is not new failure-recovery evidence. The architecture overview's stale
pending-two-distribution sentence is corrected to distinguish that historical
execution from this recovery work and unobserved live rollout.

## Executed verification

- Baseline probe: actual packaged supervisor, isolated filesystem/processes,
  expected defect observed; `/tmp/verify028-baseline.log`.
- New fixed failure-boundary test against the same baseline package: fails at
  `supervisor exited before recovery` in 1.05 seconds. The owned test binary was
  then restored byte-identically; `/tmp/verify028-regression.log`.
- Corrected process suite: **5 passed in 90.21 seconds**.
- Pinned Rust 1.97.1/Cargo 1.97.0 full locked offline suite: **76 passed**, no
  failures or ignored tests. The five new integration tests took 90.77 seconds.
  All-target Clippy with `-D warnings` passed in 8.78 seconds.
- Runtime code and fixture capture after integrating published maintenance work:
  base `2d66e76dd9a4935045f5daeb1b7ae9716ddd8740`, staged tree
  `3a5cdc0f1774bcc5425203d6cb224ec41b1e7cf0`. Subsequent helper-contract prose
  clarifies that arbitrary registration/status I/O errors still propagate;
  executable logic is unchanged.
- Final Nix Lyra sandbox gate: **76 passed**, including the five strengthened
  supervisor tests in **90.27 seconds**, with exact failed-candidate PID/start
  death assertion. All-target Clippy passed in 7.89 seconds. Derivation output
  `/nix/store/csi94bw3i00fj2i0dlzab074bpn358id-lyra-tests-0.1.0`, 141 seconds;
  archive `/home/ghuntley/.local/state/nix/build-logs/1790396033483-904869-0.jsonl`.
  Its source differs from the earlier native capture only in test fixture
  portability/lifetime assertions and helper-contract prose, not runtime logic.
  The final fixture is byte-identical to
  `/nix/store/3vpbdlpk4chx179sb2af0nyphmj5mpgk-source/tests/guest_supervisor.rs`,
  SHA-256 `56d4e40409e9fd674dbab7d55e1818f1bceae6133dd7bd0275e5dd33e26a2654`.
  The current production source differs from that tested source only in the
  helper contract's prose wrapping and wording.
- Strict native driver build passed both composed Python typing and lint. The
  installed script contains the exact current driver fragment; the packaged
  Galileo helper matches source byte-for-byte, SHA-256
  `9f91504a126e10039d83bbff00036ab116795416cd6c21d4eb6c75c7bf92e07f`.
  Native runtime derivation:
  `/nix/store/ll8rqk6agvdb0dj45mmv0nk1ydvm6bd5-vm-test-run-kittens-guest-cli-recovery.drv`.
  Driver: `/nix/store/k0jv5wkk1payv1nl5x2izkvcz67qdc4g-nixos-test-driver-kittens-guest-cli-recovery`.
  Composed script SHA-256:
  `24dc276f56d6f99dfb87368f1481cca186ca859db86c9127e75ab2b6abd8beab`.
  Build archive `1790395503743-727222-0.jsonl`, strict check lines 6587–6592.
- Native recovery journey passed all six stages, exit 0. Its frozen runtime
  derivation is the one above; output
  `/nix/store/ha7pfj17rh78v2mbqyfnwp9fv1zxzn7s-vm-test-run-kittens-guest-cli-recovery`,
  archive `/home/ghuntley/.local/state/nix/build-logs/1790396223108-953351-0.jsonl`.
  Fleet boot took 51.47 seconds; actual admission 122.23 seconds; initial shared
  operator real tool control 53.90 seconds; invalid-format recovery and fresh
  fenced tool work 12.19 seconds; registration-timeout recovery and fresh fenced
  tool work 106.99 seconds; owner deletion and physical cleanup 9.41 seconds.
  The six stages sum to 356.19 seconds. The log separately reports
  `run the VM test script` at **356.21 seconds** (line 31937),
  `test script finished` at **356.56 seconds** (line 31961), and driver cleanup
  at **2.71 seconds** (line 32038). The whole Nix command took 365 seconds.
- All fifteen captured Nix, driver, VDE and QEMU PID/start identities were absent
  after native completion, independently confirmed by the coordinator.
  `/tmp/verify028-native1-pids.json`, `/tmp/verify028-native1-cleanup.json` and
  `/tmp/verify028-root-native-cleanup.json` retain the exact owned identities and
  audit. The unrelated external ZFS runtime was untouched. Developer namespace
  fixture inventory is empty after the documented interrupted-root cleanup.
- Final independent ADR structure, contract formatting/discovery and Nix
  `python-static` checks passed. Composed native driver typing/lint retains its
  captured passing evidence above. Published improvement 033, merge
  `8af8164fb798878cfd6c27c5afb9210807310366`, was integrated before final handbook
  generation. Its configured-Hegel correction recognizes the actual attributes;
  no test marker or property classification workaround was added. The only
  integration conflicts were the review index and campaign rows; both entries
  are retained. This integration changes shared verification and documentation,
  with no application runtime delta or new native execution.
- Integrated ADR, reviewed handbook receipts, generated options/coverage/views,
  complete contract formatting and all-file `prek run --all-files` passed in
  the pinned development shell. Ruff format/check, ty and all eight logging
  catalogs passed. Nix `hldd` and `python-static` passed in 20 seconds, archive
  `/home/ghuntley/.local/state/nix/build-logs/1790397909213-1262701-0.jsonl`.
  These structural/static gates establish no additional runtime acceptance.

Initial fixture iterations are retained: the first chroot lacked its complete
Nix tool PATH; next, shell detection inspected an exec-optimized `readlink`
process and selected coreutils as interpreter. Corrected detection resolves the
shell executable directly and supplies canonical Nix tool directories. The slow
failure replay was interrupted only after checking exact ownership; its process
was absent/nonlive after interruption. Earlier samples had drained their fixture
roots. `/tmp/verify028-process2-interruption.json` records the interruption.
The first Nix sandbox gate additionally rejected a nonrecursive store bind:
Nix inputs are separate locked submounts. Recursive binding preserves all pinned
inputs and passed the subsequent full sandbox gate. No tests were skipped.
One temporary root from the interrupted faulty-shell replay was found in the
final audit, identified by its exact old synthetic interpreter/seed, and removed
after confirming no live process used it; the cleanup is recorded in
`/tmp/verify028-interrupted-root-cleanup.json`.
These fixture failures do not change the independently observed product defect.

## Remaining gaps

Ubuntu failure recovery, active real guest-command
drain during replacement, power-loss/filesystem I/O faults, independent physical
hosts and production rollout remain separate. Registration is readiness, not
code attestation; registered-but-bad semantic rollback is deliberately absent.
The namespace tests require Linux user/mount/PID/network namespace support and
Nix-provided tools. They never create guest sentinels or managed files on the
working host.
