# ADR-0157: Multi-provider repository launch and authentication resume

- ID: ADR-0157
- Date: 2026-10-10
- Status: accepted
- Implementation: implemented
- Components: Marshall, Lilly, protocol, Lyra, NixOS guest, Ubuntu guest, Porsche
- Supersedes: ADR-0128
- Superseded by: none

## Context

The user requested porting Weaver's browser launcher into Overalls, selected all
four providers, and authorized resuming creation after sign-in, including a magic
link opened in another browser tab. Source identity needs nested GitLab namespaces,
named references and provider-specific change heads. The user explicitly requested
one current schema without legacy readers or compatibility paths.

[ADR-0128](0128-repository-launch-links.md) accepted GitHub-only sources and
explicitly refused authentication resume. Those choices are materially replaced;
its guest-only cloning, current boot fencing, shared checkout, admission
transaction and readiness independence remain required. Historical acceptance
under ADR-0128 does not establish these new source or authentication paths.

## Decision

Use source protocol 2 in Elixir and Rust: a closed provider enum (`github`,
`gitlab`, `codeberg`, `bitbucket`), nonempty namespace component list, repository
name and tagged revision (`default`, `ref`, `tag`, `commit`, `change`). The current
wire object has exactly `version`, `provider`, `namespace`, `repository` and
`revision`. A default revision contains only `kind`; other revisions contain
exactly `kind` and `value`. Change numbers are positive bounded integers.
Bitbucket has no distinct tag route; its `/src/NAME` route resolves advertised
branches or tags.

Accept only exact public HTTPS provider origins and reviewed routes; bound source
URLs to 1024 bytes. Discard queries/fragments before interpretation. Reject
credentials, explicit ports, percent escapes, traversal, unsupported routes and
option-shaped source components. Preserve named path suffixes in immutable
identity; the guest resolves the longest advertised matching branch/tag and uses
a branch on an equal-name tie, including hexadecimal names. When no advertised
reference matches a `tree`/`src` path, a 7–64-hex first component selects a commit
and ignores a following file path. Explicit commit routes remain commit identities. GitHub
and GitLab change heads use their dedicated remote refs. Codeberg and Bitbucket
change heads use a bounded provider API response, no HTTP redirects, validated
same-provider HTTPS clone origin and full commit ID. Only the guest contacts Git
providers; Marshall and Lilly retain an inert source identity.

Advertised-ref capture has a thirty-second deadline and a 1 MiB stdout limit;
overflow or timeout cancels the owned git process group before joining its reader.
Malformed or oversized listings refuse, rather than permitting commit fallback.
Keep checkout object format internal: advertised refs/full object IDs select
SHA1 or SHA256; mixed-format listings refuse. Fetch-only checkout initializes
the matching format, while abbreviated commits use a negotiated clone. This
supports accepted 64-hex sources without adding a wire or stored identity field.

Public `/launch/entry` captures the fragment and submits source plus a random
128-bit visit nonce to CSRF-protected `POST /launch/pending`. It removes the
fragment from history and removes source queries/fragments before browser storage
or submission. URL user information refuses without storage/POST. The capture
minimizer preserves raw authority/path so explicit ports, literal traversal and
percent escapes still reach the strict backend parser unchanged for refusal.
The existing signed session cookie stores only canonical
source, nonce and a server-issued thirty-minute expiry. A tab can retain its
capture nonce in sessionStorage; authentication handoff uses the cookie shared
between tabs. No localStorage bridge, database pending object, credential or
user-selected return path is introduced.

Pending input establishes no identity or authority. A valid pending launch wins
the ordinary post-sign-in destination, survives a same-browser magic-link tab,
and returns through required MFA to `/launch`. Expired or malformed input creates
nothing. The connected LaunchLive mount uses the current stored login, completed
MFA and ordinary Compute admission. Provision an OSS machine with durable image
minimum sizes; derive the idempotency key from actor, canonical source and visit.
The existing drive-by creation tradeoff is retained: a navigation may trigger one
default OSS machine per distinct authorized visit, subject to capacity admission.

