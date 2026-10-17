# Standalone browser type gates — improvement 015

## Scope and architecture impact

Base: published main `8773b1b4511d38ce7deef583d67035f987ae8507`.
Dedicated branch: `verify/015-browser-type-gates`.

The user journeys are Teams ownership/creation, Control room reads and elevated
writes, ordinary handbook reading, and default OSS machine creation. Their
existing allowed paths, refusals, recovery assertions and property/native
oracles remain unchanged. This improvement closes a verification gap in the
standalone Playwright helpers used by those native journeys.

No application architecture, domain, authorization, protocol, storage or runtime
dependency changes. ADR-0033's machine verification requirement is inherited
through ADR-0043, ADR-0048, ADR-0050, ADR-0051 and current ADR-0053. ADR-0028's
contract/evidence boundary remains intact. ADR status and implementation status
do not change; ADR-0033 gains precise build evidence.

## Finding and correction

Repository Python source discovery excludes `nix/verification/tests/machines`. The NixOS
framework checks its composed driver, but cannot check a separate Python
process merely because the driver invokes it. Teams, Control room, handbook
and default OSS previously executed raw `browser.py` store paths without a
standalone type-check dependency.

Each now executes the copied artifact that must pass pinned `ty` against the
same Python and Playwright used for execution. Teams, Control room and handbook
export `checkedBrowser`; the shared fleet exports `defaultOssBrowser` and uses
it in the actual default OSS command. This follows the existing MFA, resize and
account-lifecycle pattern and permits independent artifact builds without QEMU.

The first pinned build rejected default OSS's `dict.get` on an `object` narrowed
only to `dict`: ty 0.0.38 inferred a `Never` key. Failed derivation:
`/nix/store/3ndgv0iqyrss8svhripvkrln6bq04f6a-default-oss-browser-typed.drv`.
The correction reconstructs a `dict[str, object]` from validated string keys
before retaining the existing required-string validation. JSON object keys are
already strings; this preserves accepted/rejected JSON fixture semantics without
casts or unrestricted types. Missing or non-string required values still fail.
The new local contract records that obligation.

Handbook's external section-list result now has an `object` annotation before
its existing list and per-item string checks. Its runtime statements and
assertions are unchanged. Teams and Control room Python source is unchanged.

## Contract review

Reviewed root, Nix and Nix-test ancestor contracts; the four artifact definitions;
all four runtime invocation sites; the default OSS field parser and its one
consumer; and the handbook section-list validation and navigation loop.
Artifacts check and execute the same copied bytes with one pinned Python
environment. No assertion, TLS setting, timeout, authority control or redaction
behavior was removed or weakened. Source/directory contract discovery and
formatting pass; those tools establish structure, not semantic compliance.

## Executed validation

All four standalone artifacts passed the actual Nix package's **ty 0.0.38** with
Python 3.13.15 and pinned Playwright:

| Helper | Passing artifact |
| --- | --- |
| Teams | `/nix/store/873xvjhn30aj5w7napv7rq8phcdmg97r-teams-browser-typed` |
| Control room | `/nix/store/p4g6wwwm13w5q1sa4yral001z0pw1bc5-control-room-browser-typed` |
| Handbook | `/nix/store/k1pml4qqwx0pk806v7ab5wmg2mnnndpf-hldd-browser-typed` |
| Default OSS | `/nix/store/348l3dm99djfmdsmhffly5g6scpvplb5-default-oss-browser-typed` |

Explicit-path checking of the same four sources also passed development
**ty 0.0.73**, plus ruff format/check. Ordinary broad discovery alone was not
used as evidence that these helpers were checked.

The following completed successfully:

- `prek run --all-files` inside `devenv shell`: all eight logging catalogs,
  handbook review, ruff, ruff-format and ty.
- Code-contract format/coverage and discovery for the new JSON contract and
  fleet artifact note; ADR structure/link checks (122 decisions).
- HLDD receipts, generated option reference, scenario coverage and Ash/topology
  views.
- Nix `python-static`: `/nix/store/8dqq5a85rvwgawg9rdb4h0qhyrmv6r86-overalls-python-static`.
- Nix `hldd`: `/nix/store/rzslrvqlgg4i8fsyaii8j3iqksrvgcr8-overalls-hldd-check`.

These Nix governance outputs precede final execution-summary bookkeeping only;
source helpers and artifact definitions are identical. Final documentation
receipts and the Nix HLDD check are rerun after recording this evidence.

## Evidence limits and follow-up

No native machine or application suite was rerun for this build-gate and typing
change. The application source, browser assertions and valid fixture semantics
are unchanged. Existing machine/property evidence retains its exact revision,
assertions and scope; the scenario ledger explicitly separates this static
addition. A new property mirroring the JSON reconstruction would add no useful
user-operation oracle. Required typing was verified by building the artifacts
actually consumed by the existing native tests.

Installer trust has no standalone `browser.py`; its composed driver already has
framework typing. The shared legacy composed fleet driver still explicitly skips
typing for its older variants. Other legacy browser helpers remain separate
work; this change does not imply repository-wide standalone helper coverage.
No production deployment or external provider acceptance occurred.
