# Recorder workload peer

`peer.exs` is a harness-only BEAM application using the production
`Overalls.RequestAccounting.Producer`. It owns real monitored workers, retains
their opaque tickets and appends one fsynced numeric fixture effect for every
attempt, including an unrecorded admission. Its packet-4 JSON control socket
accepts only `hello`, bounded `admit`, `finish`, `finish_many`, `kill_worker`,
`recorder_uncertain_admit` and reviewed `trace` operations. The uncertain Admit
and `trace` `lose_ack` variants send complete requests through real authenticated
Unix sockets and deliberately discard their replies. They do not fabricate a
committed outcome. The peer does not produce an accounting model or
claim that its replies prove Rust custody.

The peer needs `FIXTURE_CONTROL`, `FIXTURE_RECORDER`, `FIXTURE_MARKER`,
`FIXTURE_EFFECTS`, `FIXTURE_TRACE_SOCKET`, `FIXTURE_TRACE_SMALL` and
`FIXTURE_TRACE_LARGE`. The last two point to the reviewed native fixture hex
files, `nix/tests/fixtures/trace-spool/request.hex` and `batch.hex`.
It must run under the actual configured producer UID and cgroup. The Rust
request recorder and trace spool must run independently, with durable state on
retained storage. A hosted container cgroup with no matching `*.service`
component fails the production recorder's peer check; the workload cannot
call that an admitted measurement.

The Python workload uses the recorder-host VM's closed request/result files.
The bridge exports the real recorder `state.json` and `quality`, separate
effect file, read-only SQLite archive snapshot, kernel producer identity and
archive filesystem measurements. The workload keeps attempted and acknowledged
operations and accepted archive digests in its own SQLite ledger. Production
spool replay runs only while the spool unit is stopped, using its fixed NixOS
command and owner UID. Unavailable checkpoints, kernel identity, replay or
physical backing exhaustion remain unobserved. The exact 4,096-worker campaign
selects a long admission deadline so capacity does not become a deadline test.
