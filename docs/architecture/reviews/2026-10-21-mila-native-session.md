# Mila native Rust session

## Scope and architecture impact

ADR-0249 remains accepted and partial. A new `mila-session` crate composes
`mila-runtime` projections with `mila-transport` without introducing async/network
dependencies into the pure runtime. ADR-0220's single Porsche connection and
ADR-0228's certificate-before-device-signing requirements remain unchanged.
No server API, deployment service, authorization or persistent schema changes.

## Reviewed behavior

The session owns real SSH machine reads, validates succeeded envelopes and
canonical identities before projection, and preserves the last good listing on
refusal, malformed bytes or incomplete channel exit. Pagination commits rows and
cursor together, rejects cycles, bounds retained rows and cursors at 500, and
replaces duplicate IDs across pages with the later validated row. Duplicate IDs
within one page are refused. A refresh resets cursor history only after success.
Offline snapshots are possible only after the final page, and bind the connection
host and explicit port. Optional snapshot owner is a `self` presence marker,
never a remote account identity. No server payloads or device material are logged.

## Findings and remaining gaps

- Native applications still require async session handles and OS device-signing
  adapters. SSH authentication alone is not browser/account approval; this layer
  does not report sign-in success or invent a machine listing after connection.
- Trust fetch/pin persistence, approval, watch, mutation dispatch, snapshot custody
  and full machine details remain separate work. The listing projection contains
  only the existing snapshot fields. Retained rows after a failed refresh must be
  presented as stale by the consumer. More than 500 machines currently refuses
  continuation rather than silently truncating a complete list.
- Tests use a local real SSH server with scripted replies and a synthetic device
  signer. They establish neither hardware custody nor real Marshall authorization,
  browser sign-in, native UI execution or deployed service acceptance. A NixOS
  native-client/Porsche journey is still required before retiring Flutter.

## Validation

`cargo test -p mila-session` passed three local TCP SSH integration tests and
five decoder tests (three Hegel properties, 128 cases each). Assertions cover one
authentication across pages, deterministic projection, complete-only snapshots,
refresh replacement, cursor-cycle refusal, invalid read/version/authority refusal,
byte/row/name bounds and preservation after missing exit status. Strict Clippy
and formatting checks run for the final source; governance results are reported
separately with the change.
