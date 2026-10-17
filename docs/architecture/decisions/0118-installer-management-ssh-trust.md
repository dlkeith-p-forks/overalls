# ADR-0118: Fingerprint-verified installer management SSH trust

- ID: ADR-0118
- Date: 2026-09-25
- Status: superseded
- Implementation: partial
- Components: Marshall Web, Lyra, NixOS deployment
- Supersedes: none
- Superseded by: ADR-0124

## Context

[ADR-0124](0124-unified-ssh-host-ca.md) replaces the fingerprint trust model with
a dedicated host CA. The historical rationale and evidence below are retained.

The public Bash installer invokes Lyra account setup, which proves the user's
SSH identity through Porsche on the control-plane hostname, port 22. A fresh
client previously prompted for an unknown management host key. The user requested
an embedded fingerprint and automatic installation of the verified public key,
selected deployment configuration, and authorized implementation of the plan.

## Decision

The operator supplies one canonical SHA256 ED25519 fingerprint through
`services.marshall.managementSshFingerprint`, exported to every Marshall instance
as `MARSHALL_MANAGEMENT_SSH_FINGERPRINT`. Invalid values fail startup. Missing
configuration disables `/bin/install.sh` with HTTP 503 rather than falling back
to first-use trust. The HTTPS-served, non-cacheable script embeds the fingerprint
and the configured public hostname; request headers cannot select either value.

Before installing or executing the client, the script validates its arguments
and binds the origin hostname to the embedded hostname. It reuses matching plain
or hashed known_hosts entries. An applicable revocation or conflicting ED25519
entry stops setup, even if another matching entry exists. Otherwise a bounded
ED25519 scan obtains a candidate; `ssh-keygen` must calculate the expected
SHA256 fingerprint before a canonical host/public-key entry is installed.

The script preserves unrelated entries, refuses symlinked trust paths, locks its
trust-file update, and creates private files. It never replaces conflicting trust
automatically. Lyra's management account proof requires strict checking and
ED25519. This does not change Audi's per-route HTTPS key lookup or the guest's
normal host-key policy. Direct `config-ssh` users must establish management trust
before running setup.

## Alternatives

Blindly appending `ssh-keyscan` output or using accept-new authenticates no
expected identity. A hardcoded Overalls-only key does not support other
deployments. Publishing the full public key could avoid the scan, but the chosen
operator interface is a fingerprint and uses native OpenSSH verification.

## Consequences

HTTPS delivery authenticates the pin. The fingerprint is public configuration,
not a credential; Marshall never reads Porsche's private key. Deployment must
configure the pin before advertising a working installer. Rotation requires an
operator update and explicit client reconciliation of conflicting old trust.
Management SSH remains on port 22 even when HTTPS uses a nonstandard port.
The final guest SSH command remains interactive.

## Invariants and verification

- No management scan result becomes trusted before exact fingerprint verification.
- Failed scans, mismatches, conflicts and revocations prevent account lookup.
- Existing matching hashed entries remain byte-for-byte unchanged on repeat runs.
- Origin mismatch fails before local writes; hostnames cannot inject shell syntax.
- Trust updates preserve unrelated entries and do not follow symlinked targets.
- Real OpenSSH must connect with installed trust and reject a changed key.

## Implementation evidence

The following evidence describes the fingerprint implementation at `18761e4f`.
Current source paths implement ADR-0124; its review records their new verification.

The [renderer](../../../marshall/lib/marshall_web/overalls_installer.ex) validates
substitutions and the [controller](../../../marshall/lib/marshall_web/controllers/overalls_controller.ex)
uses only deployment configuration. The [script](../../../marshall/priv/overalls-install.sh)
verifies and installs trust. The [installer tests](../../../marshall/test/marshall_web/overalls_installer_test.exs)
execute the script in isolated homes and exercise native OpenSSH against a local
SSH server. [Lyra setup](../../../lyra/src/ssh_config.rs) enforces strict ED25519
management checks; its [integration test](../../../lyra/tests/privacy.rs) checks
the account-proof invocation. The [Nix option](../../../nix/domains/system/marshall.nix)
and [evaluation](../../../nix/verification/tests/evaluation/module-configuration.nix) cover
optional configuration, invalid input and all-instance propagation.

The generated properties in the installer tests vary malformed pins, trust-entry
ordering, hashed hosts and malformed scan position while checking refusal preserves
trust, the installed client and SSH configuration. The focused
[NixOS installer journey](../../../nix/verification/tests/machines/installer-trust/driver.py)
uses the actual Marshall HTTPS routes, packaged Lyra and Porsche account proof;
it intentionally excludes the final guest connection. Its
[verification review](../reviews/2026-09-25-installer-verification.md)
records the exact execution scope.

The [review](../reviews/2026-09-25-installer-management-ssh-trust.md) records
executed checks. Production rollout and native macOS execution remain unverified.
The reported later generic SSH configuration failure is not diagnosed by this
trust change.

## Open questions

None for the approved scope. Multiple active pins and automatic rotation are
outside this decision.

## Related decisions

[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0096](0096-lyra-developer-ssh.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md), and
[ADR-0115](0115-ssh-roster-boot-authority.md).
