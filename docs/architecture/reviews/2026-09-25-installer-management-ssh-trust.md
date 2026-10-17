# Installer management SSH trust

## Scope and architecture impact

ADR-0118 adds deployment-authorized trust bootstrap before the existing Porsche
account proof. ADR-0046's gateway ownership and ADR-0096/ADR-0110's client/account
boundaries remain intact; ADR-0115's guest authorization is unaffected. HTTPS
authenticates the embedded fingerprint, while the unauthenticated scan supplies
only a candidate public key. No new domain authority, protocol or persistence
schema is introduced. User authorization is the accepted implementation plan.

## Findings and resolution

- First-use management SSH formerly prompted for trust. The installer now binds
  the operator fingerprint to the canonical deployment hostname, verifies scanned
  key material, and requires strict ED25519 checking for account lookup.
- Existing conflicting or revoked trust is never silently replaced. Hashed
  matching entries are recognized, unrelated entries survive, and trust-file
  updates reject symlinks and use an installer lock and atomic replacement.
- Missing trust returns HTTP 503; invalid runtime configuration fails startup.
  The fleet declaration uses the fingerprint explicitly supplied by the user,
  not a value learned from an unverified network scan.

## Validation

- Focused installer/controller tests pass, including native OpenSSH scanning,
  successful strict authentication and changed-key refusal against an isolated
  loopback SSH server. Failure cases cover conflicts, revocations, malformed or
  mismatched scans, empty scans, scan failure, failed writes, symlinks, invalid
  origins and missing tools; repeat runs cover plain and hashed entries.
- Marshall's full suite passed 951 tests/properties (73 properties, 878 tests),
  including distributed checks, with two explicitly excluded host/capacity cases.
  The full precommit gate passed structural ADR/contracts, logging, browser/type
  checks and forced Dialyzer with zero errors.
- Lyra's 61 Rust tests, Clippy with warnings denied, formatting, and the sandboxed
  Nix `checks.x86_64-linux.lyra` check passed.
- Nix `checks.x86_64-linux.module-configuration` passed, including absent/invalid
  fingerprint configuration and propagation to all three Marshall instances.
  Evaluation of Overalls' service environment returned the operator-supplied
  fingerprint, and an isolated runtime-config read rejected a malformed value
  before application startup.
- ShellCheck 0.11.0 passed. Contract discovery exposes the renderer, shell origin
  and trust requirements, and both account-proof contracts in Rust. Structural
  checks complement manual review of failure paths; they do not prove semantics.

## Remaining gaps

Production rollout, native macOS execution and the separate generic account-setup
failure are not established by these checks. No production private keys or user
known_hosts files were accessed. Operator key rotation still requires explicit
client reconciliation; multiple active fingerprints are outside this change.
