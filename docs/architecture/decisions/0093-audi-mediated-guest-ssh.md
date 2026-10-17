# ADR-0093: Audi-mediated guest SSH

- ID: ADR-0093
- Date: 2026-09-22
- Status: superseded
- Implementation: implemented
- Components: Porsche, Marshall SSH, Marshall Compute, protocol, Lilly VM, Audi, NixOS, Ubuntu
- Supersedes: none
- Superseded by: ADR-0110

## Context

ADR-0047 routes VM SSH through Audi with current Marshall authorization, but the
production NixOS and Ubuntu images expose no SSH daemon and provisioning carries
no authenticated user key into a guest. Tests therefore used a special fixture
and did not prove that a Porsche-created production VM was reachable. The user
authorized automatic delivery of the key authenticating the Porsche session and
required live NixOS and Ubuntu verification through Audi.

## Decision

For Porsche `new`, Marshall MUST bind the current, registered session key ID to
the idempotent request and VM. A replay through another key conflicts. The key
must belong to the actor and remain current while admission commits. Inception
does not receive guest root SSH.

Only the immutable `provision` execution snapshot MAY contain the canonical
public key. Protocol v3 accepts the optional field only for provision; start,
resize, stop and delete reject it. Lilly encodes it as one URL-safe kernel
argument. The standard NixOS and Ubuntu images validate the same closed OpenSSH
key forms, atomically create exactly one root `authorized_keys` entry, generate
per-disk host keys and start a hardened port-22 sshd. On an unprovisioned disk,
a missing or malformed argument cannot start sshd or produce readiness for a
keyed boot. Later boots use the persisted key file without repeating key material.

Audi remains the outer authorization and revocation boundary. Guest sshd permits
root public-key authentication only and disables passwords, keyboard-interactive
authentication, forwarding, tunnels, X11 and user environment changes. The key
is not synchronized after provisioning. Restarts, clones and relocations retain
guest access and host identity only because they retain the writable disk.
Terminal-v2 remains the independent browser/vsock path from ADR-0082.

Rollout deploys the backward-compatible Lilly/protocol reader before Porsche is
used to create keyed VMs. Legacy commands without a key remain valid.

## Alternatives

Manual key installation was rejected because first access would depend on an
operator-only side channel. Periodic key synchronization was rejected because it
would let later control-plane state silently rewrite guest-local authority.
Running a public guest SSH listener without Audi was rejected because it would
bypass the existing VM-bound authorization and network fence.

## Consequences

Removing a Marshall key or share immediately blocks the outer Audi route but does
not erase the key inside an already provisioned disk. Disk recipients, including
clones, inherit its guest key and host identity unless a future explicit rotation
decision replaces this bootstrap-only model. Public VM views expose neither key
material nor its internal provenance ID.

## Invariants and verification

- Only the authenticated Porsche `new` key can enter a provision snapshot.
- Guest key material never enters diagnostics, unit descriptions or later commands.
- Keyed readiness requires hardened sshd; unkeyed guests expose no sshd.
- NixOS and Ubuntu accept the same key and generate distinct host keys.
- Strict reconnect and stop/start preserve each VM's host identity and access.
- Audi denial, password denial and disabled forwarding remain independently tested.

## Implementation evidence

Protocol validation is in
[execution.ex](../../../protocol/lib/overalls_protocol/execution.ex). Marshall
session binding and immutable snapshot construction are in
[commands.ex](../../../marshall/lib/marshall/ssh/commands.ex),
[admission.ex](../../../marshall/lib/marshall/compute/admission.ex) and
[command_snapshot.ex](../../../marshall/lib/marshall/compute/command_snapshot.ex).
Lilly boot delivery was in `jail.ex`, and the shared image validator was
`nix/domains/artifacts/guest/ssh.py`; ADR-0110 removed both paths. The
[durable command store](../../../lilly/lib/lilly/control/store.ex) permits only
the intended one-way removal of bootstrap key material when the first later
lifecycle command replaces the provision intent; it continues to reject adding,
restoring or changing that key.

Protocol, Porsche, Galileo, Lilly, Marshall and Audi precommit gates pass, as do
the Python static checks, Nix evaluation checks and actual NixOS and Ubuntu image
builds. The [live acceptance](../reviews/2026-09-22-guest-ssh.md) provisioned
ordinary NixOS and Ubuntu images through Porsche, reached both as root through
Audi on port 22, pinned distinct guest host keys, rejected password authentication
and active TCP forwarding, and preserved the key, marker and host identity across
a complete Porsche stop/start cycle. Those results complete this decision's
implementation evidence.

## Open questions

An explicit in-guest key rotation/recovery mechanism is intentionally deferred.

## Related decisions

- [ADR-0011](0011-nixos-guest-and-console.md)
- [ADR-0046](0046-porsche-ssh-management.md)
- [ADR-0047](0047-audi-ingress-and-authoritative-dns.md)
- [ADR-0052](0052-fenced-local-guest-ingress.md)
- [ADR-0068](0068-nix-built-ubuntu-guests.md)
- [ADR-0082](0082-guest-terminal-multiplexer.md)
- [Architecture review](../reviews/2026-09-22-guest-ssh.md)
