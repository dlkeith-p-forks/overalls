# Lyra developer SSH review — 2026-09-23

## Scope and architecture impact

This change adds a user-owned Rust SSH helper, a wildcard OpenSSH profile,
public immutable binary delivery from Marshall and guest-image inclusion.
It changes client installation and delivery but leaves Audi as the live SSH
authorization boundary, Marshall as route/key authority and guest sshd as the
inner authentication and host-key boundary. ADR-0096 records the new client
decision; ADR-0094 records Lyra as a second explicit Ubuntu non-archive guest
application. ADR-0047 and ADR-0093 retain their accepted rationale and server
boundaries.

## Findings and resolutions

| Severity | Evidence and failure consequence | Resolution |
| --- | --- | --- |
| High | A fixed Cargo version would cause changed binaries to be treated as current. | Update identity compares the manifest's verified SHA-256 with the managed binary and staged digest. |
| High | Concurrent background checks could stage conflicting artifacts or race with activation. | One nonblocking update lock now covers download, digest verification, staging and status; startup only activates when it can acquire that lock. |
| High | A wildcard block after an existing `Host *` block could lose OpenSSH's first-value precedence. | Lyra places its managed block first and preserves the remaining config; the integration test resolves the effective OpenSSH configuration. |
| High | Unrestricted diagnostic strings could disclose SSH command-line secrets. | The client log API accepts only a closed event enum and optional integer. The proxy inherits SSH streams without inspecting them. A synthetic canary test checks persistent files. |
| Medium | Predictable setup temporary files could be redirected by local symlinks. | Setup uses private same-directory temporary files and atomic rename; symlinked SSH config is rejected. |

## Validation and limits

Rust clippy, unit tests, Hegel input properties and the persistent-log canary
test pass both locally and in `checks.x86_64-linux.lyra`. One Linux Nix
derivation produced two static ELF and two Mach-O executables; `file`
confirmed each target format. The final NixOS and Ubuntu guest image builds
passed, with the Linux CLI in the NixOS system closure and the Ubuntu offline
rootfs builder. The Marshall release build, focused installer tests, full
Marshall precommit gate (including forced Dialyzer), ADR structure and code
contract checks all passed.

Live acceptance on 2026-09-23 used the published
`https://overalls.dev/overalls/install.sh` script against the retained
`guest-ssh-nixos-0922` VM. The installer fetched the Linux AMD64 artifact,
verified its SHA-256 against the live manifest, installed the wildcard SSH
profile, and opened an interactive root shell through Lyra and Audi. The guest
ED25519 fingerprint matched the previously pinned
`SHA256:01ZCMBaSBJr+n4Me5BihcjEdkmgnfox5dltiWIFyGLc` before first
acceptance. A separate strict `ssh root@<VM-hostname>` reconnect returned
`root`. A strict noninteractive Lyra connection to the retained Ubuntu VM also
returned `root`, using its previously pinned guest key. Both VMs were reported
running by Porsche, and Marshall's current route lookup returned HTTP 200 for
their labels. Two retired Lyra test labels returned HTTP 404 and the CLI refused
their proxy connections; stale local host keys did not authorize a route.

This proves live installer delivery and standard NixOS and Ubuntu SSH routing
for retained Porsche-created guests. A fresh VM created after the Lyra rollout
and execution of the macOS artifacts on physical macOS remain acceptance work.

## Follow-up

Record fresh-VM and native macOS acceptance before marking ADR-0096 implemented.
Retain the existing Inception-specific profile until its nested SSH route is
implemented and verified separately.
