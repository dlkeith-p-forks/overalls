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
three fixed integration diagnostics use reviewed English fallback: managed
authentication, unsupported destination and mutation redirect refusal. This
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

## Remaining acceptance

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
