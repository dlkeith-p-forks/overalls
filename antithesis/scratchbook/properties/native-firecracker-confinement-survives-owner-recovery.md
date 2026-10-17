# native-firecracker-confinement-survives-owner-recovery

**Type/priority/status:** Safety, P0; proposed, unimplemented, unexecuted. Primary `Always(condition, "Current Firecracker execution retains its jail UID namespace and cgroup confinement")`. `Always` fits each sampled current-running execution: a single admitted execution without these physical limits is a violation. `Reachable(re_adopted_confined_vmm, "A restarted Lilly owner re-adopts an independently confined VMM")` is a supplementary state witness, not a substitute for the safety oracle.

**Property:** Every execution that Lilly treats as current and running after launch or owner recovery maps to the same actual Firecracker PID confined under its expected jail root, private network/PID namespace, dedicated UID/GID and bounded service cgroup; loss of a required observation refuses current-running proof. This is distinct from guest byte ingress or readiness.

**Primary source:** `lilly/lib/lilly/vm/unit.ex:36-48,49-108` builds a systemd unit with control-group kill, CPU/memory/swap bounds and a guarded jailer chain. `lilly/lib/lilly/vm/observation.ex:5-29,31-64` reads actual cgroup process, `/proc` root/net/exe/status, UID/GID, capabilities, no-new-privileges, seccomp, namespace PID and limits, then checks API and unit status again. `lilly/lib/lilly/vm/driver.ex:1072-1094` binds boot proof to the current boot record and a locked physical observation. Root `CONTRACTS:22-26` and `lilly/AGENTS.md:8-12` bar claiming physical isolation from mocks. ADR-0017 and ADR-0140 record the intended execution/liveness split; source behavior remains a test target.

**Independent oracle and action/fault recipe:** Launch two real KVM-backed Firecracker guests with distinct placements, intended UIDs and cgroups. Before fault, the workload obtains root-owned `/proc/<pid>/{status,root,ns/*,cgroup,exe}`, cgroup controller files and `systemctl show` from a monitor outside Lilly, plus exact current intent and boot ID. Restart Lilly and actor/view processes while leaving one VMM alive; race an authenticated new or stale command and read the physical records again at each declared current-running boundary. Resolve PID reuse by recording process start time and pidfd where available, and check the jail root inode, net namespace inode, UID/GID, `NSpid`, seccomp, no-new-privileges, zero effective caps, CPU/memory/swap limits and VMM API boot ID. Require the neighboring VMM and its cgroup to stay intact. A Lilly event or process name alone is not the oracle. If the monitor cannot read an attribute, mark the sample inconclusive; do not count it as confined.

**Value menu:** fresh launch/adoption after Lilly restart; one/two guests; exact or stale placement/epoch/generation; VMM alive/exited during re-adoption; limit file present/unreadable; systemd ActiveState transitional/active; old PID reused; simultaneous neighbor unaffected. Vary one guard at a time and retain the live full-path witness. Avoid mutating a production cgroup to fabricate a violation; a disposable fixture may deliberately remove a prerequisite before admission to test refusal.

**Topology/proof limit:** Requires `native-kvm` actual Firecracker plus root monitor; TCG guest or `storage-router` has no Firecracker jailer and cannot establish this property. A single virtual host proves local confinement only, not independent physical-host isolation. Existing `zfs-guest` and fleet test source are useful fixture designs, not a current pass.

**Open questions:** How will a test-only root monitor expose a stable per-PID process-start/pidfd sample under concurrent exit? `(partial: production observation checks PID and API twice but the proposed independent sampler is not assembled)`; which current native check derivation can host the post-restart two-guest perturbation? `(partial: native campaign lists fleet/zfs-guest; no current execution receipt)`.

### Investigation log

- Examined `Lilly.VM.Unit`, `Observation`, `Driver.boot_proof`, `antithesis/scratchbook/native-campaign-inventory.md:101-110` and topology native boundary. Found precise confinement fields and a possible reboot/re-adoption window. Did not find a workload-owned atomic PID/cgroup sampler or current native execution result. Hence both questions remain partial; no defect is asserted.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. native-KVM-physical-boundary-only; independent witness: actual Firecracker PID/start, jail namespace/UID/cgroup, TAP/nft packet receiver and guest profile. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
