# VM disk limit review — 2026-09-18

## Scope and architecture impact

ADR-0053 supersedes ADR-0051 only to tighten the inherited disk ceiling from
16 TiB to 500 GiB. All remaining resize/capacity rationale is retained. ADR-0046's
Porsche domain authority is preserved: client parsing supplements Marshall's
independent Ash and structured command validation. No schema or wire format changes.

## Findings

Shared VM shape validation also governs execution and relocation descriptors.
Rejecting oversized prior workloads is intentional and authorized. No automatic
migration or disk shrinking is introduced. Image manifests retain their metadata
range; derived oversized requests still fail admission. Host physical capacity
is distinct from the per-VM disk maximum and is not capped at 500 GiB.

## Verification

All four `mix precommit` gates passed in the pinned `devenv shell`:

- Protocol: 97 passing properties/tests; Dialyzer passed without exclusions.
- Lilly: 272 passing properties/tests; Dialyzer passed without exclusions.
- Porsche: 58 passing properties/tests; Dialyzer passed without exclusions.
- Marshall: 541 passing properties/tests including the three-node distributed
  suite, six browser-state checks, and forced Dialyzer with its one existing
  upstream exclusion (no unnecessary exclusions).

Marshall used a temporary PostgreSQL instance on loopback port 55439, selected
through a temporary runtime configuration wrapper before invoking `precommit`.
The running database's authentication configuration was not changed. Porsche and
Marshall tests used the installed OpenSSL binary on PATH for disposable TLS fixtures.
Initial failures from obsolete 16 TiB property generators were fixed to match the
new executable range; oversized image defaults have independent rejection tests.

The ADR checker validates all 53 records. Contract syntax and discovery checks
passed; manual review traced the shared limit through admission, resize, execution,
relocation, image defaults and SSH parsing. The image-default contract explicitly
retains oversized image minima for admission rejection instead of clamping them.
The required formatter also normalized existing whitespace in the shared ingress
issuance codec; that file has no behavioral change. Final diff review found no
remaining contract or architectural conflicts in this scope. No deployment or
native guest acceptance is claimed.

## Decisions and remaining work

[ADR-0053](../decisions/0053-vm-disk-limit.md) records the accepted policy;
[ADR-0051](../decisions/0051-vm-resizing.md) retains its historical evidence.
Deploy consumers together. No compatibility or migration work is requested.
