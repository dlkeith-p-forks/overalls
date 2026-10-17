# ADR-0168: Dangerous native defaults for guest coding CLIs

- ID: ADR-0168
- Date: 2026-10-14
- Status: accepted
- Implementation: partial
- Components: NixOS guest image, Ubuntu guest image, Codex, Claude Code
- Supersedes: ADR-0167
- Superseded by: none

## Context

ADR-0167 installs Codex and Claude Code with native Ziggy configuration in both
guest images. Its initial client-policy decision retained each tool's approval
and command-sandbox controls. The requested guest image behavior is instead an
explicit dangerous default: these user-run clients must not stop for approval
prompts or apply their own command sandbox. The guest remains bounded by its
existing OS permissions, VM boundary, network policy and Marshall admission.

## Decision

Set the native system configuration in both image families as follows:

- Codex uses `approval_policy = "never"` and
  `sandbox_mode = "danger-full-access"` in `/etc/codex/config.toml`.
- Claude Code uses `permissions.defaultMode = "bypassPermissions"`,
  `sandbox.enabled = false` and
  `skipDangerousModePermissionPrompt = true` in
  `/etc/claude-code/managed-settings.json`.
- Fleet and native guest probes invoke the clients without launch-time sandbox
  or permission overrides, so the image configuration is the exercised policy.

The existing Ziggy URLs, verified CA trust, nonsecret Claude sentinel,
update-disable settings, offline Ubuntu closure and provider refusal behavior
remain unchanged. These settings remove only client-level prompts and command
sandboxing. They do not grant inference authority, alter Marshall admission,
change guest identity, widen network access or create host/VM isolation claims.
ADR-0167's image, Ziggy, Ubuntu closure and provider-boundary decisions remain
in force; this record replaces its client execution-policy clause.

## Alternatives

- Retain approval prompts and client sandboxes: rejected because the requested
  guest image must run the tools in dangerous mode by default.
- Add launch wrappers or flags: rejected because they create a second
  configuration path and would hide whether the image's native settings work.
- Weaken guest, VM, network or Marshall boundaries: rejected; dangerous client
  defaults do not require changing those authority boundaries.

## Consequences

Commands launched by these clients can run with the guest user's existing
  permissions without client confirmation or command sandboxing. A compromised
  process therefore has the same guest-level impact as any other process run by
  that user; host, VM, network and inference authorities remain outside the
  client policy. Users may still override Codex system defaults using native
  settings, while Claude's managed settings retain native managed precedence.

## Open questions

Production Anthropic remains disabled, and these defaults do not establish
provider readiness or host/VM isolation. Retained writable guest disks are not
migrated by this image change.

## Invariants and verification

- Both image evaluations contain the four dangerous-mode settings above.
- Native probes assert the exact values from the generated system files.
- Fleet commands do not pass `--sandbox`, permission or dangerous-mode flags;
  clients start using the image defaults.
- Existing TLS, provider-routing, disabled-Anthropic and Ubuntu closure
  invariants from ADR-0167 remain required.
- No test or documentation claims that client settings establish host or VM
  isolation.

## Implementation evidence

The shared [guest package configuration](../../../nix/domains/artifacts/guest/coding-clis.nix)
generates the Codex and Claude settings for both image builders. The
[native guest probe](../../../nix/verification/tests/machines/zfs-guest/coding_clis.py)
asserts every dangerous-mode key. The [NixOS fleet helper](../../../nix/verification/tests/machines/fleet/coding-clis-guest.exs)
and [fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/coding-clis.py)
run the native commands without launch overrides. Existing image evaluations,
Ziggy route checks and production provider-boundary evidence remain the
implementation evidence carried forward from ADR-0167.

## Related decisions

[ADR-0167](0167-native-guest-coding-clis.md),
[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0094](0094-default-development-environments.md),
[ADR-0063](0063-private-services-and-ziggy.md),
[ADR-0099](0099-marshall-owned-agent-threads.md),
[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md).
