# Underclass utop pin

## Scope and architecture impact

Advance the immutable Underclass source from `8cc7321` to `a8e51a7`. The sole
upstream commit adds a `utop` wrapper and puts its package on the PATH when its
NixOS service is enabled. The fleet owns separate package and module definitions,
so those two packaging changes are carried over locally. ADR-0081's independent
pools, admin authentication, secret custody, listener, and publication remain
unchanged.

## Findings

`utop` invokes `underclass top` with user arguments preserved. It reads the
existing admin-token-protected monitor endpoint. Adding the package to the host
PATH does not expose the private service environment file or bypass the admin
token. The default service continues to run the pinned binary on loopback.

## Verification

The package build, configuration check, service VM check, upstream locked Rust
tests, ADR checker, and code-contract check are recorded in the change summary.
The VM check verifies that both commands are on the host PATH and that `utop`
invokes the monitor subcommand. Local tests do not establish live tailnet or
provider behavior.

## Remaining gaps

ADR-0081 remains partial for live provider and tailnet acceptance, encrypted
backup, and isolated restore. The usage-ledger retention gap remains open.
