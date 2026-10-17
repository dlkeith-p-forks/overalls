# Opening socket custody

## Scope and finding

Reviewed the shared control client and Lilly terminal stream's passive connection
open, controlling-process transfer, completion, worker monitoring and termination
against repository, Protocol/test, Lilly/test and terminal contracts and
ADR-0083/0140/0142. Domain authorization, credential persistence, terminal bytes,
wire documents, heartbeat and retry limits remain unchanged.

**Recovery defect:** the linked/monitored worker transfers its socket before
sending completion. Death in between leaves a client-owned transport absent from
the client's state. Clearing the attempt restores dialing but cannot close that
socket. Lilly's stream has the same source ordering.

The retained `/tmp/kittens-control-handoff-window.ffdqptms` experiment inserts
only an observation/pause after successful handoff and before completion. A
generated property first releases a successful control and observes hello, then
kills the actual worker at that paused source window. Original Protocol source
failed socket closure after zero successful draws, generated two losses, seed0,
1.0seconds,exit2: `/tmp/kittens-control-handoff-window-original.log`.
This is an explicitly instrumented scheduling-window reproduction, not an
uninstrumented application or hosted run. No separate original Lilly runtime
counterexample is claimed.

## Repair and properties

Each current worker synchronously registers its passive socket with the owner
before transferring it. Registration binds both attempt reference and calling
worker; stale/duplicate registrations are refused. The owner records socket
custody before acknowledging. Matching worker death, failed completion and owner
termination retire that socket. Successful completion clears provisional custody
and uses the existing adoption/hello path. Linking retains abrupt owner cleanup.

The instrumented repaired Protocol property passed one property,seed0,
0.1seconds,exit0 in `/tmp/kittens-control-handoff-window-repaired2.log`.
An earlier repaired run expected immediate EOF and instead received the correct
orderly close frame; that was an oracle error, not a production defect
(`/tmp/kittens-control-handoff-window-repaired.log`). The corrected oracle
requires the decoded close frame followed by EOF.

The uninstrumented repairs and new properties are now integrated:

| Property | Fixture and recorded fork execution |
| --- | --- |
| `protocol/test/control/opening_socket_property_test.exs`: `registered opening sockets retire on worker loss or failed completion` | A gated credential fixture uses the actual opening worker with a real passive loopback socket and production registration/retirement callbacks. Every generated history covers death before/after transfer and failed completion; stale reference refuses registration and readiness remains false. Two-property execution, including the existing actual-dial/hello/owner-loss property, passed15.0seconds,seed0,exit0: `/tmp/kittens-control-opening-socket-baseline.log`. |
| `lilly/test/terminal/opening_socket_property_test.exs`: same assertion | A scripted worker is installed with real stream-owned links/monitors. Actual passive sockets, registration/retirement callbacks and pre/post-transfer/failure cases run; ordinary production dial reach is supplied separately by the existing worker property. Two-property execution passed3.2seconds,seed0,exit0: `/tmp/kittens-terminal-opening-socket-baseline.log`. |

These fixtures deliberately control the worker phase. Plain loopback and
scripted state do not establish TLS, domain authentication, production fault
timing or native guest survival. No terminal data or credentials are observed.

## Local falsification

Separate mutants remove only provisional-socket closure from each retirement
helper. Each failed the expected unretired post-handoff socket assertion after
zero successful draws, generated two repetitions,seed0,1.1seconds,exit2:
`/tmp/kittens-control-opening-socket-retirement-mutant.log` and
`/tmp/kittens-terminal-opening-socket-retirement-mutant.log`. Before-transfer
worker-owned socket closure passed first. Failed-completion assertions after the
failing case were not reached and are not mutation-credited.

Both sources were restored and copied byte-for-byte into integration. Each
restored single-property run passed0.1seconds,seed0,exit0:
`/tmp/kittens-control-opening-socket-restored.log` and
`/tmp/kittens-terminal-opening-socket-restored.log`. Patches are retained in
`antithesis/scratchbook/mutation-testing/patches/`:

- `local-control-opening-socket-retirement.patch`: SHA256 `702050335de4fb36b6cf4076aa9e234eca4a8a205103e09660d49d8498c8943b`.
- `local-terminal-opening-socket-retirement.patch`: SHA256 `456a9925bbf11bf502fd1146c26390315dec24c3bdd898165e2f6b17619b8503`.

## Architecture impact and remaining work

This restores volatile transport custody under accepted ADR-0140/0142 and
ADR-0083; no accepted rationale/status, domain boundary, physical guest authority
or protocol schema changes. Acknowledgement waits in the off-process worker;
client requests/status remain responsive during opening. Source review traced
both callers of `Connection.handoff/2` and their completion/error paths.

Current Protocol precommit passed255checks (101properties,154tests),seed282259,
438.1seconds,exit0. Gate Dialyzer passed3.17seconds and explicit forced test
Dialyzer passed4.04seconds, both with zero errors, skips or unnecessary skips.
Log `/tmp/kittens-control-opening-custody-protocol-precommit.log`. Earlier Protocol254,
Audi183, Galileo32, Ziggy66, Porsche94 and Lilly501 gates predate this custody
repair and do not verify it. Current Lilly precommit passed502checks
(96properties,406tests),seed218587,149.8seconds,exit0 using the verified native
launch-guard/source-export helpers. Gate Dialyzer passed11.62seconds and explicit
forced test Dialyzer passed14.21seconds, both with zero errors, skips or
unnecessary skips. Log `/tmp/kittens-opening-custody-lilly-precommit.log`.
Remaining consumer gates, real TLS phase
loss, authenticated native reconnect/guest custody and hosted faults remain open.
