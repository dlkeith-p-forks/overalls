# Legacy browser typing sweep — improvement 070

## Scope and architecture impact

Base: published main `6e042ea6` ("Merge verification 046: git mirror native
refresh"). Dedicated branch: `verify/070-browser-typing-sweep`.

Improvement 015 established the pinned standalone browser-helper typing
discipline for Teams, Control room, handbook and default OSS, and recorded two
residuals: other legacy browser helpers remained untyped, and the shared legacy
composed fleet driver still explicitly skipped the framework type check for its
older variants. This improvement closes both residuals.

- The fleet client's two raw browser helpers (`audi-browser.py`,
  `porsche-browser.py`) and the Inception guest helper (`browser.py`) now
  execute only through pinned `ty` artifacts, following 015's exact
  copied-artifact pattern against the same packaged Python/Playwright runtime.
- Every fleet variant's composed driver retains the NixOS framework's `ty`
  type check and ruff lint: the `skipTypeCheck` variant exclusion is removed
  entirely. Variants owned by campaign 020 (`cloneCancellation`) and 030
  (`executorLoss`) keep their existing typed state; their drivers, artifacts
  and owners' evidence are not modified.
- No application architecture, domain, authorization, protocol, persistence or
  runtime dependency changes. No production source change. No machine test was
  executed; native boundary: none (typing-only). Existing machine/property
  evidence retains its exact revision and scope.

## Pre-implementation record (2026-09-26, base `6e042ea6`)

1. **Evaluation defect (repaired here):** every fleet check failed `nix eval`
   on base with `error: undefined variable 'executorLoss'` at
   `nix/verification/tests/machines/fleet/default.nix:13:174`. 030's merged implementation
   `426e830f` added `executorLoss ? false` to the formal parameter list; merge
   `f7cdb3c5` ("Merge verification 020") resolved the first-line conflict by
   taking 020's side, dropping the formal parameter while keeping its uses
   (skipTypeCheck, `ziggyFixture`, executor helper wiring, assertions, name
   selection). Verified failing pre-change: `executor-loss`,
   `clone-cancellation`, `fleet`, `porsche-fleet`, `terminal-fleet`,
   `default-oss-creation` all rejected `.name` evaluation. Minimal repair
   restores the formal parameter at its original position; typing state of
   both owned variants is unchanged.