After admission commits, sign a completion receipt binding actor, VM, source and
visit. Browser code submits it through CSRF-protected `POST /launch/pending/clear`.
The controller verifies a fresh completed login and current owner/read authority,
clears only a matching pending capture and redirects to that same-origin machine.
A newer capture must survive an older completion. The cookie contains one pending
intent; concurrent HTTP responses have ordinary singleton-cookie ordering and do
not provide a multi-tab queue.

Image manifest 4 is the sole current decoder. Its ordered content identity binds
all artifacts/minima, required nullable `workspace_source_version` and the optional
editor descriptor. Source protocol capability is `2` only when the guest receiver
service is enabled at boot, otherwise null. New admission requires the manifest
to match its catalog ID; a source-bearing request additionally requires capability
2. Every new source-bearing provision/start command snapshot repeats the guard
against the durable image record, including a retained start; disabled current
images remain usable for retained workload identity. Initial Lilly start repeats
that capability/identity guard before host effects.
Explicitly supplied command snapshots, including resize restarts, derive their
source from the durable VM record after command-authority validation, including
the retained immutable image. Caller source data cannot source an unsourced VM,
replace its recorded reference or select a different executable image.
Crash recovery and confirmed resize coordinators check the same durable image
eligibility before restart intent. An unavailable source capability refuses the
restart without discarding valid physical evidence or the next host report.
Confirmed stopped compute is released; disk and address remain retained. A
confirmed resize completes with `workspace_source_unavailable`, retaining its
target sizes and allowing ordinary cleanup instead of an impossible retry loop.
Retained restart/adoption uses the existing portable boot bundle without consulting
or recreating staged images. This preserves retained workload custody.

Perform a one-time source-row migration to the new provider/revision fields.
Disable obsolete image catalog entries. Do not relabel old manifests, rewrite
immutable command snapshots, receiver records or lifecycle journals, or interpret
source-v1 documents as v2. Existing sourced guests whose retained source is obsolete
require recreation on a current image; old reader deployment is unsupported.
The database cutover is irreversible through migrations; rollback requires its
pre-cutover backup and matching application revision.
That source-schema rollback does not reconcile newer retained guest identities:
[ADR-0158](0158-durable-guest-identities.md) independently requires permanent
GuestAccount UUID/UID reservations and sequence reconciliation before a historical
database can serve alongside newer retained disks. Source-capability eligibility
for an unsourced retained start does not waive that identity-cutover boundary.

Persist the source in the admission transaction, pin it only in provision/start
commands, and never inherit it for a clone. Lilly keeps asynchronous, boot-bound
vsock delivery on port 1031 outside running/readiness/fencing. The independent
delivery envelope remains version 1; its nested source is strictly version 2.
The guest stores one source and runs plain git argument vectors into the shared
`/workspace/REPOSITORY` checkout. Provider/API failures affect checkout status only.
Source URLs, namespace, revisions, tokens and receipt bodies never enter diagnostics.

[ADR-0240](0240-account-machine-creation-presets.md) amends only the fixed OSS/default-size launch clause above. New launches use the account launch preset, initially OSS; admitted visits reuse their original persisted admission request before repeating ordinary admission. Source, login, completion and guest authority boundaries remain unchanged.

## Alternatives

- A source-v1 adapter or relabeled old image would obscure actual receiver support
  and violate the explicit current-schema requirement.
- A localStorage cross-tab bridge would expose an additional persistence and race
  surface; the existing signed cookie already supplies bounded shared input.
- Server-side clone or provider lookup would move untrusted repository work into
  control/host authority and make provider availability a provisioning dependency.
- An arbitrary authentication return URL would let untrusted input choose a
  destination. Resume uses only fixed `/launch` and security paths.
- Updating retained snapshots or boot bundles in place would erase historical
  identity and conflict with immutable workload custody.

## Consequences

All four providers share one source representation and admission boundary.
Current guest images have new content IDs. Fleet image selection and application
rollout must be coordinated; installed packages alone do not establish capability.
Named references resolve at checkout time and do not promise immutable upstream
content. Shared checkouts remain writable by the guest's sudo-capable writers.
Unsigned launcher packages and their public distribution are decided separately
by [ADR-0156](0156-browser-launcher-distribution.md).

