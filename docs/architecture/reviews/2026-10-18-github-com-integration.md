# GitHub.com owner integration architecture review

Date: 2026-10-18. Decision: [ADR-0202](../decisions/0202-github-com-owner-integration.md),
accepted with implementation and verification in progress.

## Scope and authority

The approved capability adds per-user GitHub OAuth custody and scheduled refresh
to Marshall/Galileo's private service path at `com-github.integration.internal`.
Automatic eligibility follows the VM owner, with persistent detach/reattach.
Shared writers exercise that identity; no trusted per-process human binding
exists. One numeric GitHub account has one active Marshall owner.

Impact includes Ash ownership, encrypted persistence, credential lifecycle,
authorization, edge routing and managed guest configuration. ADR-0080's
single-attempt forwarding/leases and ADR-0134's generic attachment rule remain.
ADR-0202 records the built-in eligibility exception. ADR-0111's exact wildcard
already covers the hostname: no new SAN, issuer, service or public listener.
ADR-0158's shared sudo boundary remains explicit.

## Findings and required controls

| Boundary | Finding and resolution |
| --- | --- |
| External identity | Persist numeric GitHub identity, enforce active uniqueness and refuse silent cross-Marshall transfer. |
| Guest authority | Resolve the VM owner's connection server-side; guest account claims cannot authenticate an initiating human. Document shared-writer delegation. |
| Permission extent | Keep accepted daily scopes and `read:org`; no organization administration or repository deletion. Provider/organization policy remains an independent refusal. |
| Refresh concurrency | Durable attempt/generation fences and current locked settlement supply authority; Oban delivery does not. Keep network waits outside transactions. |
| Rotation uncertainty | Lost exchange/result/commit can follow provider rotation. Require reconnect rather than blindly replaying the old token. |
| Open requests | Drain at most five minutes, withdraw remaining leases before refresh. Disconnect, detach and retirement withdraw authenticated admission and renewal; new public requests use no token. |
| Anonymous fallback | An absent, detached, disconnected or reconnect-required connection permits reviewed anonymous forwarding. GitHub decides authentication requirements; no global GET/HEAD restriction is introduced. An anonymous retry is a fresh guest request and cannot revive an old authenticated attempt. |
| Credential routing | Restrict REST/GraphQL/Git/LFS to reviewed targets. Arbitrary destinations, guest Authorization and unsafe redirects cannot select recipients. |
| Transfer custody | OAuth bearers remain per-request Marshall authority. The accepted provider exception retains only LFS action headers and signed targets in bounded, at-most-sixty-second Galileo memory with method/execution/generation selectors and fresh lease checks before use. No durable credential cache or arbitrary target selection is authorized; Galileo contracts distinguish this from generic forwarding. |
| Secret retention | Exclude plaintext and ciphertext from PaperTrail, job arguments/projections, user responses, Events and provider-error diagnostics. |
| Existing machines | Image configuration does not upgrade writable disks. Retained delivery and all seven families need native evidence; immutable native promotions remain exact. |
| Recovery | Backup ciphertext can contain consumed refresh credentials. Decryption is not current provider authority; reconnect is the recovery path. |

## Evidence

The initial review inspected the architecture overview/index, ADR-0080,
ADR-0134, ADR-0111, ADR-0158, ADR-0157, ADR-0142, ADR-0186 and ADR-0191;
Galileo admission/renewal and single-attempt upstream; private wire bindings;
and Enrico/AshOban work precedents. The current source review additionally traces
the [GitHub domain](../../../marshall/lib/marshall/github.ex), encrypted resources,
ID-only worker, configured provider, callback controller, owner-based Galileo
admission, closed protocol routes, response rewrites and ephemeral LFS selectors.
The [maintenance coordinator](../../../marshall/lib/marshall/agents/maintenance.ex)
separates desired tool generation from executor/placement-fenced installation
receipts. Its resource is owned by Agents, while OAuth resources belong to
GitHub. No new deployable service is introduced.

Executed focused checks, under `devenv shell` on the working implementation:

- In `protocol`, `mix test test/github_test.exs test/github_tools_test.exs
  test/integration_test.exs --warnings-as-errors`: **26 passed**, seed `768903`.
  This covers closed route/target/header selection and content-addressed tool
  metadata. It does not exercise Marshall authorization or a native client.
