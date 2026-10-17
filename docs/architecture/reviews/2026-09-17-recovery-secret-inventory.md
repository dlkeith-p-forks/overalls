# Recovery-only secret inventory review

## Scope and decisions

ADR-0044 carries forward ADR-0041 while adding an explicit recovery-only document
class. Review covers the typed registry, CLI recipient policy, Git bootstrap
inventory and operator instructions. Host identity, runtime secret publication
and deployment authorization are unchanged.

## Findings and resolution

The committed bootstrap ciphertext was omitted from inventory-wide checks and
rekeying. Registering it and adding an explicit document kind closes that gap.
Ordinary hostless documents still fail, recovery-only documents reject hosts,
and both kinds require recovery recipients. Existing staged reconciliation and
private-file handling are reused. No additional plaintext enters the repository.

## Verification

- The pinned `secret-reconciliation` Nix check passes 13 tests using real SOPS,
  age and generated SSH identities. This includes recovery-only CLI roundtrips,
  recipient changes, host exclusion, data-key rotation and mixed-document staging.
- `nix run .#secrets -- check` validates one real document: `git-bootstrap`.
  The exported public recipient manifest includes its exact recovery-only set.
- `devenv shell -- elixir scripts/check_adrs.exs` passes structural and link checks.
- Contract syntax/coverage and discovery checks pass in the isolated change.
  Relevant contract semantics were reviewed against the policy guards and
  existing reconciliation callers. The shared checkout's full contract scan
  reports missing contract coverage in 14 unrelated, untracked Antithesis skill
  assets; those files are outside this change. Its ADR check passes with all
  concurrent decisions present.
- The shared checkout's host-derived inventory was also evaluated with the pinned
  package input; its built secret command reports `Checked 1 document(s)`.
- No application code or shared governance tooling changed, so application
  precommit suites and machine tests are outside this change's verification scope.

## Remaining deployment work

Production recovery decryption requires the operator's private identity and has
not been performed. Host enrollment requires authenticated public host keys.
Synthetic cryptographic tests do not establish production machine acceptance.