## Invariants and verification

- Elixir/Rust shared vectors and properties cover canonical source/wire round
  trips, closed fields, provider routes and hostile references.
- Capture removes source queries/fragments before sessionStorage or submission,
  refuses URL user information and preserves hostile raw authority/path for backend
  refusal. Staging changes no domain rows, bounds the signed cookie and expires by
  server time. Required MFA and revoked login refuse before admission.
- Generated browser histories admit one VM per actor/source/visit; failed clears
  preserve input, and old receipts cannot clear a newer capture.
- Source-bearing admission, new command snapshots and initial Lilly start reject
  absent, obsolete or mismatched image capability before committed allocations,
  dispatch or host effects. Unsourced retained starts do not inspect image capability.
- Delivery binds the current boot; source conflicts and uncertain replies never
  authorize another source or change physical readiness.
- Both real guest families must prove ordinary refs and provider changes, sign-in
  resume across tabs, required MFA and retained reboot without re-clone in isolated
  NixOS machine tests. The incoming frozen browser-feature NixOS family passed all twenty provider/revision
  combinations and its complete journey; the complete current Ubuntu family remains
  pending.

## Implementation evidence

[Elixir source codec](../../../protocol/lib/overalls_protocol/workspace_source.ex),
[Rust source codec](../../../lyra/src/workspace_source.rs) and
[checkout resolver](../../../lyra/src/workspace_checkout.rs) implement source2.
[Source resource](../../../marshall/lib/marshall/compute/workspace_source.ex) and
[cutover migration](../../../marshall/priv/repo/migrations/20261010000100_workspace_source_v2.exs)
implement durable storage without snapshot rewriting. On the host the source
rides only on `provision`/`start` commands and never enters persisted dataset
identities; claim, snapshot-source and adoption checks compare
[Spec.storage/1](../../../lilly/lib/lilly/vm/spec.ex), the spec with the
source cleared, after a production clone prune was refused for a restarted
source carrying one (ADR-0162 decision 7).
[PendingLaunch](../../../marshall/lib/marshall_web/pending_launch.ex),
[HTTP capture/clear](../../../marshall/lib/marshall_web/controllers/repository_launch_controller.ex),
[LaunchLive](../../../marshall/lib/marshall_web/live/launch_live.ex) and
[capture hook](../../../marshall/assets/js/repository_launch.js) implement bounded
authentication resume and successful-admission clear.

[Manifest4](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[admission](../../../marshall/lib/marshall/compute/admission.ex),
[Lilly start](../../../lilly/lib/lilly/vm/driver.ex) and both
[NixOS](../../../nix/domains/artifacts/guest/default.nix)/[Ubuntu](../../../nix/domains/artifacts/guest/ubuntu/default.nix)
builders implement explicit source capability. Focused component and declaration
checks are recorded in the [current review](../reviews/2026-10-10-browser-launcher.md).
The complete current NixOS multi-provider/MFA/cross-tab/retention/download/CLI
journey passed; the complete current Ubuntu family remains pending, so
implementation status is partial. Live provider and production acceptance remain
separate validation gaps.
These are incoming browser-feature captures before ADR-0158 integration; they
do not establish the latest combined source2/generated-identity component or
native source. The durable review retains separate original-feature and
`d4499c4c` integration captures.

## Open questions

Private repository credentials, arbitrary/self-hosted origins and a pending
multi-tab queue are outside this decision. Coordinated production cutover and
native verification of current guest/provider journeys remain required.

## Related decisions

[ADR-0128](0128-repository-launch-links.md),
[ADR-0158](0158-durable-guest-identities.md),
[ADR-0156](0156-browser-launcher-distribution.md),
[ADR-0113](0113-guest-trust-at-boot.md),
[ADR-0123](0123-remembered-browser-authority.md),
[ADR-0131](0131-automatic-magic-link-sign-in.md),
[ADR-0130](0130-verified-provisioning-fastpath.md),
[ADR-0153](0153-official-source-browser-editor.md).