- In `galileo`, `mix test test/github_capabilities_test.exs
  test/github_response_test.exs test/github_http_test.exs --warnings-as-errors`:
  **16 passed**, seed `242957`, 13.9 seconds. Generated histories cover
  execution/generation/method selector custody and mutation redirect refusal;
  fixtures cover one-winner PUTs, expiry, redacted state and LFS
  method/header/OID/size. A controlled real TLS origin observes one injected
  mutation and sanitized response, with a stubbed control authority and an
  explicitly redirected localhost test transport. It does not establish the
  packaged Audi/Lilly path or real GitHub.
- `elixir scripts/check_adrs.exs`: **passed, 198 decisions**, structure and
  local links only. `elixir scripts/hldd_views.exs --write` regenerated and
  checked current source ownership and evaluated placement. Coverage regeneration
  validates ledger/source references; these commands do not execute scenarios.
- In `nix/domains/artifacts/guest/github/transport`,
  `GOTOOLCHAIN=local /nix/store/9sz1nv010igaizprggzydbmybx8jm9ym-go-1.27.0/bin/go
  test ./...`: **5 Go tests passed**, including `TestRouteProperty` with
  **1,000 generated cases**. The source tests exercise routing, stripped caller
  authority, streaming and mutation redirect refusal through a synthetic
  RoundTripper. They do not boot a guest or invoke real GitHub.
- `devenv shell -- bash -c 'cargo test --manifest-path lyra/Cargo.toml --lib
  agent::maintenance'`: **6 Lyra maintenance tests passed**. Local temporary
  files and fixture health binaries cover exact length/digest, interrupted
  staging/reconciliation, bad activation paths/links, rollback and generated
  last-healthy-generation histories. Artifact URL properties keep the fixed
  private transport boundary. This is Linux-host test evidence, not Windows ACL,
  FreeBSD/OmniOS runtime, fleet rollout or retained-VM acceptance.
- The managed tool release built all eight `gh`/LFS binaries for Linux, Windows,
  FreeBSD and illumos at
  `/nix/store/dhjnr74s9hafmpf48dq5zyipmgwnadnk-overalls-github-tools-release-v1`.
  The inspected manifest generation is
  `c36e5c9035b5f7f8b6848ef688690779a70d00abf9c666057dde46023a9c2a6a`;
  Git configuration SHA256 is
  `ffb88fe7e67a83101c694c5d33ce272d2f200f8e4b7d529c7865a63ae9557974`.
  Build presence does not qualify any native image or prove the clients operate
  through the packaged private route.
- In `ziggy`, `MIX_ENV=test mix test test/bootstrap_release_test.exs
  test/maintenance_artifact_test.exs test/tool_release_test.exs
  test/provider_selection_test.exs` under `devenv shell` with `ERL_FLAGS=+S 4:4`:
  **21 passed**, seed `225546`, 0.1 seconds. The focused tests cover immutable
  loader/schema/corruption checks, closed duplicate/malformed selectors and
  exact current-authority digest/size matching before synthetic artifact bytes
  are released. They do not establish a native executor bootstrap or guest
  installation. The real public tool bundle's four-platform/twelve-file integrity
  was checked separately; that is artifact evidence, not native execution.

Marshall compiler/type/state-history results, distributed commits, packaged
browser/machine journeys and live-provider results remain separate until recorded.
Structural ADR/HLDD gates do not establish runtime or production acceptance.

## Prerequisite governance repairs

The required gates exposed existing duplicate IDs from independently added
records. Machine pins keep ADR-0193 and memory suspension keeps ADR-0199,
including their accepted supersession chains. Git attribution remains the
canonical ADR-0198 and localization is ADR-0201; the incoming GitHub, guest
reflection and newsletter records use ADR-0202 through ADR-0205. Only identifiers,
paths and references changed during reconciliation, preserving each rationale
and implementation status.

The coverage recognizer now accepts exact parenthesized/multiline Elixir
`property`, `Hegel.check` and `Hegel.run` forms, using the existing regression
fixtures and rejecting similarly named or foreign-qualified functions. Stale
archived-retry assertion references now identify current imported-history source
as present only; earlier executions remain in their historical reviews. A
deterministic prompt test is classified as unit evidence. These are repairs to
the shared verification ledger, not proof of GitHub behavior.

