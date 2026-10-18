# ADR-0117: Personal terminals in the machine workspace

- ID: ADR-0117
- Date: 2026-09-25
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, Lyra, terminald, NixOS guest, Ubuntu guest
- Supersedes: ADR-0084, ADR-0115, ADR-0116
- Superseded by: ADR-0125

## Context

[ADR-0125](0125-fresh-guest-identities.md) replaces only the inherited exact
guest-name rule for permanently reserved mailbox names. All workspace, terminal,
roster, authority and guest-materialization requirements below remain in force.

The user approved a terminal-first machine page with separate management tabs,
prominent installation/SSH commands, and automatic terminal opening. The user
also requires browser shells to provision the same personal account and home
as Audi SSH, reusing the account implementation. This authorization includes
implementation, tests, commit and push. The user subsequently authorized immediate
deployment while native testing continued; observed rollout is recorded in the review.

This replaces the machine detail layout inherited by ADR-0116, the terminal
entry/create interaction of ADR-0084, and the profile eligibility of ADR-0115's
roster. All other requirements of those decisions remain, including the Overview
usage removal, terminal transport/consent, and physically verified boot binding.

## Decision

The machine root opens Terminal. Terminal, Agents, Resources, Access and Settings
are addressable tabs; existing terminals, threads and resize routes remain valid.
A shared header displays state, size, authorized power actions, and authorized
installation/SSH commands with clipboard feedback on every tab. Settings holds
relocation, clone and deletion. Relocation explains the development fleet's
1 Gbit/s link and the expected improvement on AWS in production.

A writable running machine automatically opens a personal terminal after a
successful empty session listing. Accessible sessions are reused. A stopped
machine requires an explicit Start action. A small UI state machine distinguishes
waiting, opening, ready, closed and failed states. Database opening receipts
provide one deterministic request per actor, guest account incarnation, VM,
placement, execution epoch and boot generation across nodes, reloads and reconnects.
The authorized VM projection exposes an opaque execution reference for UI state resets,
preserving the privacy of internal placement IDs. Closing or
exiting a shell cannot cause automatic recreation; New starts an explicit request.
Viewers may attach permitted sessions but cannot create personal accounts/shells.

Marshall's GuestAccounts remains the only allocator of email-derived guest names
and never-reused UIDs. Browser creation resolves the authenticated stored account
under current Cedar write authority, ignoring client guest usernames. It requires
no SSH key because the browser has an independently authenticated login.

Before passwd lookup and PTY creation, configured terminald calls the packaged
`overalls-ssh-authorize ensure <username>` helper with a bounded deadline and no
shell interpolation. The helper requires the account in a fresh verified private
roster and invokes the same reconciliation as SSH. One exclusive root-owned lock
serializes timer, stdin and on-demand state/account mutation. The reconciler owns
`/home/<username>`, UID, permissions, sudo and retirement rules. terminald uses
passwd to select credentials, HOME and working directory. Missing authority or
failed reconciliation fails closed, without selecting a fallback user.

The authenticated host's existing explicit root PTY operations remain available
for administration and native fixtures. Browser creation never selects that path.
Inception receives personal account rosters under the same boot proof, without
enabling its standard Audi SSH key/login endpoints. No host wire protocol or database
schema changes are required. Existing guest disks need the updated helper and
daemon to gain on-demand provisioning; new images package both together.

## Alternatives

Duplicating useradd, username derivation or home paths in terminald would diverge
from SSH account retirement and UID allocation. Waiting for the periodic sync
cannot guarantee a missing account exists before a shell opens. Using root or a
client-selected account would not meet the personal identity requirement.
Browser-local request IDs alone cannot deduplicate across reloads or Marshall nodes.

## Consequences

Opening a new personal shell depends on current roster availability. Existing
PTYs survive navigation and reconnection. Account names and terminal parameters
remain outside opening persistence: the ledger retains their digest. Existing
byte transport, clipboard consent, sharing and ticket authority remain unchanged.
Authorized writers retain passwordless sudo; home directories are not an
isolation boundary between writers, as already established by ADR-0110.

## Invariants and verification

