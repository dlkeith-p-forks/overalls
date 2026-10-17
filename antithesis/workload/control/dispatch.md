# Lilly Control dispatch probes

`control_dispatch/singleton_driver_dispatch_closed.py` runs once in its own
terminal template. It uses the enrolled Lilly credential to bind a
real Marshall Control v1 socket. It first opens a valid Execution v4 session and
observes that session's exact PostgreSQL row. It then sends one valid
foreign-service document plus two drawn foreign or invalid Lilly requests, each
with a fresh nonce. The foreign documents are accepted by their own service's
decoder: Audi `ssh_open` (v1 synthetic ed25519 key and label), Porsche
`commands` (v1 session token and a valid `stop` mutation), Ziggy v2
`agent_next`, and Galileo `authorize` (four-field private binding and an
integration name). The invalid Lilly requests are an unknown Lilly operation or
an invalid session document (old/future/missing version, extra field, wrong
type or wrong machine).

Before and after each request the probe reads the fresh nonce's
`compute_host_sessions` row and one read-only snapshot counting
`ingress_sessions`, `ssh_requests`, claimed `agent_model_calls` and
`galileo_peer_tokens`, the durable effects of those four foreign routes. The
catalog `Control rejects cross-service and invalid documents before domain
effects` assertion is evaluated after an observed precondition, successful SQL
reads, and either a correlated reply or an observed forbidden effect. It passes
only for a correlated refusal with the session row absent and every foreign
count unchanged. A changed count or session row fails even after a lost reply;
a lost reply without an effect remains unknown. The effect counts are
meaningful because the control-core profile runs no Audi, Porsche, Ziggy or
Galileo principal that could change those tables concurrently; selecting this
command in a profile with those services would need a per-request effect key.

Scope: only a Lilly-bound socket is exercised. Foreign service sockets, their
own invalid-document handling, native effects and external upstreams are not
bound or observed, and Galileo's peer-token mint is not an upstream mutation.
Opening the valid session supersedes the host's prior session, so this template
must never be selected with repeated core Control commands or other commands
that depend on the same Lilly session.

`serial_driver_outer_version.py` sends wrong outer Control version headers to
the real upgrade endpoint and checks HTTP 426 before socket upgrade. It does not
observe a BEAM Control.Client owner. The 4001 terminal-owner check is the
separate [`version_refusal.py`](version_refusal.py) probe, which drives the
real shared client against the loopback peer.

`control_legacy_request/singleton_driver_legacy_execution_request.py` also runs
once in its own terminal template. It sends v1, v3, or v5 inner Execution
session documents through an authenticated Control v1 socket after a prior
valid v4 session succeeded. For each request it reads the fresh session row and
Marshall's committed host session and epoch (`compute_hosts`) before and after.
The catalog `Execution v4 refuses legacy authority without changing durable
command` assertion (`AlwaysOrUnreachable`) requires the correlated
`unsupported_version` refusal, an absent row and an unchanged committed
session. Installing the legacy nonce or erasing the committed session fails.
Any other change is the live Lilly runtime reconnecting after the probe's own
session superseded it, so that request is left unexercised. This exercises
Marshall's request decoder and durable host row only. It does not inject
malformed server responses into Lilly's actual Control Client/Runtime, inspect
Lilly Store or Journal files, or observe a physical launch marker. That valid
session supersedes the host's prior session, so this template must remain
isolated from repeated core Control commands and the dispatch template.

These commands tolerate unavailable transport and SQL observations without
turning them into passing refusals. The selected variant is drawn through the
Antithesis SDK from the service-prefix and Execution version/body menus visible
in `Marshall.Control.Services.*`, the foreign route decoders,
`ProvisionerRequests` and `OverallsProtocol.Execution`. No hosted execution has
been recorded yet.
