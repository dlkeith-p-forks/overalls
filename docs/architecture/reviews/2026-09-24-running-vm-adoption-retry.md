# Running VM adoption retry review

## Scope and observed failure

This review covers Lilly's reconciliation of an already running Firecracker VM
under [ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md).
It does not change the physical identity checks or Cedar's guest authorization
decision in [ADR-0110](../decisions/0110-cedar-guest-ssh-accounts.md).

On Overalls, Marshall reported six active VMs as `unknown` with
`identity_mismatch` while nine were `running`. For the previously reported VM,
Lilly's structured journal repeatedly recorded `vm.adopted` and a `running`
outcome followed by an `unknown` outcome. Its immutable VM claim, Firecracker
process UID, jail root, executable, network namespace, cgroup limits and
Firecracker API ID/state/version matched the expected running placement when
inspected. The alternating observations establish that adoption sometimes
succeeded; they do not by themselves identify every failed predicate on other
polls. After the first rollout, the new structured event identified
`:network_unavailable` on repeated adoption attempts across all 13 running
Firecracker units on Overalls. The host's network claim and lock directory
remained root owned and readable; successful `vm.adopted` events continued
between failures. This establishes transient network-lock acquisition as a
production contributor, while leaving individual failed handshakes unproven.

The running branch in `Lilly.VM.Executor` treated temporary network lock
unavailability as `identity_mismatch`. A VM lock collision is collapsed to
`:execution_unavailable` by the driver and already retried by the executor, but
the driver's zero-retry lock acquisition made the result sensitive to brief
contention. A network lock collision could replace a verified running observation
with `unknown`, briefly denying ingress even though the VMM survived. The same
path handles ordinary start and post-relocation start commands. Other observation
or network identity failures can also produce `unknown`; the exact cause of each
production transition is not yet established.

## Correction and architecture impact

`Driver.adopt` now waits at most two seconds for its existing per-VM native lock.
`Executor` returns `{:retry, reason}` for temporary VM or network lock
unavailability, retaining the last durable observation. Other adoption failures
still withhold a running outcome as `unknown`. The actor's existing observation
freshness limit continues to bound access when a fresh result cannot be obtained.
The reviewed `vm.adoption_unconfirmed` diagnostic records a bounded reason atom
with VM and placement IDs after an unsuccessful adoption. Claim and physical
observation failures now have distinct atoms, so production evidence can
distinguish them from contention without exposing credentials or guest data.
`Network.refresh_labels` now waits at most two seconds for definite contention
on the shared native network lock, using the already tested lock acquisition
primitive. Other network mutations retain their zero-retry behavior. The VM
lock remains held during this refresh, and an unconfirmed lock or claim still
prevents a new running observation.

No lock bypass, guest restart, storage rebinding, authority expansion or protocol
change is introduced. This implements ADR-0017's existing busy-lock retry and
uncertainty rules; its accepted decision and partial implementation status remain.

## Verification and remaining gaps

The focused adoption and actor tests passed. Lilly's full precommit passed again
after the network lock follow-up with 396 tests, including 45 properties, and
zero Dialyzer errors. The four
Firecracker SSH journey and relocation checks for NixOS and Ubuntu passed with
this Lilly change. The revised NixOS and Ubuntu journey checks also passed with
a nondefault client key. The first production rollout reached healthy on both
hosts; Marshall reported all 15 active VMs as running on the sampled query.
The focused Brady flow machine check passed with the bounded network-lock
follow-up. The full Brady fleet check failed twice at its first guest HTTP
assertion; the same check failed at the same assertion on deployed `main` before
this follow-up. The failure does not establish a regression from the lock retry,
and that full scenario remains unverified. Both hosts reached the auto-update
`healthy` phase at `f3d8d1af`. In the first observation window after their Lilly
restarts, Overalls recorded 819 `vm.adopted` events and Dungarees recorded 126,
with no `vm.adoption_unconfirmed` events on either host. Marshall still reported
all 15 active VMs as `running`. This verifies the reduced contention over that
short window; sustained load and the failed Brady suite remain open checks.

The previously reported VM's guest disk predates Cedar and still has no SSH
listener. This change cannot install a guest listener into that existing disk.
Production off-host backups are also not enabled; replacing or migrating that
disk requires a recoverable data plan. The old guest SSH gap remains separate
from this host reconciliation fix.
