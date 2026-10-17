# Antithesis integration architecture review

## Scope and source identity

This review covers the current uncommitted rebuild at base
`c835eb1017d24a001215c319373fa4204d64269b` (ordinary predecessor
`9fe1e493b2090d44bacd16089049cd12b316d58a`): build selectors, the
controlled and integrated Lilly paths, the TCG guest and measured inner ZFS
host, private operator actions and witness, optional terminal observer, image
closures and selected Compose templates. It is a source and contract review,
not an executed integrated or hosted acceptance result. The shared worktree is
moving; the findings below describe the files and SHA-256 snapshot observed
during this review. Recheck changed hashes before using it as a run receipt.

| Source | SHA-256 at inspection |
| --- | --- |
| `lilly/lib/lilly/control/runtime.ex` | `9a92886599809440583f5fc80dd1106d60438f890c98f9a3e8f99b4a0787c65b` (earlier snapshots `c2dfab6f…`, `bdcd2675…`) |
| `antithesis/lilly/lib/overalls_antithesis/lilly/guest_executor.ex` | `82961f953034b9bd20d87d97747a3cd90727cce22f08346c6fb918c45e83faf8` |
| `antithesis/lilly/lib/overalls_antithesis/lilly/integrated_health.ex` | `8557214c0fc25a966fcfa81ce2974062a90aa1f0f0ea294b35c65bc24ff4ac8d` |
| `antithesis/lilly/lib/overalls_antithesis/lilly/integrated_ownership.ex` | `7e07b31bd6c7d9d3d2437ba42ac4dbcb0dedf699c17b6a5d2b82b3e401a0d943` |
| `antithesis/emulation/host/bootstrap.py` | `62cf3e2b7757f60274f7a3543a5452ca4a930b61f7990e0bee9db99505f5a54b` |
| `antithesis/emulation/guest/server.py` | `baf55df72f070bacd236e431fdd347bb4540ad61e344b657844f1c5bcb3686c4` |
| `antithesis/entrypoints/control-operator.sh` | `8c9915ad15ca09c7d0676dbf982011ed85a80ddf040f6a78f93e003a0f9568a6` |
| `antithesis/entrypoints/marshall.sh` | `d910cc5f19eb4826c64f302b07f98907d505fd59abf01e124262f32d1579adda` |
| `antithesis/operator/guest_witness.ex` | `c5509e9556e1ea69cfa02fd5dd847cbb85471ecf7f707a22bcb6f40b8022fe4d` |
| `antithesis/nix/images.nix` | `1d345be9696dbae4ae5e2942145165c9b4d210d6107050f507e38ab369ebe636` |
| `antithesis/nix/lilly-host.nix` | `8c6083ab0724f2d4eb6100c8c6b76aac644f001fe172d56d7875f52f3cd03595` |
| `antithesis/nix/storage-router.nix` | `0c75c566e39fa1895fc0a92a19f8b61feac7404e93cfe9fbefc5b0a430e263f3` (fixed literal-cookie finding at earlier `8a98f779fd276d19fe7f5ccdabbcea70df72630b0138637197ebf58ad6e9bdee`) |
| `antithesis/emulation/storage/bootstrap.py` | `328a821939af24d29dd1225178ed561f54504d37baf60803129dddaababa7836` |
| `antithesis/emulation/host/runner.py` | `2c255e3af43f36a479f25b314cd4a8acfcd469d50204fea14f6b2ea0883c31a6` |
| `lilly/lib/lilly/host/ownership.ex` | `dfb62e1a82e5c06a74e51be2e5330a67f197c25063b53bc9447c03893f350b4c` |
| `nix/domains/artifacts/terminald/src/observer.rs` | `61117f313df92dc8a84a96401ebb79467482e4a095b0637d29304cc9bf9bbe2b` |

## Architecture impact and findings

The rebuild adds optional build-selected adapters and an isolated TCG topology.
It does not change PostgreSQL/Ash authority, production placement rules or the
accepted native host and guest obligations. ADR-0017 remains accepted/partial,
ADR-0033 retains its inherited NixOS-machine verification boundary, and
ADR-0149 still separates diagnostics from control. ADR-0153–0158 guest,
editor, source and identity capabilities gain no acceptance merely because a
guest package or observer is installed. No replacement ADR is indicated by the
inspected design. The initial findings and subsequent source corrections below
still require composed execution before integrated readiness can be claimed.

1. **Source-resolved; execution pending — TCG inner-host ownership.** The
   initial [IntegratedOwnership.acquire/1](../../../antithesis/lilly/lib/overalls_antithesis/lilly/integrated_ownership.ex)
   delegated to production ownership, whose native KVM probe cannot pass in
   the TCG VM. Subsequent source `54cdb55b…` supplies a selected owner with
   root, systemd, machine-ID, reserved-UID, fixed global lock, persistent
   host/pool binding and combined native/emulator unit inventory; it omits only
   the native KVM probe and refuses adoption of a native owner record. The
   [inner host runner](../../../antithesis/emulation/host/runner.py) still uses
   TCG. The [integrated-host boot record](../../../antithesis/verification/integrated-host-boot.json)
   now captures a third actual host boot with real ZFS and cgroup sample after
   two failed-health attempts. A fourth private-service image also built and
   booted with measured ZFS/cgroups, runtime PKI preparation and a
   workspace-source-v2 guest image witness. The fourth host's credential,
   pool ID and CA were issued, but the application rejected runtime
   configuration before authenticated Control. The stopped-root journal
   recorded two invalid-configuration errors; the owned root dataset lacked
   the required LZ4 compression and IPv4 forwarding was omitted. Both samples
   remain disconnected and execution-unready; admission is pending.
   This software emulator cannot satisfy ADR-0017's native KVM/isolation requirement.

