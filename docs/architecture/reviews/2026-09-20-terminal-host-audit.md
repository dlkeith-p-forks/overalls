# Terminal host audit remediation

- Date: 2026-09-20
- Scope: terminal audit findings C3, H3 and H6
- Decisions: [ADR-0082](../decisions/0082-guest-terminal-multiplexer.md),
  [ADR-0083](../decisions/0083-terminal-host-stream-and-registry.md)

## Findings resolved

- The credential-bearing terminal WebSocket now verifies the TLS peer and HTTPS
  hostname, sends the configured control-plane hostname as SNI and uses the same
  configured CA file as the control client.
- Terminal readiness remains false through TCP, TLS, WebSocket and hello send. A
  validated `hello_response` establishes readiness; stream loss clears readiness
  before reconnect scheduling and emits the catalogued, payload-free loss event.
- Firecracker output now passes through a packaged byte-oriented host helper that
  continuously drains stdout and stderr while retaining at most 1 MiB per VM boot.
  The reader remains bounded, and arbitrary bytes are persisted without text
  decoding or rewriting.

## Verification

- Focused terminal, VM-unit and boot-log tests pass: 11 tests, including two
  properties.
- The full Lilly suite passes: 354 tests, including 41 properties.
- The host-tools Nix derivation builds the new helper with warnings as errors.
- ADR structure and links pass. The aggregate Lilly precommit run passed its
  contract, logging, compile, format and Dialyzer gates with zero Dialyzer errors;
  its test phase had one unrelated timing-threshold failure at 612 ms versus
  500 ms. The immediate standalone full-suite rerun passed.

## Architecture impact

The remediation implements existing ADR-0082/0083 requirements without changing
domain or protocol boundaries. Host stream authority remains authenticated and
connection-scoped, terminal bytes remain outside diagnostics and PostgreSQL, and
the serial console remains a bounded read-only boot log. Both decisions retain
their existing status; native VM restart and fleet-load acceptance remain
separate from these unit and application checks.