The initial Marshall compile also exposed duplicate Git-settings attributes and
actions in `User`, plus router references to removed `SecurityLive` and
`SSHKeysLive` modules. The duplicate declarations are removed and `/settings`
uses the existing `AccountLive` under accepted ADR-0196. Its single
`#nav-account` entry is restored. The existing Git-preferences form/action moves
into the profile section with stable field IDs and the whole-page strict mount;
the duplicate `SettingsLive` is removed. ADR-0198's creation-time Git defaults
remain available through the accepted account page. These repairs grant no new
GitHub authority. Current compiler and account-page checks must be recorded separately.

Managed upstream clients have no existing Localize/Gettext integration. Their
four fixed integration diagnostics use reviewed English fallback: managed
authentication, unsupported destination, mutation redirect refusal and unavailable
managed native trust. This
change does not invent a second translation-key system or claim translated
native CLI diagnostics. Marshall UI/documentation remain in the established
catalog extraction and source-fallback workflow; native linguistic review is a
separate limitation.

The full protocol suite exposed a pre-existing checkpoint round-trip failure,
reproduced on detached baseline `28d508d` with seed `442850`. Its command encoder
now recursively encodes the existing checkpoint structure, matching the strict
decoder and existing regression. This repairs the accepted wire contract and
introduces no new protocol decision; passing focused GitHub tests alone did not
establish the complete protocol gate.

## Historical gate corrections and acceptance checklist

The later full Protocol gate recorded **371 of 372 tests passing** in
**910.0 seconds**, seed **700067**. Its sole test failure was the stale private
certificate-name expectation, subsequently corrected with **4 focused tests
passing**. Covenant recorded **14 of 14 obligations**. That run then exposed an
incorrect `Integration.strip_prefix/1` typespec: its existing `nil` clause and
authorization result already permit an absent prefix, while the function's
success type omitted `nil`. The correction changes only that success type to
`binary() | nil`; validation, wire values and refusals are unchanged, preserving
ADR-0080 and ADR-0202. Existing nil, malformed-prefix and closed GitHub
authorization tests passed in the **22-test** focused Integration/GitHub run,
seed **979616**, in **0.1 seconds**. Forced Protocol Dialyzer then passed with
**0 errors and 0 skips** in **3.67 seconds**. Logs:
`/tmp/osmatrix-protocol-postfix-precommit.log`,
`/tmp/osmatrix-protocol-private-focused.log`,
`/tmp/osmatrix-protocol-null-prefix-focused.log` and
`/tmp/osmatrix-protocol-null-prefix-dialyzer.log`. The complete Protocol suite
was not repeated after these focused corrections.

- Inspect final callback/scope checks, lifecycle transitions, encryption,
  generation-bound requests, drain/refresh workers and retirement wiring.
- Exercise replay/expiry/login changes, numeric ownership, detach persistence,
  multi-worker settlement and ambiguous recovery with independent state oracles.
- Run browser/`gh`/Git/LFS with TLS origins and independent effect counters;
  prove withdrawal, no mutation replay and no unsafe token recipient.
- Record seven-family/retained-update execution separately from declarations;
  qualify live OAuth App/organization consent and production rollout separately.
- Review final source/contracts/HLDD; run component and protocol-consumer gates,
  ADR/reference checks and evaluated Nix `hldd`. Inception remains out of scope.

## 2026-10-19 closure verification

Controlled packaged edge check: **passed** at revision
`97809b51f5187f38d46c0d261c923771a880cddc`, using
`nix build .#checks.x86_64-linux.github-integration --no-link`. The run
completed in 74 seconds (VM script 38.10 seconds); structured log
`1792372715941-407085-0.jsonl`. It exercised two managed gh owners, Git clone
and push, pagination and redirect refusal without mutation retry, Actions and
release downloads, LFS upload/verify/second-owner download, generation and VM
fences, anonymous fallback, lease withdrawal and credential redaction.

This fixture substitutes Marshall/Lilly authority. It does not prove browser
OAuth, scheduled Oban refresh, real fleet admission, retained-image acceptance
or live GitHub consent. A single passing run also does not establish the cause
of earlier intermittent transfer failures. ADR-0202 remains partial. The older
Protocol results above are historical; current component and fleet gate results
will be recorded independently.

Current focused Marshall GitHub, admission and contract suite, including
`--include distributed`, passed **36 tests**, seed **30**, in **29.8 seconds**
using an isolated PostgreSQL instance (`/tmp/github-marshall-focused2.log`).
This records bounded BEAM/database authority behavior, not native fleet or live
provider acceptance.

