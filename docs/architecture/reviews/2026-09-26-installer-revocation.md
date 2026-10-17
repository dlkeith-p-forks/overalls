# Installer revocation, upgrade trust preservation and macOS-boundary delivery proofs

Date: 2026-09-26. Discovery: verification-campaign improvement 115 (scope
`/tmp/opencode/campaign/discovery-052-installer.md`), branch
`verify/115-installer-revocation`.

## Scope and architecture impact

No production code, protocol, authority or persistence change. The work extends
the two-VM `installer-trust` native driver and the shared fleet
`user-ssh-journey` scenario with closed-refusal and preservation evidence for
installer account proof, artifact upgrades and platform selection boundaries.
ADR-0124 (one SSH host CA) keeps its accepted decision; its implementation
evidence section was extended to reference this review. No new decision.

Affected ADRs: ADR-0124 (evidence text only). ADR-0046 user-key proof,
ADR-0110 Cedar accounts, ADR-0104/0113 update and platform trust rules unchanged.

## Implementation

- `nix/verification/tests/machines/installer-trust/`: two static eval fixtures
  (`register.exs`, `revoke.exs`) apply the real owner-scoped
  `Marshall.SSH.add_key`/`remove_key` domain actions when the driver starts
  their one-shot units. Two release fixtures copy `packages.lyra`: the
  `upgraded` fixture appends one byte to `linux-amd64` and regenerates every
  manifest digest from the actual bytes; the `mismatched` fixture appends one
  byte and intentionally keeps the stale packaged manifest (build-time
  assertion guarantees the disagreement). The driver selects the served release
  through a runtime systemd drop-in for `OVERALLS_LYRA_RELEASE`; only
  `/nix/store` paths satisfy the controller.
- Whole-tree refusal snapshots compare type, mode, symlink target and file byte
  digest for `~/.ssh`, `~/.local/bin` and `~/.config/overalls` around every
  refusal; the Lyra trust writer atomically rewrites identical bytes, so modes
  and digests (not mtimes) are the compared content.
- Refusal probes run the real `install.sh` without a pty and capture complete
  stderr/stdout; completed installs keep the existing `script(1)` terminal
  wrapper for the final `exec ssh` boundary.
- `user-ssh-journey.py` gains one revoke→probe→re-register cycle placed after
  the installed CLI opens its interactive guest shell, on both the NixOS and
  Ubuntu fleet variants. Revocation uses the real owner-scoped removal action
  via the fleet operator eval; an unattended eval cannot honestly hold the live
  passkey elevation the administrator action requires, so the administrator
  path is recorded as a boundary rather than fabricated.

## Defect verdicts (discovery 052)

1. **Trust-before-proof asymmetry** (`lyra/src/ssh_config.rs:218` before
   `:220`): reproduced and pinned, no reorder. A first-contact account-proof
   refusal natively leaves CA trust installed (`known_hosts` block and
   `overalls-trust.json`, mode 600) while the executable, managed SSH block,
   proved identity file and CLI configuration stay absent or byte-identical.
   The existing `installer-refusal-retains-client` contract requires only the
   executable/configuration preservation, so the asymmetry is asserted and
   documented rather than reordered. Pinned natively by the `installer-trust`
   subtests "revoked account key refuses before any client replacement"
   (installed client: full byte retention) and "revoked key at first contact
   installs trust but no account binding" (fresh client: exact `.ssh` delta is
   precisely the trust pair).
2. **Mismatched-digest stderr-only distinction** (`overalls-install.sh:68-76`):
   pinned by assertion. The mismatched-digest refusal is distinguished only by
   the stderr text `Binary checksum mismatch`; the installer shares exit
   status 1 and emits no structured refusal. Asserted by the "mismatched
   served digest refuses before replacing the executable" subtest against a
   real served release whose manifest disagrees with its bytes.
3. **Stale-stage native desktop activation** (`lyra/src/update.rs:150-173`):
   recorded boundary only, owned by the update scenario (agent 113). The
   desktop-pending digest revalidation has no native activation coverage here;
   not expanded.

## Closed-refusal semantics observed

A revoked account key is an archived registration. At the Porsche boundary the
publickey transport completes, then the account layer refuses the exec with
exit status 3 and an `approval_required` JSON receipt — never a succeeded
proof. The packaged CLI maps that closed proof to its generic
`SSH configuration failed` without echoing the proof's stdout. The fleet
journey asserts status 3 with the approval receipt and no succeeded JSON for
Porsche `whoami --json`, and a nonzero closed refusal with empty stdout for the
managed guest SSH path; re-registration through the real domain action restores
both (same fingerprint, new key row identity).

## Evidence (exact results)

Native NixOS `installer-trust` (`vm-test-run-overalls-installer-trust`,
output `/nix/store/3dy8vnh4zc5lsca8dgssq21r3gkxza13-vm-test-run-overalls-installer-trust`)
passed in 173 seconds of build time under the campaign HEAVY lock. Subtest
durations: first installation 1.00s; repeated installation 0.56s;
conflicting/revoked trust refusals 0.89s; fresh account install with four-way
digest agreement, four-target checksum/manifest agreement, known_hosts
recomputed via `ssh-keygen -y` from the test CA, and three-way
SQL↔proof↔identity association 11.00s; revoked account key refusal with
closed proof (status 3, `approval_required`, no succeeded receipt) 4.67s;
first-contact asymmetry pin 0.89s; re-registration restore 4.65s;
appended-byte upgrade preservation 9.69s; served-digest mismatch refusal 8.93s;
unsupported-platform refusal 7.79s; Darwin selection with recorded
darwin-arm64 fetch/checksum URLs 1.13s; checksum-tool absence refusal and the
shasum fallback completion 7.75s.

Fleet `user-ssh-journey` revoke→probe→re-register cycle: see commit summary.

Environment note recorded for reruns: refusal probes capture the installer's
complete stdout/stderr directly; `script(1)` pty typescripts proved lossy for
sub-second refusal runs and are retained only for the existing terminal-bound
install boundary. The shasum fallback's hidden real digest tool keeps its
`sha256sum` basename because the NixOS system profile is a coreutils multicall
dispatching on argv[0].

Focused Marshall installer suite: 3 checks passed (1 property, 2 tests).
Lyra gate `checks.x86_64-linux.lyra` =
`/nix/store/ddklaznhkkwbk3dva1bwkwx6bbmiwygp-lyra-tests-0.1.0`, passing cargo
test and clippy --all-targets in 159 seconds.

## Remaining gaps

- Native macOS runtime (UseKeychain, Keychain/1Password agents, Gatekeeper)
  remains an external boundary; this change proves only selection, checksum and
  refusal boundaries on the Linux client with shimmed platform input.
- The final guest connection and identical re-install coverage are unchanged
  and retain their recorded scopes; macOS runtime coverage is not claimed.
- Administrator `revoke_for_admin` revocation within an unattended eval would
  require fabricating live MFA elevation; the campaign boundary records the
  owner-scoped real action instead. Browser-driven administrator revocation has
  separate coverage under the admin account journey.
