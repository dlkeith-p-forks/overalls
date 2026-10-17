# Standard branding and open-domain eligibility review

Date: 2026-10-09

## Scope and architecture impact

The authorized plan renames the product profile to Standard, retains its 10.20/16
network and tool permissions, opens eligibility to safe mailboxes on any domain,
uses Geoffrey Huntley's MIT notice, and targets fresh
installations. ADR-0147 replaces ADR-0103's naming; ADR-0148 replaces ADR-0131's
inherited organizational eligibility and clarifies same-user domain-only guest
identity. ADR-0049 and its review retain historical restriction rationale with
neutral wording. The follow-up authorizes merging and publication to the original
repository. Git history rewriting, existing-state migration and live activation
remain excluded.

The Antithesis testing integration, research, skills, SDK and environment variables
remain. Only product fixture profile values in its runnable harness change.
Remaining vendor names identify this retained integration, not a product profile
or registration requirement. The SDK and vendored Hegel header must stay identical.

## Findings and implementation boundaries

- The mailbox validator had delegated the organizational-domain check to guest
  username validation. Both boundaries now use the same safe mailbox/local-part
  rules, with no domain allowlist. The complete email remains the account identity.
- Guest-account allocation already serializes permanent reservations and assigns
  fresh UID-based suffixes. Cross-domain equal local parts cannot inherit homes.
  A domain-only edit of the same User keeps its unchanged source local-part identity.
- Fresh database migration/snapshot baselines use the new profile enum. These file
  edits do not simulate an upgrade and cannot repair an already-applied schema or
  retained Lilly journal. Historical revisions remain available in Git.
- Source links, host fetching/enrollment and updater defaults retain the original
  repository on `main`. Deploy-key access is not established by source changes.
  Recovery ciphertext is untouched.

The final diff preserves Ash domain/resource ownership, PostgreSQL transaction
authority, Lilly fences, capacity accounting and the profile address/permission
algorithms. The architectural changes are the fresh-state closed profile spelling
and open-domain eligibility in ADR-0147/0148. Contract review followed the eligibility
validator's three User action callers and guest-name allocation boundary; request
refusal, verified identity validation and permanent reservations remain coherent.
Profile consumers were reconciled across protocol, both applications, CLI and
native fixtures. No contract violation was found in the inspected changed scope;
native runtime acceptance remains limited by the results below.

## Origin integration

The follow-up request restores the original repository and `main` branch and
publishes to `origin/main`. `origin` itself was never changed; the first push used
the other repository's URL. Source links, deployment repository declarations,
clone/enrollment probes and updater defaults now retain `antithesishq/overalls`
and `main`. These repository references are an explicit cleanup exception. The
Standard profile, safe open-domain registration, MIT notice and preserved testing
integration remain.

The cleanup is merged with upstream `fb7789672c1885552d4e4ef148cdff85a049c63b`,
preserving both histories. Twelve textual conflicts were reconciled against
upstream behavior: the old actor roster callbacks and retired Galileo API test
stay removed; the runtime roster predicate uses Standard; SMTP fixtures retain
the new outbox-row selection; the Brady fixture retains its additional guest;
network diagnostics retain their bounded profile counts; the handbook fixture
revokes both ordinary and remembered login credentials. The scenario ledger and
generated chapters retain upstream additions and add the cleanup scenario.

Upstream already assigned ADR-0133/0134 to other decisions. Cleanup records are
renumbered ADR-0147/0148, with reciprocal links and their own index entries; the
upstream records are preserved. No new domain/resource ownership, routing
authority, execution fencing or capacity decision is introduced by this merge.
New upstream fixtures use Standard and neutral test domains. SDK, Hegel header,
testing skill assets and environment-variable wiring remain identical to the
upstream parent.

While verification ran, upstream advanced to
`9d95fa32e32fd81e15d51077c7618f147c132b95`. A second ordinary merge preserves
its control socket custody, mail identity, terminal reattachment, CloneCopy
journal and disabled block-clone/standby switches. Five documentation conflicts
were resolved by retaining both review/index additions and merging the scenario
ledger by stable IDs, then regenerating coverage and option references. No source
conflict required discarding upstream behavior. Final component gates use a fresh
`standard_origin_final` PostgreSQL partition. The superseded first integration
passed Protocol (251 cases) and Lilly (504 cases), including Dialyzer; its Marshall
and native runs were stopped to validate the newer integrated tree.