The closure adds real-fleet scenarios for Linux shared writers exercising the
VM owner's GitHub identity and detached eligibility surviving authorized native
stop/start with a changed systemd invocation. They remain present evidence until
an executed fleet result is recorded. Relocation, reconnect persistence and
Windows shared-writer acceptance remain distinct gaps.

Harness prerequisite repairs copy the public CA into the browser-owned fixture
directory and load the manifest validator's required GuestAgents module. These
preserve certificate verification and image validation rather than bypassing
those controls. Required empty Egyptian Arabic plural forms preserve catalog
schema and existing translations; the forms remain untranslated fallback gaps.

The retained native fixture's smart-HTTP parser incorrectly compared a path
containing its query with a query-free advertisement path. The repair keeps path
and query separate and retains closed service selectors and mutation-query
refusal. `native-fixture-unit` passed under pinned Nix; its regression includes a
real verified-TLS shallow clone. This is fixture evidence, not native acceptance.

The repaired fixture exposed historical FreeBSD `/workspace/*` ownership trust:
checkout bytes passed, but the unchanged unrelated-root repository oracle rightly
refused acceptance. Current retained tool setup now validates completed immutable
source and exact owned checkout before installing a durable exact policy, inside
the existing configuration rollback journal. Absence preserves existing policy;
pending/corrupt source refuses. This implements ADR-0128's shared checkout model
within ADR-0202's retained update, without extending trust to unrelated paths.
Rust maintenance tests cover exact policy, preserved settings, idempotence,
rollback and late source. Native upgrade/reboot execution remains separately
required; Linux-host tests cannot establish FreeBSD or illumos behavior.

Closure component gates: Protocol full precommit passed **380 tests**, Covenant
**14/14**, and forced Dialyzer with **0 errors** (test phase **917.5 seconds**,
`/tmp/github-closure-protocol-precommit-final.log`). Lilly full precommit passed
**651 tests**, Covenant **15/15**, and forced Dialyzer with **0 errors**
(`/tmp/github-closure-lilly-precommit.log`). These are component/BEAM results;
they do not qualify the native fleet or live provider.

The full Marshall run exposed a duplicate-bootstrap claim defect: repeated polls
minted a replacement attempt before the first could acknowledge start. Returning
the same unstarted envelope after current executor/fence validation restores the
existing maintenance idempotency contract. The generated claim history and fixed
duplicate assertion passed in the fresh 45-test focused run, seed 625844,
including distributed cases (`/tmp/github-marshall-fixes.log`).
This preserves ADR-0202 rather than introducing new delivery authority.

The fleet browser probe also incorrectly required a visible LiveView root even
though the existing stylesheet uses `display: contents`. Its connection assertion
now requires exactly one connected root, while subsequent real controls retain
their own assertions. HTTP response and connection stages remain distinct; no
page body, token-bearing URL or raw browser exception enters diagnostics.

### Current closure results and remaining failures

Current Marshall focused verification passed **53 tests**, seed **644555**, in
**91.6 seconds** (`/tmp/github-marshall-csp-fixes.log`). It includes GitHub,
distributed authority, bootstrap histories, suspension/login fixture corrections,
the private-history runner correction and the exact CSP form-origin regression.
This result does not establish a passing full Marshall gate.

Galileo's complete suite passed **59 tests**, seed **817719**, in **3135.3
seconds** (`/tmp/github-galileo-precommit-20261019.log`). The initial aggregate
gate then found missing test-only Hegel applications in the Dialyzer PLT. Adding
them, matching Marshall's test analysis, changes no runtime dependency. Forced
Dialyzer subsequently passed with **0 errors** and all non-test gate stages
passed (`/tmp/github-galileo-dialyzer-20261019.log` and
`/tmp/github-galileo-final-gates-20261019.log`). Covenant records **4/4** passing
obligations. The focused real-TLS capability suite passed **12 tests**, seed
**180808**, including binary framing and partial-download withdrawal without
replay; these remain bounded edge tests.

The fleet browser committed an OAuth attempt but did not navigate to GitHub.
The production `form-action` allowlist omitted the fixed GitHub origin and could
block the same-origin POST's external redirect. ADR-0202 amends ADR-0194 with
exactly `https://github.com`; other CSP directives and arbitrary-origin refusals
remain unchanged. The focused policy regression passes; complete browser/fleet
execution after this repair is still separate acceptance.

