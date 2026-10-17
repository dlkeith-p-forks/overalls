# SSH onboarding guidance review

## Scope and architecture impact

ADR-0120 adds a diagnostic-only Audi channel and a gateway-authenticated key
recognition operation. ADRs 0046, 0047 and 0110/0117 retain their account,
placement, admission and revocation boundaries. No guest image or schema changes
are required. The user approved implementation, isolated worktree development,
tests, integration into main and push; production activation is separate.

## Findings and resolution

- Direct SSH previously rejected PTY without guidance. The explicit channel
  state machine acknowledges diagnostics without allocating a shell or connector.
- Key recognition previously required duplicating lookups. Marshall's shared
  registry preserves archival filtering, exact key matching and admission locks.
- Protocol text could corrupt nested SSH. Audi emits guidance only on stderr,
  returns nonzero, and reserves stdout for guest bytes.
- An unknown key cannot identify an account. Copy describes the offered key;
  unavailable verification is not treated as unknown registration.
- Browser approval requires a live proved Porsche connection. Human one-shot
  commands now direct users to interactive onboarding, and interactive guidance
  explains that closing the connection invalidates the link. The native browser
  flow retains its connection through approval; no authority lifetime is widened.
- Integration with ADR-0117 preserves the shared personal guest account and
  roster authority. Diagnostic handling neither allocates an account nor uses
  the browser's separately authenticated identity as SSH proof.
- Applicable ancestor and local contracts were checked across the registry,
  authority callers, versioned client/API, channel state machine and renderers.
  No substantive mismatch remains in the inspected paths.

## Validation

The native scenario explicitly removes the owner's registered key through the
UI, verifies VM ownership and zero active keys in PostgreSQL, and offers a fresh
never-registered key. It checks direct PTY/non-PTY and proxy failures, approves
that same key through Porsche's browser flow, and logs into the same Firecracker
VM as the owner. Both NixOS and Ubuntu variants include this case.

- Protocol `mix precommit`: 210 passed (75 properties, 135 tests).
- Audi `mix precommit`: 143 passed (31 properties, 112 tests), including real
  OpenSSH, stderr separation, signature-proof gating and channel properties.
- Porsche `mix precommit`: 83 passed (11 properties, 72 tests), including
  connection-lifetime guidance and unchanged pending JSON responses.
- After integration with current main, Marshall `mix precommit`:
  982 passed (76 properties, 906 tests), with the
  standard two exclusions;
  Lilly: 407 passed (48 properties, 359 tests).
- Forced Dialyzer, ADR checks, code-contract checks and Python/logging hooks
  passed. Initial parallel runs hit existing short timing assertions; full gates
  passed serially without changing thresholds.
- Native execution exposed fixture issues now corrected: the helper follows
  the current `/overview` login redirect, repeated logins use fresh private
  token files, and expected SSH failures use the driver's returned exit status
  because its shell runs with `set -e`.
- Native `user-ssh-journey-fleet` and `user-ssh-journey-ubuntu-fleet` both passed
  the complete owner-with-no-keys onboarding, browser approval, interactive and
  remote-command login, SSH-agent forms, relocation and preserved account/home
  checks. They ran sequentially with real nested KVM; an earlier parallel run
  hit the existing host-freshness assertion without changing its threshold.
  These journeys tested the SSH implementation before the final main rebase;
  the Marshall/Lilly gates above were rerun after integrating upstream cloning,
  legacy config-download retirement, roster-lock retry and Ubuntu sudo packaging.
  The onboarding implementation did not change during that rebase.

## Remaining gaps

Production deployment and live user acceptance are outside this change.
