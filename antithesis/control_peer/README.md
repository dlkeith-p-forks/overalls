# Controlled Control client peer

`runner.exs` loads the source-built `OverallsProtocol.Control.Client` BEAM modules
and connects that client to a loopback WebSocket peer in `peer.ex`. The peer
records complete request frames after decoding them from the socket. It can
hold, reorder, duplicate and retire replies, then observe caller results. The
Python commands in the `control` template run it through `control.peer.run_peer`.

Modes are `capacity`, `pending` and `delivery`. All take an advertised window
from `0, 1, 8, 64, 255, 256, 257` and a timeout from `50, 500, 5000` ms. The
process emits one tab-delimited `RESULT` record with typed booleans and counts;
`RESULT\tunavailable` means the fixture could not complete its observation.
The wrapper rejects malformed or incomplete output. No credential is passed to
the peer; its fixed loopback token is synthetic and never accepted by Marshall.

This establishes the shared client transport boundary when the workload image
actually runs. It does not establish Marshall dispatch, a durable mutation or
native guest behavior. The authenticated Marshall/SQL workloads provide those
separate witnesses. Local script runs in this source tree are useful development
checks, but they are not an Antithesis hosted baseline.