- Viewer/revoked access cannot create a personal shell or choose another user.
- Retries produce one registry and guest shell; closure is durable across reload.
- A missing account is created before PTY spawn, with the SSH UID and home.
- Failed roster validation/materialization never falls back to root.
- Inception roster access keeps all physical boot and operation checks.
- Stopped machines remain stopped until the user requests Start.
- Each management tab and connection panel remains responsive and authorized.

## Implementation evidence

The [startup recovery review](../reviews/2026-09-25-terminal-startup-recovery.md)
records preparation/reconnection notices, late-reply resilience and generated
retry histories. It preserves the existing automatic-opening lifecycle.

[Personal terminal authority](../../../marshall/lib/marshall/terminal/authority.ex)
reuses [GuestAccounts](../../../marshall/lib/marshall/accounts/guest_accounts.ex)
and the existing opening ledger. The
[opening state machine](../../../marshall/lib/marshall_web/terminal_opening.ex)
and [LiveView](../../../marshall/lib/marshall_web/live/terminal_live.ex) implement
workspace transitions. The
[guest helper](../../../lyra/src/bin/overalls-ssh-authorize.rs),
[PTY daemon](../../../nix/domains/artifacts/terminald/src/session.rs), and
[NixOS](../../../nix/domains/artifacts/guest/default.nix)/
[Ubuntu](../../../nix/domains/artifacts/guest/ubuntu/units/lilly-terminals.service) wiring
share account reconciliation.

[Property tests](../../../marshall/test/marshall_web/terminal_opening_test.exs)
exercise transition invariants. [Authority tests](../../../marshall/test/marshall/terminal/personal_session_test.exs)
exercise identity reuse, retries, exit and revocation. The
[native browser scenario](../../../nix/verification/tests/machines/fleet/browser.py) tests missing
account restoration and passwd/home identity on a real guest. Execution results
and remaining rollout/native scope are recorded in the
[review](../reviews/2026-09-25-personal-terminal-workspace.md).

The [terminal verification follow-up](../reviews/2026-09-25-terminal-workspace-verification.md)
repairs delayed ticket delivery that could reopen an inactive browser pane. The
[typed delivery boundary](../../../marshall/assets/js/terminals/tickets.js) checks
current selection/connection and validates external reply shape. Mounted-hook
regressions pass. The same review records a profiled xterm accessibility layout
bottleneck and a reproducible vendor correction that batches row writes and width
measurements while retaining selection geometry and announcement scheduling.
Complete NixOS and Ubuntu terminal journeys on base `3f679eff`, captured tree
`e710ef1e`, passed fifty shells, all 10,000 sixel images, accessible completion and
mixed-width selection, retained-shell replay, machine-loss recovery, sharing,
writer refusal and grant/login revocation. The linked review records exact
artifacts and timing; existing guest-disk migration remains separate.

The shared header decided above is implemented by
[`machine_header/1`](../../../marshall/lib/marshall_web/components/workspace_components.ex):
a bordered heading box with the name, state label and an operating-system label
(the immutable image's registered display name, projected as `image_name` by
[`Marshall.Compute.Views`](../../../marshall/lib/marshall/compute/views.ex)),
the resource facts, the machine ID with a one-line Copy control, the authorized
power actions, and the installation/SSH connect box with clipboard feedback on
every tab. [Machines LiveView tests](../../../marshall/test/marshall_web/machines_live_test.exs)
pin the header ids, the Ubuntu label on the detail, Settings, Machines and
Overview pages, and the retained installer/SSH commands;
[views tests](../../../marshall/test/marshall/compute/views_image_name_test.exs)
prove the projection exposes only the display name. The
[browser probe](../../../marshall/scripts/monospace_browser_probe.py) exercises
the heading box, the machine-ID copy and the installer copy in both themes and
at phone width against synthetic machines; it is presentation evidence, not
guest execution evidence.

## Open questions

The host release was deployed on both fleet hosts. Migration of existing guest
disks remains unverified; host activation does not update their installed binaries.

## Related decisions

[ADR-0084](0084-browser-terminal-workspace.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0115](0115-ssh-roster-boot-authority.md),
[ADR-0116](0116-overview-without-usage-summary.md).
