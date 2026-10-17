# Focused recorder NixOS VM

`antithesis/nix/recorder-host.nix` builds one TCG NixOS host. Its
`recorder-peer.service` runs the maintained BEAM request-accounting client under
the `recorder-peer` Unix account and `fixture.slice`. The production Rust request
recorder and trace spool have separate accounts, services, sockets and storage.
The producer keeps its marker and fsynced attempted-effect ledger on the root
overlay. The request recorder keeps its checkpoint on that overlay. The trace
spool keeps SQLite in `/archive/state` on a retained, separate **64 MiB ext4
block device**. `/archive/pressure` is a sibling of the spool state, so the
production spool never sees a foreign entry inside its private state directory.

The trace fixtures contain `galileo.request_denied`; the spool's fixed schema
service is therefore `galileo`. Request accounting uses its independent `brady`
source. The different source labels do not grant cross-service authority: both
Rust receivers check the producer's real kernel UID and service cgroup.

The outer workload writes a complete, fsynced JSON request named by 32 lowercase
hex digits to the private request volume. The in-guest bridge accepts only a
closed producer command, an exact `producer|recorder|spool` systemd action
(`start|stop|restart|kill`), `replay`, `pressure_fill`, `pressure_clear`, or
`status`. It publishes a matching result separately. It cannot select an
arbitrary unit, binary, path, shell command or payload. `replay` runs the
production spool with its fixed config as the actual spool account, and only
while that unit is inactive. `pressure_fill` writes at most 64 MiB on the
dedicated archive mount and returns `enospc: true` only after a real write or
fsync reports ENOSPC.

The root-owned observer publishes `identity.json` and `spool_identity.json`
from each exact systemd MainPID and two `/proc` start-tick reads, with expected
UID and cgroup checks. It also exports the real checkpoint, source quality
marker, effect ledger, the kernel boot ID, a read-only SQLite backup, and archive
block-device/free-space measurements. Missing or changed identity removes its
witness. The VM
health check requires a fresh observer sample, active units, both identities,
the distinct 32–64 MiB archive, and readable checkpoint and SQLite state.

Runtime acceptance is pending the serialized VM slot. Build the exact
`antithesis-recorder-host-vmm-context` output, boot its QEMU process, then record
the context derivation, image hashes, QEMU PID, guest kernel boot ID and source
hashes. Before signaling setup completion, require the health check and verify
that the checkpoint's producer PID/start ticks match `identity.json` and the
trace receiver accepts a reviewed batch into its independent SQLite archive.
The focused workload commands are
`test/v1/recorder/first_capacity.py`,
`test/v1/recorder/serial_driver_recovery.py`, and
`test/v1/recorder/serial_driver_traces.py`.

The capacity run must witness all 4096 real pending BEAM workers, the 4097th
unrecorded attempted effect, durable gap quality and two retired workers freeing
capacity. Recovery must retain the exact producer PID/start ticks through a
request-recorder process replacement and conserve the checkpoint. Trace runs
must witness exact accepted SQLite bodies, discarded intake ACK and replay,
then actual archive ENOSPC on the distinct ext4 device. A poisoned-spool
assertion requires the **same** spool PID/start ticks before and after a storage
failure; a restart or missing identity makes that branch unexercised. After
clearing pressure, a deliberate spool reopen must preserve prior bodies and
permit a fresh reviewed batch. Runtime failures or unavailable evidence do not
become passing properties. Static evaluation and unit checks do not establish
these VM effects or hosted Antithesis acceptance.
