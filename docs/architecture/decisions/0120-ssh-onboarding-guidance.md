# ADR-0120: SSH onboarding guidance

- ID: ADR-0120
- Date: 2026-09-25
- Status: accepted
- Implementation: implemented
- Components: Marshall, Audi, Porsche, Protocol, NixOS
- Supersedes: none
- Superseded by: none

## Context

A user connected directly to an Audi VM hostname and received only a PTY
allocation failure. Audi rejected the direct PTY request before guest admission,
without explaining key registration or the required Overalls proxy configuration.
Porsche already supports browser
approval, but its human output exposed technical response fields.

## Decision

The user authorized actionable setup guidance, shared sources of truth, explicit
channel states, and unit, property and native machine verification. Audi may
acknowledge PTY and shell requests exclusively for bounded diagnostics. This
does not allocate a terminal or execute a shell. Diagnostic states cannot
transition into guest admission or relay states. Unsupported subsystems and
forwarding remain disabled. Every diagnostic response exits nonzero.

Marshall owns active-key recognition. A new authenticated gateway-only
`ssh-key-status` request returns a closed version-1 result containing only
`recognized` or `unknown`. Gateways call it only after signature proof, never
for unsigned probes. It creates neither approval nor admission records, and
its result grants no authority. Porsche onboarding and this operation share
the canonical active-key lookup; admission retains row locks and fresh checks.

Audi directs unknown keys to Porsche's existing browser approval flow and the
machine page's Overalls setup command. A separately configured public origin
supplies links; private control origins never appear in guidance. Ordinary SSH
does not convey a VM hostname, so direct connections receive generic setup
instructions. Unknown keys do not identify an account, and messages must not
claim that an account has no keys. Verification outages are distinct from
unknown keys. No key or machine ownership is disclosed.

Shared protocol code defines status decoding and bounded terminal-safe human
guidance. Audi writes diagnostics only to SSH extended-data stderr. An exec
acknowledgement means its diagnostic request was handled, not that guest access
was admitted; the exit status and absence of a stream distinguish rejection.
Porsche preserves JSON framing, browser approval authority and explicit retry.
Approval requires the originating proved connection to stay live. Interactive
guidance states this lifetime; human exec failures direct users to a fresh
interactive connection instead of displaying a link invalidated by disconnect.
Multiplexed JSON clients retain the existing approval response and must keep
their connection alive until approval completes.
Successful guest sessions receive no additional banners.

## Alternatives

Approving keys inside Audi would duplicate Porsche onboarding and extend its
authority. Static failure text cannot distinguish unregistered keys from
verification outages. Writing messages into relay stdout corrupts nested SSH.
Allocating a real shell or guest PTY before admission violates existing authority.

## Consequences

Failed connections may perform one additional bounded control request. Channel
setup has an eight-second ceiling accommodating admission, recognition and
diagnostic delivery. A missing public origin falls back to generic settings
instructions. Deploy the additive Marshall endpoint before Audi; older servers
produce unavailable-verification guidance. There are no database migrations.
Fingerprints and approval links remain terminal output, never diagnostic logs.

## Invariants and verification

- Generated channel histories cannot escape diagnostics, reopen closed channels,
  or request admission more than once.
- Real OpenSSH receives readable setup guidance with and without a PTY.
- Failed proxies emit no stdout, and successful relays preserve arbitrary bytes.
- Active, absent and archived keys resolve through current persisted authority.
- Protocol decoders reject unknown fields and versions; rendering bounds and
  escapes untrusted strings.
- Native NixOS and Ubuntu journeys assert that the account owns a running VM
  and has zero active registered keys. A fresh offered key must receive guidance
  on direct and proxy requests. Browser approval of that same key then permits
  per-user access to the same VM, with ownership unchanged.

## Implementation evidence

The [shared guidance](../../../protocol/lib/overalls_protocol/ssh_onboarding.ex),
[key registry](../../../marshall/lib/marshall/ssh/key_registry.ex), and
[channel state machine](../../../audi/lib/audi/ssh/state.ex) implement these
boundaries. [Transport tests](../../../audi/test/ssh_transport_test.exs) exercise
real OpenSSH and byte preservation; [state properties](../../../audi/test/ssh_state_test.exs)
exercise arbitrary request histories. The [native journey](../../../nix/tests/machines/fleet/scenarios/user-ssh-journey.py)
covers the full setup flow. Validation results and remaining gaps are recorded
in the [review](../reviews/2026-09-25-ssh-onboarding-guidance.md).

## Open questions

Production activation and live acceptance are separate from source integration.

## Related decisions

[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0047](0047-audi-ingress-and-authoritative-dns.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md), and
[ADR-0117](0117-personal-terminal-machine-workspace.md) retain their authority
requirements, including ADR-0115's physically verified SSH roster boot binding.
