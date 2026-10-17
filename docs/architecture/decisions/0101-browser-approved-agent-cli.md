# ADR-0101: Browser-approved agent CLI sessions

- ID: ADR-0101
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Marshall, Lyra
- Supersedes: none
- Superseded by: none

## Context

ADR-0100 keeps the agent event loop and VM authorization in Marshall. The
`overalls` desktop CLI needs to submit prompts and read turn results without
receiving Ziggy's host credential or adopting the browser's session cookie.
The existing CLI has no user login flow.

## Decision

For each CLI invocation, Lyra generates a fresh 256-bit secret in memory and
shows the SHA-256 digest in a browser approval URL. A current authenticated
browser user must explicitly approve that digest for one VM. Marshall stores
only the digest, approving actor, VM and one-hour expiry in an Ash resource;
the same transaction writes a content-free audit receipt. The URL digest
cannot authenticate an API request. Lyra sends the secret only in a verified
HTTPS Authorization header using its bounded native HTTP client. The secret
remains in memory and does not enter process arguments or a file. The earlier
curl standard-input implementation has been replaced while preserving this
custody boundary.

The CLI API returns the root thread, admits an idempotent prompt and reads one
turn's terminal result. Every request checks the current VM and actor's write
access. Prompt admission additionally checks that the supplied thread belongs
to the approved VM and uses the existing transactional prompt/wake coordinator.
The CLI owns no model, command, guest or recovery loop. It displays an explicit
unavailable result if the VM or access disappears. Sessions expire after one
hour and are purged after a further retention hour.

## Alternatives

Exporting the browser cookie would weaken the browser security boundary.
Giving the CLI a Ziggy or guest credential would cross the host/VM authority
boundary. Storing a reusable API token on disk adds revocation and custody
work not needed for a single prompt invocation.

## Consequences

Users approve each invocation in a browser before the prompt starts. The CLI
gets a bounded one-hour window to wait for the result; longer turns require a
new approved invocation to inspect the browser workspace. The approval URL
contains a non-secret digest, but it is still tagged as an authentication path
so diagnostics never record it. The API currently returns the final response,
not an event stream.

## Invariants and verification

- An approval GET causes no state change; only a current authenticated form
  submission writes the session and audit receipt.
- The browser sees only the digest and the API sees the secret. Database rows,
  logs and process arguments contain neither the secret nor prompt content.
- One approved session is scoped to one VM. A thread ID from another VM is
  rejected even when the same user can access both.
- Revoked VM access, deleted user, expired session or deleted VM denies every
  subsequent CLI request.
- CLI tests and a NixOS machine test verify the packaged binary against a
  synthetic HTTPS control. A captured whole-system NixOS run also verifies
  browser approval and prompt completion with a real guest and isolated provider;
  its source scope and reliability limits remain explicit below.

## Implementation evidence

The [session resource](../../../marshall/lib/marshall/agents/cli_session.ex),
[access coordinator](../../../marshall/lib/marshall/agents/cli_access.ex),
[API](../../../marshall/lib/marshall_web/controllers/agent_cli_controller.ex),
[browser approval](../../../marshall/lib/marshall_web/live/agent_cli_approval_live.ex),
and [CLI](../../../lyra/src/agent_cli.rs) implement the flow. The
[focused tests](../../../marshall/test/marshall_web/agent_cli_test.exs) exercise
HTTP and LiveView boundaries against PostgreSQL, including access revocation,
expiry, cross-VM IDs and deletion. Native Rust checks cover the executable;
the [NixOS CLI test](../../../nix/tests/machines/agent-cli/default.nix)
executes the packaged binary through the approval, prompt and result RPCs over
verified HTTPS.

The [CLI verification review](../reviews/2026-09-25-agent-cli-verification.md)
records generated authority histories and a passing six-stage native journey
from ordinary browser consent through the packaged CLI and real guest result.
It includes exact tool/path/result/executor binding, Standard capability
refusal and stale approval after UI sharing withdrawal. An earlier executor
interruption remains unexplained; the passing capture predates the subsequent
Underclass pin. Physical hosts, live providers, Ubuntu and production load remain
outside this result, so implementation stays partial. Its exact execution scope
is separate from the existing synthetic CLI and private-operator guest evidence.

The [lifetime generator repair](../reviews/2026-09-26-cli-history-generator.md)
reproduces a finite-set duplicate-exhaustion failure and preserves all three
expiry, deletion and retirement boundaries through generation and shrinking.
It changes verification only; the earlier native evidence and partial status
remain unchanged.

The [executor-loss review](../reviews/2026-09-26-executor-loss-histories.md)
adds composed application histories and a scoped native started-effect interruption
fixture with explicit user retry. Execution status and pre-start native gaps stay
separate; the earlier unexplained interruption and partial status are preserved.

## Open questions

None for the per-invocation authorization boundary. A persistent CLI login or
streaming UI would require a separate decision.

## Related decisions

[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) owns agent execution;
[ADR-0096](0096-lyra-developer-ssh.md) owns CLI distribution;
[ADR-0022](0022-browser-terminal-and-live-login-checks.md) governs current
browser login validation.
