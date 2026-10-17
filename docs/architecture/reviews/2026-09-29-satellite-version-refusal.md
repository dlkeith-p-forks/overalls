# Satellite version refusal recovery review

- Date: 2026-09-29
- Decisions: ADR-0063 (carried Ziggy authority and accounting), ADR-0080
  (Galileo single-attempt renewal), ADR-0042 (catalogued diagnostics)
- Architecture impact: error classification and recovery behavior inside two
  independently deployed satellite releases. Marshall's wire schema, Ash
  ownership, credential custody and durable authority are unchanged.

## Findings and resolution

Ziggy previously mapped every non-200/403 control reply except exact completion
conflicts to `:authority_unavailable`. Its reporter retried an unacknowledged
completion every second and its model worker polled every second. A durable HTTP
426 could therefore generate an unbounded stream of the same control request.
Marshall also returned 400 for explicit wrong Ziggy/Galileo body versions, so a
current version-skewed client would never reach a distinct 426 branch. Both
closed API families now return uncached 426 for an explicit wrong version and
retain 400 for absent or malformed envelopes; a generated route property checks
the wire status and body on every supported route.
The control client now retains `:unsupported_version` even if the response body
exceeds its normal limit, with a fixed catalogued version-refusal event. The
reporter stops retrying and leaves the spool untouched; the model poller stops
claiming work. Guest requests still receive a service-unavailable response and
never gain authority from the new class.

Galileo previously collapsed HTTP 426 into control unavailability. Its control
client now retains the terminal class across authorization, identity and renewal,
including oversized bodies, and emits a fixed event. Its accepted ADR-0080
behavior still closes the one upstream attempt on the first failed renewal;
no new retry or secret persistence path was introduced. Lilly's existing
`unsupported_version` Runtime fence has a generated transient-prefix property
that checks Store preservation and no tick restart.

## Verification and limits

Marshall's focused satellite API suite passed 10 checks (one property, nine
tests). Ziggy's focused version suite passed four properties, including local
verified TLS oversized-426 replies. Galileo's focused control and upstream suite
passed 14 checks (four properties, ten tests). Lilly's focused historical-fence
suite passed nine checks (two properties, seven tests). Full pinned-runtime
`mix precommit` gates passed in Marshall (1,377 checks, 189 properties), Lilly
(463 checks, 74 properties), Ziggy (52 checks, 10 properties) and Galileo
(23 checks, six properties), including forced Dialyzer with zero findings.
The Nix HLDD check, ADR structure, HLDD receipt/coverage/views/options checks
and diff whitespace check passed. These are local properties and fixture TLS
endpoints; they do not prove a hosted mixed-version rollout, native guest
effects or production timing.

Audi's control client still classifies 426 as a generic HTTP error. Lilly's
terminal WebSocket 404 retry loop remains a separate version-skew gap. A Ziggy
Reporter or AgentWorker process restart resets its in-memory version fence and
may make one more request before seeing 426 again. Persistent cross-restart
fencing and hosted request-count bounds remain open.
