# ADR-0128: Repository launch links and guest-cloned workspaces

- ID: ADR-0128
- Date: 2026-09-28
- Status: superseded
- Implementation: implemented
- Components: Marshall, Lilly, shared protocol, Lyra, NixOS guest, Ubuntu guest, Porsche
- Supersedes: none
- Superseded by: ADR-0157

## Context

[ADR-0157](0157-multi-provider-authenticated-repository-launch.md) replaces the
GitHub-only source schema, anonymous no-resume behavior and image capability
assumptions with multi-provider source2, bounded signed-cookie authentication
resume and explicit manifest4 capability. The original rationale and historical
implementation evidence below retain their original scope.

Developers want a Gitpod-style entry point. A signed-in user who opens
`https://ghuntley.dev/#https://github.com/<owner>/<repo>`, or its `/tree/<branch>`,
`/commit/<sha>` or `/pull/<n>` form, should receive a new OSS-profile machine
that already contains that public repository checked out at the requested ref.
The same workflow is wanted from the terminal as `overalls open <url>`, which also
opens an SSH session into the checkout.

Observed constraints:

- The URL fragment never reaches the server. Only browser code can read it.
- Execution commands are closed v3 maps with exact field counts
  ([ADR-0037](0037-workload-placement-and-relocation.md)). Before this
  decision, no per-VM bootstrap data field existed.
- Per-VM data reaches a guest only through boot-bound Firecracker vsock pushes
  from Lilly ([ADR-0113](0113-guest-trust-at-boot.md)) or guest HTTPS pulls from
  private services. Guests have no cloud-init, MMDS or configuration disk.
- OSS guests already have masqueraded egress through Brady
  ([ADR-0069](0069-brady-egress-cache.md)), and both guest images ship `git`.
- Only public repositories are in scope. No GitHub credential is involved.

The product owner explicitly authorized the design below in the approved plan
of 2026-09-28. That included guest-side code written in Rust rather than Python,
and support in both guest images.

## Decision

**Only the guest clones.** Each component's role is:

| Component | Does | Never does |
| --- | --- | --- |
| Browser link / `overalls open` | Validates the URL and asks Marshall for an OSS VM with the source reference | Runs git |
| Marshall | Stores `{owner, repo, ref_kind, ref}` and pins it in the provision/start command | Contacts GitHub |
| Lilly | Hands the reference to the guest over boot-bound vsock port 1031 | Runs git, touches the guest disk, or waits for the clone |
| Guest `overalls-workspaced` | Receives the reference and runs plain `git clone` over its own egress | — |

1. **Closed source grammar.** `OverallsProtocol.WorkspaceSource` accepts only
   `https://github.com/<owner>/<repo>[.git]` with an optional `/tree/<branch>`,
   `/commit/<7-40 hex>` or `/pull/<n>[/files|/commits|/checks]`.
   - Branches use a conservative ASCII subset of `git check-ref-format`.
   - No owner, repository or ref may start with `-`, so an accepted value can
     never become a git option.
   - Query strings and fragments are discarded. Percent encoding, userinfo,
     ports and other hosts are refused.
   - A 40-hex `/tree/` ref is treated as a commit.
   - The Rust port in Lyra shares one vector file with the Elixir parser.
2. **Browser entry.** `/` redirects signed-in users to `/launch`, and the
   browser carries the fragment across the redirect. A colocated LiveView hook
   reads `location.hash`, keeps a per-visit 128-bit nonce in `sessionStorage`,
   removes the fragment from history and submits `{source, visit}`.
   - Marshall derives the idempotency key as
     `sha256(user | canonical URL | visit)`. Reloads and back navigation reuse
     the VM, and a fresh visit creates a new one.
   - Creation is automatic and always uses the OSS profile, the default image
     and the default shape.
   - Anonymous visitors see sign-in, and nothing resumes after login.
   - Without a fragment, `/launch` navigates to `/overview`.
3. **CLI entry.** Porsche's `new` accepts `--source <url>`. It is refused with
   profiles that do not allow egress and is kept in replay options, so the same
   request id with a different source is an idempotency conflict.
   `overalls open <url> [-- command]` validates locally, calls Porsche
   `new --source … --json`, waits for running, then runs `ssh` into the guest.
   A fixed remote script waits for the guest clone status and changes into
   `/workspace/<repo>`.
