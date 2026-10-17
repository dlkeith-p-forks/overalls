# ADR-0008: Identity, sharing and terminal access

- ID: ADR-0008
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts and authorization, terminal relay, Lilly
- Supersedes: none
- Superseded by: ADR-0049

## Context

[ADR-0049](0049-organizational-email-registration.md) restricts registration to the
Standard domain and carries forward the other identity/access decisions below.

Users log in to provision VMs and can share them through Marshall. Each VM is an
actor with a readable/writable TTY. The user selected open email registration,
access to all profiles and a single active terminal writer.

## Decision

Use open email magic-link registration. Any signed-in user may provision any of
the three profiles subject to host capacity, without per-user quotas initially.
Use real Cedar policy evaluation through an Ash authorization bridge for VM and
sharing actions; policy-shaped conditionals are not a Cedar implementation.

Share with existing registered users identified by exact email. Viewer grants
read terminal access; operator adds terminal writing; manager adds lifecycle,
delete and sharing management. The owner retains protected ownership and full
access; ownership transfer is excluded initially. Enforce grants server-side for
HTTP, live connections and asynchronous actions as appropriate.

The guest terminal is a root shell. Permit multiple readers and at most one
active writer per VM. Grants and writer ownership must remain authoritative
across Marshall instances and reconnects, and revocation must reach established
sessions. These are accepted access requirements.

## Alternatives

Invite-only registration was not selected. Simultaneous writers can corrupt
interactive commands and were rejected in favor of one writer. Separate shells
would change the single VM-console model. Duplicating authorization in UI guards
would leave API, jobs or existing sockets unprotected.

## Consequences

Terminal access is high privilege inside the guest. Open registration plus no
quotas requires observable host capacity and clear rejection under exhaustion.
Terminal streams need bounded buffers and backpressure; terminal bytes and
credentials must not leak into logs or audit payloads.

## Invariants and verification

- Cedar denies ungranted actions, including requests bypassing the UI.
- A viewer cannot write or escalate a grant; manager actions cannot remove or
  transfer protected ownership.
- At most one writer remains valid through concurrent acquisition, disconnect,
  failover and reconnect; revocation removes effective access promptly.
- Terminal input/output is ordered within the chosen stream protocol and buffer
  growth is bounded under slow or disconnected clients.
- Test the permission matrix as properties and session revocation end to end.

## Implementation evidence

[User resource](../../../marshall/lib/marshall/accounts/user.ex) configures
magic-link registration and Ash authentication;
[router](../../../marshall/lib/marshall_web/router.ex) provides authentication
routes. [Cedar policies](../../../marshall/priv/cedar/compute.cedar) and the
[Ash bridge](../../../marshall/lib/marshall/authorization/ash_authorizer.ex)
authorize provision and protect internal compute actions. The
[VM resource](../../../marshall/lib/marshall/compute/virtual_machine.ex) records
ownership. [Policy properties](../../../marshall/test/marshall/authorization/cedar_test.exs)
verify the role matrix through the real engine. See
[ADR-0010](0010-capacity-admission-transactions.md).

[Encrypted auth-email outbox](../../../marshall/lib/marshall/accounts/auth_email.ex)
and [bounded SMTP delivery](../../../marshall/lib/marshall/accounts/deliver_auth_email.ex)
now implement durable production mail under
[ADR-0024](0024-durable-magic-link-email.md). Local TLS fixtures verify single-use
sign-in through the delivered message; deployment provider/inbox verification
remains required.

Owner lifecycle authorization now uses Cedar `manage` in
[the lifecycle coordinator](../../../marshall/lib/marshall/compute/lifecycle.ex)
under [ADR-0016](0016-executable-generations-and-lifecycle.md).
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md) adds persisted
[grants](../../../marshall/lib/marshall/access/grant.ex), fresh Cedar mapping,
manager lifecycle integration, bounded record-scoped views and
[authenticated machine pages](../../../marshall/lib/marshall_web/live/machines_live.ex).
[ADR-0019](0019-terminal-session-and-writer-authority.md) adds expiring sessions,
fresh token checks and pending/active writer authority in PostgreSQL. A local gate
exists under [ADR-0020](0020-local-console-fences-and-bounded-streams.md), connected
through the runtime and HTTPS relay under
[ADR-0021](0021-console-relay-connections-and-mailboxes.md). The
[NixOS guest](../../../nix/packages/guest/configuration.nix) and its local
console client provided a
verified root serial shell under [ADR-0011](0011-nixos-guest-and-console.md);
the remote relay applies the persisted user sharing/session policy.

## Open questions

Persisted grants are implemented under ADR-0018 and control-plane terminal authority
under ADR-0019. Browser rendering and reconnect behavior now exist under
[ADR-0022](0022-browser-terminal-and-live-login-checks.md). The
[fleet browser test](../../../nix/tests/machines/fleet/browser.py) now passes real sharing,
writer handoff, revocation and Marshall loss through the production proxy.
Complete broader fault/load acceptance under the intended workload. The configured
session and writer intervals do not establish an end-to-end revocation guarantee.

## Related decisions

[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0009](0009-assurance-and-testing.md).

## Amendment 2026-09-19: guest multiplexer terminals

Terminal access is no longer the single serial console root shell described
above. [ADR-0082](0082-guest-terminal-multiplexer.md) provides many
persistent PTY sessions per VM through the guest multiplexer, sharing keeps
Cedar read/write semantics per session, and the browser workspace under
[ADR-0084](0084-browser-terminal-workspace.md) renders them with full
sequence fidelity. The identity and sharing authority model is unchanged.
