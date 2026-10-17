# Host maintenance and retirement

Maintenance uses the trusted Marshall release command environment described in
[provisioner enrollment](provisioner-enrollment.md). Deploy the host-maintenance
migration and compatible Marshall code on **every node** before using these
commands. Deploy the updated Lilly executor for stop/delete lock-contention retries.
The migration is forward-only: rolling it back would erase maintenance
history and operation provenance. Lilly continues to use the existing v2 protocol.

## Drain for maintenance

Choose and save a UUID for this request and a public operator/ticket reference.
The reference starts with an ASCII letter/digit and contains at most 128 letters,
digits, `_`, `.`, `:`, `@`, `/` or `-`. Do not put secrets in it.

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' show lilly-host-01
bin/marshall eval 'Marshall.Operations.CLI.main()' drain HOST_UUID REQUEST_UUID ops:ticket-123
bin/marshall eval 'Marshall.Operations.CLI.main()' drain-status REQUEST_UUID
```

Drain immediately disables admission and new starts on that host, then stops its
VMs through AshOban in batches of at most twenty. This interrupts guest execution
and terminal sessions. It retains each VM's disk, address and host assignment.
It does not migrate guests. Automatic crash recovery is suppressed. User deletion
continues normally; a drain does not turn deletion into a retained stop.

The command commits the request, admission exclusion and initial job together.
An uncertain command result is safe to retry with the **same three arguments**.
Changing the host or reference for the same request UUID conflicts. Only one
open drain is allowed per host. `show` includes `maintenance_mode` and
`active_drain_id`. The operator process can insert jobs, but consumes none;
serving Marshall nodes run the `maintenance` queue and periodic recovery scheduler.

| Field/status | Meaning |
| --- | --- |
| `draining` | Intent accepted; guests may still be running or unreachable |
| `drained` | At a recorded instant, every live VM was confirmed stopped, no compute reservation remained, and a fresh ready report existed |
| `currently_quiescent` | The open drain still meets those conditions now |
| `report_fresh` | The latest observation is within the configured freshness window |
| `compute_allocations` | Reservations still holding CPU and memory |
| `retained_disks` | Reservations still holding disk capacity |
| `stop_requests` | Maintenance-origin stop operations recorded for this drain |

For maintenance readiness, require `status=drained` **and**
`currently_quiescent=true`. Historical `quiesced_at` remains visible after reports
become stale. An offline host can remain pending indefinitely. Timeout, delivery,
an empty job queue or a stop request never proves physical shutdown. Inspect and
repair Lilly's reported failure; there is no force-release shortcut.

## Resume service

After maintenance, let Lilly reconnect and publish a fresh execution-ready report:

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' resume-host REQUEST_UUID
```

Resume requires confirmed, currently fresh quiescence. It closes the drain and
enables admission. VMs remain stopped; owners/managers explicitly start them, and
starts still require enough CPU/RAM on the original host. Repeating resume is
idempotent. A later maintenance window needs a new request UUID.

`disable HOST_UUID` remains an admission control and does not stop VMs. `enable`
cannot bypass an open drain or revive a retired host. Credential rotation during
a drain invalidates observations, so fresh reports are required again.

## Retire an empty host

Retirement is permanent. Owners/managers must explicitly delete retained VMs and
wait for physical cleanup. A drain alone cannot make a populated host retireable.
With a confirmed open drain and fresh empty pool reports:

```sh
bin/marshall eval 'Marshall.Operations.CLI.main()' retire-host REQUEST_UUID
```

Marshall checks for live VMs, held compute/disk reservations, active addresses
(including inconsistent historical rows), and reported managed pool allocations.
Only an empty host can retire. It revokes credentials atomically and permanently
excludes new credentials, admission and starts. Repeating retirement is idempotent.
Lilly loses authority on its next authenticated exchange. Host identity and audit
history remain; retirement does not erase disks, reinstall the host or recycle
its machine identity. Prepare and enroll replacement infrastructure separately.

The [maintenance ADR](architecture/decisions/0026-host-maintenance-and-retirement.md)
records the coordination and evidence. This workflow provides no cross-host data
migration or forced recovery from permanently lost storage.