4. **Persistence and command.** `Marshall.Compute.WorkspaceSource` is an
   immutable row keyed by VM, written in the admission transaction, and part of
   the idempotency comparison. The command snapshot includes the encoded source
   for `provision` and `start`. Clones of a VM do not inherit it.
5. **Protocol.** Execution commands may carry an optional versioned
   `workspace_source`, only on `provision`/`start`, and only for profiles that
   `ProfilePolicy` allows `:egress`. Older Lilly builds reject the field, so
   **Lilly must be deployed before or together with Marshall**. The fleet
   deploys both from one revision.
6. **Delivery.** After guest trust is installed, Lilly delivers one bounded
   JSON envelope on vsock port 1031. The envelope carries the placement, epoch,
   boot challenge, a fresh nonce and the source. The guest's reply echoes the
   binding and nonce with `accepted` or `conflict`.
   - Delivery runs asynchronously with a bounded retry budget and is journaled
     as `pending → delivering → delivered | failed`.
   - It never delays the VM reaching running, never fences a placement and
     never affects readiness.
7. **Guest clone.** `overalls-workspaced` is a standalone Lyra binary, not a
   `overalls` CLI verb. It runs in both the NixOS and Ubuntu images.
   - It stores the source once (`/var/lib/overalls-workspace/source.json`, mode
     0600), replies, then runs plain `git` with an argument vector (never a
     shell) into `/workspace/.<repo>.partial`, renaming it to `/workspace/<repo>`
     on success.
   - Fetches are shallow: `clone --depth 1` for the default branch and
     branches; a full commit SHA or `pull/<n>/head` is fetched alone with
     `fetch --depth 1` into an empty repository. An abbreviated SHA cannot be
     fetched by name and uses a blobless partial clone (`--filter=blob:none`).
   - A `done` marker prevents re-cloning after reboot or redelivery.
   - `/run/overalls-workspace/status` publishes `waiting|cloning|done|failed` to
     login users.
   - Git trusts the platform CA bundle so that Brady interception works.
   - The unit is not a readiness dependency.
8. **Logging.** Events carry only VM, placement and reason identifiers. URLs,
   owners, repositories and refs never enter diagnostics.

## Alternatives

- **The guest pulls the reference from a Marshall private service.** Rejected
  because the product owner wanted Lilly to hand the reference over as part of
  bootstrap, and because vsock delivery is already boot-bound without a new
  Audi route.
- **Lilly or Marshall clones and injects the files.** Rejected because it would
  put untrusted repository content and GitHub availability on host paths, and
  would need disk mutation.
- **Enrico mirrors.** Rejected because they are admin-registered, unreachable
  from guests, lack smart HTTP and do not track pull-request refs.
- **The existing agent executor runs the clone.** Rejected because of its hard
  20-second command limit, and because it would mix model tooling with
  bootstrap.
- **A new `overalls` CLI verb inside the guest, or a Python receiver.** Rejected
  by the product owner. A standalone Rust binary that runs standard git
  replaces both.
- **A one-click confirmation page.** Rejected in favour of fully automatic,
  deduplicated creation. The drive-by risk is accepted and recorded below.
- **Resuming the fragment after sign-in.** Rejected. Anonymous visitors only
  see sign-in.

## Consequences

- Any web page can navigate a signed-in user to a launch link and create an
  OSS VM on their behalf (drive-by creation). This is accepted.
  - Creation is limited to the OSS profile with the default shape.
  - Admission capacity still applies.
  - Each navigation creates at most one VM per fresh visit.
  - The VM is owned by and visible to the user.
  - No credential or private data is involved.
- The guest reaches `github.com` through Brady. GitHub outages or rate limits
  show up only as `failed` clone status, never as VM failure.
- A rolling upgrade must deploy Lilly first. A newer Marshall talking to an
  older Lilly would have commands rejected.
- Checkouts are world-writable only as described in the implementation
  evidence. Guest login users can edit them directly.

## Invariants and verification

