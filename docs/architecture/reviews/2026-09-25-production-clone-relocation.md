# Production Porsche clone and relocation acceptance

## Scope and architecture impact

On 2026-09-25, the operator authorized creating fresh production fixtures through
Porsche at `overalls.dev`, cloning, both relocation directions between Overalls
and Dungarees, and concurrent same-source and opposite-direction requests.
Administrative SSH and sudo were used only for read-only diagnosis. Successful
fixtures were to be removed; failed fixtures were to remain for investigation.

**Acceptance failed: a pre-existing clone retained Overalls' transfer slot.**
Creation and guest access passed. The requested copy and physical moves did not
complete. No implementation, protocol, authority, or deployment change was made.
This review adds evidence for [ADR-0055](../decisions/0055-queued-machine-cloning.md)
and [ADR-0092](../decisions/0092-portable-workload-bundles.md), carrying forward
[ADR-0046](../decisions/0046-porsche-ssh-management.md) and
[ADR-0089](../decisions/0089-porsche-user-relocation.md). Accepted rationale and
implementation status remain unchanged; historical native successes do not imply
that the currently deployed fleet can admit a new transfer.

Source inspection used `58cf73900d0013e477e358659d51586b74478590`.
At 22:12 UTC both hosts reported updater revision
`e30726885830264580b60b438dac9a42ae38d88f`; the inspected clone coordinator,
clone placement, relocation capacity and transfer-slot modules have no diff
between those revisions. Overalls' system closure changed between the 22:07 and
22:12 observations, from `7q7bfilp5grw3hdn90m7apakcwp93k4l` to
`zdk90blakm62190drxwx0j3q38v8972i`; Dungarees retained
`ygbk0xnr1c0bhag3c0lqglacfv4aa4ks`. All are NixOS system-store hash prefixes.
This run was not a frozen-release experiment, and no updater was invoked by it.

## Executed scenarios

The source was `acceptance-0925-220708`, VM
`55df4998-77cf-4d51-a2a6-ee089d4393e3`, created on Overalls with the advertised
NixOS image, OSS profile, 1 vCPU, 512 MiB memory and 4 GiB disk.

| Scenario | Request identity | Observed result |
| --- | --- | --- |
| Fresh creation | `b1178abe-8756-4e09-8817-104ae5a1972c` | Succeeded; operation `db4b0d7a-f2a1-41fc-8049-f112588e8f25`; accepted at 22:08:57, success observed at 22:09:18 UTC |
| Guest SSH and synthetic file | Source VM above | Passed at 22:09:47 and 22:13:35; checksum unchanged |
| Clone | `7a5eed31-ddd5-4879-9348-6fbf924102e5` | Accepted at 22:09:56, then failed `source_unavailable`; clone `dcf1f369-80aa-4792-bd04-1f1ff5d449f7` |
| Overalls to Dungarees relocation | `3e94dd6f-6666-48e2-a29e-b8850a333810` | Refused `transfer_busy` at 22:10:26; no relocation admitted |
| Concurrent same-source clone | `b6bcef90-aed7-4789-b8e9-7513106c52f2` | Accepted, then failed `source_unavailable`; clone `6b75de4c-3f64-4af0-bce5-9111d6056e6c` |
| Concurrent same-source relocation | `bd5101be-390c-4f1d-bafb-2577a2dc9e4d` | Refused `transfer_busy` |
| Exact creation and clone replays | Original identities above | Retained original VM, destination identities and operation IDs; failed clones remained failed |
| Return relocation and opposite-direction concurrency | Not submitted | Blocked: no successful clone or relocation could establish the required fixtures |

The two concurrent SSH invocations left a shared thread barrier at
22:11:00.391 UTC. Both encountered the pre-existing transfer occupancy; this
does **not** establish which request wins a race on otherwise available hosts.
Porsche exit statuses were checked alongside structured receipt status; initial
queue acceptance was not counted as successful cloning.

The synthetic file SHA-256 remained
`0c57c78499f602679c6b90ca0df615338f1d94970df444e5d439a2c9c7c4bc7d`.
The source's exact systemd VM unit was active and its exact ZFS dataset existed
at final physical inspection. Read-only SQL confirmed zero created destination
VMs for both failed clone identities and zero relocations for the new source.
Neither independent clone writes nor post-move guest data preservation was tested.

## Findings and source explanation

**High: retained clone recovery blocks new transfers involving Overalls.**
Clone `fd660424-11a0-4087-ae91-a659320b6fac`, created at 09:23:37 UTC before
this run, remained active in `cleaning`, with `source_restart_failed`, null
`source_restored_at`, and a published destination. Its one Overalls transfer
slot remained unreleased at 22:13 UTC. Both hosts were enabled, in normal
maintenance mode, and reporting fresh observations.

