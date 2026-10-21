# ADR-0111: Verifiable private-service certificate names

- ID: ADR-0111
- Date: 2026-09-24
- Status: accepted
- Implementation: partial
- Components: Audi, Lyra, protocol, NixOS guest, Ubuntu guest, deployment secrets
- Supersedes: ADR-0078
- Superseded by: none

## Context

ADR-0078 established one offline fleet certificate but included `*.internal` in
its SAN set. The deployed chain has that name before `*.integration.internal`.
The Rustls guest SSH client rejects it as `MalformedDnsIdentifier` during the
TLS handshake. A fresh production Cedar VM consequently fails roster
reconciliation and does not start `sshd`, despite a reachable, trusted Audi
private listener. OpenSSL verifies the same chain and the requested
`ssh.integration.internal` hostname. The offline issuer key remained in
recovery-only custody and was unavailable to the 2026-09-24 deployment session.

## Decision

Future offline fleet leaves have exactly `llm.internal`, `reflection.internal`
and `*.integration.internal` as SANs. The first is Ziggy's fixed name; the
second is Peach's fixed reflection endpoint; the third covers named
integrations and the reserved SSH private endpoint. The root,
name-constrained intermediate, shared leaf custody and host distribution from
ADR-0078 remain. Rotation of the deployed leaf requires the existing recovery
issuer key and replacement of both host ciphertexts; the public root need not
change.

Until that operator rotation, the Rust guest SSH helper uses native TLS with
the image's explicit CA bundle, exact hostname verification, no proxy or
redirects, and the existing fixed private endpoint. Other Lyra HTTPS clients
select Rustls explicitly. A failure to verify the chain or hostname still
denies roster, key and login decisions. The user's instruction to repair live
SSH and permit breaking changes authorizes this correction.

## Alternatives

Keeping the broad SAN would preserve a certificate that standards-strict
clients reject. Bypassing certificate or hostname verification would turn a
private network route into identity authority. Creating a second online issuer
would restore moving signing authority expressly removed by ADR-0078.

## Consequences

The existing certificate still works for the guest SSH helper after its new
image reaches VMs. A new certificate without `*.internal` will also work for
that helper and standards-strict clients. Arbitrary single-label names under
`.internal` will no longer be certified; the supported fixed Ziggy name and
named integration zone remain. Existing guest disks need a data-preserving
upgrade to receive the helper; a host deployment alone does not rewrite them.

## Invariants and verification

Offline issuance and the shared protocol must agree on the exact SAN set and
reject caller-selected names. The guest helper must verify the production
chain and `ssh.integration.internal` before sending any roster or key request;
an untrusted root or wrong name must fail closed. NixOS and Ubuntu user journeys
must reach a shell with the expected account and home, including after a move.
Production acceptance requires a fresh VM created through Porsche and a real
Lyra SSH command through Audi. Certificate rotation requires verification on
both hosts and against a Rustls client before this decision is implemented.

## Implementation evidence

The [offline issuer](../../../audi/priv/private_pki/authority.py) and
[shared name list](../../../protocol/lib/overalls_protocol/private_services.ex)
now specify the reduced SAN set. The [Rust helper](../../../lyra/src/bin/overalls-ssh-authorize.rs)
uses verified native TLS for the existing deployed leaf, and the
[Nix build](../../../nix/domains/artifacts/infrastructure/lyra.nix) packages it for guest images.
The [PKI tests](../../../audi/test/private_pki/test_authority.py) and
[protocol tests](../../../protocol/test/private_services_test.exs) check the
exact new names. The [fleet PKI fixture](../../../nix/verification/tests/machines/fleet/galileo.nix)
uses a constrained intermediate, and the
[NixOS and Ubuntu user journey](../../../nix/verification/tests/machines/fleet/scenarios/user-ssh-journey.py)
checks login, commands, home and a second login after relocation. At the
2026-09-24 checkpoint, host ciphertexts contained the earlier leaf and existing
VM disks contained the earlier helper. Those rotation and migration obligations
kept implementation partial; later leaf-replacement evidence follows.

The [2026-10-13 coding CLI review](../reviews/2026-10-13-native-guest-coding-clis.md)
records a later production checkpoint on 2026-10-14: both hosts activated
`8930a70f`, but the first NixOS Codex canary timed out before any inference
admission; cleanup was confirmed and Ubuntu creation was not issued.
Independent offline validation of both captured public chains with pinned
WebPKI 0.103.13 failed chain verification as `MalformedDnsIdentifier` while
`llm.internal` name verification passed. Isolated constrained-issuer Codex tests
separately passed the exact names and refused the old extra name, wrong roots
and wrong hostname. The original timed-out guest's TLS stderr was not retained.
Same-root preparation recovered the unchanged issuer/root, issued the exact
two-name leaf and independently preserved both host payloads. The public
preparation proof passed pinned Rust chain/name validation for `llm.internal`
and `ssh.integration.internal`; no ciphertext or deployment change had occurred
at that preparation checkpoint. Publication, both-host live Rustls acceptance,
fresh production SSH/move and retained-disk obligations remain separate.
Retaining the root requires no guest trust-root replacement or re-imaging for
this leaf rotation; migration of older SSH helpers remains a separate obligation.

The encrypted replacement checkpoint replaced both repository host ciphertexts
through sequential per-file atomic operations, with original, intermediate and
final digest pins verified. Each document independently decrypts to its complete
prepared payload; only the chain/key changed, every nonleaf value is preserved
and runtime signing material remains absent. The replacement leaf carries the
three names above. The public root and recovery ciphertext are unchanged.
Repository publication and host activation are separate from this encrypted
evidence.

## Open questions

The recovery identity was available and used for the same-root leaf preparation
and encrypted replacement. Both-host live verification and renewed production
acceptance remain deployment evidence; an off-host recoverable backup
destination is still required before migrating retained user disks.

## Related decisions

- [ADR-0078](0078-fleet-wildcard-certificate.md): original offline custody and superseded SAN set.
- [ADR-0110](0110-cedar-guest-ssh-accounts.md): guest roster and key authority.
- [ADR-0070](0070-host-recovery-backups.md): recovery point before retained-disk migration.
