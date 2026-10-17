# Agent capability architecture review

## Scope and decision

Reviewed ADR-0100, Customer isolation under ADR-0069, Cedar VM authorization,
Marshall model calls, guest executor RPCs and their audit boundaries. ADR-0103
adds a Marshall-owned fixed tool allowlist based on the persisted VM profile.
It does not change user/VM write authorization or make Customer agent-eligible.

## Findings

The existing model protocol advertised all three tools for every eligible VM.
It accepted a well-formed child-spawn call without checking profile. Tool
advertisement alone cannot constrain a model response. Marshall now checks
each call before any command or child creation, and rechecks guest commands
before claim and before the `started` RPC acknowledgement. A denied start must
commit its cancellation before the RPC returns an error; otherwise the guest
could receive success and execute, or the outer RPC transaction could roll back
the cancellation. Previously started effects remain subject to the existing
single-attempt recovery rules.
Marshall also rechecks durable queued model requests before Ziggy claim, so
a request built by an older release cannot advertise a removed tool.

The policy is a closed Marshall module rather than a new Cedar action. Cedar
continues to check fresh user VM write access. No capability is accepted from
the model, guest or client. Audit receipts use closed kinds and outcomes, and
diagnostics contain no command or model payload. The browser renders a safe
profile-specific explanation for `capability_denied`; the CLI receives the
closed turn failure reason through its existing result API.

## Verification and remaining work

Property tests cover the independent profile matrix and generated mixed tool
responses. Database tests cover forbidden model responses, queued command
retirement and a claimed command's denied start RPC. The agent fleet NixOS
fixture checks a real Standard tool round trip and a forbidden child call.
`nix build .#checks.x86_64-linux.agent-fleet --no-link` passed on 2026-09-23.
The ADR structure checker and `prek run --all-files` passed. Marshall's final
`mix precommit` passed with 910 tests (70 properties), 2 excluded, and zero
Dialyzer errors. Revision `3374b179` reached healthy status on Dungarees and
Overalls. On the live OSS thread `01a0cd34-324f-7e85-9df2-95850daf9316`,
turn `01a0cde0-8506-71a7-ae23-f74c19cfddb8` completed: both model requests
advertised the three OSS tools, `read_file` completed, and prompt, model, tool
and turn audit receipts were present. No Standard VM was available in
production for a live profile-denial check; the NixOS fleet test covers that
path with a real guest and a controlled provider response.
