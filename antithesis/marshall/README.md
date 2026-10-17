# Marshall terminal replay observer

The `ANTITHESIS_HARNESS=1` Marshall build includes `OverallsAntithesis.Marshall.TerminalReplay`.
The ordinary release does not compile the module. In the `compose.host-vmm.yaml`
template, the enrollment operator and both Marshall replicas share the private
`/run/overalls-terminal-replay` volume; the workload and Lilly do not mount it.

The operator creates `claimed/` and `receipts/`, then exclusively publishes one
`active.json` at a time. Its exact version-1 JSON fields are `request_id`,
`host_id`, `connection_session_id`, `connection_epoch`, `terminal_session_id`,
`vm_id`, `placement_id`, `execution_epoch`, `guest_session_id`, and `channel`.
IDs are lowercase UUIDs, and all numeric fields are positive integers. The
connection epoch belongs to the authenticated host stream; execution epoch
belongs to the VM placement. The operator must validate current fixture and VM
ownership before publication.

On the next matching viewer input, HostStream checks the current host credential
and connection, validates the attached channel's exact identity, then atomically
moves `active.json` to `claimed/<request_id>.json`. It returns the original
encoded DATA frame followed by the identical encoded DATA frame in one WebSocket
binary reply. A cumulative input ACK from Lilly for that sequence causes a
`receipts/<request_id>.json` with `state: "acknowledged"`, `channel`, `sequence`,
and `acknowledged_frames`. The ACK is possible only after Lilly has decoded both
frames in that WebSocket payload. The receipt contains no terminal bytes and
does not itself prove how many times the guest executed the input; the guest
probe's fsynced digest ledger supplies that independent effect evidence.

An arm that never matches or loses the stream has no acknowledged receipt. A
claimed arm is never replayed again, including after Marshall restarts. The
operator must treat a missing receipt as unavailable rather than infer success.
