# Independent Underclass fleet rollout

## Scope and architecture impact

This review covers ADR-0081's new per-host Underclass persistence,
authentication, Tailscale publication, monitoring and recovery boundaries on
Overalls and Dungarees. It also checks the rollout against ADR-0042 diagnostics,
ADR-0070 recovery claims, ADR-0075 overlay exposure and ADR-0078's abolished
online private-certificate issuer. The accepted independent-pool decision still
holds; no replacement ADR is required.

## Findings and resolution

### Credential diagnostics

The selected upstream initially printed generated API and administrative tokens
at startup, violating ADR-0042. Underclass commit `c7d07f1` removes those values
from diagnostics, and the fleet VM test searches the service journal for both
synthetic markers. The NixOS unit receives both values through an encrypted
SecretSpec document and systemd `EnvironmentFile`, never through the Nix store
or command arguments.

### Persistent state bounds

Underclass capped its in-memory sticky-binding LRU but never removed expired or
evicted SQLite rows. That implementation defect allowed unbounded durable growth.
Upstream commit `18a7aa1` adds transactional expiry and newest-entry pruning at
startup, every periodic synchronization and after binding persistence. Rust unit
tests cover expiry and cap behavior. OAuth account rows remain operator-managed
state; provider account count is not request-amplified.

### Publication ownership and health

The first module used a detached `tailscale serve --bg` command with
`RemainAfterExit`, so systemd could report success after publication failed. It
also needed an imperative stop command against shared node Serve configuration.
The final unit supervises foreground `tailscale serve`; process loss is visible
to update health and fleet monitoring and triggers restart, while process exit
owns its listener cleanup. Underclass remains bound only to IPv4 loopback, no
firewall port opens, and Funnel is absent. Live HTTPS and ACL behavior remains an
explicit deployment acceptance item rather than a local-test claim.

### Authorization and fleet schema

The service now refuses to start if proxy/admin keys are absent or equal. The VM
test verifies unauthenticated requests, wrong-boundary keys and the correct key
for both `/v1` and `/admin/api` surfaces. Marshall's closed monitor and enrolled
host role schemas now include `galileo` and `underclass`, with the maximum raised
from six to the complete eight-role set and tests retaining unknown-role
rejection.

### Existing architecture drift

ADR-0078 deleted online private-certificate issuance, but stale flake, Dungarees,
evaluation, bootstrap and operator-document references still expected the issuer
module. Those implementation defects are removed. The PKI bootstrap now places
root and intermediate keys only in its recovery envelope and emits a separate
leaf certificate/key deployment envelope, matching ADR-0078.

## Verification

Underclass upstream passed `cargo test --locked`, release compilation,
code-contract discovery, diff checks and its NixOS VM test before both fixes were
pushed to `main`. The fleet package and configuration checks, Audi private-PKI
test, and Overalls/Dungarees production evaluations pass. Final repository gates
and the repinned fleet VM check are recorded in the change summary after they run.

## Remaining gaps

ADR-0081 remains partial. Production deployment must verify MagicDNS HTTPS, the
chosen tailnet ACL principals, off-tailnet denial and separate provider account
sets on both hosts. Production backups were deliberately deferred; no durability
or restore claim exists until encrypted backup and isolated restoration pass.
Provider terms, account onboarding and observed capacity remain operational
obligations.
