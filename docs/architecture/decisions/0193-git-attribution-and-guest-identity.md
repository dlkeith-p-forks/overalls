# ADR-0193: Git attribution and guest identity

- ID: ADR-0193
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall, Protocol, Lilly, Lyra, guest-images
- Supersedes: none
- Superseded by: none

## Context

Users need editable Git author defaults for new machines and optional attribution
for Marshall-owned agent commits. The user's implementation request authorizes
these settings. Login identity and guest execution identity remain independent.

## Decision

Account settings default to Git username `Overalls`, Git email
`noreply@overalls.dev`, and enabled commit trailers. Only the authenticated account
may update its preferences. Machine admission captures an immutable Git identity;
clones capture their new owner's current preference. Restart and relocation retain
that snapshot, while existing machines without a snapshot remain unchanged.

Provision/start commands carry the validated identity as inert guest configuration.
Kernel guests receive encoded boot metadata; firmware guests receive MMDS metadata.
Guest services publish an atomic protected Git configuration consumed through the
system Git configuration. Identity values never enter diagnostic events.

Marshall injects current application-owned developer instructions using the stable
thread configuration owner. Enabled instructions request exactly one
`Co-authored-by: Overalls <noreply@overalls.dev>` trailer, preserve other trailers,
and forbid rewriting past commits solely for attribution. Disabled instructions
override earlier attribution instructions. This follows Codex's instructional
approach; it is not command interception or a guarantee of model compliance.

## Alternatives

Rewriting Git commands would introduce another execution parser and change user
commands. Updating existing machines would violate the requested creation-time
scope. Using the latest collaborator's preference would make shared thread policy
unstable. Login email is not used as a Git default.

## Consequences

Consumers and guest artifacts must understand the new configuration before new
identity-bearing machines are admitted. Image manifests advertise version 1 Git
identity support; admission refuses images without it. Previously saved machines
without a Git snapshot omit this metadata. Native image qualification is not
implied by the new capability. Git configuration remains an overridable
default under ordinary Git precedence and existing guest sudo permissions.
No service, listener, credential or authorization capability is introduced.

## Invariants and verification

Bounded typed Hegel generators exercise identity round trips, malformed input,
command restrictions, immutable admission snapshots and trusted attribution policy.
Rust properties and guest checks cover boot parsing and Git configuration.
BEAM properties do not establish actual guest execution or production rollout.

## Implementation evidence

The [command snapshot](../../../marshall/lib/marshall/compute/command_snapshot.ex)
and [allocation snapshot](../../../marshall/lib/marshall/compute/git_identity.ex)
retain VM-owned identity. Execution and guest evidence are recorded in the
[review](../reviews/2026-10-18-git-attribution.md). Native and deployment acceptance
remain separate until explicitly recorded.

## Open questions

Production rollout and complete cross-OS machine acceptance remain unrecorded.

## Related decisions

- [ADR-0178](0178-durable-agent-context-and-planning.md)
- [ADR-0179](0179-guest-instructions-and-managed-skills.md)
- [ADR-0191](0191-elixir-hegel-property-verification.md)
