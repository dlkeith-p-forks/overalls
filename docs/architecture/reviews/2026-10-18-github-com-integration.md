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

The subsequent FreeBSD retained run established both boot0 and boot1 GitHub
workflows, with an independently certified clean shutdown between boots:
managed API, credential absence, Git push, LFS transfer/content and exact
workspace ownership refusal passed. Structured log
`1792382859702-2804140-0.jsonl` records the two tool-verification markers and
clean shutdown (events1537/1538/1557). The enclosing check still failed after
270s at the unchanged historical daemon withdrawn-group observation
(events1558–1562); this is scoped two-boot feature evidence, not a complete
native check pass or executor upgrade. OmniOS diagnostic run
`1792382487609-2733808-0.jsonl` recorded43 failed GH artifact streams,
zero LFS/config fetches and49/49 accepted heartbeats; no installed generation.
This isolates first-artifact transfer failure without attributing it to lease
refusal or changing the real timeout bounds.

Merge review of origin `eaca39a46` found optional version-4 Android agent
metadata rejected by the editor descriptor shape check. Separately validated
agent metadata is now excluded only from that shape check and retained in
immutable identity. The focused protocol run passed19 tests,seed218704,
including a100-case composition/refusal property. Lilly image consumer tests
passed15 checks,seed274501, with forced Dialyzer reporting zero errors/skips.
ADR and generated HLDD checks passed after merge; evaluated Nix HLDD passed
in10s (`1792383088496-2839730-0.jsonl`). These are scoped checks, not
Android or live GitHub acceptance. Incoming account catalog duplicate-msgstr
syntax failures were patched forward across28locales: current translations
remain active and retired translations are comments. All696PO/POT catalogs
parsed with pinned Expo1.1.1 and the strict28-locale/24-domain catalog check
passed with zero empty, unreviewed, fuzzy or invalid target forms. Full Marshall
verification is being rerun.

Final Protocol verification of the optional-agent composition repair passed
**381 tests**, seed **236249**, in **902.7 seconds**. Covenant obligations held;
both precommit and explicit forced Dialyzer reported zero errors and skips
(`/tmp/github-android-protocol-precommit-20261019.log`). The separate Lilly
image consumer result remains15 tests,seed274501, plus forced Dialyzer zero
errors/skips. Neither result establishes fleet, native or provider acceptance.

Native cold-admission finding (unresolved): the exact reviewed FreeBSD and
OmniOS manifests lack `git_identity_version:1`, while allocation now requires
that explicit content-bound capability. The existing exact-native admission
regression consequently refuses with `git_identity_unavailable`. Preserve both
closed capability validation and the accepted native-admission requirement;
changing the test to expect refusal would conceal the conflict. Current native
workspace source installs validated MMDS attribution under the current boot
fence and the native service payload includes its Git configuration, but this
is not evidence that the older pinned disks contain it. Resolution requires
new immutable candidates, actual attribution propagation/workflow execution
and promotion of their exact reviewed identities. Retained GitHub tool
installation evidence does not establish new-machine cold admission.

The native builder correction adds an explicit nullable `gitIdentityVersion`
opt-in, requiring integer1, source-v2 and a native payload. Only the current
FreeBSD candidate opts in; default and promoted image identities remain
unchanged. The evaluated `native-os-guest-unit` check passed in2s
(`1792384510977-3209837-0.jsonl`), including refusal of missing source,
unknown version, floating-point and string versions. This is construction-policy
evidence, not native runtime qualification. The attribution harness checks
effective personal-user configuration and actual commit authorship on every
boot; complete candidate qualification remains pending.

Fleet acceptance now includes real detached relocation (completed destination,
host change, advanced execution epoch and inactive source unit), browser
disconnect/reconnect with an exact new exchange count and persisted exclusion,
and Windows shared-writer identity via the actual member terminal account.
The final disconnect oracle counts a new revocation, excluding the earlier
reconnect revocation. These assertions are present; runtime results are pending.

### Closed bootstrap renewal diagnostics

The Lyra HTTP/RPC observer changes only the one-shot retained-tool bootstrap's
nonzero exit category when its heartbeat renewal fails. Existing unobserved
request/RPC callers retain their no-op observer, request bounds and refusal flow.
The bootstrap reports fixed HTTPS stage/error categories as 80–109, request
encoding as 110 and response JSON decoding as 111. Other invocation errors remain
1 and malformed invocation remains 64. An acknowledged poll returns 0; its
maintenance row still owns the installation outcome. Claim, transition,
artifact transfer and reconciliation failures are not given these renewal codes.
No URL, error text, identifiers, credentials, payload or tool output enters the
observation. A refused renewal still removes authority and aborts installation;
there is no retry, new wire field, durable state or authority. This preserves
ADR-0100's executor fencing and ADR-0202's retained-tool custody, with no new
architectural decision or native image qualification.

