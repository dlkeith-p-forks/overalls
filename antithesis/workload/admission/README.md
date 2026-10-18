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

## Stub storage substrate (`admission-stub` profile)

The `admission-stub` selection profile
(`verification/selections/admission-stub.json`, overlay
`config/compose.admission-stub.yaml`) runs the atomic-allocation and
key-replay commands on the base graph with a harness **stub** storage
substrate. It is not ZFS. The controlled Lilly release reads a fixed private
substrate file written by `entrypoints/lilly.sh` and reports configured stub
pool totals for the enrolled pool identity, with no allocation credit. Host CPU
and memory headroom remain measured by Lilly's real usage sampler over the
container's cgroup subtree. Lilly digest-verifies a tiny non-bootable stub
image (`Lilly.Host.Image.load/1`), and the enrollment operator registers its
manifest through Marshall's reviewed `Images.register` action, then enables
lilly-a through the reviewed CLI `enable` action once Lilly's stub report is
fresh and execution-ready (Marshall excludes a disabled host from catalog
capacity). A fully
stub-backed report advertises placement readiness so Marshall's real
admission transaction can choose the host; the controlled executor still only
publishes requested work and never launches a guest. The bootstrap probe
requires the enabled normal-mode host, the committed execution-ready report,
measured compute headroom, a
fresh stub pool row and an enabled advertised image in SQL before setup.

Each command logs a fixed `Compute admission unexercised: <reason>` INFO line,
once per reason and process, whenever it stops before a settled Marshall
decision (catalog reply unavailable, capacity unknown, no advertised image, SQL
snapshot or operator reply unavailable, operator image precheck, or a delete
that was never observed archived). The catalog's unlocked headroom only
prefers a fitting image: when measured CPU or memory headroom is below the
request shape the request is still submitted, because Marshall's serialized
admission transaction decides placement. A definite `insufficient_capacity`
refusal is a real admission decision: the atomic command asserts it left no
rows, and the key command replays the refused key once and asserts it admits
at most one VM. The hosted run `8e582f650dd7092cda983705eb7b0e05-65-0` returned
before any of this silently, because these INFO lines were never configured
and the old catalog fit check withheld submission.

Admission decisions, idempotency history, rows and dispatch jobs are all real
Marshall effects; only the storage substrate (and the image artifacts) are
stubbed. Results from this profile are admission-logic evidence. They are not
ZFS, physical-capacity, KVM, Firecracker or isolation evidence. Because the
controlled executor never completes a delete, the archived-replay branch of the
key command stays unexercised under the stub.

## Measured physical capacity

The capacity command lives in its own `test/v1/admission_physical` template
and `admission/physical_scenario.py` module, so the stub profile never declares
its live-ZFS assertions. No profile selects it yet.
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
