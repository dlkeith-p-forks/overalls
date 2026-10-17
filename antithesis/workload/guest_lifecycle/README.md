# Guest lifecycle workload scope

`serial_driver_physical_boot_cycle.py` is a draft test command for the unselected
`integrated-zfs-guest` template. It uses the private fixture operator for real
Marshall Compute provision/stop/start operations, keeps every request in an
attempt/acknowledgment ledger, and joins committed `compute.operation` outcomes
with a separate read-only guest witness. The witness reads actual QEMU/backend
PID and process start ticks, port-1024 boot ID and challenge digest, and a stopped
qcow2 hash. A lost operator reply or missing witness is unexercised. A completed
outcome that contradicts the current VM state or execution tuple fires a failing
assertion.

The draft currently emits narrower physical boot and stop assertions. The five
catalog properties remain **unexercised as full properties** until these joins
exist:

| Property | Additional independent evidence required |
| --- | --- |
| `guest-readiness-binds-current-physical-boot` | Lilly's current boot journal challenge digest and boot ID, joined to the accepted outcome and guest witness across a delayed/replaced boot. The current Marshall outcome records `guest_ready` but no boot ID. |
| `guest-ready-does-not-claim-workspace-checkout` | A source-v2 image and actual guest done marker, Git HEAD and source digest. `workspace_source_version: null` means capability absent and is distinct from a checkout refusal or success. |
| `continuing-boot-advances-generation-without-second-boot` | A supported newer-running-intent adoption action plus old delivery barrier and exact journal settlement. Stop/start is a fresh boot, not an adoption. |
| `stop-retains-disk-until-restart` | Per-placement measured ZFS dataset GUID, retained guest content marker/hash, address and network detach. The stopped qcow2 hash alone does not prove these. |
| `runtime-restart-requires-fresh-readiness` | Closed Lilly restart and database fault controls, a current authenticated delivered report/actor witness, and unchanged QEMU process identity. |

The pure oracle functions in `oracle.py` return `UNEXERCISED` when those proofs
are missing. Tests cover stale generation/PID reuse, absent source capability,
and unknown disk content. This harness code changes no product protocol, domain
boundary or accepted architecture decision. It is not a native Firecracker or
ZFS acceptance result; no `/hldd` behavior or verification status changes until
a selected, measured run supplies the missing evidence.
