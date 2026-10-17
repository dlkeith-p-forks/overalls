# Private-services PKI rotation review

## Scope and decisions

This review covers production generation and encrypted custody of ADR-0078's
offline fleet wildcard hierarchy, plus the operator command needed to rotate an
existing encrypted payload atomically. ADR-0078, ADR-0044 and ADR-0041 remain
unchanged: recovery users alone receive root/intermediate signing authority;
Overalls and Dungarees receive only the shared leaf chain and private key.

## Findings and resolution

- **Resolved, high: obsolete deployed hierarchy.** The committed trust anchor
  expired in 2031 and both host ciphertexts lacked ADR-0078's static wildcard
  chain and key. A new P-256 root, constrained intermediate and exact-name leaf
  were generated with the reviewed offline bootstrap. The public root and all
  three ciphertexts now carry the same 20/10/10-year hierarchy.
- **Resolved, medium: no atomic payload-update command.** `kittens-secrets
  encrypt` exclusively created documents and `rekey` changed recipients without
  changing payloads. Removing a committed ciphertext before re-encryption would
  create a publication gap. Explicit `encrypt --replace` now snapshots the old
  ciphertext and reuses the existing fsynced compare-and-replace path; the
  default remains create-only.
- **Accepted rollout effect.** Existing writable guest disks retain the old
  trust anchor and cannot validate the new leaf until re-imaged, as ADR-0078
  already specifies. New guest images receive the new public root.

## Verification

- `kittens-secrets check` validated all 27 document recipient sets after rotation.
- Recovery-identity decryption proved the recovery document exactly matched the
  generated root/intermediate payload and both host documents preserved their
  existing Audi credential.
- OpenSSL verification proved root-to-intermediate-to-leaf chaining, exact SANs
  `llm.internal`, `*.internal`, `*.integration.internal`, matching leaf key and
  the 2046/2036/2036 expiries. Both host documents contain the same chain/key.
- The `secret-reconciliation` and `audi-private-pki` Nix checks pass with local
  builds. The repository-wide Prek gate passes logging checks, Ruff format/lint
  and ty; the ADR checker passes all 84 records and local links. Live activation
  remains separate and does not follow from these structural checks.

## Remaining work

Activate the committed revision on both physical hosts, verify Audi private TLS
readiness and rebuild or replace any guest that still requires the old root.