2. **Resolved in moving source; execution pending — integrated readiness.** An
   earlier inspected [Lilly runtime](../../../lilly/lib/lilly/control/runtime.ex)
   snapshot (`c2dfab6f…`) set integrated execution readiness to a constant false
   and never called
   [IntegratedHealth.ready?/2](../../../antithesis/lilly/lib/overalls_antithesis/lilly/integrated_health.ex).
   The intervening `bdcd2675…` source called the measured gate but allowed a
   new true sample to combine with an older delivered report timestamp. The
   later source binds `mode_ready?/1` to the matching delivered
   report sequence, closing that source-level mismatch with ADR-0017 and
   Runtime's `readiness-requires-delivered-observation` contract. The selected
   integrated release and actual measured true/false transitions remain
   unexecuted in this review.

   A subsequent private-host diagnostic exposed a bootstrap cycle in the
   integrated variant: requiring inner Ziggy/Audi readiness to advertise the
   physical host as execution-ready prevents reviewed host enablement, while
   private role credential issuance depends on that enablement. The inspected
   [IntegratedHealth source](../../../antithesis/lilly/lib/overalls_antithesis/lilly/integrated_health.ex)
   now gates the host report on the complete measured ZFS/cgroup and guest-vmm
   preflight only. The inspected
   [GuestExecutor source](../../../antithesis/lilly/lib/overalls_antithesis/lilly/guest_executor.ex)
   checks current private readiness before a new launch/restart runner effect;
   it permits re-observation only with exact matching boot identity and positive
   live-process proof. The required order is physical host preflight, current
   delivered report, reviewed enablement and credential rotation, private role
   readiness, then guest effect. This follows the production Executor's
   launch/restart boundary and does not change accepted host authority. The
   source correction has no passing composed private execution yet: the latest
   captured private host still had report sequence zero, and inner network
   forwarding plus role startup remain under repair.

3. **Source-resolved; execution pending — measured-host enrollment.**
   The [inner bootstrap](../../../antithesis/emulation/host/bootstrap.py) publishes
   `lilly-host-enrollment.json`, then `activate()` waits for
   `lilly-host-credential.json`, `lilly-host-pool-id` and a CA in its private 9p
   share. [Host Compose](../../../antithesis/config/compose.host-vmm.yaml) mounts
   that share into the enrollment container, but
   the initial enrollment entrypoint only enrolled `lilly-a`. Subsequent
   [operator source](../../../antithesis/entrypoints/control-operator.sh) accepts
   the fixed measured-host request, uses Marshall's reviewed CLI, verifies the
   credential and host/pool identity, and writes the private outputs. A durable
   started marker refuses ambiguous reissuance. Inner bootstrap still refuses
   missing or mismatched identity after its bounded wait. The fourth attempt
   did issue the host credential, pool ID and CA, but its application did not
   reach authenticated Control or a committed report. Inner Ziggy credential
   rotation refused because the host was disabled; Galileo was not attempted.
   Actual guest admission remains unexecuted.

The optional private host/guest source adds inner Audi, Ziggy and Galileo
roles with runtime PKI and a public inert bootstrap root whose signing key is
discarded. Guest trust requires boot-bound delivery and an exact durable
receipt before private channels can count as ready. Twelve adapter checks and
forced Dialyzer passed. The fourth private host image built and booted, but
runtime role credentials and private-service, terminal or nested-guest
acceptance remain pending. The private 9p witness observed the first three
image identities; nine focused crash-actuator tests passed without an actual
QEMU crash. A full integrated-mode suite attempt failed at 7/559 and cannot
be cited as a passing gate.

The earlier `8a98f779…` [storage-router Nix source](../../../antithesis/nix/storage-router.nix)
embedded a fixed BEAM cookie in two systemd environments, contradicting
`antithesis-runtime-secret-custody` and `isolated-synthetic-secrets`. The
revised source removes those literals and has Brady load
`/run/router-release-cookie`; bootstrap generates a random cookie in private
runtime state. The separate [storage-router record](../../../antithesis/verification/storage-boot.md)
now captures a passing exact-image direct TCG boot and reset with this repair,
real ZFS/Brady, retained GUIDs and marker, and reapplied quota. Its container
entrypoint and hosted graph were not exercised; physical power-loss durability
and production packet attribution remain unverified.

