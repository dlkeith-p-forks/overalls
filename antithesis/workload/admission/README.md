# Marshall admission workload

The three `serial_driver_*` commands in `test/v1/admission` use the trusted
`compute.*` operator actions with the fixture's `admin_a` identity. Each
provision request has a workload-generated key and is recorded before dispatch.
The operator performs the real Ash action; the workload reads PostgreSQL through
the SELECT-only oracle afterward. An unavailable operator result or SQL read is
unknown, including when the first request may have committed before its reply
was lost.

The atomic command checks the first committed allocation's VM, current
placement, matching reservation and address, provision operation and qualified
Oban dispatch job in one PostgreSQL statement. The job check is immediate; job
retention can remove evidence later. The key command repeats the exact request,
tries one changed name, requests real lifecycle deletion, and only enters its
archived branch after SQL observes `archived_at`. The operator serializes these
requests, so this template does not cover cross-node simultaneous first admits
or a cut at the actual commit boundary.

The capacity command needs the `compose.host-vmm.yaml` overlay and a fresh
read-only `/run/overalls-host-observation/physical.json` sample from inner Linux
and OpenZFS. It waits up to four seconds for a sample newer than the SQL
pre-frame, before submitting an admission. It checks exact pool/dataset GUIDs and independent ZFS available
bytes, then compares a newly acknowledged reservation with pre/post SQL snapshots
only if the report and all earlier holds stayed unchanged. A concurrent report
or hold change leaves the commit-time budget unknown to this observer. A sample
older than the SQL frame, or a later ZFS free-byte disagreement, is also unknown:
unrelated physical I/O can change free space between these independent reads.
The sample records cgroup CPU and memory values, but this command does not
correlate them with the production usage interval. Exact commit-time physical
headroom and native KVM or Firecracker isolation remain unverified.

`AdmissionOracle.recovery` exposes retained crash timestamps, held resources
and durable recovery operation count. The crash-recovery property has no selected
test command until an exact physical guest-crash actuator and independent exit
receipt exist and Lilly's runtime loss watcher is verified. A managed stop is
not a crash stimulus.
