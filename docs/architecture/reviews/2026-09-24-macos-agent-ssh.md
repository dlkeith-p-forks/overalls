# macOS agent-backed guest SSH review

## Scope and finding

This review covers the public installer, Lyra's local key selection, and the
isolated Audi gateway connection under ADR-0110 and ADR-0096. The live installer
matches the repository source. It selects `darwin-arm64` or `darwin-amd64`,
verifies a SHA-256 digest, runs `overalls config-ssh`, then invokes OpenSSH. The
published macOS artifacts match their manifest digests. The reported
`SSH configuration installed` line therefore establishes that download and
account proof completed; the following `audi@... Permission denied (publickey)`
comes from the gateway connection.

Setup's Porsche proof uses the user's OpenSSH configuration, including a
`Host * IdentityAgent` rule such as 1Password's quoted socket path. Lyra's
Audi subprocess uses `-F /dev/null` and previously discarded that agent choice.
If the selected key exists only in the configured agent, Lyra writes the exact
registered public key to `overalls-identity.pub`, but the isolated subprocess
cannot reach the signer. `IdentityFile` alone cannot repair that missing agent.
An encrypted private file could also be missed because setup attempted to
derive its public key with an empty passphrase. Separately, a pending desktop
update could overwrite a fresh installer binary at its first invocation.
The [OpenSSH client manual](https://man.openbsd.org/ssh_config#IdentityAgent)
also specifies `IdentityAgent $VARIABLE`, `${VARIABLE}`, socket paths,
home-directory and percent-token expansions, `SSH_AUTH_SOCK` and `none`.
The initial fix rejected legacy variable and relative forms. It also probed
without Porsche's remote command, so a `Match command` rule could select a
different agent during proof and gateway use.

## Decision and boundaries

Lyra now evaluates the effective Porsche `IdentityAgent` with `ssh -G` on each
gateway invocation, including the `whoami --json` proof command. It preserves
OpenSSH's expanded socket bytes, resolves the legacy `$VARIABLE` form from the
current environment, accepts relative socket paths, and honors inherited or
disabled agents. An explicitly empty expanded socket remains distinct from an
absent setting. The chosen socket is supplied through child-only
`SSH_AUTH_SOCK`.
The exact proved public key remains the sole `IdentityFile`, with
`IdentitiesOnly=yes`. The Audi subprocess retains its isolated SSH options,
current HTTPS host-key pin, and public-key-only authentication. It can prompt
for a selected encrypted key's passphrase; macOS can use its Keychain option.
The socket path and SSH payload remain absent from persistent diagnostics. A
closed structured event records only whether an explicit agent was selected.

The desktop updater now requires the managed binary's digest to equal the
recorded staging base before activation. A fresh installer copy therefore
cannot be downgraded by an older pending artifact. These changes implement
ADR-0110's existing exact-key requirement and ADR-0096's verified updater
boundary; no new persistence, authorization or protocol decision is needed.

## Verification and remaining gap

Rust unit and Hegel tests cover quoted agent-path parsing, direct, environment,
token and relative agent forms, command-specific selection, exact child-agent
selection, encrypted file keys, and stale-stage rejection. Rust tests and
Clippy, Python formatting/lint/typing hooks, code-contract checks, and ADR
structure checks passed for the initial change. The NixOS fleet journey passed
with an agent-only key through a quoted socket path containing spaces and
repeated SSH after VM relocation. Additional agent forms are included in the
fleet journey; its updated packaged runs, the Ubuntu run and native macOS
execution remain to be verified.
