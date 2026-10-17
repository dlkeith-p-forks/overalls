# ADR-0096: Lyra developer SSH client

- ID: ADR-0096
- Date: 2026-09-23
- Status: superseded
- Implementation: partial
- Components: Lyra, Marshall Web, Audi, NixOS guest, Ubuntu guest
- Supersedes: none
- Superseded by: ADR-0110

## Context

ADR-0093 provides authenticated guest SSH through Audi, but each downloaded
OpenSSH profile names one VM and is cumbersome for a developer with many VMs.
The user authorized a Rust client named Lyra, installed as `overalls`, with a
wildcard SSH profile, a curl-to-bash connection option, automatic updates and
short lived structured diagnostics. It must be built for Linux and macOS from
one Linux Nix expression and included in both standard guest images.

## Decision

Marshall serves four immutable CLI artifacts and their SHA-256 digests over
its configured HTTPS origin. Its authenticated machine view offers a setup and
connect command, and a plain SSH command. The public installer verifies the
download against the digest and installs the user-owned CLI. Setup adds one
managed `Host *.zone` block to the user's OpenSSH config after checking that
OpenSSH rejects metacharacters in hostnames.

Lyra's ProxyCommand accepts only canonical VM labels in the configured zone.
It obtains the current Audi gateway key from Marshall over verified HTTPS and
uses a strict, isolated outer SSH invocation. The guest SSH client still owns
its normal host-key policy. Audi remains the live authorization boundary.
The client never receives or records the inner SSH command or terminal bytes.

Each user-owned CLI invocation outside a managed guest starts an asynchronous update check. The check verifies the
artifact digest and stages it, while a later invocation atomically activates
it. A `overalls update` verb reports background operation and `update status`
reports state. Diagnostics are JSON lines with a closed event vocabulary and
numeric metadata only, rotating by day and size with a seven-day maximum.

The accepted plan authorizes this decision. The implementation uses the
Marshall operator origin and zone directly; no Porsche protocol change is
needed to establish a local SSH profile.

## Alternatives

Per-VM downloaded OpenSSH profiles remain available for legacy and Inception
access but require repeated local configuration. A Go client conflicts with
the requested Rust toolchain. A direct guest network route would bypass Audi
authorization. An in-band update check would delay SSH startup.

## Consequences

The public binary and checksum endpoints add bandwidth demand to Marshall.
An update can be staged on one invocation and activated only on the next.
If a fresh public installer copy replaces the managed binary between staging
and activation, the stale candidate is discarded instead of replacing it.
Existing user SSH configuration may take precedence over the appended wildcard
block; setup must not rewrite unrelated entries. Inception's nested route
still uses its dedicated profile until Lyra implements that distinct chain.

## Invariants and verification

- The installer and updater must verify the selected binary digest before
  execution or staging.
- Hostname validation and strict outer key lookup must fail closed.
- Diagnostics must exclude credentials, arguments, environment and SSH bytes.
- Update checking must not delay an interactive SSH session.
- Nix must produce all four binaries in one Linux derivation, and both guest
  images must contain the Linux CLI.
- A Porsche-created VM must be reached through the installed wildcard profile
  after fleet deployment.

## Implementation evidence

The legacy per-VM download and its server-side renderer were
[retired on 2026-09-25](../reviews/2026-09-25-ssh-config-download-retirement.md). The installer, local wildcard setup
and host-key discovery remain. References above to available downloaded profiles
describe the earlier implementation; nested client support remains outside Lyra.

The [client](../../../lyra/src/main.rs), [Nix derivation](../../../nix/domains/artifacts/infrastructure/lyra.nix),
[public routes](../../../marshall/lib/marshall_web/router.ex),
[delivery controller](../../../marshall/lib/marshall_web/controllers/overalls_controller.ex),
and [machine view](../../../marshall/lib/marshall_web/live/machines_live.ex)
implement the first integration. Hegel properties cover input validation in
[config.rs](../../../lyra/src/config.rs) and run in the pinned Nix Lyra check.
The [desktop updater](../../../lyra/src/update.rs) rejects a staged binary
whose recorded base digest differs from the newly installed CLI.
The current public installer, manifest, four artifacts and checksum routes use
`/bin/` on Marshall; the [route and delivery review](../reviews/2026-09-25-public-cli-bin-routes.md)
records the URL change and its compatibility effect.
The single Linux derivation built all four executable formats, both standard
guest images and the Marshall release built, and Marshall precommit passed.
The [live acceptance](../reviews/2026-09-23-lyra-developer-ssh.md) installed
the public Linux artifact and wildcard profile, opened a root shell through
Audi to a retained Porsche-created NixOS VM, and strictly reconnected. A
separate strict connection to a retained Ubuntu VM passed. A newly created VM
and native macOS execution remain before this decision can be marked
implemented.

## Open questions

None for the initial standard guest SSH route. Nested Inception SSH is a later
extension requiring its own strict chain and verification.

## Related decisions

[ADR-0047](0047-audi-ingress-and-authoritative-dns.md),
[ADR-0093](0093-audi-mediated-guest-ssh.md),
[ADR-0094](0094-default-development-environments.md), and
[ADR-0104](0104-private-guest-cli-updates.md) for the guest-specific updater.
