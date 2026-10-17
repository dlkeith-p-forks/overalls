# VM resizing review

## Scope and architecture impact

ADR-0051 carries forward ADR-0050 and adds durable VM resource transitions. It
changes Compute persistence, execution protocol, owned disk binding and the
manager UI while preserving placement, sharing and usage-based capacity policy.
The implementation is based on `codex/usage-overcommit`; unrelated main-checkout
work is excluded. The user supplied the accepted resize plan.

## Findings and reconciliation

- **High, resolved:** shape was embedded in immutable command, VM and
  ZFS claims. [Driver transitions](../../../lilly/lib/lilly/vm/driver.ex) and
  [owned disk transitions](../../../lilly/lib/lilly/host/zfs_dataset.ex) now journal
  exact source/target configurations before effects, retain the native GUID and
  reject other bindings. Ordinary command identity remains strict. This implements
  ADR-0051's exception; the native interruption/recovery scenario passed.
- **High, resolved:** provisioning retries compared current resources. The
  [admission coordinator](../../../marshall/lib/marshall/compute/admission.ex)
  now compares retained provisioning sizes. The migrations backfill existing VMs
  and operation snapshots before making the latter required.
- **High, resolved:** ordinary stop evidence releases compute, which would lose
  future restart capacity during resize. The
  [resize coordinator](../../../marshall/lib/marshall/compute/resize.ex) retains
  that hold, advances generations and rechecks physical headroom before restart.
  Unknown effects retain commitments. Stale proofs cannot settle a future hold.
- **High, resolved:** supplied command snapshots now cross-check host
  and pool against the operation's placement, in addition to operation identity,
  generation and execution epoch. The regression rejects mismatched authority
  without creating an operation.
- **Medium, resolved:** a retry by a different manager could be attributed
  to the original requester. Retry operations now identify the authorizing actor;
  later automatic phases inherit that actor while the original request and prior
  operations remain unchanged. Revocation is rechecked before each retry.
- **Medium, resolved:** the page could resurrect pre-resize values when
  progress completed. It now builds the next form from confirmed sizes. Existing
  drafts keep their expected generation across polling/reload; only an explicit
  review action renews generation/key while retaining requested sizes.
- **High, native verification passed:** the real
  [ZFS/KVM test](../../../nix/verification/tests/machines/zfs-guest/driver.py) passed disk-growth
  and metadata-publication interruptions, filesystem expansion, CPU/RAM increases
  and decreases, stopped behavior, data/GUID preservation and neighbor isolation.
- **Deployment incomplete:** no production deployment has been performed. Follow
  the [coordinated deployment notes](../../operations/vm-resizing.md), migrating before new
  resize actions are served and using one revision for both consumers.

## Requirement audit

| Requirement | Source and executable evidence | Status |
| --- | --- | --- |
| Owner/manager page, exact drafts, limits, pending versus confirmed, progress and retry | [Page](../../../marshall/lib/marshall_web/live/resize_live.ex), [page tests](../../../marshall/test/marshall_web/resize_live_test.exs), [coordinator tests](../../../marshall/test/marshall/compute/resize_test.exs) | Implemented; application verification |
| Durable phases, exact retry/stale rejection, retained provisioning parameters and immutable operations | [Request](../../../marshall/lib/marshall/compute/resize_request.ex), [coordinator](../../../marshall/lib/marshall/compute/resize.ex), [snapshots](../../../marshall/lib/marshall/compute/command_snapshot.ex) | Implemented; application verification |
| Full target admission, growth-only hold, current-generation settlement, lifecycle/relocation/maintenance exclusion | [Coordinator tests](../../../marshall/test/marshall/compute/resize_test.exs), [three-node races](../../../marshall/test/marshall/compute/distributed_admission_test.exs) | Implemented; database/distributed verification |
| Strict wire shapes, recorded resource rebinding, actor restart and receipt replay | [Protocol tests](../../../protocol/test/execution_test.exs), [store tests](../../../lilly/test/lilly/control/store_test.exs), [actor tests](../../../lilly/test/vm/actor_test.exs) | Implemented; physical executor mocked in actor tests |
| Existing owned disk growth, interruption recovery, failed restart fencing and guest readiness | [Disk](../../../lilly/lib/lilly/vm/disk.ex), [driver](../../../lilly/lib/lilly/vm/driver.ex), [executor](../../../lilly/lib/lilly/vm/executor.ex), [native fixture](../../../nix/verification/tests/machines/zfs-guest/probe.exs) | Implemented; application and native verification |
| Native data/identity preservation, filesystem growth, CPU/RAM changes, stopped behavior and neighbor isolation | [Native scenario](../../../nix/verification/tests/machines/zfs-guest/driver.py) | Passed real ZFS/KVM scenario |
| Shared schema and coordinated consumer deployment | Ordinary migrations and common protocol dependency; [deployment notes](../../operations/vm-resizing.md) | Source implemented; deployment pending |

## Contract review

Reviewed the changed coordinators, wire codec, dispatch snapshots, store transition,
driver, disk/ZFS mutation and their direct consumers against ancestor contracts and
local notes. Reconciled the retained-shape contract with ADR-0051 and the closed
wire schema note with the explicit resize variants. Contract discovery covers the
new coordinator, snapshot, driver, ZFS and protocol obligations. Syntax and coverage
checks are structural, not proof of native safety.

## Validation

Completed application gates passed: protocol 74 tests/properties, Lilly 218, and
Marshall 408 including three independent Marshall peers. All compiler, formatting,
contract and Dialyzer gates passed; Marshall retains only its existing upstream
Dialyzer exclusion. Assets, the native Elixir fixture syntax check and the 51-decision ADR checker
passed. The final gate includes requester attribution, ownership, command authority
and completed-page draft regressions.

Both source-built release checks passed (`marshall-release` and `lilly-release`).
The full `checks.x86_64-linux.zfs-guest` test passed on 2026-09-17 in 1,838 seconds,
including its 419-second resize scenario. It used the source-built Lilly release,
real ZFS datasets and nested Firecracker guests. The native output is
`/nix/store/h6wh2n62107s3avaw2f833rjsj2gx775-vm-test-run-overalls-zfs-guest`.
The builder exposed `/dev/kvm` with nesting enabled; the local build explicitly
advertised `kvm nested-kvm nixos-test big-parallel` and used root because the
configured Nix build users lacked KVM device access. This does not establish
independent physical-host power-loss durability or deployment acceptance.

No coordinated deployment has been performed. The deployment target remains
unspecified; the accepted implementation status stays partial until rollout and
its environment-specific acceptance are complete.