The source-argument property exposed a pre-existing mismatch: a valid repository
such as `..o` is not a traversal segment. The assertion now forbids exact `.`/`..`
path segments and continues to forbid double dots in branch references, unsafe
characters and option-shaped values. The parser and shared Rust vectors are
unchanged. This is a verification correction within ADR-0128's existing grammar.
Three remaining host probes/ancestry references were restored from `trunk` to
`main`, matching their clone branch and the original repository.

The integrated tree passed Python format,
lint and typing; Lilly passed 518 cases (103 properties, 415 tests), with zero-error
forced Dialyzer. Nix `hldd`, `host-planning`, `module-configuration` and the complete
native `hldd-browser` passed together in 311 seconds. The browser script passed in
48.80 seconds, including source links, individual chapters/diagrams and ordinary
and remembered login revocation. Logs are `/tmp/overalls-standard-origin-latest-`
`python.log`, `lilly.log` and `nix.log`. Protocol subsequently passed 257 cases
(101 properties, 156 tests) and forced Dialyzer in `latest-protocol.log`.

The next upstream tip, `47139d6187b5289696ebec4509e10eab103bae92`, enables
block-clone copies and thirty-two standby disks in fleet source, increases the
option/parser bound to thirty-two and removes a stale testing helper build step.
These incoming changes are preserved; this cleanup performs no live activation.
Lilly's rerun passed all 518 cases with forced Dialyzer in
`/tmp/overalls-standard-origin-publish-lilly.log`. The first Nix rerun captured a
deployment receipt before its refresh and failed stale-review validation; current
local receipts pass and the final evaluated gate is rerun after recording.

Marshall's upstream operator-boot property hardcoded another session's expired
PostgreSQL socket. Its child process now inherits the current test environment and
invokes Elixir directly, overriding only test mode and the generated server flag.
This retains the reduced-child/disabled-queue assertions without changing runtime
behavior. Its focused boot property passed using a separate fresh partition.

The full Marshall run completed in 1282.7 seconds: 1492 cases passed, five
properties failed and six cases were invalidated (two excluded). One failure was
the expired boot socket. A concurrent focused run recompiled shared Marshall beam
files while mail/Enrico peers started, causing the other four failures and six
invalidations. After compilation and the full suite ended, all eleven affected
cases passed (five properties, six tests) in 50.8 seconds with distributed tests
enabled and warnings treated as errors. The full run's JavaScript gates and forced
Dialyzer passed. The fresh-schema migration check passed after the focused rerun.
These combined results are not a single uninterrupted full-suite pass. Logs are
`/tmp/overalls-standard-origin-latest-marshall.log`,
`/tmp/overalls-standard-origin-boot-test.log` and
`/tmp/overalls-standard-origin-marshall-recheck.log`.

Later ordinary merges preserve `891cf5c0`'s healthy standby lock correction and
`e203bbc78617d941988292e8174b02b6e46c196e`'s claims-first exhaustive sweep,
slow-remount custody, single-listing audit, one-hundred-twenty-eight standby
configuration and benchmark materialization handling. The cleanup introduces no
net changes to those implementations. The final Lilly precommit passed 518 cases
(103 properties, 415 tests) and zero-error forced Dialyzer in
`/tmp/overalls-standard-origin-tip-lilly.log`; all Python hooks passed there too.
SDK/header/skills and environment wiring still match the upstream parent, apart
from the runnable harness's Standard product fixture. ADR, contract, conflict and
generated handbook checks pass. Final evaluated HLDD and configuration checks run
after recording this review. No live activation or existing-state upgrade is
claimed, and the initial native agent/enrollment gaps remain open.
The results below describe the initial cleanup before this upstream integration.

## Initial verification

Checks use the pinned Elixir 1.20.4 / OTP 29.0.6 environment in the separate
`cleanup/standard-branding` worktree at baseline
`af84b088943db2b20144b03e36c5c69993e8f948`, with an owned Unix-socket PostgreSQL 18
cluster and fresh `standard_branding` test partition. No live fleet was changed.

- Protocol `mix precommit` passed: 221 cases (82 properties, 139 tests), including
  forced Dialyzer; `/tmp/overalls-standard-protocol.log`.
