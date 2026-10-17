# Antithesis guest-lifecycle profile with stub storage

Date: 2026-10-17

## Decision and scope

The Antithesis harness gains a fourth launchable selection, `guest-lifecycle`.
It selects the existing `guest_lifecycle` command template and renders the base
Compose graph plus `compose.guest-vmm.yaml` and `compose.guest-lifecycle.yaml`.
Hosted Antithesis has no KVM, so the guest runs under QEMU TCG in the separate
`guest-vmm` container.

The container `lilly-guest` release (compiled with `ANTITHESIS_HARNESS=1` and
`ANTITHESIS_GUEST=1`, without `ANTITHESIS_INTEGRATED_HOST`) now uses
**stub storage**. `StubStorageCollector` reports each configured controlled pool
as a fixed synthetic 1 TiB pool with zero usage and no allocation credit. Its
compute headroom is one free guest-vmm slot (1 vCPU, 2 GiB), capped by the
container's measured cgroup limits and removed while guest-vmm's live inventory
holds a running, degraded or uncertain placement. `StubStorageHealth` sets
`execution_ready` only with that stub report, a verified advertised image and a
passing guest-vmm health check. The enrollment operator registers the baked
guest image manifest through `Marshall.Compute.Images.register`. The bootstrap
completes setup only after it reads the guest-vmm image identity through the
read-only witness bridge and finds a Marshall catalog that offers that image
with known capacity for its shape.

The production, controlled-harness and integrated-host Lilly branches are
unchanged. The stub is not native ZFS, KVM, Firecracker, isolation or capacity
evidence.

## Evidence

- `lilly/lib/lilly/control/runtime.ex` selects the stub collector and health
  gate only in the container guest harness branch.
- `antithesis/lilly/test/guest_stub_storage_test.exs` covers slot headroom, cgroup
  caps, coverage filtering, the stub pool and every readiness refusal.
- Selection, Compose-boundary and bootstrap/readiness unit tests cover the
  profile, the socket and volume boundaries and each fixed readiness reason.
- `nix build` produced the `lilly-guest`, `lilly` and `guest-vmm` contexts.
  The `lilly-guest` context carries the stub modules and the same image
  derivation as guest-vmm.
- The profile has not been built with Compose, validated with Snouty or
  launched. No local or hosted run is recorded.

## Architecture impact

No accepted architecture decision changes. The new branch is harness-only and
compile-time selected. It introduces no product domain, resource, protocol,
authorization, persistence or deployment boundary. Marshall admission,
reservation and outcome logic are reused unchanged against the synthetic
report. The HLDD reference and topology chapters record the profile and its
stub boundary.