The inspected controlled path preserves the intended negative result:
[Collector](../../../antithesis/lilly/lib/overalls_antithesis/lilly/collector.ex)
reports unavailable pools and nil capacity; Lilly's hosted compile branch
forces execution readiness false. It now derives CPU/memory limits from its
actual unified cgroup v2 process subtree and ancestors, refusing an unavailable
or ambiguous observation rather than substituting a configured native slice.
The earlier ephemeral Podman mount preflight did not prove an actual-container
report. A later local base Compose diagnostic did publish a connected, fresh
v4 report (sequence 44 before six serial Control commands, 392 afterward) and
emitted setup. Its committed `lilly-a` host row had 32 effective cores,
134558031872 effective memory bytes, `capacity: nil` and false execution
readiness. These are collector-derived fields; raw cgroup file values were not
independently compared. The guest adapter checks exact image, command
shape and boot tuple and requires QEMU/backend identities plus port-1024
readiness before returning an *emulated* running observation. Later source adds
trust receipts and a bounded crash actuator/watcher, with focused tests only;
no QEMU crash or native boot proof has been recorded.
The guest server's inventory and health reject uncertain/degraded state and
require a writable state root. These source properties do not establish a
successful composed guest journey or native Firecracker/KVM isolation. The
optional terminal observer is feature-selected only in the TCG guest package;
the ordinary terminald package leaves it off. Its source checks host CID 2,
current boot hello proof, closed operations and numeric/digest-only output.
This is a source boundary assessment, not a completed guest security test. The
optional guest TAP runs directly in the inner host network. Audi can observe
an actual pre-NAT peer with current Lilly boot proof, but this fixture does
not establish production namespace/nft anti-spoof policy or adversarial guest
network isolation. Cooperative terminal evidence, if later recorded, would
retain that limit.

The private operator accepts closed request schemas, obtains a fresh synthetic
actor through the stored login and passkey assertion, and calls production Ash
domain actions for Compute, terminal and Galileo operations. The witness
bridge checks current Marshall placement/epoch/generation and sanitizes the
guest-vmm reply. Internal ledger reads enrich an authorized result; they do not
themselves grant a workload mutation. An operator request with an ambiguous
result remains uncertain. The source inspection found no intentional direct
database mutation for guest admission. Despite source corrections, these paths
still lack an integrated admitted guest on which to establish
their intended effects.

A clean local base Compose diagnostic subsequently started pinned Nix
PostgreSQL 18 with migration, both Marshall HTTPS replicas, enrollment and
Lilly health. Marshall operator mode retains Repo, Vault, authorization,
PubSub and Endpoint with `server: false` for the real WebAuthn origin; it
disables serving listeners and background jobs. The operator completed three
synthetic users and passkeys, confirmed by read-only SQL, and `ss -lnt`
showed no operator listener. In that earlier project the workload remained at
`host_connection_or_report`: the connected v4 host had report sequence zero
and no report timestamp, so setup was incomplete. Diagnostic4 subsequently
recorded `INFO Antithesis setup complete`, a fresh v4 report at sequence 44,
six successful serial Control commands with 13 true SDK assertion records,
and a later fresh sequence 392. Its selected manifest has four stale runtime
dependency hashes, so the result is local execution of the identified images,
not a frozen or hosted baseline; see the tracked
[local Compose acceptance record](../../../antithesis/verification/compose-local-acceptance.md).
The historical command record is
`antithesis/runtime/diagnostic4-control-commands/README.md`.
ADR-0048's deployed one-Marshall
topology and ADR-0065's live browser passkey authority remain unchanged.

The optional `private-host-vmm` context and `compose.inner-private.yaml`
select the private fourth-image branch after the host-vmm overlay. Compose
render passed; that Docker variant has not started. The direct TCG fourth
image boot, runtime PKI preparation and guest witness remain separate from
private Audi/Ziggy/Galileo service or terminal acceptance.

## Validation and remaining gaps

I read root/component guidance, the architecture overview, decision index,
ADR-0017 and the inherited ADR-0033 boundary, the foundation/reset/prerequisite
reviews, applicable `CONTRACTS`, and the architecture-review and code-contracts
skills. I traced callsites and data flow across Lilly Runtime/Actor,
GuestExecutor/IntegratedHealth, the inner host/bootstrap, operator, Nix image
selection and Compose overlays. The initial snapshot lacked a working measured
readiness handoff and inner-host credential writer; subsequent source inspection
found both implementations. `git diff --check` passed during
inspection. `cc-check` was unavailable, so contract syntax and semantic
compliance were inspected manually; no type checker, Compose build/up, selected
Nix context build, NixOS machine test or hosted Antithesis run was executed for
the integrated graph. Separately, the direct router TCG smoke passed at the
source and artifact identities in its record, and ordinary Protocol/Lilly gates
passed 262/559 checks with forced Dialyzer. Concurrent edits can supersede
source conclusions and must be checked
against their own source hashes and actual execution logs.

Run the complete selected graph with
real migration, both Marshall HTTPS replicas, inner ZFS enrollment, authenticated
Lilly Control/report, physical guest oracle and exactly one workload setup
owner. Preserve separate labels for controlled, software-emulated and native
effects, and freeze source, image, command and assertion identities before any
hosted verdict. ADR-0017 and ADR-0033 remain partial until matching executed
evidence exists.