The focused Linux-host run passed **7 HTTP tests** and **10 maintenance tests**,
including the generated last-healthy-generation property, followed by
`cargo clippy --lib --tests -- -D warnings`
(`/tmp/github-native-renewal-stage-final-check.log`). Contract discovery and
format checks passed (`/tmp/github-native-renewal-stage-contracts.log`). The
invalid-request regression checks unchanged refusal and closed numeric mapping.
These results do not establish a native TLS failure cause, OmniOS artifact
delivery, candidate attribution qualification or promoted-image acceptance;
the separate native transfer diagnostic and complete candidate qualification
remain pending.

### Partial native candidate execution and fixture diagnostics

**Both native boot attribution checkpoints passed.** The fresh FreeBSD crash
candidate verified current MMDS Git configuration and actual commit attribution.
The five-target graph captured at
`1ab4f04e` terminated at its crash-recovery variant after 712 seconds. Structured
log `1792384835389-3296256-0.jsonl` records
`native current-boot Git attribution verified boot=0` and `boot=1` at events
5978 and 6003. Both boots also completed ordinary execution, live-group
observation, withdrawn-group death and fresh-fence completion, followed by
`native service fenced execution verified` at events 5985 and 6010. These are
scoped native observations from isolated synthetic authority, not a Marshall
admission or live GitHub result.

Event 6011 then reports `external-machine-oracle` failure. No complete crash
receipt or five-variant qualification passed. Nix stopped the graph on this
first failure; the four other in-progress variants have interrupted, unrecorded
outcomes, not four additional native failures. The candidate remains unpromoted
and the exact admitted image pins remain unchanged. The subsequent independent
five-target graph uses keep-going; its outcomes remain pending.

The crash fixture now emits fixed phase names and a bounded decimal UFS fsck
status from 0 through 255. It preserves the same `fsck_ufs -B -f` command and
zero-only success requirement; raw stdout/stderr remain discarded. The original
command wrapper already enforced nonzero failure through `set -eu`. This change
identifies a failed phase without relaxing recovery evidence or diagnosing the
earlier native cause. **8 host crash-boundary tests passed**, with pinned Ruff
format/check and ty (`/tmp/github-native-crash-closed-stage-check.log`). The new
native diagnostic execution remains pending.

Shared default-OSS setup now explicitly starts Audi private services after
observing Ziggy and Galileo ready. This retries a dependency-failed setup start
that a later dependency restart does not recreate. The explicit start has a
900-second bound; the existing Audi readiness wait and production service
dependencies/certificate deadline are unchanged. Pinned Ruff format/check,
contract format and the actual composed driver's ty check passed; the latter
uses Python 3.13.15 and ty 0.0.73 with typed framework-injected globals
(`/tmp/github-composed-driver-ty.log`). Corrected fixture runtime remains pending.
These diagnostic and fixture changes preserve the accepted authority and native
qualification boundaries; they introduce no architectural decision.

### Native qualification checkpoint on 2026-10-19

**The fresh FreeBSD candidate passed all five exact-artifact scenarios.**
Image `sha256:0150b6d1aee0b30892b937eb0566a3dcebf2c5ca4cec75f7a252bd9ae00beac6`
declares manifest v6, source v2 and Git identity v1. Its immutable identities are:

| Artifact | SHA256 |
| --- | --- |
| Raw disk | `db752667ec8b3deaa1fe797d466789339f80f80dc972bb252c1b4b15c2441175` |
| Kernel | `20e38f12f5f7d19de54e3d7f7cf2b3a18e059ba9bccd838f49b1b1ccbc7e3384` |
| Firmware | `261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2` |
| Firecracker | `9815649a9bed84194ca45c5aef4c9307a596c7ffbe1f9f0e881c1ae536226d02` |

Structured graph log `1792386874057-3638536-0.jsonl` records services 621.10 s,
growth 651.03 s, isolation 646.25 s and daemon recovery 634.81 s. The parallel crash
attempt failed at the integrity command before an fsck status was available;
that failure remains recorded. A separate reduced owned-load crash run passed
in 323.20 s, log `1792387617111-3914170-0.jsonl`, output
`/nix/store/x7v7bndpd45m9jixxi4dwq39ilrrj63d-vm-test-run-overalls-freebsd-native-crash-recovery`.
Other VM/build activity remained, so the passing replay does not establish
contention as the earlier failure's cause. The unchanged 20 s SSH bound and
zero-only `fsck_ufs -B -f /dev/gpt/rootfs` integrity requirement remain.

