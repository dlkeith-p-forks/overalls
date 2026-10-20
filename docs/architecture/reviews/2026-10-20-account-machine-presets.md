# Account machine creation presets review

Date: 2026-10-20. Scope: the current branch's Accounts preference persistence,
settings forms, machine/thread initial defaults, launch replay projection,
catalogs and revised verification sources under ADR-0240.

## Architecture impact

Accounts continues to own User preferences. Compute continues to own admission,
immutable VM identity and archived request history. The additive columns introduce
no new domain or deployable service. The owner/key-scoped Compute projection
returns original request inputs only; ordinary admission still checks the current
actor and immutable source. Profile permissions, capacity accounting, isolation,
guest fencing and provider protocols remain unchanged. ADR-0240 amends the
initial-default clauses of ADR-0147/0157 and section list of ADR-0196.

## Reviewed failure boundaries

The save action locks the actor's live User and checks its stored login before
writing. Inputs cannot select another owner. Presets accept only Standard/OSS,
enabled ordinary images and bounded whole-unit shapes meeting image minima.
Launch requires source2 plus validated workspace capability. Invalid writes
leave all groups unchanged. Resolution falls back against current eligibility;
ordinary admission remains authoritative if availability changes afterward.

Machine URL inputs override initial preferences. Later refreshes preserve drafts
and request keys. Thread collaboration Work remains separate from VM profile.
Admitted launch replay reads original provisioning sizes, including after resize
or archival, so changing preferences/catalog observations does not change the
idempotency request. A concurrent first admission with changed settings may
conflict; a later retry reads the committed original request. No extra allocation
is authorized by a conflict or failed lookup.

## Validation

The final focused Marshall run passed 92 checks (seed 493808, 180.2 seconds),
including the 100-case profile history exploration and repository-launch
histories, alternate-image persistence and internal-update refusal. The test partition
used disposable socket-only PostgreSQL; its database was created from UTF-8
template0 after the initial SQL_ASCII template refused creation.

Repository-wide Python formatting, ruff and ty hooks passed with the pinned
development shell. ADR validation and code-contract syntax/coverage passed;
contract discovery and source review covered the save action, resolver,
creation consumers and original-request projection. These structural checks do
not establish contract semantics or native execution.

The final application checks passed formatting, code-contract validation and its
20 validator regressions, 42/42 Covenant static obligations, 42 executable
Covenant tests and runtime coverage, terminal/workspace checks, Monospace
structure, pinned locale data, translated documentation and strict catalogs.
Compilation passed with warnings treated as errors. Covenant remains bounded to
the BEAM test VM; its module-loadability baseline does not prove native isolation.

Upstream `644810bd` was integrated before publication. Its fleet decision retains
ADR-0235; this preset decision is ADR-0240. The supplemental run passed nine
checks covering presets, image-size defaults and the integrated ACME configuration.
The sizing typespec now admits catalog metadata alongside its required minima,
matching its existing runtime behavior; a closed two-key map had made Dialyzer
infer that usable catalog images could not reach the resolver.

Native catalog freshness passed. Follow-up application Dialyzer analysis against
the dependency PLT checked by the preceding forced run reports only five
unchanged lifecycle/SCIM warnings: `delete_for_team/3` contract/return/call typing,
the configuration nil comparison and retirement-worker return typing. There are
no remaining preset/resolver warnings; the overall type gate remains red.
The final upstream integration through `a881d783` preserves the Android relay,
FreeBSD and Windows custody work and its own evidence. It changes no Marshall
preset implementation; the earlier full-suite Android failure describes that
attempt's revision, before the upstream fixture correction.

Native extraction also found pre-existing unextracted SCIM/GitHub messages and
an Android label using the forbidden default domain. The catalogs now include
those exact identities and the Android technical-literal reviews; unrelated
reference-location refreshes follow native extraction. The User snapshot also
includes the existing SCIM fields already introduced by the 20261019 migrations;
the new migration adds only the fifteen preset columns.

The bundled-font integrity command stopped at the existing
`noto-arabic-OFL.txt` SHA-256 mismatch, before glyph coverage. This change does not
alter the font files or manifest.

The full Marshall attempt used seed 330867, included distributed tests and kept
host/capacity fixtures excluded. Before build interference it reported unrelated
SCIM digest-substring, Android bridge-close and locale-task timeout failures.
Later distributed peers encountered unavailable modules while native Gettext
extraction rebuilt application beams; that run was interrupted and has no valid
final test count. Those later failures are not product evidence. The full
`mix precommit` gate is not claimed green. Final focused tests and remaining
gates run sequentially after extraction.

Property execution uses the locked Hegel checkout
`b0dec2abf868c7036950c00256a2ebf5af2929e7`, native version `0.43.7`, and its
dependency-local `priv/hegel_nif.so`, without `HEGEL_NIF_PATH`. The profile and
launch histories retain their 100-case exploration budgets. The launch history
has a finite 180-second aggregate timeout after the combined run exceeded its
former 60-second limit; its assertions and per-operation waits remain bounded.

The disposable real-Chromium fixture passed independent saves and reloads for
all three presets, matching machine/thread creation inputs, and 36
route/locale/theme/viewport combinations: `/settings`, `/machines/new` and
`/threads/new`; English, Arabic and Japanese; light/dark; 1440 px and 390 px.
All combinations passed overflow, character-grid, local primary-font and
direction checks; theme contrast and same-origin/CSP checks also passed.
Screenshots of the English desktop, Arabic dark mobile and Japanese desktop
preset forms were inspected. This was a scoped manual script using the existing
Monospace probe helpers and owner-private disposable browser state, not native
guest execution or independent linguistic acceptance. The broad presentation
probe separately stopped on an account-grid assertion; the scoped rerun passed
all affected routes. The broad probe is not claimed green.

## Remaining acceptance

The revised native default-profile browser journey is present; native execution
is separate from BEAM and static checks. The existing recorded guest network and
isolation histories retain their original revisions. Independent linguistic review,
real-browser layout beyond the three inspected locales, production migration and fleet rollout
are not established by this change's application tests. Known Inception failures
remain outside this work.