The older source `e93801d3-90ef-4f20-84b7-b44cd5ef68d2` was observed failed
with `execution_failed`; its VM unit was inactive. Its published destination
`cd9369eb-04a3-4f2c-85f9-e85fd87faeec` was observed running in PostgreSQL.
Lilly logs show the source stopped, restart requested at 09:23:52, failure at
09:23:53, and repeated `vm.failure_cleanup_unconfirmed` events with
`stage=network`, `reason=network_unavailable`. A narrower event projection finds
`vm.launch_preparation_failed` with `reason=disk_not_ready` at 09:23:53.015,
before `vm.failed` at 09:23:53.062. That diagnostic's `vm_id` is the older
source's placement ID `77d84d25-76da-4029-8b7c-61f1e8eb9e5f`, matching the
[driver's use of the placement specification](../../../lilly/lib/lilly/vm/driver.ex).
[Disk readiness](../../../lilly/lib/lilly/vm/disk.ex) collapses failed native
dataset/readiness validation or portable-bundle loading to `disk_not_ready`.
The exact failing predicate is not established. Network cleanup warnings are
subsequent evidence, not proof of the original launch cause. No disk or network
repair was attempted.

[Clone placement](../../../marshall/lib/marshall/compute/clone_placement.ex)
rejects an occupied source host as `source_unavailable` before stopping or
allocating a destination. [Relocation capacity](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
rejects an occupied source as `transfer_busy` and excludes occupied destinations.
With this two-host fleet, occupancy prevents movement in either direction.
[Transfer slots](../../../marshall/lib/marshall/compute/transfer_slots.ex) reserve
both endpoints atomically, so even after recovery, opposite-direction attempts
must serialize or refuse busy admission; simultaneous copies are not promised.

[Clone coordination](../../../marshall/lib/marshall/compute/clone_coordinator.ex)
requires source restoration, revoked effects, snapshot pruning and destination
settlement before releasing its slots. This preserves ADR-0055's physical
uncertainty contract. The observed availability failure is not evidence that
force-releasing the slot is safe.
[Clone controls](../../../marshall/lib/marshall/compute/cloning.ex) support
explicit retry of source restoration. Recovery of the older workload requires
investigating its disk-readiness and cleanup failures, then using the supported retry path
and verifying restoration, cleanup and slot release. The older workload was
outside this run's mutation scope; it was not retried or cancelled.

After recovery, repeat baseline cloning, independence checks, both physical
relocation directions, and both concurrency scenarios. Add native regression
coverage for a published clone whose source restart fails while unrelated VMs
attempt clone and relocation; retain property checks for ownership and slot
release. This review does not replace those preferred tests.

## Evidence, retention and validation

Private command timestamps, intents, receipts, filtered structured logs and SQL
results are retained outside Git at
`/home/ghuntley/porsche-acceptance/porsche-20260925-220708/`.
Administrative known-host entries were added using keys verified against the
repository's existing host identities. Database queries used `BEGIN READ ONLY`;
there were no database writes, service restarts, forced cleanup or deployments.

Retained failure fixture: `acceptance-0925-220708` on Overalls, VM
`55df4998-77cf-4d51-a2a6-ee089d4393e3`. The two failed clone requests reserved
identities but created no destination VMs. No additional successful fixtures
exist to delete. The pre-existing clone and its machines remain untouched.

The private typed Python command recorder passed Ruff formatting, annotation/lint
checks and `ty check --python-version 3.13`; it executed on the available Python
3.14.7 runtime, so Python 3.13 execution is not claimed.

Validation in `devenv shell`:

- Marshall `mix precommit` passed with isolated local partition
  `_porsche_20260925_220708`: 1101 passed (113 properties, 988 tests), 2 excluded,
  seed 813340, 442.9 seconds for ExUnit. Terminal, dashboard and workspace checks
  passed; forced Dialyzer finished with zero errors, skipped warnings or
  unnecessary skips. This is local regression evidence, not production transfer
  acceptance.
- ADR structure/local-link validation, contract syntax/discovery, HLDD review
  receipts, generated scenario/options checks and Ash/topology views passed.
- `nix build .#checks.x86_64-linux.hldd --no-link` passed, including evaluated
  deployment topology. These checks establish documentation consistency only.
- `git diff --check` passed. The final diff contains documentation and reviewed
  evidence receipts only. No runtime implementation or accepted contract changed.