The retained native fixture now permits the exact `llm.internal` bootstrap
destination and handles at most eight concurrent authority requests, so a stalled
artifact reader cannot monopolize lease renewal. Real TLS fixture regressions
exercise shallow clone, closed DNS and stalled-peer renewal. Native Go clients
explicitly load the reviewed FreeBSD `/etc/ssl/cert.pem` or illumos
`/etc/ssl/cacert.pem` bundle, bounded to two MiB, refusing missing/malformed roots
without vendor or environment fallback. Linux/Windows retain platform trust.
Pinned Go tests/vet, Rust migration tests/Clippy, Python Ruff/ty and the Nix
native-fixture-unit gate passed; those checks do not establish native admission.

FreeBSD first-boot managed GitHub API, secret refusals, Git push, LFS transfer
and exact ownership refusal passed under synthetic native authority in structured
log `1792379603103-1832815-0.jsonl`. The enclosing check then failed historical
executor cancellation at withdrawn-group observation; reboot remains unverified.
OmniOS did not publish an installed generation despite repeated artifact reads.
Neither complete native check passed. A one-shot tool bootstrap does not replace
the historical executor daemon.

The full fresh Marshall suite remains unsuccessful. Before a terminal fixture
exhausted the global supervisor restart intensity and stopped the application,
it exposed SMTP per-case sandbox/listener lifetime defects, redundant nested
Hegel options (repaired in the focused run), and expensive generated histories
exceeding health or aggregate runtime limits. The subsequent Repo-loss cascade
and interrupted exit are not test results. Preserve exploration counts, real
operation deadlines and health checks while repairing fixture isolation; rerun
the full gate rather than inferring it from focused passes.

SMTP fixture repair subsequently passed **6 ordinary tests**, seed **176849**,
in **12.0 seconds** (`/tmp/github-smtp-fixture-focused-20261019.log`); its two
long generated properties were excluded from that scoped run. Each generated
case now owns its sandbox, Mailer environment restoration and exact listener
cleanup. The existing one hundred cases and actual ten-second attempts remain;
each property has a finite one-hour aggregate limit. Terminal generated cases
likewise own fixtures and isolate intentional budget crashes under a case-owned
supervisor, preserving production supervision intensity.

The pinned `hegeltest-c` 0.43.7 runner's `run_one` accumulates the entire callback
duration into `total_test_time`; its default `TooSlow` health check requires ten
valid examples before thirty seconds accumulate. Real fifteen-second terminal
histories cannot meet that early-run default even with pure bounded generators.
The fixed C ABI exposes no generator timing scope; early completion would lose
assertion/replay/shrink authority. No health suppression or case reduction is
introduced by these repairs. Long-property and complete Marshall passes remain
unrecorded; a measured generator-time engine facility is a separate upstream
requirement if the current health policy is to remain unchanged.

Provider compatibility review on 2026-10-19 checked GitHub's current
[OAuth App authorization documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps).
It documents `offline_access` opt-in for OAuth Apps, eight-hour access tokens,
rotating refresh tokens, the returned expiry fields, S256 PKCE and
`grant_type=refresh_token`. This matches the implemented OAuth App flow;
GitHub App installation tokens are not substituted. GitHub Enterprise Server
may omit expiring tokens, but this integration targets GitHub.com and refuses
nonexpiring/malformed pairs. Documentation compatibility is not live App
provisioning, consent or rotation evidence.

Terminal restart verification exposed a production refusal defect in addition
to its fixture isolation defect: normal WebSocket close can retain a Bandit
connection that still dispatches application callbacks. Incoming PeerSocket now
aborts transport on loss of its admitting budget incarnation, preserving normal
close behavior elsewhere. The strict two-second old-owner termination oracle,
exact successor slots and synthetic host-stream survival remain. The regression
also attempts an old-socket application frame before replacement admission;
the configured 100-case budget property passed in the current 12-test selection
(seed656999,101.4s; `/tmp/github-terminal-fixture-final-20261019.log`).
Ten tests passed; the only two failures were the real fifteen-second silence
properties hitting Hegel TooSlow after two valid cases (32.595s and31.412s).
No application-supervisor collapse or SQL ownership failure occurred.
This preserves ADR-0083's incarnation boundary,
without claiming native guest or independent-node recovery from loopback TLS.