- The parser accepts and refuses the same shared vectors in Elixir and Rust,
  and accepted values never start with `-` or contain shell or traversal
  characters. Verified by StreamData properties
  (`protocol/test/workspace_source_test.exs`) and Hegel properties
  (`lyra/tests/workspace_receiver.rs`).
- Commands carry a source only for egress profiles on provision/start, and
  unknown nested keys are rejected (`protocol/test/workspace_source_test.exs`).
- Visits are deduplicated. The number of VMs equals the number of distinct
  `(source, visit)` pairs, and anonymous or invalid visits create nothing.
  Verified by a model-based LiveView history property.
- Delivery is boot-bound and never gates running (Lilly command-sequence and
  state-machine properties).
- The guest stores at most one source, reports conflict for a different one,
  never re-clones after `done`, and never passes an input-derived git argument
  starting with `-` (Hegel stateful receiver test).
- End to end, in both images: browser links in all four forms, the
  `overalls open` CLI and a reboot without re-clone are exercised by the
  `repository-launch` and `repository-launch-ubuntu-fleet` NixOS machine tests
  against a local fake `github.com`.

## Implementation evidence

Implemented: all components, recorded native NixOS and Ubuntu journeys and
production acceptance. See the
[review](../reviews/2026-09-28-repository-launch.md) for recorded gate results.

- Shared grammar and command field:
  [workspace_source.ex](../../../protocol/lib/overalls_protocol/workspace_source.ex),
  [execution.ex](../../../protocol/lib/overalls_protocol/execution.ex),
  [ssh_command.ex](../../../protocol/lib/overalls_protocol/ssh_command.ex),
  [workspace_source_test.exs](../../../protocol/test/workspace_source_test.exs).
- Marshall persistence, admission, entry and Porsche:
  [WorkspaceSource](../../../marshall/lib/marshall/compute/workspace_source.ex),
  [admission.ex](../../../marshall/lib/marshall/compute/admission.ex),
  [launch_live.ex](../../../marshall/lib/marshall_web/live/launch_live.ex),
  [history property](../../../marshall/test/marshall_web/repository_launch_history_test.exs).
- Lilly delivery and journal:
  [workspace_source.ex](../../../lilly/lib/lilly/vm/workspace_source.ex),
  [journal](../../../lilly/lib/lilly/lifecycle/workspace_source.ex),
  [store metadata](../../../lilly/lib/lilly/control/store.ex),
  [delivery properties](../../../lilly/test/vm/workspace_source_test.exs).
- Guest and CLI:
  [overalls-workspaced](../../../lyra/src/bin/overalls-workspaced.rs),
  [receiver](../../../lyra/src/workspace_receiver.rs),
  [overalls open](../../../lyra/src/open_cli.rs),
  [receiver state machine](../../../lyra/tests/workspace_receiver.rs).
- Native journey: [driver](../../../nix/tests/machines/repository-launch/driver.py);
  recorded passing on NixOS and Ubuntu guests, including shallow checkouts,
  restart without re-clone and the `overalls open` CLI.

The checkout ownership model is a shared workspace: the guest clones as root
and makes `/workspace/REPO` world-writable with `core.sharedRepository=world`
and a system `safe.directory` entry, because every guest login account is
already a sudo-capable Cedar writer.

## Open questions

- Private repositories and non-GitHub hosts are out of scope.
- Brady interception of git smart HTTP to the real `github.com` is verified
  only by the production acceptance run recorded in the review, not in CI.

## Related decisions

- [ADR-0113](0113-guest-trust-at-boot.md) guest trust at boot (vsock
  delivery pattern; port 1030)
- [ADR-0094](0094-default-development-environments.md) default development
  environments
- [ADR-0103](0103-profile-scoped-agent-capabilities.md) profile-scoped
  capabilities
- [ADR-0069](0069-brady-egress-cache.md) Brady egress
- [ADR-0096](0096-lyra-developer-ssh.md) Lyra developer SSH
- [ADR-0101](0101-browser-approved-agent-cli.md) browser-approved agent CLI
- [ADR-0097](0097-enrico-git-mirrors.md) Enrico mirrors (alternative rejected)
- [Repository launch review](../reviews/2026-09-28-repository-launch.md)