2. Twenty fleet variants skipped framework typing:
   `fleet`, `porsche-fleet`, `cloning-fleet`, `brady-fleet`,
   `customer-isolation-fleet`, `relocation-fleet`, `ubuntu-fleet`,
   `audi-fleet`, `ssh-bootstrap-fleet`, `ssh-bootstrap-ubuntu-fleet`,
   `user-ssh-journey-fleet`, `user-ssh-journey-ubuntu-fleet`,
   `audi-ubuntu-fleet`, `audi-ubuntu-relocation-fleet`, `audi-relocation-fleet`,
   `galileo-fleet`, `agent-fleet`, `agent-ubuntu-fleet`, `terminal-fleet`,
   `terminal-ubuntu-fleet`. The carve-out conflicted with
   `nix/verification/tests/support/CONTRACTS` contract `composed-drivers-statically-checked`
   ("The complete driver MUST pass the NixOS framework's lint and type
   checks").
3. Three standalone browser helpers executed without a typed artifact:
   `fleet/audi-browser.py` and `fleet/porsche-browser.py` (raw store paths in
   `writeShellScriptBin`, fleet/default.nix:782/788) and
   `inception/browser.py` (`environment.etc` source, inception/default.nix:230;
   its composed driver was already framework-typed).
4. No `skipLint` or other typing carve-outs exist elsewhere under `nix/`.

## Corrections

All fragment changes are rename- or narrowing-only; assertions keep their
previous acceptance sets and no scenario step, timeout, authority control or
diagnostic redaction was added or removed.

| File | Change | Reason under pinned ty 0.0.38 |
| --- | --- | --- |
| `fleet/default.nix` | Restore `executorLoss ? false`; `skipTypeCheck = false`; `audiBrowser`/`porscheBrowser` typed artifacts wired into the two client wrappers; passthru exports | Pre-existing eval break; legacy exclusion; raw executables |
| `inception/default.nix` | `checkedBrowser` artifact; the `/etc/inception-browser.py` source is the checked artifact; passthru export | Raw guest helper copy |
| `helpers.py` | Add `ProfiledPlacement(ProvisionedPlacement)` TypedDict | Declare the `profile` key customer fragments already stored |
| `scenarios/customer-setup.py` | Build a `ProfiledPlacement` with identical values instead of `vm["profile"] = profile` mutation of a `ProvisionedPlacement` | `invalid-key`: unknown TypedDict key |
| `scenarios/bootstrap.py` | Rename loop variable `source` → `backing` | Module-level `str` binding joined with the later `ProvisionedPlacement` binding inside lambda closures |
| `scenarios/ssh-bootstrap.py` | Rename `retry` → `retry_clone` (framework prepend `retry` function) and `log` → `boot_log` (framework `log: AbstractLogger`); keep identical assertions, with explicit `: str` bindings after the existing `isinstance`+UUID round-trip validation for `destination_id`/`retained_id` | Framework name shadowing; lambda closures read declared (pre-narrowing) types |
| `scenarios/user-ssh-journey.py` | Reconstruct the Porsche receipt envelope through validated `dict[str, object]` (015 idiom), keep `version == 1`/`status == "succeeded"` acceptance, add `isinstance` narrowing that the same equality acceptance already implied, construct `JourneyReceipt` by keywords; narrow `users["owner_email"]`/`users["owner_id"]` before `.split`/`uuid.UUID` | `dict.get` on `Unknown`-keyed dicts; TypedDict literal construction; `object.split` |
| `scenarios/audi.py` | Narrow `users["owner_email"]`/`users["member_email"]` to `str` before `.split` (the existing ssh-bootstrap.py idiom) | `object` has no attribute `split` |
| `scenarios/galileo.py` | `galileo_metrics(machine, gauge_name) -> int` validates the consumed gauge only (same JSON, same compared values) instead of returning the whole decode as `dict[str, object]` | subscripting `object` from the outer dict |
| `inception/browser.py` | Reconstruct validated `dict[str, object]` before the token fetch (015 idiom); key set and token assertions unchanged | pinned ty `Invalid --python`-independent `dict.get` Never-key rejection: first artifact build `/nix/store/nmpvvcfj3q3cmwgs3ps8s6cr2n7y8r48-inception-browser-typed.drv` failed on exactly this |
| `fleet/audi-browser.py` | Bind `urlsplit` hostname to a local and require `is not None` before the (unchanged) membership guard | development ty 0.0.73 additionally reports `str \| None` as a `dict[str, int]` key; pinned 0.0.38 did not flag it |

### Contract review

Root and `nix/verification/tests` ancestor contracts were reviewed before implementation.
The change brings the composed legacy drivers back under the
`composed-drivers-statically-checked` obligation they had silently escaped.
New contracts: `audi-browser-subprocess-typing`, `porsche-browser-subprocess-typing`
(fleet/default.nix) and `inception-browser-subprocess-typing`
(inception/default.nix), mirroring 015's per-helper obligations. The 015 fleet
comments that described composed-script typing as deferred work were replaced
with the current boundary text. No existing contract prose was weakened;
`nix-test-real-packages` and `nix-test-isolated-inputs` are unaffected because
no check gained or lost runtime scope.

## Executed validation

Pinned artifacts pass **ty 0.0.38** with Python 3.13.15 and pinned Playwright
(the same interpreter the guests execute):

| Helper | Passing artifact |
| --- | --- |
| Fleet Audi browser | `/nix/store/8ifkc28vjr9wrlmfbmpgihbjjsgac01c-fleet-audi-browser-typed` |
| Fleet Porsche browser | `/nix/store/rdlynqi78jc2xy1dmq2qqbjs9fkgjws4-fleet-porsche-browser-typed` |
| Inception browser | `/nix/store/88dy8pa7rd0s2xqfhy4mqi4lqjhhqidv-inception-browser-typed` |

The existing artifacts (Teams, Control room, handbook, MFA, default OSS,
resize, account lifecycle, team resources, terminal, maintenance evacuation,
agent CLI, private web, clone, executor loss, administration, Git mirrors, job
history) retain their own gates; `defaultOssBrowser` and `terminalBrowser`
re-evaluate from the amended fleet file with unchanged content.

Explicit-path checking of the three newly gated sources also passed
development **ty 0.0.73** and **ruff 0.16.3** format/check (playback against
the same pinned Python 3.13.15 + Playwright store interpreter:
`/nix/store/qy4b2i5aihm8gnm4673svq2hfsh4siq5-python3-3.13.15-env`).
Repository discovery alone is not claimed as evidence for these helpers.

### Composed fleet drivers

Every fleet check attr evaluates and every composed driver derivation passes
the framework's pinned `ty check` and `ruff --select F` on the final tree.
The sweep consulted the actual composed script (including the framework's
`test-script-prepend.py` and machine type hints). All 32 fleet checks:

| Variant | Driver typing (framework ty 0.0.38 + ruff -F) |
| --- | --- |
| fleet, porsche-fleet, cloning-fleet, brady-fleet, customer-isolation-fleet, relocation-fleet, ubuntu-fleet, audi-fleet, ssh-bootstrap-fleet, ssh-bootstrap-ubuntu-fleet, user-ssh-journey-fleet, user-ssh-journey-ubuntu-fleet, audi-ubuntu-fleet, audi-ubuntu-relocation-fleet, audi-relocation-fleet, galileo-fleet, agent-fleet, agent-ubuntu-fleet, terminal-fleet, terminal-ubuntu-fleet | all pass (previously skipped) |
| default-oss-creation, resize-browser, account-lifecycle, fleet-guest-trust, team-resources, integration-renewals, private-web, maintenance-evacuation, clone-cancellation, agent-cli-journey, guest-cli-recovery, executor-loss | all pass (unchanging typed variants, re-verified) |

Intermediate failing derivations retained for the record:
`9yknh55d9qayjdj3i9yiba0w5ps52k54` (customer-isolation: TypedDict key),
`9yp29lfp5wjp1qkyd3fsf3iw687a6sh8` (audi: `object.split`),
`b67i5pvpqbf5x5h58nv30pkv57smq65q` (user-ssh-journey: receipt narrowing),
`26scqq04v597y021hgdv2lpspw0lypc2` (galileo: gauge subscript), plus the
ssh-bootstrap framework-shadowing failures superseded by the passing builds.

Two `unused-ignore-comment` warnings remain on `nix/verification/tests/support/update.py`'s
documented `# ty: ignore[unresolved-reference] # driver preamble` guards: they
are load-bearing in the standalone prek/python-static context (where the
composed preamble is absent) and warn-only in composed context; removing them
would break the standalone gate.

### Repository and handbook gates

- `prek run --all-files` inside `devenv shell`: ruff, ruff-format and ty pass on
  the edited tree; the receipt hook initially reported the four expected stale
  groups before receipts were recorded (see below).
- `elixir scripts/check_adrs.exs`: passed (124 decisions).
- `elixir scripts/hldd_options.exs --check`, `hldd_coverage.exs --check`,
  `hldd_views.exs --check`: pass without regeneration; no option, scenario or
  inventory change is introduced.
- `scenarios.json` and `19-coverage.md` are deliberately unchanged: no evidence
  row changes classification, because this improvement adds static build gates
  over existing journeys and runs no machine test.
- Review receipts recorded after all content edits (`system`, `protocol`,
  `governance` updated — chapter 17's gate inventory and the review/ledger/ADR
  rows — and `deployment` no-impact); `elixir scripts/check_hldd.exs` passes
  ("HLDD review receipts and references are current").
- `nix build .#checks.x86_64-linux.hldd`:
  `/nix/store/sx728npsawnva93fz08i4mpr58ngns0b-kittens-hldd-check`.
- `nix build .#checks.x86_64-linux.fleet-guest-trust-configuration` and
  `python-static` pass against the amended fragments.
- `marshall` `mix precommit` (run because `marshall/priv/hldd/17-reference.md`
  changed): 1,187 checks (138 properties, 1,049 tests), two exclusions, seed
  `757236`; forced Dialyzer zero errors/skips/unnecessary skips; contracts gate
  passed (102 CONTRACTS files, 1,817 native notes, 125 parsed source files).

## Evidence limits and follow-up

- No machine test was run and no application suite rerun: this improvement is a
  build-time static gate. All historical native executions keep their recorded
  revisions, assertions and scopes; no scenario ledger row changes its evidence
  classification, so `19-coverage`/scenarios.json are intentionally unchanged.
- Pre-existing observation, recorded not repaired: the fleet `name` chain never
  mentions `sshBootstrap`, so the ssh-bootstrap variants report driver names
  `kittens-audi-relocation-fleet`/`kittens-audi-ubuntu-relocation-fleet`. Their
  composed scripts (and store hashes) remain distinct from the audi-relocation
  variants, which also pass. Renaming a check derivation is out of scope.
- Guest-side non-browser fixtures (systemd helpers such as `origin.py`,
  `sink.py`, `serper.py`, `seal-*.py`, `provider-catalog.py`, etc.) remain plain
  source copies; they stay outside this sweep's browser/driver scope, matching
  015's boundary.
- The Inception browser artifact pins typing only; per campaign direction no
  new Inception runtime validation is claimed or added.
- No production deployment, external provider or hardware acceptance occurred.