All five service receipts bind the same disk/kernel/firmware/VMM, distinct boot
identities, all 26 exact named checks and the scenario's required endings. Growth
has three boots; other scenarios have two. The checks include current-MMDS
personal-user Git configuration and actual commit attribution on every boot,
workspace ownership and executor withdrawal/cancellation with fresh-fence
completion. Supporting receipts cover the same boots. Every receipt retains
`native_admission=false`. The actual production structural verifier `verify!`
passed all artifact bytes and five evidence sets in
`/tmp/github-freebsd-qualified-review-20261019.pesqsY/verification.log`;
`approval-review.json` SHA256 is
`c94ad916d529205e4496d73025d5d462f52f916eaf82aabf8be7c4bd35691d81`.
This local review has performed no cache publication, registry admission or
catalog activation. It does not establish a Marshall-driven or live GitHub journey.

**The fresh OmniOS candidate passed direct two-boot services and exact payload verification.**
Its image ID is
`sha256:679f5f8bd16c6e0df68602b1fe7f3dfe985647dd94ff1d906e868c637930637e`,
raw disk SHA256
`069571c6f46c029f51cd77500603d6853cea0e9cd14471101b78eb613565ee96` and kernel
SHA256 `c56dc5c19523ef29511e2bfe4b98a6544b786a089b55b654c30ea32e821bdd21`.
Firmware and VMM match the table above. Fresh target-native assembly linked
nine modules from 26 objects and verified 765 installed payload records.
Direct host-KVM execution observed boot IDs
`23e557e5-1506-4fb5-858d-ad6e3995f768` and
`ded6c831-794b-4ad9-8be8-d659ca716546`: both passed all 26 service checks,
current-MMDS Git configuration/commit attribution at epochs 7/8, exact running
kernel/module/static payload verification, disabled vendor automation and
independently observed clean shutdown. Receipt
`/tmp/github-omnios-candidate-20261019.oLpWda/direct-services-receipt.json`
has SHA256 `e238eec7294ede8a88468a59e8576783cade970fab545908de7fb91d59cae936`.
The candidate remains unadmitted. Its separate five-scenario nested-NixOS
qualification is pending at this checkpoint; the earlier graph was explicitly
deferred and interrupted, not recorded as a native failure. Direct services and
assembly cannot stand in for the five-scenario matrix or retained-tool acceptance.

The promotion verifier now preserves the historical 22-check FreeBSD and 25-check
OmniOS sets when Git identity is absent. An explicitly validated integer-v1
capability requires all 25 current baseline checks plus attribution for either
OS. Missing, extra, substituted or duplicated names refuse. Generic manifest
validation plus an explicit native-v6 guard prevents malformed capability values
from bypassing the wrapper; `verify_approved!` separately requires exact registry
admission. The Nix `native-image-promotion` gate passed **23 tests** in 4 s
(`1792387107999-3746948-0.jsonl`), including malformed-capability and
structurally-complete-but-unadmitted candidate refusals. These are host verifier
tests, not additional native executions.

Current closed diagnostics report only fixed command/transport stages, bounded
counts/gauges, exit status and byte counts. No error text, commands, URLs or
credentials are emitted. Transport overlap means a parsed heartbeat or response
while an artifact stream is active; it does not prove a particular worker's lease
renewed. Pinned Ruff/ty and **9 crash-boundary tests** passed
(`/tmp/github-native-closed-command-check.log`); native-control Ruff/ty and
**16 focused tests** passed (`/tmp/github-native-transport-test.log`,
`/tmp/github-native-transport-ty.log`). Generated receipt filters accepted exact
25/26-check sets and refused duplicate, foreign, missing and extra names
(`/tmp/github-native-receipt-consumer-check.log`). Contract formatting passed
(`/tmp/github-native-final-contract-format.log`); that is syntax/discovery
evidence, not semantic or fleet acceptance.

### Preserve immutable admission history before changing native defaults

The current registry derives admitted manifests and portable bundles from only
the selected FreeBSD and OmniOS files. Overwriting either file would revoke the
previous exact identity. [Lilly restart](../../../lilly/lib/lilly/vm/driver.ex)
validates the retained placement bundle and repeats native admission before
launch, while explicitly refusing to consult or recreate a catalog artifact.
Existing guests would therefore lose cold restart and their row-bound capabilities
even with intact disks. [Image registration](../../../marshall/lib/marshall/compute/images.ex)
also requires immutable stored content.

Before activation, preserve old manifests and immutable promotion/cache pins
and add newly qualified identities to a separately maintained admission history;
select the default from that history independently. Keep old staging until
in-flight original provisioning no longer needs its exact `config.images`
entry. Retained restart/relocation use the portable bundle rather than staged
images. Historical machines without a Git snapshot continue omitting Git
metadata; new allocations and clones still require real Git identity capability.
Native pause/resume remains separately unqualified and Linux-only.

This is an unresolved implementation finding under ADR-0190, ADR-0202 and
ADR-0204, not a new product policy. Current-format v6/v3 immutable authorization
records are not an older decoder or compatibility path under ADR-0159. Require
regressions for old/new manifests and bundles, modified-identity refusal,
unchanged old capability absence, capable default selection and catalog-free
retained restart before changing defaults. No history migration or activation
has been performed at this checkpoint.
