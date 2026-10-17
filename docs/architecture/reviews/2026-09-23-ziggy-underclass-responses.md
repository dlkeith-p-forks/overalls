# Ziggy Underclass Responses review

## Scope

Reviewed ADR-0100, ADR-0081, the Marshall model protocol and durable call
coordinator, Ziggy's pull worker, enrolled-host configuration, and synthetic
provider fixtures. Production Ziggy already selects host-local Underclass and
loads only its proxy key; the live Overalls origin and key snapshot matched the
Underclass service. No origin or secret-custody code change is needed.

## Findings and implementation

The failing live thread selected `gpt-5.5` and received HTTP 400. Marshall
sent Chat Completions to Ziggy, while Underclass's Codex backend forwards that
body to a Responses endpoint without protocol translation. A bounded live
probe showed that the Codex backend also requires `stream: true` and that its
final `response.completed` object can have an empty `output` array; completed
items arrive as `response.output_item.done` events. A second live probe used
a real function call and a stateless `function_call_output` continuation;
both requests returned HTTP 200 and the second produced a message. The agent path now uses
`gpt-6-sol` and streamed Responses with medium reasoning. Both enrolled hosts
now advertise that model in their persistent Underclass catalogs. Ziggy assembles
only completed items into a bounded result for Marshall. Marshall stores that
output in private, authorized thread events for stateless continuation;
conversation reads omit it. Audit and structured diagnostics remain
content-free. Ziggy accepts both wire shapes during a rolling update, but a
claimed call still has only one upstream attempt and is never replayed.

The new internal event consumes event sequence and context budget. The current
256-event and 262144-byte request caps can end a long conversation with
`context_too_large`; pagination and context compaction remain open under
ADR-0100. Unknown models pass through Underclass's Codex backend, but the
host catalogs should explicitly advertise `gpt-6-sol` for discovery.

## Verification

Focused Marshall and Ziggy tests exercise Responses shape, bounded tool
parsing, replay and legacy completion. The Ziggy service NixOS fixture
exercises agent polling and the Responses path. The Ziggy–Underclass NixOS
check exercises the proxy-key boundary for that path; its empty synthetic pool
returns 503. `mix precommit` passed in Marshall and Ziggy, including their
compiler, tests, contracts and Dialyzer gates. The ADR checker and Python
`prek run --all-files` passed. `nix build .#checks.x86_64-linux.ziggy-service`,
`ziggy-underclass`, and `agent-fleet` passed. The agent-fleet test exercised a
shared operator prompt waking a stopped guest, two synthetic streamed Responses
calls, a fenced guest tool call, a completed answer and a wake audit receipt.
The live Underclass probe established the real provider's streamed tool call
and stateless continuation shapes. After the Marshall rollout, a fresh prompt
on the previously failing production thread completed with the expected answer
through one `gpt-6-sol` model call. The turn produced prompt, model and finish
audit receipts. Its completed output was retained in one private replay event
and omitted from authorized conversation reads.
