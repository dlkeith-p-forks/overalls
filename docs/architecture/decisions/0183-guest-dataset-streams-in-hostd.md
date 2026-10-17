# ADR-0183: Guest dataset streams run in lilly-hostd

- ID: ADR-0183
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: Lilly, lilly-hostd, lilly-transfer-stream, NixOS lilly module
- Supersedes: none
- Superseded by: none

## Context

[ADR-0182](0182-unprivileged-lilly-beam.md) step 3 planned to move the
transfer and export helpers into hostd jobs. As first built, the BEAM ran
them itself as `lilly`, and each pool dataset delegated
`send,receive,create,mount,snapshot,hold,release,userprop` to that user.

That design failed and was unsafe:

- **It failed.** The unprivileged zfs-guest cross-pool clone ended with
  `received_dataset_unconfirmed`. A throwaway-pool experiment showed why: a
  delegated, non-root `zfs receive -o …` exits 0 but silently drops every
  non-user property it was given (`readonly`, `exec`, `setuid`, `devices`,
  `canmount`, `mountpoint`, …). Lilly's verification then correctly
  refuses the dataset.
- **It was a privilege hole.** Any process with the `lilly` uid could
  receive a crafted stream. The received dataset would inherit `setuid=on`
  and `devices=on` and be mounted at the next boot, which means root-owned
  setuid binaries or device nodes on the host. The same process could also
  `send` any guest disk under the pool.
- **Inheritance cannot fix it.** The pool dataset cannot carry
  `devices=off`, because the jails beneath it need `/dev/kvm`.

The delegation existed only in an unshipped batch; production still ran
Lilly as root. The user asked for the most secure implementation and
needed no backwards compatibility (2026-10-16).

## Decision

