# ADR-0078: Fleet wildcard private-service certificate

- ID: ADR-0078
- Date: 2026-09-19
- Status: superseded
- Implementation: implemented
- Components: Audi, NixOS, deployment secrets, protocol
- Supersedes: ADR-0063
- Superseded by: ADR-0111

## Context

ADR-0063 accepted per-host leaf certificates issued at runtime by an online
intermediate through Marshall, with five-year lifetimes and explicit
rejection of fleet-wide shared server keys. The user later directed that
this internal service runs on a trusted platform reachable only from
Firecracker guest network namespaces, that moving parts must be minimized,
that certificates be backed up by the automatic Restic capture and be
portable across Lilly nodes, and that no backwards compatibility is
required. This decision replaces the certificate provisions of ADR-0063;
its other provisions remain carried by ADR-0064.

## Decision

Abolish per-host issuance. A single fleet-wide wildcard server certificate
with SANs `llm.internal`, `*.internal` and `*.integration.internal` is generated offline by
the private PKI bootstrap alongside the root and intermediate, and is
distributed to every private-services host through the existing
SecretSpec/SOPS bundle and systemd `LoadCredential` pipeline, exactly like
every other fleet credential. Root, intermediate and leaf lifetimes are 20,
10 and 10 calendar years; root and intermediate keys remain recovery-only
custody and no host ever holds signing authority. The issuer service, the
Marshall issuance route, the per-host renewal agent and its timer are
deleted. Rotation is an operator action: re-encrypt the bundle and redeploy.
Guest images embed the new root as a reproducible image input.

The shared-key tradeoff accepted here: any holder of the leaf private key
can impersonate private services to guests. Containment: the key never
enters guests, Marshall or logs; the `.internal` namespace is only
reachable from inside guest network namespaces at 169.254.254.1; the
certificate is name-constrained to `.internal`; compromise recovery is one
SOPS rotation and redeploy. Backup and portability hold by construction:
the ciphertext is committed and materialized into every host backup, and
every host already holds the same certificate, so node drain and
replacement need no certificate migration.

## Alternatives

Retaining per-host issuance with wildcard SANs was rejected: it keeps the
issuer service, the renewal agent and the Marshall issuance route alive for
no security gain on a trusted internal platform. Per-name leaf certificates
were rejected: names are user-created and dynamic; issuance would become a
moving part again. A longer-lived single root-signed leaf without the
intermediate was rejected: the intermediate's critical `.internal` name
constraint remains valuable defense in depth and costs nothing at runtime.

## Consequences

Existing guests keep the previous root and fail private-service TLS until
re-imaged; the fleet is small and images are reproducible, so this is an
accepted rollout step recorded in the ledger. Certificate expiry becomes a
decade-scale operator obligation tracked by the lifetimes constant in the
protocol library. Host-local certificate state directories disappear from
backup path lists; the bundle ciphertext capture already covers the
material.

## Invariants and verification

PKI unit tests cover the exact canonical Ziggy name, wildcard SAN issuance,
exact-set CSR validation, name
constraints and the 20/10/10 lifetimes. The private-services machines test
verifies guests trust only the new root and that the wildcard certificate
serves both `llm.internal` and the integration zone. The exact Ziggy SAN is
required because standards-compliant clients do not match `*.internal` directly
against `llm.internal`. The secrets checker
continues to enforce recovery-only custody for root and intermediate
documents and per-host recipients for the leaf.

## Implementation evidence

The [PKI authority](../../../audi/priv/private_pki/authority.py) generates
the wildcard names and lifetimes, mirrored by
[PrivateServices](../../../protocol/lib/overalls_protocol/private_services.ex).
The [audi-private module](../../../nix/modules/audi-private.nix) consumes
the static certificate through systemd credentials, and the
[machines test](../../../nix/tests/machines/private-services/default.nix)
exercises the resulting DNS/TLS path. The issuer module and renewal agent
are removed in this change. The production
[recovery ciphertext](../../../secrets/private-ca-recovery.enc.json),
[host ciphertext](../../../secrets/overalls-audi-private.enc.json) and
[public root](../../../secrets/private-services-root.pem) implement the offline
20/10/10-year hierarchy; the
[rotation review](../reviews/2026-09-21-private-services-pki-rotation.md)
records recipient, payload and cryptographic verification.

## Open questions

None.

## Related decisions

- [ADR-0111](0111-private-service-tls-names.md): replaces the malformed broad SAN while retaining offline fleet custody.
- [ADR-0063](0063-private-services-and-ziggy.md): superseded certificate provisions.
- [ADR-0064](0064-customer-workspace-isolation.md): carries the remaining obligations.
- [ADR-0044](0044-recovery-only-secret-documents.md): recovery-only custody.
- [ADR-0070](0070-host-recovery-backups.md): backup capture of bundle ciphertext.
- [ADR-0080](0080-named-edge-integrations.md): the integration zone served by this certificate.
