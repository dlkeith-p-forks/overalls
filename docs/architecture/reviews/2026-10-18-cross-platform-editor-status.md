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
| Windows | Existing `windows-v1` remains editor false by [ADR-0171](../decisions/0171-windows-guest-agents.md); version-5 firmware manifests reject editor descriptors. ADR-0200 adds the separate unselected `windows-editor-v1` candidate with manifest v7 and portable bundle v4. | The completed native Code OSS bundle passed reviewed import; its package capability remains false. Portable broker tests, Windows cross-link, 30 native Windows library tests and 13 SYSTEM installer-custody cases cover their stated scopes below. No admitted candidate image, listener/personal-worker lifecycle or authenticated browser journey is recorded. The workstation client in ADR-0172 remains a CLI/SSH client. |

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

The concurrent Linux/Windows asset path now uses a closed version-1 registry
with only `linux-x64` and `win32-x64`. Marshall derives the target from the
validated immutable image and requires its exact descriptor; a tuple approved
for the other target does not authorize that image. Audi serves fixed immutable
roots and reports each release separately. The receipt uniqueness constraint
includes the complete tuple, preserving independent readiness and expiry.
Publication's single SQL snapshot requires the complete configured asset set
on every advertised editor or neutral webview gateway. This is necessary
because neutral DNS cannot choose a gateway by release. Missing, malformed,
duplicate or foreign configuration fails closed. Empty registries disable
editor capability. The reviewed rollout applies the receipt-index migration
first and rebuilds each host's application and generated configuration
atomically; an old Linux-only gateway under a two-target registry stays absent
from editor/webview discovery until both receipts are current. No old singular
configuration reader or option is retained, preserving ADR-0159.

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
recovery.

Native Windows Code OSS build and reviewed bundle import completed on
2026-10-18 for source commit
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c` and exact release
`fbd3ccab8ae104bf2aee689e77deb6e47a3e9f12b2e4cbe3eeccdaf8afcb7dfe`.
The native source build includes its four signed extensions and the maintained
Windows shebang correction. The imported output is
`/nix/store/rhs8krgq3s8sk0apspmw3kbix8zc8pqy-overalls-vscode-web-windows-native-bundle`,
reviewed recursive NAR
`sha256-fc7oAJaJWv1eQf92InZoKNFAopzC/QI+GqbHxdRGreM=`; the transferred
archive's SHA256 is
`4de55ab22eae02f224df71f9e8557207bd666f35010aba2ecdf4704a9e5f049b`.
The importer verified the exact descriptor, complete product policy, licenses,
closed native provenance, regular entries and absence of Nix-store references.
This is native build/import evidence. Package capability remains false; it does
not qualify an installed candidate image, personal worker, browser journey,
recovery path or workstation CLI.

Existing decisions retain their statuses; ADR-0200 is new and accepted/partial.
Architecture impact includes that Windows candidate design and the evidence
reconciliation, while accepted editor authority and native fail-closed rows are
unchanged. The remaining work is a fresh current-revision Linux browser journey
and, separately, exact Windows package, native custody, task and browser
qualification followed by reviewed production image selection. FreeBSD and OmniOS
editor support remain outside this decision.

The incoming ADR registry collision was reconciled without changing rationale:
per-user pins retain ADR-0193 and localization retains ADR-0197; Git attribution
is ADR-0198 and memory suspension is ADR-0199, with reciprocal supersession links
and the missing settings/localization index rows restored. The identical repeated
Git action, policy and attributes in `Marshall.Accounts.User` were removed while
retaining the original action contract and authority rule. These integration
repairs preserve accepted behavior and require no new handbook behavior claim.

The incoming account-settings integration also restored routes to removed
`SecurityLive` and `SSHKeysLive` modules, split the sidebar into a Settings link
and stale Account link, and reintroduced removed URLs into the browser probe.
These violated ADR-0196 and the adjacent `signed-in-account-navigation`
contract. Removing those routes and probe visits and restoring the single
`nav-account` entry preserves the accepted `/settings` page, section anchors,
fresh-login mount and Git settings section. Existing account tests explicitly
check old-path 404 responses and the single navigation entry. This repairs
design drift and introduces no new architecture decision or handbook behavior.
The same integration dropped the Ash policy entries for `set_time_zone` and
`set_locale`, leaving the existing self-only locked implementations unreachable.
Restoring their authenticated-actor policy preserves ADR-0195/ADR-0197; the
implementations still reject non-User or retired actors and accept no target
account identifier. Existing account and domain tests cover successful updates
and unauthorized or invalid preference refusal.
The locale action also preserves empty strings through Ash casting so its
closed validator can reject them. Previously Ash converted an empty string to
nil and cleared the preference, contradicting the existing invalid-input test.
Only explicit nil clears the saved locale; this restores the accepted refusal
boundary without broadening the supported language set.

The full protocol gate also exposed an incoming baseline defect in
`Execution.encode_command/1`: resume encoded the checkpoint's atom-key map
without its closed wire codec, so its existing round-trip test failed. The
narrow repair calls `Checkpoint.encode/1`, matching the existing outcome path,
and pins the nested wire shape in that test. Architecture assessment: this
preserves ADR-0199's accepted inert descriptor and execution requirements; it
adds no capability, continuation authority or checkpoint admission. Final gate
results must include the repaired source before claiming verification.

The Lilly gate also exposed three incoming Hegel test incompatibilities:
the stop oracle expected an unreviewed event enum, a VM spec property used
unsupported nested execution options, and an image property called an obsolete
draw API. Their repairs preserve production behavior and ADR-0191's property
engine boundary. A separate code-contract review found that hostd's mutating
`systemctl` predicate accepted `lilly.slice`, violating ADR-0176/ADR-0182's
one-VM-unit confinement. The corrected predicate admits mutations only for an
exact `lilly-vm-UUID.service`; slice and wildcard reads remain available.
Recorded Rust execution passed all 58 hostd tests and Clippy, including explicit
slice/wildcard refusal. This is grammar evidence, not native cgroup or systemctl
execution. Full Lilly and Marshall gates remain separately required.

Audi's forced Dialyzer run also exposed missing test-helper PLT entries for
the development/test-only Hegel packages. Adding `ex_unit`, `hegel` and
`hegel_ex` to that PLT inventory preserves ADR-0191's test-only dependency and
runtime boundary; it does not add a production dependency or suppress unknown
application calls. The final forced run must establish the repaired gate.
