# Compact Nix build logs: implementation and completion review

Date: 2026-09-21

This is the historical review of the implementation at
[4bca9a0b](https://github.com/antithesishq/kittens/tree/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7).
The [standalone extraction review](2026-09-21-standalone-nix-compact.md) records
the subsequent move to a pinned public dependency. Source links below retain the
reviewed implementation snapshot rather than referring to compatibility shims.

## Scope and architecture impact

The user authorized a native custom Nix shared by NixOS and the development
shell to reduce agent input-token usage, preserve full received logs, show bounded
failure context, advertise retrieval, and never infer execution failure from text.
They additionally required Hegel property-based tests.

[ADR-0087](../decisions/0087-compact-nix-build-logs.md) records the new CLI/evidence
decision as accepted and implemented. Only the pinned Nix CLI component is
source-patched; store/daemon libraries and wire protocols remain upstream.
Hegel's pinned C ABI is test-only. No domain, database, guest lifecycle, fleet
placement, authentication or log-export boundary changes.

[ADR-0042](../decisions/0042-host-observability.md) remains in force: producer-side
diagnostic protection is preserved, session files are private local evidence,
and no arguments/environment snapshot or fleet export is introduced.
[ADR-0086](../decisions/0086-reciprocal-nix-caches.md) is unchanged: remote-protocol
fixtures do not enable remote build delegation on the fleet. Existing `nix log`
and legacy maintenance commands retain their implementations.

## Prompt-to-artifact audit

| Requirement | Artifact and actual evidence |
| --- | --- |
| Source-patched Nix, not a wrapper | [Package override](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/default.nix) copies reviewed C++ headers into the pinned source and patches native command selection/completion. Both complete package variants built successfully with upstream gates enabled. |
| NixOS and development-shell selection | [Module](../../../nix/modules/nix-compact.nix), [devenv](../../../devenv.nix), [flake](../../../flake.nix), [configuration check](../../../nix/packages/nix-compact/configuration-check.nix). Evaluated all enrolled/base host configurations; each selects the stable-input custom package. Actual `devenv shell` executable resolution matches the development-input patched CLI. |
| Suppress routine output and show progress | [Presenter](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/session.hh): 15-second/160-byte heartbeat, 12 KiB invocation diagnostic budget, 4 KiB excerpts and separate 2 KiB completion allowance. Real 16-second silent build and TTY fixtures passed. |
| Preserve full received output | [Archive](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/archive.hh): append before filtering, numbered physical payload lines, event/activity identity, reversible non-UTF-8 encoding, private unique files and live writes. Hegel byte round trips and a real 10,000-line builder verify capture. |
| Useful bounded context | Per-activity 20-before/20-after context, two-second continuation window, rendered structured messages, exact deduplication and non-repeated overlapping lines. A terminal failure without an earlier error can recover 40 lines from its recently completed builder. Generated interleaving and deterministic completed-builder fixtures passed. |
| Recognize Elixir/Rust logging | [Classifier](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/classify.hh) handles LoggerJSON severity, tracing level/nested fields, Cargo compiler-message nesting and text fallbacks. Deterministic fixtures and 200 structured-precedence cases per run passed. Native ErrorInfo summaries preserve the primary message even when formatted traces precede it. |
| Error strings never fail builds | No classifier API can mutate a build result. Fifty generated real-build cases per package variant compare compact and raw execution status, check the archive footer against the actual process status, and run a successful subsequent invocation. |
| Explain suppression and log references | Start notices name the absolute archive, explain `L#`/`D#`, and supply a reader command. Completion reports actual status/counts and preserves the log pointer; failures include a bounded investigation command. |
| Stable line/diagnostic retrieval | [Reader](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/reader.hh) supports diagnostics, ranges, tails, activity/build selection, original bytes and oversized-line continuations. The suite executes **200 pagination cases per run**, plus native range lookup and Unicode-boundary fixtures. Indexes are optional, validated against the archive and recoverable by a scan. |
| Hegel property-based tests | [Properties](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/property-test.cc), [pinned engine](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/hegel.nix). Five properties × 200 cases = 1,000 core cases; native checks add 50 generated real builds. Both variants passed. A previously shrunk native counterexample was replayed successfully after fixing the fixture's incorrect use of `--rebuild` on failed outputs. |
| Honest storage failure and retention | Startup and mid-write capture failures restore visible logging. Hegel tests preserve active/incomplete sessions and verify age/byte pruning of completed logs and indexes. SIGINT preserves upstream exit status; missing completion means incomplete. |
| CLI compatibility | Native runtime tests passed for JSON stdout, output paths, explicit internal-json, full streaming, TTY, Unix-socket daemon and both SSH builder protocols with separate stores. Upstream raw-mode tests remain enabled; only the expected completion list gains `build-log`. |
| Documentation and maintenance | [User guide](../../nix-build-logs.md), ADR, overview and this review document behavior, reproducible checks, replay and limitations. Nix version drift fails explicitly. Header reads invalidate devenv's evaluation cache. |

## Verification results

The final source was built through the four exported checks:

- `checks.x86_64-linux.nix-compact-core`: strict C++ compilation, 20 classification
  fixtures, archive regressions, 1,000 Hegel cases and edge fixtures.
- `checks.x86_64-linux.nix-compact-native`: 1,050 Hegel cases plus real runtime
  compatibility, daemon, remote, heartbeat, TTY and SIGINT fixtures.
- `checks.x86_64-linux.nix-compact-native-host`: the same suite with stable NixOS
  packages; 1,050 cases and runtime fixtures passed.
- `checks.x86_64-linux.nix-compact-configuration`: native package selection,
  unchanged daemon libraries, opt-out and explicit-package override assertions.

Both `nix-compact` and `nix-compact-host` complete packages built. The retained
development-input Nix functional suite reports **201 passed, 0 failed, 8 skipped**;
skips are upstream/environment skips, not tests removed for this implementation.
The source checks were evaluated directly against the working files and locked
flake inputs before new files were Git-tracked; the exported flake package/check
and host mappings were also evaluated from the working `flake.nix`.

On each variant, the noisy-success fixture produced **609 compact stderr bytes
versus 359,114 bytes with compact disabled and full build logging**, retaining all
10,000 builder lines. This is over 99.8% fewer console bytes for that fixture,
not an exact tokenizer measurement or a universal reduction guarantee.

Types are checked by compiling the actual C++ with `-std=c++23 -Wall -Wextra
-Werror`, the native Nix compilation, and the locked Rust engine build/checks.
External JSON statuses are range-checked: a regression fixture rejects a value
that would otherwise narrow to exit code zero. Colocated directory contracts
cover the C++ sources; contract syntax tooling alone is not semantic proof.

Executed inside the pinned development shell:
`elixir scripts/check_adrs.exs`, `node scripts/check_contracts.mjs format`, and
`node scripts/check_contracts.mjs coverage`; all passed. `git diff --check` also
passed. The runtime host is NixOS 26.05. These structural gates supplement the
native/Hegel evidence above; they do not establish behavioral correctness alone.

## Findings resolved during implementation

- Upstream Nix uses error verbosity for mandatory build-plan text. The adapter
  distinguishes ErrorInfo from unstructured verbosity rather than surfacing every
  planned derivation as an error.
- A native multiline error must be one diagnostic, and different errors sharing
  an `error:` header must deduplicate by the whole event, not that first line.
- The diagnostic exhaustion notice needs reserved bytes inside its own budget.
  Completion retains separate space and still reports the real result if archive
  finalization fails.
- Low-confidence keyword matches have a 4 KiB sub-budget so they cannot consume
  all capacity before a structured error arrives. A noisy-keyword/structured-error
  fixture verifies this priority independently of the total output limit.
- Reader pagination must retain intra-line offsets and UTF-8 boundaries, and a
  broken optional index must never become the only path to archived evidence.
- Devenv's cached selection did not initially observe header-only changes.
  Explicit `readFile` dependencies fix that; a comment-only edit changed the
  evaluated package and restoring it restored the original package exactly.
- The NixOS selection contract explicitly accounts for administrative package
  overrides, matching the intentional `mkDefault` behavior and configuration
  check rather than claiming an enabled default overrides explicit choices.

## Contract review and remaining boundaries

Reviewed the new archive/classifier/presenter/reader/adapter call paths and package
selection against [the reviewed contracts](https://github.com/antithesishq/kittens/blob/4bca9a0b1a3656dde55e188b2a6ee4d7693995f7/nix/packages/nix-compact/CONTRACTS)
and ancestor contracts. No unresolved implementation/contract discrepancy was
found in this scoped change. The review covers the maintained compact sources,
command-selection hook, package consumers and exercised upstream logging paths.
No shared validator tooling or Elixir implementation was changed.

Operational boundaries are explicit rather than inferred from passing tests:

- Existing fleet hosts still require their normal rebuild/activation. No live
  fleet rollout or physical-network acceptance is claimed.
- Remote checks exercise real protocols through Nix's localhost bypass, with
  independent stores. They do not assert network reliability or fleet capacity.
- Capture starts after command parsing. Producer-disabled messages, startup
  diagnostics emitted before selection and historical substituted-build logs are
  outside this invocation archive. Received payloads may already be normalized
  by upstream Nix.
- Archive I/O can backpressure on a slow disk. Retention is a soft target that
  preserves active/incomplete evidence; it is not a hard disk quota.
- Live context/deduplication, parsing and cleanup work have explicit bounds. Full
  received payload history remains on disk when presentation limits are reached.
