# Cross-platform browser editor status (2026-10-18)

## Scope and architecture impact

This review reconciles the personal browser editor in [ADR-0153](../decisions/0153-official-source-browser-editor.md) and the durable guest identity boundary in [ADR-0158](../decisions/0158-durable-guest-identities.md) with the multi-OS admission rules in [ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md). It records what the current source and retained evidence establish for each guest family and reviews [ADR-0200](../decisions/0200-windows-browser-editor-candidate.md)'s additive Windows editor candidate contract. The selected Windows catalog and current authorization fences remain unchanged; native acceptance is independent of the new codec support.

The editor capability is an immutable image property. A package, a catalog row, a guest-agent name, a workstation client, or a successful terminal/SSH journey cannot grant it. Marshall still requires a current stored login, current write authority and the existing owner policy; Lilly and the guest broker still enforce the existing transport and execution fences.

## Current status

| Guest family | Editor decision and implementation status | Evidence and remaining boundary |
| --- | --- | --- |
| NixOS and Ubuntu | Version-4 Linux images may carry the reviewed editor descriptor and broker. ADR-0153 remains accepted with partial implementation. | The source/package and application authority are recorded, but there is no current-revision native browser sign-in, edit/readback and recovery receipt in this review. Historical package, fixture and earlier fleet records retain their original revisions and do not qualify the current trunk or production. |
| Arch Linux and AlmaLinux | They retain the version-4 Linux contract. The shared foreign-Linux builder can carry the editor package, broker and descriptor; an old image without those bytes must refuse. | The retained Alma suite passed its twelve native stages and the Arch diagnostic replay passed twelve stages, but both are bound to captured image/source revisions. The Arch broker-restart 502 remains unresolved, and neither result establishes a current-revision or production browser journey. |
| FreeBSD (`freebsd-v1`) | Editor remains false. ADR-0190 permits only the reviewed native subset after complete image admission; its version-6 manifest has no editor descriptor. | Native transport, service, growth and recovery evidence does not implement an editor broker, editor package or browser admission. Physical isolation, broader recovery and fleet acceptance remain separate. |
| OmniOS/illumos (`illumos-v1`) | Editor remains false. Native admission qualifies only the exact reviewed image and its bounded non-editor subset. | Native service, growth, transport and crash records do not implement the editor package, broker or browser path. Physical recovery, isolation and fleet acceptance remain open. |
| Windows | Existing `windows-v1` remains editor false by [ADR-0171](../decisions/0171-windows-guest-agents.md); version-5 firmware manifests reject editor descriptors. ADR-0200 adds the separate unselected `windows-editor-v1` candidate with manifest v7 and portable bundle v4. | Source/bundle staging retains `editorCapability = false`. Portable broker tests, Windows cross-link and 30 actual Windows library tests cover their stated scopes below. No complete native Code OSS bundle, admitted candidate image, listener/personal-worker lifecycle or authenticated browser journey is recorded. The workstation client in ADR-0172 remains a CLI/SSH client. |

## Findings

The [Windows candidate decision](../decisions/0200-windows-browser-editor-candidate.md)
now records the separate source-built bundle, SYSTEM gateway, SAM/S4U personal
worker, exact job/pipe recovery and supervised-task design. ADR-0200 is
accepted/partial and activates no supersession. Its new `windows-editor-v1`
agent row uses only manifest v7 with a required closed editor tuple and bundle
v4 preserving the tuple. Existing v5/v2 codecs reject the new fields and row.
Marshall still revalidates the exact image ID and configured editor release;
Lilly retains the descriptor across portable starts. Exact native/browser
qualification and production selection remain open; ADR-0171's false editor
row is unchanged.

1. **The Linux gap is evidence freshness, not an authorization exception.** The retained Linux editor records prove bounded package, broker, image and selected native-fleet behavior at their captured revisions. They do not prove the current source revision, a production browser sign-in, or a complete current-image recovery journey. The missing evidence must be closed with a fresh image-bound browser run; changing the capability table or treating a terminal/SSH pass as an editor pass would violate ADR-0153 and ADR-0190.
2. **Native guest work does not imply editor support.** FreeBSD and OmniOS have explicit fail-closed native capability rows. Their accepted native evidence is deliberately limited to the named transport, service, storage, growth and recovery scopes. Editor support would require a new agent/editor implementation, a matching immutable descriptor and a separate authority and browser acceptance review.
3. **Windows agent readiness does not imply editor support.** The existing `windows-v1` contract excludes editor and Inception. Runtime/source payload staging, a portable identity/custody model, Win32 launcher code and a roster authorizer lock now exist. Only the separate manifest-v7/bundle-v4 candidate declares editor support; it has no recorded native listener or browser acceptance and remains outside selected catalog images. The workstation CLI review covers installation and SSH tooling, while earlier guest reviews cover firmware, agents and terminal/workspace boundaries. ADR-0200 activates no supersession or existing-row widening.
4. **High, explicitly unimplemented qualification: native custody and browser admission.** The source in `windows.rs`, `windows_main.rs`, `windows_pipe.rs` and the candidate task installer defines SAM/S4U, executable/PATH, job, pipe and recovery checks, but portable tests cannot establish the corresponding Win32 behavior. Incorrect native behavior could select a foreign account or process, mishandle cancelled I/O or fail to restart the broker. The native acceptance harness is present under `nix/verification/tests/machines/windows-editor`; static compilation and refusal tests do not execute Windows. Keep the candidate outside production selection and run exact-bundle native custody, task crash/reboot and authenticated browser journeys before accepting the exact image.

