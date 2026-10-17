# Cedar guest SSH account foundation review

## Scope and decision

ADR-0110 replaces ADR-0093's provision-time root key and extends ADR-0096's
Lyra profile to an email-derived, per-user Linux account. At this foundation
checkpoint, the worktree implemented account naming and UID reservation, a Rust
roster reconciler and an internal fresh key decision. The guest SSH path still
used the prior provision-time root mechanism. Later implementation is assessed
in the completion review for this change.

## Findings

- **Blocker: private transport and guest wiring.** The new Rust helper has no
  authenticated VM-bound roster or key-decision transport. Both guest images
  still condition sshd on a provisioned root key. Enabling the new path before
  those pieces are installed would strand new VMs or grant stale access.
- **Blocker: login audit.** Marshall can check guest key eligibility, but the
  current code has no post-authentication receipt from sshd. Eligibility must
  not be represented as a completed guest login.
- **Blocker: developer setup.** Lyra still writes `User root`. An authenticated
  registered-key proof and identity lookup must select the matching email local
  part and key before the wildcard profile can become the default.
- **Verification gap:** Unit and Hegel tests prove name and roster parsing and
  Marshall database tests prove account reservation and a fresh internal key
  decision. Neither constitutes NixOS/Ubuntu guest or live fleet acceptance.

## Checks executed

- Focused Marshall account tests: passed (four tests).
- Focused Marshall guest key eligibility test: passed (one test).
- Rust helper unit/Hegel tests and Clippy: passed (three tests).
- ADR structure and local links: passed.
- Ash migration snapshot check: passed.

## Follow-up

Finish the private service, NixOS and Ubuntu sshd integration, Lyra registered-key
setup, post-authentication audit, native machine tests, full project gates and
live deployment review before merging to main.
