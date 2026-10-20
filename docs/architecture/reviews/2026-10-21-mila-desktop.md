# Mila desktop clients and Susan WNS architecture review

Scope: [ADR-0235](../decisions/0235-mila-desktop-clients.md) (Mila on macOS and
Windows, dev and release targets for every platform) and
[ADR-0236](../decisions/0236-susan-wns-provider.md) (Susan's WNS provider). This
covers commit `cd597def` and the follow-up change that adds the Windows runner,
WNS deployment wiring, CI and these records.

Boundaries reviewed:

- **Identity and custody.** Device keys stay per deployment and non-exportable
  wherever the platform offers that.
  - Signed macOS builds use the Secure Enclave.
  - Windows uses CNG: the TPM provider first, then the software key storage
    provider. Per the user's decision, a missing TPM is not refused, and an
    existing key is reopened from the provider that holds it.
  - Unsigned macOS dev builds use owner-only software keys under
    `MILA_SOFTWARE_KEYS`. A release build that carries the define throws at
    startup, and the release planner never sets it.
  - Marshall does not learn the custody kind (ADR-0235 open question).
- **Authorization and protocol.** `device register --platform` accepts exactly
  `ios`, `android`, `macos` and `windows` in the protocol, in Marshall and in
  `mila_core`'s command catalog, while `linux` is refused. The column is `text`
  with no check constraint, so no migration is needed. Older Mila builds never
  send the new values; a new Mila build against an older Marshall gets a
  refused registration, which Mila shows as a refusal.
- **Transport and egress.** Susan's egress is no longer a finite list of
  origins: WNS channel hosts vary per device and are bounded by the
  `.notify.windows.com` suffix, which Microsoft controls. The URI is sealed in
  the push key at issuance and re-checked before every send, so a poke cannot
  redirect Susan. Mila applies the same shape before it contacts Susan. Entra
  tokens come from a compiled origin, with the tenant UUID as the only
  configured path segment.
- **Storage.** On Windows, owner-only means a protected DACL granting only the
  current user and SYSTEM. A file with inheritance, extra entries or a foreign
  owner entry is refused, not repaired. POSIX hosts keep 0700/0600.
- **Secrets and deployment.** WNS secrets are expected only when
  `services.susan.wnsAppIds` is non-empty. Salopettes does not set it, so the
  deployed bundle and Susan's runtime configuration are unchanged.
- **Build and release.**
  - Release plans refuse demo mode, software keys, another host's target and
    any missing signing input, and they verify signatures as the final step.
  - Secrets reach tools only through the environment.
  - Windows builds run outside Nix from a Linux-built source bundle that copies
    the patched dartssh2, which preserves ADR-0227.

Findings:

1. **Medium, accepted risk: egress bounded by a DNS suffix.** Egress is now
   bounded by a DNS suffix instead of an origin list (ADR-0236 consequence). If
   an attacker controlled a `*.notify.windows.com` host, they would receive
   ciphertext only, because pokes stay end-to-end encrypted. No change
   recommended.
2. **Medium, open: no Windows evidence yet.** The Windows native runner has not
   been compiled or run in this change; the evidence is the CI `windows` job
   once it runs. Until then ADR-0235 stays `partial`.
3. **Low, open: config tests are Linux-only.** Susan's configuration-loading
   tests read `/proc/self`, so on macOS they cannot pass. They need a Linux run
   for the WNS configuration path.
4. **Low, open: WNS machine tests not run.** The `susan-service` and
   `susan-secrets` machine tests now cover WNS, but they were not run because
   no x86_64-linux builder was available.

Decision status: ADR-0235 and ADR-0236 are `accepted`, implementation
`partial`. ADR-0224 is amended (egress and third parties), not superseded.

## Validation

Run on aarch64-darwin:

- Dart: `mila_core` 144 passed; `mila_transport` 56 passed (including the WNS
  channel property and Windows registration tests); app 55 non-golden tests;
  `mila/tool` planner tests.
- Swift: the macOS and iOS-simulator `RunnerTests`, including `PushPokeTests`.
- macOS: `mila-build macos dev` built and launched sandboxed.
- Protocol: `ssh_command_test`.
- Marshall: device and contract tests.
- Susan: 68/72 tests and Dialyzer clean. The four failures are the
  `/proc/self` Linux-only cases.
- HLDD and ADRs: `check_hldd`, `hldd_views --check`, `hldd_coverage --check`
  and `check_adrs`.

Not run here: the Linux Nix builds, the NixOS machine tests, `hldd_options`,
anything on Windows, and the signed release paths.

## Follow-up

- Run the `mila-builds` workflow and record the `windows` and `macos` job
  results against ADR-0235.
- Register the Entra application for the MSIX identity, add the WNS secrets,
  set `wnsAppIds`, and run `susan-service` on Linux.
- Decide whether Marshall should display device custody.