- Lilly `mix precommit` passed: 468 cases (78 properties, 390 tests), including
  forced Dialyzer; `/tmp/overalls-standard-lilly.log`.
- Marshall's initial complete run passed 1394 of 1395 cases, including all 200
  properties. Its only failure was a stale invitation assertion rejecting a valid
  external domain. The corrected invitation suite passed all 10 tests in
  `/tmp/overalls-standard-invitations.log`. The full suite rerun passed all 1395
  cases (200 properties, 1195 tests; two excluded) in 973.7 seconds;
  `/tmp/overalls-standard-marshall-final.log`. The complete `mix precommit` gate
  passed, including JavaScript checks and forced Dialyzer (47.5 seconds).
- The open-domain registration, distinct cross-domain guest identities and
  same-user domain-only identity tests passed in that complete run. The generated
  safe-local-part round-trip property passed across valid domains. These are local
  Ash/PostgreSQL and property results, not native cross-domain home acceptance.
- `MIX_ENV=test mix ash_postgres.generate_migrations --check` passed against the
  fresh schema; `/tmp/overalls-standard-schema.log`.
- Python format, lint and type hooks passed, including the corrected updater
  fixtures; `/tmp/overalls-standard-python-final.log`.
- Nix `hldd`, `host-planning` and `module-configuration` passed together;
  `/tmp/overalls-standard-nix.log`. ADR, contract syntax/coverage and generated
  handbook option, coverage and architecture-view checks passed.
- The isolated SDK smoke passed with emission inert when `ANTITHESIS_OUTPUT_DIR`
  was absent and exact setup/declaration/assertion JSONL shapes when set. SDK
  class/file metadata was retained. SDK and Hegel header bytes match the baseline;
  `/tmp/overalls-standard-sdk.log`.

Native results include passing profile/updater checks and three incomplete journeys:

- Customer fleet passed actual profile egress and same-host/cross-host guest denial
  before its release-upgrade phase failed fetching the fixture's old branch. Shared
  and standalone updater fixtures now initialize `trunk`. Standalone native
  `auto-update` passed in 79.32 seconds, including activation, rollback, health
  retry, fetch refusal and active-system drift recovery. The complete customer
  fleet rerun passed in 1345.91 seconds: actual profile egress and cross-guest
  denial, real release upgrades retaining guests, encrypted credential-only
  reconnection, Lilly daemon-death recovery and Customer denial after guest
  stop/start on both hosts. The combined Nix build exited zero in 1380 seconds;
  `/tmp/overalls-standard-native-updater.log`.
- Agent CLI passed the fresh approved invocation's Standard child-agent refusal
  before a later owner-withdrawal inventory equality assertion failed. The failed
  assertion is outside the profile naming/permission changes; no complete agent
  journey pass is claimed; `/tmp/overalls-standard-native-core.log`.
- Handbook source-link checks passed in both Workspace and Control room before
  the revocation assertion failed. All individual chapters and diagrams were
  visited before that failure. The expected sign-in redirect instead reached the
  overview; the browser uses automatic remembered sign-in and its fixture
  invalidates only the ordinary login token. No complete revocation acceptance is
  claimed.
- Host enrollment failed before exercising the changed Git branch at the isolated
  `nix copy` SSH connection (reset during key exchange on loopback port 2222);
  `/tmp/overalls-standard-native.log`. Enrollment activation remains unverified.

The source-link assertion's execution record now points here, rather than attributing
the changed destination to the September capture. Historical native results retain
their revision and scope. The remaining vendor references, tracked filenames and
symlink targets were inspected as retained harness/research/skill/SDK documentation;
the only integration source edit is its product fixture profile value. No old
product enum, company-domain eligibility or organization repository remains outside
that retained testing integration. Git history and original-worktree files remain
untouched.

Final ADR, HLDD receipt/reference, generated option/coverage/view, code-contract
syntax/coverage/regression and conflict-marker checks passed. The Nix `hldd` gate
passed after recording the final review; `git diff --check` is clean. All three
component gates passed without bypasses. The original worktree remains clean at
the baseline; changes are uncommitted in the new worktree. The owned test database
was stopped and the temporary SDK capture removed. Live deployment, existing-state
migration, native cross-domain guest homes and the three failed native journey
assertions remain outside this passing evidence.
