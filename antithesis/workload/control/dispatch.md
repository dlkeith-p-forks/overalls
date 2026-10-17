# Lilly Control dispatch probes

`control_dispatch/singleton_driver_dispatch_closed.py` runs once in its own
terminal template. It uses the enrolled Lilly credential to bind a
real Marshall Control v1 socket. It first opens a valid Execution v4 session and
observes that session's exact PostgreSQL row. It then sends a foreign service
operation, an unknown Lilly operation, or an invalid Lilly session document with
a fresh nonce. The scoped `Bound Lilly invalid requests do not create a durable
execution session` assertion fires only after an observed valid precondition,
a correlated negative response or an observed forbidden row, and a successful
SQL read of that row. A lost response with no observed effect remains unknown.
The row witness covers only creation of a Lilly execution session. The foreign
`audi.ssh_open` probe deliberately receives `invalid_request` from Lilly, but
its Lilly-shaped body would also be rejected by Audi's decoder if a routing bug
sent it there. An Audi effect requires a valid Audi document and a separate Audi
effect witness. The full cross-service dispatch property remains unclaimed; this
probe does not cover Audi, Porsche, Ziggy, Galileo, native effects, or external
services.
Opening the valid session supersedes the host's prior session, so this template
must never be selected with repeated core Control commands or other commands
that depend on the same Lilly session.

`serial_driver_outer_version.py` sends wrong outer Control version headers to
the real upgrade endpoint and checks HTTP 426 before socket upgrade. It does not
observe a BEAM Control.Client owner, pending calls, or retry scheduling. The
broader terminal-owner property needs the separate controlled BEAM client peer.

`control_legacy_request/singleton_driver_legacy_execution_request.py` also runs
once in its own terminal template. It sends v1, v3, or v5 inner Execution
session documents through an authenticated Control v1 socket. It checks the
correlated `unsupported_version` refusal and exact SQL session-row absence after
a prior valid v4 session succeeded. This exercises Marshall's request decoder.
That valid session supersedes the host's prior session, so this template must
remain isolated from repeated core Control commands and the dispatch template.
It does not inject malformed server responses into Lilly's actual Control
Client/Runtime, inspect Lilly Store or Journal files, or observe a physical
launch marker. The broad legacy-document primary remains unclaimed until that
separate path is instrumented and run.

These commands tolerate unavailable transport and SQL observations without
turning them into passing refusals. The selected variant is drawn through the
Antithesis SDK from the service-prefix and Execution version/body menus visible
in `Marshall.Control.Services.Lilly`, `ProvisionerRequests`, and
`OverallsProtocol.Execution`. No hosted execution has been recorded yet.