Accepted by the user on 2026-10-16 (plan approval: "the best possible
implementation that's secure"). This replaces ADR-0182 step 3's delegation;
the rest of ADR-0182 stands.

1. **No ZFS delegation.** The `lilly` user holds no ZFS permission on any
   pool. `lilly-ownership` revokes any delegation an earlier build granted.
2. **One typed hostd request.** `TransferStream` (protocol op 11) carries a
   held lease, a deadline (1–86 400 s), a byte rate and a typed producer
   and consumer, never argv:
   - producers: a local `send` of `<pool>/vm-<placement>@lilly-b`; a
     local resume (`lilly-resume-token` must first accept the snapshot,
     to-GUID and token); an SSH pull with verb export, resume or probe;
   - consumers: a `receive` into `<pool>/vm-<placement>`; a probe compare
     against a Lilly file.
3. **hostd derives every command.** hostd builds `zfs send`,
   `zfs receive -u -s` (the twelve fixed policy properties, the mountpoint
   and the four `lilly:*` markers), `ssh` (fixed options, user
   `lilly-transfer`, fixed remote verbs) and `cmp` from validated fields.
   Pools must be configured `--pool-dataset`/`--socket-root` pairs.
   Placements and ids must be UUIDs, nonces 32 lowercase hex and tokens in
   the ZFS resume-token grammar. Paths must be inert and absolute. The
   generic `Run` request refuses the stream helper, `ssh` and `cmp`.
4. **Least privilege inside the stream.** Only the ZFS sides run as root.
   The SSH producer and the compare consumer run as the service uid, with
   no supplementary groups, no new privileges and a parent-death signal set
   after the uid drop. They read Lilly's own key files by path. A root
   hostd serving another uid with no service uid refuses those sides.
5. **Custody is the lease.** The helper runs under the caller's stream
   lease with ordinary command custody: the deadline, the caller's death or
   a released lease kills and reaps the whole pipeline before hostd replies.
   hostd returns the helper's closed exit code, which Lilly maps to
   `Stream` failure atoms.
6. **Progress is a file.** hostd opens `<lease directory>/progress` beneath
   its roots and passes it to the helper. The helper `pwrite`s an 8-byte
   big-endian byte count there, and Lilly polls it. Counts are never a
   receipt.

The source host's root export worker (`lilly-source-export`) is not the
Lilly service and keeps its trusted argv.

## Alternatives

- **Delegation plus property fix-up.** hostd sets the dropped properties
  after a delegated receive. This was rejected: there is a window in which
  a dataset received with `setuid=on` is mountable, and `lilly` can still
  receive arbitrary streams.
- **A durable hostd job with fd-passed key files.** The plan proposed a job
  that outlives hostd and passes the key and known-hosts file as
  `/dev/fd` paths to a root `ssh`. This was rejected for two reasons: the
  ordinary lease semantics already revoke a stream on caller death, and
  running `ssh` as the service uid keeps the network-facing client
  unprivileged.
- **Caller-built argv with a validator.** A validator for a caller-built
  argv would have to parse it back, whereas hostd already knows every
  legitimate shape.

## Consequences

- A compromised BEAM can no longer create a setuid or device-bearing
  dataset, or read another placement's disk with `send`. It can only ask
  hostd to stream a placement it names into a policy-fixed target.
- A hostd restart kills in-flight streams; ZFS resume tokens recover them,
  as before.
- Machine-test fixtures can no longer inject arbitrary producers or
  consumers through Lilly. Fixtures that need fault injection (a partial
  receive, a blocked sender) use typed consumers with rate and deadline
  limits, or call `ssh` directly.

## Invariants and verification

- The derived argv equals the expected argv for every producer and
  consumer, and every out-of-grammar field is refused:
  [`transfer_tests.rs`](../../../lilly/native/hostd/src/transfer_tests.rs)
  (including a Hegel decode round trip and a real `ssh -G` resolution of
  the fixed options).
- The stream runs under a lease, the resume check gates a local resume,
  and the helper's code is returned:
  [`tests.rs`](../../../lilly/native/hostd/src/tests.rs)
  (`transfer_streams_run_the_helper_under_the_lease`,
  `local_resume_requires_the_token_check`).
- The helper drops privilege only for the named sides, writes the final
  progress count and refuses a non-regular progress descriptor:
  [`stream.rs`](../../../lilly/native/transfer-stream/tests/stream.rs).
- Lilly's deadline, failure, owner-death, contention and grammar refusals:
  [`stream_test.exs`](../../../lilly/test/transfer/stream_test.exs).
- Native evidence required: the zfs-guest cross-pool clone, zfs-transfer,
  export-endpoint (pull, partial and resume, cancellation) and
  `zfs allow` showing nothing for `lilly` on deployed hosts.

## Implementation evidence

- hostd: [`transfer.rs`](../../../lilly/native/hostd/src/transfer.rs)
  (`hostd-transfer-stream-typed`),
  [`session.rs`](../../../lilly/native/hostd/src/session.rs)
  (`hostd-transfer-stream-under-lease`),
  [`leases.rs`](../../../lilly/native/hostd/src/leases.rs)
  (`lease-progress-file-beneath-root`),
  [`utilities.rs`](../../../lilly/native/hostd/src/utilities.rs)
  (`typed-only-utilities`).
- Helper: [`lib.rs`](../../../lilly/native/transfer-stream/src/lib.rs)
  (`transfer-pins-children-to-owner`).
- Lilly: [`Hostd.transfer_stream/6`](../../../lilly/lib/lilly/host/hostd.ex),
  [`Stream`](../../../lilly/lib/lilly/transfer/stream.ex),
  [`ReceivedDataset`](../../../lilly/lib/lilly/transfer/received_dataset.ex)
  (`receiver-fields-from-local-intent`),
  [`SSH`](../../../lilly/lib/lilly/transfer/ssh.ex),
  [`SourceSnapshots.local_producer/3`](../../../lilly/lib/lilly/transfer/source_snapshots.ex).
- Module: [`lilly.nix`](../../../nix/domains/system/lilly.nix)
  (`lilly-unprivileged-mode`: revocation, fixed uid and gid 377).

- Machine runs (2026-10-16, local, both passing): `zfs-transfer`, which
  includes the production helper stream, revocation, resume and the adoption
  fault latches. `export-endpoint`, which covers the cross-host SSH pull,
  interrupted-stream resume, command refusal, listener shutdown, revocation and
  the probe-only credentials. The second needed the export worker unit to drop
  `RestrictSUIDSGID`, whose `openat2` ENOSYS refused every private-hostd lease.

- Machine runs (2026-10-17, local): `zfs-guest` passed every subtest
  through the cross-pool clone, the no-delegation refusal and the root-era
  handover; its final Inception clone subtest still fails (Inception is
  outside this rollout) and its `coding-clis` step, failing on main, was
  skipped locally. `ssh-transfer` passed after its fixture moved from a raw
  `dd` consumer, which hostd now refuses, to the typed `compare` consumer: the
  32 MiB pull matches byte for byte, a last-byte mismatch is refused, and the
  wrong-host-key, unpermitted-key, fenced-permit and retired-key cases refuse.

  `zfs-guest-clone` (1,887 s), `source-export` (156 s), `audi-service` (81 s)
  and `enrollment-operator` (59 s) passed on the same revision. The last
  needed its fixture to create the `nix/policy` directories that the
  2026-10-16 domain reorganisation moved `users.nix` and the secret documents
  into.

- Machine run (2026-10-17, local, `df94ad026`): the multi-host `fleet`
  test passed all 20 subtests (1,893 s) with unprivileged Lilly. Getting
  there exposed and fixed three faults recorded under ADR-0182: the pool
  imported after the ownership handover in its fixture, a root-only control
  CA and unreadable private readiness sockets. It also fixed a trust
  confirmation that starved behind hostd's placement lease, and the
  findings in the
  [socket review](../reviews/2026-10-17-lilly-owns-every-socket.md).

Remaining gap: a production VM create, delete and clone with this design
are not yet recorded.

## Open questions

None.

## Related decisions

- [ADR-0182](0182-unprivileged-lilly-beam.md): this decision replaces its
  step 3 (ZFS delegation).
- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): hostd as
  the only root component, leases and command custody.
- [ADR-0155](0155-stopped-only-relocation.md): the single `lilly-b`
  transfer snapshot every stream binds.
