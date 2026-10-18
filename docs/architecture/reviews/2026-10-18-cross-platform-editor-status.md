# Cross-platform browser editor status (2026-10-18)

## Scope and architecture impact

This review reconciles the personal browser editor in [ADR-0153](../decisions/0153-official-source-browser-editor.md) and the durable guest identity boundary in [ADR-0158](../decisions/0158-durable-guest-identities.md) with the multi-OS admission rules in [ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md). It records what the current source and retained evidence establish for each guest family. It does not add a protocol capability, widen authorization, or mark an unsupported operating system as editor-capable.

The editor capability is an immutable image property. A package, a catalog row, a guest-agent name, a workstation client, or a successful terminal/SSH journey cannot grant it. Marshall still requires a current stored login, current write authority and the existing owner policy; Lilly and the guest broker still enforce the existing transport and execution fences.

## Current status

| Guest family | Editor decision and implementation status | Evidence and remaining boundary |
| --- | --- | --- |
| NixOS and Ubuntu | Version-4 Linux images may carry the reviewed editor descriptor and broker. ADR-0153 remains accepted with partial implementation. | The source/package and application authority are recorded, but there is no current-revision native browser sign-in, edit/readback and recovery receipt in this review. Historical package, fixture and earlier fleet records retain their original revisions and do not qualify the current trunk or production. |
| Arch Linux and AlmaLinux | They retain the version-4 Linux contract. The shared foreign-Linux builder can carry the editor package, broker and descriptor; an old image without those bytes must refuse. | The retained Alma suite passed its twelve native stages and the Arch diagnostic replay passed twelve stages, but both are bound to captured image/source revisions. The Arch broker-restart 502 remains unresolved, and neither result establishes a current-revision or production browser journey. |
| FreeBSD (`freebsd-v1`) | Editor remains false. ADR-0190 permits only the reviewed native subset after complete image admission; its version-6 manifest has no editor descriptor. | Native transport, service, growth and recovery evidence does not implement an editor broker, editor package or browser admission. Physical isolation, broader recovery and fleet acceptance remain separate. |
| OmniOS/illumos (`illumos-v1`) | Editor remains false. Native admission qualifies only the exact reviewed image and its bounded non-editor subset. | Native service, growth, transport and crash records do not implement the editor package, broker or browser path. Physical recovery, isolation and fleet acceptance remain open. |
| Windows (`windows-v1`) | Editor remains false by [ADR-0171](../decisions/0171-windows-guest-agents.md). Version-5 firmware manifests reject editor descriptors; the Windows workstation client in [ADR-0172](../decisions/0172-windows-workstation-client.md) is a CLI/SSH client, not a guest browser editor. | Windows readiness, roster, SSH, ConPTY, workspace and agent checks do not establish an editor package, broker, browser origin or browser journey. A future editor requires a reviewed manifest/agent contract and native browser evidence; no such implementation is accepted here. |

## Findings

1. **The Linux gap is evidence freshness, not an authorization exception.** The retained Linux editor records prove bounded package, broker, image and selected native-fleet behavior at their captured revisions. They do not prove the current source revision, a production browser sign-in, or a complete current-image recovery journey. The missing evidence must be closed with a fresh image-bound browser run; changing the capability table or treating a terminal/SSH pass as an editor pass would violate ADR-0153 and ADR-0190.
2. **Native guest work does not imply editor support.** FreeBSD and OmniOS have explicit fail-closed native capability rows. Their accepted native evidence is deliberately limited to the named transport, service, storage, growth and recovery scopes. Editor support would require a new agent/editor implementation, a matching immutable descriptor and a separate authority and browser acceptance review.
3. **Windows agent readiness does not imply editor support.** The Windows agent contract explicitly excludes editor and Inception. The workstation CLI review covers installation and SSH tooling, while the Windows guest reviews cover firmware, agents and terminal/workspace boundaries. None supplies browser editor authority or a Code OSS broker. No decision is changed by this status review.

## Verification and limits

The review inspected ADR-0153, ADR-0158, ADR-0169 through ADR-0173, ADR-0190, the versioned manifest and guest-agent capability declarations, the foreign-Linux editor review, the guest OS matrix review and the Windows workstation/guest-agent reviews. It also inspected the current HLDD guest, interactive and security prose and scenario ledger. No runtime, browser, machine or production test was run for this status update.

Affected decisions remain accepted or proposed with their existing `partial` implementation status. The architecture impact is a documentation reconciliation: the editor authority boundary and native fail-closed rows are unchanged. The remaining work is a fresh current-revision Linux browser journey and, separately, any future proposal for native or Windows editor capability with its own protocol, image, broker, authorization and native evidence.
