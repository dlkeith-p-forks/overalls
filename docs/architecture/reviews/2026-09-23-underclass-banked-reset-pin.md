# Underclass banked-reset pin

## Scope and architecture impact

Advance the immutable Underclass source from `b256419` to `aaca487`. The sole
upstream commit adds automatic Codex banked-reset redemption. ADR-0081's
independent host-local pool, SQLite custody, application authentication,
loopback listener and Tailscale publication decisions remain unchanged. The
new behavior is confined to each host's own provider accounts and database.

## Findings

Upstream enables automatic redemption by default. A live request can consume
one finite credit when all enabled Codex accounts are unavailable. It chooses
an account using the latest natural quota recovery, persists the credit and
idempotency key before the upstream call, and checks usage before readmission.
Polling also refreshes Codex usage and administrative display data. Reset
decisions log account labels, shortened account identifiers, outcomes and
durations rather than tokens, credit IDs or upstream response bodies. Copilot
routing remains separate.

The fleet Nix module retains its private runtime environment file. A host
service environment override can disable redemption without changing secret
delivery.
No migration action is required: upstream creates the reset-attempt table in
the existing host-local SQLite database. The upstream unit and property tests
cover selection and retry with a mock provider; the fleet service check covers
packaging and existing local service boundaries. Live provider credit behavior
and quota timing remain unverified.

## Verification

`nix build .#underclass --no-link` passed with the new immutable source hash
and unchanged locked Cargo dependency hash. Both
`nix build .#checks.x86_64-linux.underclass-configuration --no-link` and
`nix build .#checks.x86_64-linux.underclass-service --no-link` passed. At the
upstream revision, `cargo test --lib --locked` passed 49 tests and
`cargo test --test properties --locked` passed 10 tests. The ADR structure
check and code-contract format check passed; these do not prove live provider
behavior. `cargo test --test e2e --locked` passed its proxy pool integration
scenario.

## Remaining gaps

ADR-0081 remains partial for live tailnet ACLs, provider onboarding and
encrypted backup/isolated restore. Verify a real banked reset on a provider
account before relying on automatic recovery in production.
