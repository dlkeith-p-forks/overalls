# Installer pre-existing SSH configuration verification

## Scope and architecture impact

Campaign improvement 060 covers the user operation of installing and
re-installing the local tooling (`overalls config-ssh`, the staged installer's
final local step) against arbitrary pre-existing local SSH configurations. It
preserves ADR-0124's unified SSH host CA model and ADR-0118's strict management
SSH and refusal semantics. The production change is a bounded refusal
strengthening in [Lyra's SSH configuration writer](../../../lyra/src/ssh_config.rs)
plus test seams; no protocol, authorization, storage authority or deployment
policy changes. Marshall is untouched. Native macOS installation remains an
explicit external acceptance boundary, unchanged from the
[002 installer record](2026-09-25-installer-verification.md).

## Pre-implementation record

The installer writes `$HOME/.ssh/config` through a `NamedTempFile` created in
the SSH directory, fsynced and renamed into place; a dropped temporary file
unlinks itself. The pre-existing config passes through an inline marker splice:
the byte ranges around `# BEGIN OVERALLS SSH` and `# END OVERALLS SSH` are
removed when one begin precedes one end, the untouched prefix and suffix are
kept, and a fresh managed block is prepended. A symlinked config is refused
before any read. Unmatched single markers already refuse. `trust.rs`'s
known-hosts `merge` already refuses anything but zero markers or exactly one
well-ordered pair; the SSH config splice did not perform that exactly-one
check, so a duplicated begin or end marker was silently mangled rather than
refused — the bounded defect this improvement records and repairs with a
regression property.

Baseline before the change: the pinned Rust 1.97.1 / Cargo 1.97.0 locked
offline suite passed 76 checks (5 guest-supervisor integration checks took
90.10 seconds); the remaining 71 checks took at most 0.51 seconds. No failures
or ignored tests.

## Independent oracle and generated matrix

The oracle is a byte-level inventory of the SSH directory taken independently
of the production writer: before and after each case, every file's bytes and
the directory entry list are recorded through direct filesystem reads. A
successful install may differ from the pre-existing config only in the managed
block: stripping the marker-delimited region from the result must reproduce
exactly the stripped pre-existing bytes. The result must contain exactly one
begin and one end marker. Every refusal must leave the whole directory, not
just the config, byte-identical. No case may leave stray temporary files, and
a dropped `NamedTempFile` (crash before persist) must leave the pre-existing
tree byte-identical. Reinstall must converge: a second run over the first
run's output must be byte-identical at the spliced region boundaries.

| Pre-existing configuration | Expected result |
| --- | --- |
| Empty directory (no config) | Config created containing exactly one managed block; identity key installed |
| Unrelated content only | Content preserved byte-identically below the prepended managed block |
| Unrelated blocks above and below a prior managed block | Both unrelated regions byte-identical; only the managed block replaced |
| Prior managed block (idempotent reinstall) | Reinstall over real installer output converges byte-identically |
| Adversarial near-marker content (`SSH TRUST` markers, marker text without newline, mid-line) | Treated as unmanaged bytes, preserved; not recognized as delimiters |
| Dangling marker text that the append/splice glue joint would promote into a real marker | Closed refusal before any write (repaired defect); plain trailing text otherwise preserved |
| Exactly-one violation (two begins, two ends, end before begin, lone end, lone begin) | Closed refusal; entire directory byte-identical |
| Symlinked config; config is a directory | Closed refusal before any write; directory byte-identical |
| Crash before persist (dropped named temporary file) | Original config byte-identical; zero stray temp entries; reinstall converges |

The known-hosts `merge` in [trust.rs](../../../lyra/src/trust.rs) receives the
same preservation/refusal matrix at the pure level, since it already implements
the exactly-one contract; this records its behavior against generated
pre-existing configurations without changing it.

The candidate-marker checks close two defects the generated matrix reproduced:
duplicated or spliced marker arrangements previously produced a config or
known-hosts file that every later install would refuse (markers rederived on
each pass), or silently dropped user bytes between stray markers.

## Validation

Pre-implementation baseline and defect reproduction: the pinned Rust 1.97.1 /
Cargo 1.97.0 locked offline suite passed 76 checks. Extraction of the marker
splice into a pure seam preceded the fix; with only the extraction in place,
the (1,1) splice accepted duplicated marker arrangements and the known-hosts
fresh append promoted dangling trailing marker text into a real marker on the
next run — the generated matrix reproduced both:

- `trust.rs merge`: prior `# BEGIN OVERALLS SSH TRUST example.test` with no
  trailing newline accepted, then the result contained two begin markers and
  the second install refused (`invalid managed SSH trust`) — a self-wedging
  reinstall.
- `ssh_config.rs` splice: prior with two begin markers was silently rewritten,
  dropping bytes between the first begin and first end and leaving the second
  begin marker embedded in the result.

Bounded repairs, each with regression tests: the splice now refuses any input
whose marker counts are not zero pairs or exactly one well-ordered pair, and
refuses when the spliced candidate itself does not carry exactly one pair;
`merge` performs the same candidate check on its fresh append. Refusal happens
before any write, so the whole SSH directory stays byte-identical.

Execution evidence (this worktree, branch `verify/060-installer-ssh-config`):

- `cargo test --locked` (devenv shell, Rust 1.97.1 / Cargo 1.97.0):
  **85 passed, 0 failed, 0 ignored** — lib 3, `overalls` bin 59 (including
  `generated_configurations_preserve_unmanaged_bytes` with 64 generated
  cases, `generated_marker_ambiguity_is_refused_and_preserves_every_byte`
  with 64, `generated_known_hosts_configurations_preserve_unrelated_bytes`
  with 64, `generated_known_hosts_marker_ambiguity_is_refused` with 64, the
  four fixed boundary/refusal tests and the two promotion-defect regression
  tests), host-certificate 1, ssh-authorize 11, trustd 5, guest-supervisor
  integration 5 (90.54 seconds), privacy 1.
- `cargo clippy --all-targets -- -D warnings`: passed in 8.22 seconds with
  zero findings.
- Nix Lyra gate `.#checks.x86_64-linux.lyra` (`cargo test --locked --offline`
  plus all-target clippy `-D warnings` in the sandbox): **85 passed, 0 failed,
  0 ignored**; the guest-supervisor integration file took 90.30 seconds;
  clippy finished in 8.38 seconds with zero findings; buildPhase 2 minutes 19
  seconds. Output
  `/nix/store/579w5kwnx450abpab60323yzk9i59qjr-lyra-tests-0.1.0`.
- `elixir scripts/check_adrs.exs`: 124 decisions, structure and local links
  pass. No ADR text constrains marker-level mechanics; the refusal
  strengthening implements ADR-0124/0118's existing closed-refusal semantics.
- Focused handbook consumer check `mix test test/marshall_web/hldd_live_test.exs`
  (partition `verify060`): 8 checks (1 property, 7 tests), seed 759135, 3.2
  seconds — exercises the edited scenario ledger and regenerated coverage
  chapter through real Marshall rendering. Full Marshall `mix precommit` is
  not required: no Marshall source, schema or configuration changed.
- `prek run --all-files`: ruff format, ruff check, ty and all eight logging
  catalog hooks passed; the hldd-review hook passed after the reviewed
  receipts below.
- `elixir scripts/hldd_options.exs --check` and
  `elixir scripts/hldd_views.exs --check` passed;
  `elixir scripts/hldd_coverage.exs --write` regenerated the installer row
  (plus three property evidence links) and `--check` passes.
- Nix `hldd` gate `.#checks.x86_64-linux.hldd` passed on the receipted staged
  tree: output `/nix/store/20f97kqsq87bjrh7s5qqx9pyyhn4czfr-overalls-hldd-check`.
  After the final evidence sentences and campaign row the governance receipt
  was re-recorded and this gate rerun on the final tree; both receipts and the
  gate are green at commit time. The gate validates structure and evaluated
  placement, not runtime behavior.

## Remaining gaps

Native macOS installation and its `UseKeychain` variant, the final guest SSH
connection, production rollout, and OS-level fault injection between the
fsync and rename remain outside this scope. The crash-before-persist boundary
is exercised at the `NamedTempFile` drop level; a physically interrupted
rename is not simulated.
