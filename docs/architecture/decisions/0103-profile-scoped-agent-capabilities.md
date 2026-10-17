# ADR-0103: Profile-scoped agent capabilities

- ID: ADR-0103
- Date: 2026-09-23
- Status: superseded
- Implementation: implemented
- Components: Marshall
- Supersedes: none
- Superseded by: ADR-0147

## Context

[ADR-0147](0147-standard-profile-name.md) replaces only profile spelling and
fresh-install compatibility. The authority policy and historical rationale below
remain; historical profile labels are normalized to Standard.

ADR-0100 makes Marshall the agent event loop, but its model request advertised
the same tools for every eligible VM. Tool authority must derive from the
persisted, immutable VM profile. Cedar already decides whether a user may write
to a VM; the requested first policy does not vary by user or team.

## Decision

Marshall owns one closed, typed profile-to-tool allowlist. OSS and Inception
allow `exec_command`, `read_file`, `spawn_child_agent`, `web_search` and
`web_fetch`. Standard allows `exec_command`, `read_file`, `web_search` and
`web_fetch`. Customer remains ineligible for an agent, and
unknown profiles and tools deny. User access remains subject to fresh Cedar VM
write authorization.

Marshall advertises only allowed tools in model requests and checks all returned
calls against the current persisted profile before creating any command or
child. One forbidden call rejects the whole model response and fails the turn
with `capability_denied`. A queued model request is checked again before Ziggy
claims it, so an older request cannot advertise a removed tool. Guest commands
are checked again at claim and before
the `started` acknowledgement that precedes execution. A denied queued or
claimed command is durably cancelled; its turn fails. The guest receives an RPC
error only after cancellation commits. Already started effects cannot be undone
or replayed. Marshall checks server-owned search commands at claim; they never
enter the guest command path.

## Alternatives

Cedar could model each tool as a separate VM action, but that would add profile
attributes and per-tool authorization checks to the current user/VM policy for
a fixed profile matrix. A guest-supplied capability list would cross the trusted
boundary. Advertising fewer tools without validating model output or dispatch
would leave an execution bypass.

## Consequences

Changing the allowlist in a deployment applies to new model responses and
pending guest commands. Previously created child threads and retained history
remain. The policy has no per-user overrides and introduces no guest or Ziggy
wire field. A future role-dependent tool policy requires a new decision.

## Invariants and verification

- Every advertised tool belongs to the VM profile's allowlist; unknown values
  fail closed.
- A queued model request containing a removed tool is cancelled before provider
  dispatch.
- A model response containing any forbidden call creates no command or child.
- A forbidden queued or claimed command cannot pass the guest's `started`
  handshake. Cancellation commits before the error response.
- Denial audit and diagnostic records contain no model or tool payload.
- Property tests cover profile/tool combinations and mixed model calls; database
  and NixOS tests cover durable denial and the real agent path.

## Implementation evidence

The [default-profile journey](../../../nix/verification/tests/machines/default-oss/driver.py)
also inspects registration after native browser/Porsche creation: both OSS VMs
have roots, while an explicitly selected Customer VM has no root and its owner
receives a closed conversation refusal from packaged Marshall. The
[execution review](../reviews/2026-09-25-default-oss-verification.md) records the
passing native journey; this is registration/refusal
scope, not a rerun of hostile model-tool execution.

The [policy](../../../marshall/lib/marshall/agents/capabilities.ex),
[model boundary](../../../marshall/lib/marshall/agents/model_protocol.ex), and
[guest command boundary](../../../marshall/lib/marshall/agents/executor_session.ex)
implement the profile matrix and layered checks. The
[property tests](../../../marshall/test/marshall/agents/capabilities_test.exs)
and [database tests](../../../marshall/test/marshall/agents/executor_session_test.exs)
exercise the policy and durable retirement. The
[fleet NixOS scenario](../../../nix/verification/tests/machines/fleet/scenarios/agent.py)
passed with a Standard guest tool round trip and a denied child call.

## Open questions

None for the fixed first profile matrix.

## Related decisions

[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) owns the agent event
loop and guest executor; [ADR-0107](0107-marshall-owned-agent-web-search.md)
owns server-side search; [ADR-0069](0069-brady-egress-cache.md) carries forward
Customer isolation.
[ADR-0108](0108-guest-agent-web-fetch.md) adds guest-executed fetch to the
profile matrix.
