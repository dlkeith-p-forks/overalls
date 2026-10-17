# Resizing a machine

Owners and managers can open **Resize** from a machine's details page. CPU and
memory may increase or decrease; disks may only grow. The page shows confirmed
resources and the requested changes separately. Image minimums and the shared VM
limits apply. Resource drafts survive page refresh and browser reload. If the machine changes,
review its confirmed resources and use **Use current machine state, keeping these
sizes** before submitting the stale draft again. This refresh does not resize the
machine. After a successful resize, a new form starts from the confirmed sizes.

**Resize and restart** stops a running machine, changes its resources, and starts
it again after checking current headroom. Expect downtime. **Resize machine**
keeps a stopped machine stopped. The guest grows its filesystem on its next boot.
The machine retains its data, placement, address, image, identity and sharing.

If a phase fails, **Retry resize** resumes the recorded workflow after checking
current management permission and capacity. Confirmed disk growth is retained.
A failed restart is fenced and stopped before another restart is allowed.
Unconfirmed physical state retains its reservations and blocks other lifecycle or
relocation work; a failure message is not proof that execution or storage is gone.
There is no disk shrink, live resize, relocation fallback, cancellation or SSH
resize command.

## Coordinated deployment

Resize changes Marshall's schema and the shared execution contract. Build Marshall
and Lilly from the same revision and deploy their shared protocol together. Apply
the ordinary release migrations before serving the new resize action. The normal
automatic updater migrates before stopping consumers; use a coordinated maintenance
window for this upgrade:

1. Pause automatic updates and remove Marshall from traffic. Stop every Marshall
   instance and Lilly daemon, leaving PostgreSQL and independently supervised guests
   running. Confirm both old consumer versions are stopped.
2. Run the new release's serialized migration with the existing database, TLS and
   encryption configuration. The required operation snapshots must be present
   before accepting further commands.
3. Activate the same reviewed revision on both consumers, start them and verify
   Marshall readiness and Lilly reconciliation before restoring traffic.
4. Exercise a resize on a disposable VM, confirm resources and retained data, then
   restore automatic updates to the reviewed deployment revision.

Do not operate mixed consumer versions or roll an old Lilly back over a store containing
resize commands. The original provisioning sizes and immutable operation payloads
are backfilled by the migrations; no capability negotiation or compatibility mode
is provided.

Complete the native `zfs-guest` check on a disposable nested-KVM builder before
production rollout. It exercises interrupted disk growth and metadata publication,
CPU/RAM increases and decreases, filesystem expansion, data preservation, stopped
behavior and a running neighbor. Application tests and building the test driver
alone do not establish those physical properties. See the
[resize review](../architecture/reviews/2026-09-17-vm-resizing.md) for executed checks
and remaining acceptance work.
