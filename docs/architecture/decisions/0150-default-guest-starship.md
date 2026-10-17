# ADR-0150: Default Starship prompts in guest images

- ID: ADR-0150
- Date: 2026-10-10
- Status: accepted
- Implementation: implemented
- Components: NixOS guest image, Ubuntu guest image, Lyra guest account reconciliation
- Supersedes: none
- Superseded by: none

## Context

The user wants to evaluate Starship as the default interactive prompt for all
users in both Firecracker guest distributions. Installing a command alone does
not activate it in a shell. Personal accounts are created after boot from a
fresh private roster, and the reconciler previously selected `/bin/sh` on both
creation and refresh. Browser terminals and SSH must receive the same prompt
through their existing shared account materialization path.

The user approved the implementation plan on 2026-10-09, including a new worktree,
verification, commit, merge to main and push. The plan applies to rebuilt guest
images and does not authorize migration or deployment of existing writable disks.

## Decision

New NixOS and Ubuntu guest images MUST install Starship and initialize its stock
prompt globally for interactive Bash login and non-login shells with the native
NixOS module's `TERM=dumb` exception below. Bash MUST be the default interactive
shell for root and ordinary accounts, including accounts
created after boot. Derived NixOS guests, including Inception, inherit these
image defaults. Service accounts keep their non-login shell policies.

NixOS uses the pinned NixOS `programs.starship` module with interactive-only
initialization. Preserve its native behavior: NixOS skips prompt initialization
when `TERM=dumb`; ordinary browser and SSH terminals advertise a capable terminal
and receive Starship. Ubuntu initializes interactive Bash, including `TERM=dumb`,
through its guarded initializer. Ubuntu installs Bash and Starship from the
existing signed Ubuntu snapshot lock, sets the `useradd` default to Bash and sources one guarded
initializer through its global Bash and login startup files. Repeated sourcing
MUST initialize once per shell, while a nested interactive Bash initializes its
own hooks. Noninteractive commands MUST retain exact output without prompt noise.

The existing roster reconciler MUST select executable
`/run/current-system/sw/bin/bash` on NixOS or `/bin/bash` on Ubuntu before account
mutation and assign it on creation and every active-account refresh. A missing
or non-executable selected Bash fails reconciliation without distribution or
shell fallback. Retired-account login refusal, UID allocation, home ownership,
mode-0700 homes and passwordless sudo remain governed by the existing decisions.

Use Starship's standard appearance and per-user configuration. Do not overwrite
user dotfiles or force a custom prompt theme. The reconciler continues to own
managed account shells; manually changing a managed account shell is reverted
by its next successful refresh. No API, roster schema, host wire protocol,
credential, listener or authorization change is introduced.

## Alternatives

A package-only installation does not provide the requested default prompt.
Per-home startup-file edits miss newly materialized accounts and can overwrite
user customization. Choosing a Nix store hash as a managed NixOS shell would
bind writable passwd entries to one image generation rather than its stable
system path. Keeping `/bin/sh` as the managed shell cannot activate the global
Bash integration consistently across Ubuntu and NixOS.

An upstream installer or first-boot download would bypass the pinned image inputs
and fail on restricted guests. The native Ubuntu snapshot package preserves
ADR-0068's archive boundary without adding another Nixpkgs application exception.

## Consequences

Image closures and immutable rootfs identities change; image-derived minimum disk
sizing continues to apply. Existing writable guest disks retain their installed
shells and startup configuration until a separately authorized replacement or
migration. Starship evaluates the user's current directory and configuration as
the ordinary shell user; it adds no privileged service or new authority.

Prompt formatting is variable, so native fixture readiness must use explicit
command completion markers rather than matching the historical root prompt.
Users may customize Starship through their normal configuration and startup
files. Guest account refresh still restores the reviewed Bash shell policy.

## Invariants and verification

- Image evaluation requires Starship installation, Bash defaults and global
  interactive initialization in both distributions.
