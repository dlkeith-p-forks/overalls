# Guest terminal witnesses

The TCG guest image alone builds terminald with `antithesis-observer`. Its
second AF_VSOCK listener (port 1076) accepts kernel-observed host CID 2 and
terminald's current boot HMAC hello. It serves one bounded, read-only request
per connection. The ordinary port 1075 and production build keep their existing
protocol.

Both requests use terminald's `0x4c, op, u16 length, payload` frame. After a
normal HELLO (`op=1`), `SNAPSHOT` (`op=0x20`, empty body) returns an `OP_OK`
frame with this big-endian version-1 payload:

| Field | Type |
| --- | --- |
| version, session count | `u8`, `u8` (at most 64) |
| PTY births, retirements | `u64`, `u64` |
| aggregate ring reservation, viewer permits | `u32`, `u16` |
| terminald lifetime | PID `u32`, `/proc` start ticks `u64` (zero means unknown) |
| marker record count | `u8` (at most 128) |
| marker digests | record count × 16 raw FNV-1a-128 bytes, with duplicates |
| each sorted session | ID `u64`, child PID `u32`, `/proc` start ticks `u64` (zero means unknown), alive `u8`, ring base and tail `u64` each, logical limit and actual `VecDeque` allocation `u32` each, viewer count `u8` |
| each session viewer | queued bytes `u32`, socket writer blocked flag `u8` |

`INPUT_STALL` (`op=0x21`, body one session ID `u64`) returns `OP_OK` with
master-input write in-progress `u8`, monotonic elapsed milliseconds `u64`, and
child PID `u32`. This reads atomics and stays available while a PTY write holds
the session mutex. An in-progress flag alone does not prove a sustained block;
the workload must observe elapsed time above its threshold.

The separately packaged `/run/current-system/sw/bin/overalls-terminal-probe`
accepts exactly one 32-character lowercase hexadecimal marker through its PTY
stdin. It appends only the FNV-1a-128 digest to a root-private `/run` ledger,
syncs the file, and then emits a fixed `ACK`. The snapshot reads these records
under a shared lock. The ledger survives terminald restart within the same
boot, but `/run` is ephemeral across guest reboot. FNV is a synthetic marker
identity, not a secret or authentication proof. A malformed ledger or failed
observation yields no snapshot; callers must treat that as unknown.

These witnesses report guest-local process, allocation, pressure and consumed
marker facts. They do not prove Firecracker/KVM isolation, native ZFS, or
Marshall-to-Lilly data-frame deduplication. No hosted guest workload has yet
passed against this image.
Birth and retirement counters are scoped to the daemon lifetime; compare them
only when both nonzero PID/start-time pairs match.