## Verification and limits

The review inspected ADR-0153, ADR-0158, ADR-0169 through ADR-0173, ADR-0190, the versioned manifest and guest-agent capability declarations, the foreign-Linux editor review, the guest OS matrix review and the Windows workstation/guest-agent reviews. It also inspected the Windows runtime/source recipes, Win32 broker model/launcher/listener, roster authorizer lock, current HLDD guest, interactive and security prose, scenario ledger and static evaluations. Runtime and boundary evaluations are staging/metadata evidence only.

Recorded on 2026-10-18: the focused protocol run passed 33 tests with ExUnit
seed 652199, including the new 100-case Windows identity/portable-storage property
with fixed Hegel seed 2001710 and retained v5/v2 refusal/vector tests. The Lilly
focused run passed 2 tests with seed 923427, including exact retained editor
tuple, Git capability, changed-tuple refusal and old-bundle refusal through the
actual materialization/load paths. These use pure codecs or owned local files,
not a running guest. Full three-application gates remain separately required.

Recorded on 2026-10-18: broker portable execution passed 26 library and 7 Linux
binary tests, with one deliberate subprocess fixture ignored. Windows-target
clippy with `--all-targets -D warnings` and `cargo check --tests` passed using
the pinned Lyra Rust toolchain. Final Linux clippy also passed. The production
Windows cross-link is
`/nix/store/1p8x3ga0wx41walws6062wnnxa5ybsyf-overalls-vscode-web-broker-windows-0.1.0`;
that alone establishes no Win32 behavior. The separate test artifact
`/nix/store/0p7mc938wbsj19fipxbqjkmfzppixnn6-overalls-vscode-web-broker-windows-tests-0.1.0`
executed on native Windows VM `24e54ee7` through administrative SSH and passed
30 library tests and 0 binary tests. In particular,
`native_pipe_copies_completed_bytes_and_retires_timeout_without_caller_storage`
and `native_idle_relay_read_waits_for_bytes_or_explicit_shutdown` exercised real
named-pipe completion/timeout/cancellation. The native platform-authority and
directory-custody tests exercised actual Windows security descriptor validation
and foreign-owner/write refusal. These do not execute the complete SAM/S4U,
personal worker, Task Scheduler, guest image or browser journey. The new native
acceptance harness passed strict TypeScript, ruff, ty, pinned PowerShell parser
and six portable boundary/relay tests, including a real local TLS relay exchange.
These do not execute its native Windows/browser assertions or qualify those
unexecuted boundaries.

The separate SYSTEM custody fixture passed 13 native Windows cases, including
foreign ancestor ownership and writes, reparse refusal, private-state access,
the exact TrustedInstaller ancestor exception, the scheduler's private DACL and
unlimited task settings. The disposable task and fixture were removed after the
run. This establishes those bounded installer checks, not broker crash or reboot
recovery. Code OSS and its native dependencies also compiled on the isolated
Windows builder; extension packaging then failed on a PowerShell argument-splat
error. The corrected build is being rerun against its changed release identity;
there is still no completed, imported native editor bundle in this checkpoint.

Existing decisions retain their statuses; ADR-0200 is new and accepted/partial.
Architecture impact includes that Windows candidate design and the evidence
reconciliation, while accepted editor authority and native fail-closed rows are
unchanged. The remaining work is a fresh current-revision Linux browser journey
and, separately, exact Windows package, native custody, task and browser
qualification followed by reviewed production image selection. FreeBSD and OmniOS
editor support remain outside this decision.

The incoming ADR registry collision was reconciled without changing rationale:
per-user pins retain ADR-0193 and localization retains ADR-0201; Git attribution
is ADR-0198 and memory suspension is ADR-0199, with reciprocal supersession links
and the missing settings/localization index rows restored. The identical repeated
Git action, policy and attributes in `Marshall.Accounts.User` were removed while
retaining the original action contract and authority rule. These integration
repairs preserve accepted behavior and require no new handbook behavior claim.

The full protocol gate also exposed an incoming baseline defect in
`Execution.encode_command/1`: resume encoded the checkpoint's atom-key map
without its closed wire codec, so its existing round-trip test failed. The
narrow repair calls `Checkpoint.encode/1`, matching the existing outcome path,
and pins the nested wire shape in that test. Architecture assessment: this
preserves ADR-0199's accepted inert descriptor and execution requirements; it
adds no capability, continuation authority or checkpoint admission. Final gate
results must include the repaired source before claiming verification.
