# Architecture review: continuous capacity and local receipt

## Scope and affected decisions

Reviewed the real Linux collector, private configuration, OS ownership lock,
durable command store and automatic HTTPS loop, including staged/unstaged changes
and new files. ADR-0013 records authorized implementation details; ADRs 0004,
0005, 0006, 0010 and 0012 remain applicable. No accepted decision is superseded.

## Findings

1. **High — documented unimplemented requirement:** the runtime acknowledges
   durable intent only. VM actors, jailer/systemd placement, image/address
   validation, disk mutation coordination, networking and physical reconciliation
   remain absent. The [pool collector](../../../lilly/lib/lilly/host/pool.ex)
   conservatively excludes sparse files, but a real driver must enforce
   preallocation and serialize mutations before any execution claim.
2. **Medium — documented unimplemented requirement:** key/credential delivery,
   device hot-replacement identity, telemetry aggregation/retention and sampling
   at fleet load remain open. The loop's bounds do not prove 100-node capacity.
3. **Resolved defects:** integer quota division prevents float rounding from
   advertising an extra core. Zero effective capacity now stays a valid fresh
   observation. Cgroup and device helpers normalize failed reads instead of
   accidentally returning malformed successful tuples. Retry scheduling uses
   the actual monotonic time origin. Collector errors remain visible despite
   otherwise successful control requests.

## Verification

Unit/property tests cover ancestor constraints, malformed/escaped/threaded
cgroups, quota precision, CPU sets, counter rates/resets, filesystem reserved
blocks, device overlap/stack rejection, private file modes, OS exclusion,
generation conflicts and reordered durable receipt.

Real host integration uses this Linux VM's ext4 filesystem and cgroup v2, with
Marshall over verified TLS. It checks automatic reports, an admitted Ash command
stored before acknowledgement, Lilly restart/reacquisition, revocation fencing,
pool unavailability/freshness expiry and restoration. This requires neither root
nor KVM and does not start a guest. Explicit host tests are separate from normal
portable tests; three-node control-plane tests remain in precommit.

All three precommit gates pass: Marshall 57 tests/6 properties (including three
independent BEAM nodes), Lilly 21 tests/8 properties and protocol 2 tests/3
properties. Three additional explicit host integration tests pass: 83 tests and
17 properties total. Compiler/format checks pass; Dialyzer has no new findings
and retains only the previously documented upstream Marshall exclusion. Schema
codegen is current. Lilly's production release was rebuilt, started through a
private `LILLY_CONFIG_FILE`, and stopped successfully. The final 13-record
structural check and `git diff --check` pass. These checks do not establish the
remaining VM execution, network or fleet invariants.

## Follow-up

Complete operator enrollment/configuration delivery, then connect durable commands
to independently supervised Firecracker VMs with image/address validation and
profile isolation. Add lifecycle outcome reconciliation and bounded crash recovery.
Keep the full platform goal open, including sharing, terminal writer ownership,
retention, multi-host KVM proof and scale measurements.
