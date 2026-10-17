# Enrico repository workload

The four commands in `antithesis/test/v1/repository` exercise three repository
properties against the optional origin and Enrico Compose overrides. They require
the private, trusted Marshall fixture manifest and closed `refresh_repository`
operator action. Workload code never writes Marshall's database or repository
state directly.

`serial_driver_published_head.py` begins only when Marshall's registered row is
`ready`, its published SHA matches the fixture's current Git head, and a native
read of the mirror's `README.md` has the expected sentinel. It force-pushes the
fixture's branch to the unrelated commit, asks the real Marshall Catalog action
to enqueue an Oban refresh, sets a synthetic Git transport failure, and requires
a fresh failed attempt in the SQL audit. If Marshall still publishes the prior
SHA, an explicit SHA Git read from the read-only bare mirror and Enrico's
authenticated blob API must return the original bytes. An unavailable SQL,
operator, Git or API observation is unknown, not evidence of absence.

`serial_driver_attempt_replay.py` repeats the same Enrico repository and attempt
IDs during an actual native Git operation and after its completed receipt. The
independent origin receipt journal must show no new Git request after a retained
replay. `singleton_driver_replay_cap.py` is a bounded, at-most-once-per-timeline
campaign of 1,025 real completed native Git attempts. It checks that the oldest
receipt is missing and a newest receipt remains replayable without a second
upstream request. The guarantee ends at eviction or service restart; the command
does not assert indefinite exactly-once behavior.

`serial_driver_native_admission_restart.py` fills eight native flock slots,
restarts the exact Enrico release through a closed request/receipt path, waits
for old slot owners to retire, fills the slots again, and probes ninth admission.
It cross-checks live flock occupancy with a fresh passive `/proc` observer
snapshot for the restarted generation. The snapshot is a point-in-time witness;
the assertion does not claim continuous process enumeration between samples or
detect descendants that bypass all native lock descriptors.
The workload cannot select a process, executable, command argument or service
other than the fixed Enrico restart operation.

The required inputs are `ANTITHESIS_ENRICO_URL`,
`ANTITHESIS_ENRICO_CA_FILE`, `ANTITHESIS_ENRICO_TOKEN_FILE`,
`ANTITHESIS_ENRICO_MIRROR_ROOT`, `ANTITHESIS_ENRICO_CONTROL_ROOT`,
`ANTITHESIS_ENRICO_OBSERVER_FILE`, `ANTITHESIS_ORIGIN_ADMIN_URL`,
`ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE`, `ANTITHESIS_REPOSITORY_FIXTURE_FILE`,
and the shared core SQL and Marshall settings. Credentials remain in private
runtime files; assertions contain only fixed outcome text.

These are workload definitions, not recorded passing execution. A full
`snouty validate` or Antithesis run must use the merged Compose overrides and
record which branches and assertions actually fired before claiming acceptance.