- Real Firecracker guests with a capable terminal prove root login and nested
  interactive Bash hooks; NixOS retains its native `TERM=dumb` skip.
  Ordinary manual accounts inherit the image shell defaults.
- Actual personal SSH and browser shells prove Starship hooks, the allocated
  username and unchanged home, including after repeated reconciliation and reboot.
- Noninteractive SSH commands retain exact stdout; startup does not print prompts
  into command output. Repeated global sourcing preserves one initialization.
- Missing executable Bash refuses reconciliation before account or state mutation.
- Existing current-roster, certified SSH, terminal fencing, retired-account and
  home-preservation tests remain authoritative for their existing boundaries.

## Implementation evidence

The [NixOS configuration](../../../nix/packages/guest/configuration.nix) enables
the native Starship module and interactive Bash defaults. The
[Ubuntu builder](../../../nix/packages/guest/ubuntu/default.nix),
[required package set](../../../nix/packages/guest/ubuntu/required-packages.json)
and [initializer](../../../nix/packages/guest/ubuntu/starship.sh) package and
activate the distribution's locked Starship command without home-file edits.
The [managed account helper](../../../lyra/src/bin/overalls-ssh-authorize.rs)
selects an executable distribution-specific Bash and applies it on both
creation and refresh; source-local tests cover selection and refusal.

[Image evaluation](../../../nix/tests/evaluation/guest-toolset.nix) checks NixOS
installation and prompt initialization, while
[Ubuntu evaluation](../../../nix/tests/evaluation/ubuntu-guest.nix) checks its
required inputs and startup wiring. The
[shared native guest probe](../../../nix/tests/machines/zfs-guest/probe.exs)
checks root and manually created users in both images, including nested shells
and exact noninteractive output. The
[personal SSH journey](../../../nix/tests/machines/fleet/scenarios/user-ssh-journey.py)
checks real PTY hooks through repeated refresh, relocation and reboot, and invokes
[the browser prompt probe](../../../nix/tests/machines/fleet/browser.py) on its
newly provisioned guest. Before integration with independent observability at
`a2d9e6e` (feature `63214e60` on base `1cd8be40`), both complete root machine suites
and both serial personal SSH/browser journeys passed: root/manual-account prompts
and checked fixture cleanup, managed-account startup and refresh, relocation and
reboot. The historical NixOS managed journey captured the strict direct-refresh
fixture; Ubuntu's final historical journey captured bounded successful service
completions. The production image/account code is unchanged between those managed
fixture versions and across integration.

Both managed journeys passed again on the merged `63214e60`/`a2d9e6e` candidate,
with two successful bounded real roster-service refreshes, actual SSH and HTTPS
browser Starship hooks, nested shells, exact noninteractive output, relocation
and reboot. Their native driver times were 890.30 seconds for NixOS and 909.18
seconds for Ubuntu. The integrated full Lyra check (including Clippy), image
evaluations and all-files static hooks also passed. The root/manual-account
suites, Marshall's full precommit with zero Dialyzer errors and evaluated Nix
handbook result retain their explicitly historical scope.
The prompt capability is implemented. The
[review](../reviews/2026-10-10-guest-starship.md) records exact artifacts and earlier
failed attempts. Scenario coverage remains partial because generated reconciliation histories
and native custom-configuration rendering are absent;
existing disks and deployment remain outside this change.

The review keeps pre-integration artifacts separate from the two merged managed
journeys and the integrated component/evaluation/static gates. Historical
root/manual-user suites do not establish a merged root-suite rerun or acceptance
of the independent diagnostic cutover. Renumbering this record preserves the
independent accepted ADR-0149 and its supersession rationale.

## Open questions

None. Production deployment and migration of existing guest disks are outside
this change.

## Related decisions

[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0094](0094-default-development-environments.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md),
[ADR-0125](0125-fresh-guest-identities.md),
[ADR-0149](0149-independent-observability.md).
