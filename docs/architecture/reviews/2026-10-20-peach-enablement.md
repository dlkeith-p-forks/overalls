# Peach enablement review

This review covers completing Peach and enabling it on the Lilly hosts. It
follows the [guest reflection review](2026-10-18-guest-reflection.md) and
[ADR-0203](../decisions/0203-guest-reflection.md).

## What changed

- **Peach service.** Startup is explicit: without `PEACH_CONFIG_FILE` no listener
  or control link starts. A configured file loads strictly (closed keys, version,
  host UUID, HTTPS origin, private socket and CA paths). The control credential
  must be a private 0600/0400 regular file outside the Nix store. The HTTP Plug
  refuses unknown paths (404), other methods (405), queries and missing,
  duplicated, malformed or foreign-host bindings (403), all before any control
  request. It serves only a protocol-valid snapshot whose guest ID matches the
  binding, with `cache-control: no-store`. A Marshall refusal answers 403; an
  outage or invalid snapshot answers 503. Diagnostics go through the new
  `Peach.Events` catalog behind a redacting logger filter, and Peach joins the
  logging check, pre-commit hooks, CI precommit matrix and flake outputs.
- **Marshall projection fixes.** The first fleet run reached Peach and Marshall
  but every snapshot failed. Four defects in `Marshall.Reflection.Snapshots`,
  none covered by earlier tests:
  1. The owner was read as the compute actor without the `:internal_lookup`
     action, so Cedar policy forbade it.
  2. The owner email (and team name) stayed `Ash.CiString`, which the control
     envelope cannot encode.
  3. `archived_at == nil` is always false in Ash, so named integrations never
     appeared.
  4. Header queries filtered on a column `IntegrationHeader` does not have, and
     passed stored kinds (`bearer`, `basic`, `static`) that the protocol's closed
     kinds (`authorization`, `content_type`, `custom`) reject.

  A database-backed test now drives the Peach control service end to end through
  the control envelope and the protocol decoder.
- **Operator commands.** Marshall's operator CLI gains `peach-rotate HOST TTL
  OUTPUT`, `peach-verify OUTPUT` and `peach-revoke HOST`, using the same private
  output custody as Galileo. Before this, no operator path could issue a Peach
  credential.
- **NixOS module.** The `peach` SecretSpec bundle delivers `PEACH_CREDENTIAL`.
  Startup copies it and the control CA into a 0700 runtime directory, because the
  unprivileged service cannot read `/run/overalls-secrets`. The socket is 0660 in
  the `peach-proxy` group, which only Audi joins. Peach no longer requires
  `lilly.service`; it keeps the identity assertion.
- **Fleet.** The Galileo fleet machine test issues real Peach credentials and
  reads the projection from inside a Firecracker guest. Its private fixture leaf
  now carries `reflection.internal`, matching the name the protocol already
  declares.

## Architecture impact

No boundary changes: Marshall keeps projection and credential authority, Audi
keeps routing and the binding, and Peach holds no database or retained state.
The operator commands add a trusted issuance path for an existing credential
domain. ADR-0203 stays partial until the production private leaf is reissued
with `reflection.internal` and hostname-verified guest TLS is observed.

## Recorded verification

- The Peach suite passed **13 tests** (`mix test` in `peach/`), including the
  four Covenant obligations. `mix format --check-formatted`, `compile
  --warnings-as-errors`, `logging.check`, `covenant.check --no-run` and
  `dialyzer --force-check` passed. The repository-wide `contracts.check` failed
  only on existing Mila Rust files outside this change.
- The focused Marshall run passed **10 tests**: `mix test
  test/marshall/reflection/snapshots_test.exs
  test/marshall/operations/peach_test.exs test/marshall/peach
  test/marshall/control/peach_service_test.exs`.
- `checks.x86_64-linux.peach-service` evaluation passed. It checks the runtime
  configuration, the secret bundle, Audi's `peach-proxy` membership and that
  Peach does not require Lilly.
- The Galileo fleet machine test passed (`checks.x86_64-linux.galileo-fleet`,
  test script finished in **751.20s**). Its Peach subtest issued credentials
  through the real Marshall operator path, sealed them into the runtime bundle,
  checked the socket (`peach-proxy`, 0660) and credential directory (0700), and
  then, from inside the Firecracker guest, read `/guest`, `/integrations` and
  `/` over hostname-verified TLS and saw `/secrets` answer 404. The first run of
  this test failed on the Marshall projection defects listed above.

## Remaining gaps

The production private leaf lacks `reflection.internal`; reissuing it needs the
recovery-only intermediate. Generated current/stale execution and credential
expiry histories, host loss and same-host native isolation remain unrecorded.
