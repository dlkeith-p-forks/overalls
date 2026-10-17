# Exact native image admission (2026-10-17)

## Scope and architectural impact

This review covers activation of the exact reviewed FreeBSD 14.3 image through
the protocol capability authority, Marshall admission, Lilly launch and a
separate immutable Nix promotion constructor. The explicit instruction to enable
admission authorizes per-image activation under
[ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md). That
decision remains accepted with partial implementation. Its original requirement
for kernel provenance, complete service closure and scoped native evidence is
preserved; an OS name or candidate manifest still grants no capability.

There is no new Ash domain, persistence format, protocol wire identity or deployed
host/service role. The reviewed authority changes from an unavailable native
implementation to one approved immutable image. The unqualified `freebsd-v1`
and `illumos-v1` capability rows remain false. Complete image-qualified identity
is required, and editor and Inception remain false. OmniOS remains closed while
its exact service matrix is incomplete. This activation does not claim physical
isolation, power-loss durability, reproducible native full-disk assembly or
Marshall-driven fleet acceptance.

## Exact artifact and authority

| Identity | Reviewed value |
| --- | --- |
| Image ID | `sha256:d141e4266c29da00a1378157b1d39369b1d48e577bca4ce7375e8ff6d399557b` |
| Raw disk SHA-256 | `5022d714b94032253bc44b706b37426f8a247debd155fbe223fde28000228f55` |
| Kernel SHA-256 | `5d6ea5f9ba4caa0c30dc048eac56af2c6cfa4d9121fde6a859113373e736784f` |
| Firmware SHA-256 | `261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2` |
| Firecracker SHA-256 | `5dc9a44417e758c94fd70cb78113bd55f04f3d9170307215a9ff2e88aabd6c90` |
| Sealed candidate NAR hash | `sha256-jnULElxnAk9yzcohR6SPgdr8AprHiv1Oa9OTU6Va06E=` |

The [reviewed manifest](../../../protocol/priv/native/freebsd-14.3.json) is
compiled into the pure
[native registry](../../../protocol/lib/overalls_protocol/native_admission.ex).
There is no runtime file lookup. After ordinary versioned validation, admission
requires the complete normalized native image or portable boot descriptor to
equal the approved identity. The descriptor's image ID binds the published
manifest; matching only a kernel, agent set, row ID or OS does not suffice.

[GuestAgents](../../../protocol/lib/overalls_protocol/guest_agents.ex) preserves
the existing all-false native `capabilities/1` rows and adds qualified
`capabilities/2`. The approved FreeBSD image enables readiness, trust, workspace,
terminal, flush, SSH and agents. Editor and Inception remain false. Linux and
Windows retain their existing behavior. Callers must supply validated complete
identity; they cannot substitute a capability name or a detached catalog ID.

Marshall checks the normalized manifest against the durable image row ID and
refuses unapproved native requests before address or host allocation. Existing
stock native rows remain readable for diagnostics, with capabilities false.
Lilly independently refuses an unapproved native identity before a new launch;
neither a Marshall request nor a portable descriptor bypasses that boundary.
After launch, the existing boot-bound kernel attestation, host CID 2 / guest
CID 3 transport, placement/epoch/challenge fences, trust and readiness checks
remain required. Exact artifact approval is not current-boot readiness.

## Promotion and cache custody

The [promotion constructor](../../../nix/domains/artifacts/guest/native-promotion/default.nix)
and [verifier](../../../nix/domains/artifacts/guest/native-promotion/verify.ex)
are separate from the candidate builders. Version-1 approval binds the complete
manifest/image ID, actual disk and firmware sizes/hashes, the reviewed VMM,
hash-bound native assembly receipt and exactly five scenario sets: services,
growth, isolation, daemon recovery and crash recovery. Each service receipt
must cover the same artifacts, distinct boot IDs and all 22 service checks.
Growth requires three clean boots; ordinary two-boot scenarios require clean
exits; crash recovery requires observed SIGKILL followed by a clean boot.
Supporting evidence must name those same boots. Missing, altered, foreign,
replayed or incomplete evidence refuses publication.

The [FreeBSD approval](../../../nix/domains/artifacts/guest/native-promotion/freebsd.nix)
uses the sealed source
`/nix/store/qr4n7d7f8iwv3pial7glygy2y8jk3fdi-overalls-native-freebsd-14-3-5022d714`.
It contains the disk, regular dereferenced firmware and public evidence. Pinned
recursive fixed-output derivation binds its NAR hash and uses the existing signed
Overalls Cachix substitution policy. Its fallback builder only refuses with publication
instructions; it never reads a temporary path, disables signature checks or
reconstructs a stock image. No token or signing key enters evaluation or the
guest. Public availability, trusted signature and exact fetched contents need
their own publication record, separately from artifact verification.

Promotion writes `manifest.json` only after verification and publishes exactly
`disk.raw`, `firmware` and that manifest. Evidence, installation media and debug
hooks stay outside the launchable directory. Candidate and historical machine
receipts retain `native_admission=false`; the separate approval and runtime
registry establish the new authority without rewriting those past results.

The current source's local interface-MAC normalization rebuilds a different
FreeBSD userland candidate, including changed executable bytes. That candidate
remains unadmitted. Production promotion continues to consume the sealed reviewed
`5022d714` closure; no byte-identical-current-rebuild claim is made.

The realized production output is
`/nix/store/gshb3mlah1wfl7kx8xr1div8dxih0837-lilly-freebsd-14_3-x86_64-promoted`.
It contains exactly the 6,477,687,296-byte disk, 4,194,304-byte firmware and
831-byte manifest. Its recursive NAR hash is
`sha256-wcEv0jqRuJRZHRuTDi1IRQQhvQ+2NVOxVoHLFMaDl5Q=` with no store references.

The [bootstrap correction](../../../lyra/src/native_bootstrap.rs) accepts exactly
six local `ifconfig` octets containing one or two ASCII hexadecimal digits and
normalizes them before equality with MMDS. External metadata remains strict;
foreign identity and malformed local output refuse. The pinned Rust tests,
Clippy, native/Windows type checks and new OmniOS kit build passed at
`/tmp/overalls-native-bootstrap-fixed-build.log`. Kit `sis8` subsequently passed
fresh native nine-module/764-payload assembly, all three SMF validations,
read-only receipt extraction, clean export and administration shutdown. Its
sealed 8-GiB disk SHA is
`1e095659319faae2a2e7a8af6172fba056f02f4ac5e0c3b5a0f57cc570b99a60`;
assembly receipt SHA is
`f6d9f0be3bb8170c3d2b78aa31babb28f3a7e2070de68198df8d475fd90152d4`.
The test-only artifact is `/tmp/overalls-omnios-native-bootstrap-fixed-artifact`.
It retains false runtime/admission flags. Complete service replay remains
pending; assembly cannot establish daemon execution or readiness.

The structural service audit confirmed growth/bootstrap ordering, supervised
probe/trust listeners before roster/certificate bootstrap and readiness's
complete live-service predicate. Direct `sis8` diagnostics subsequently passed
MMDS/network configuration, current-boot kernel identity, trust and one native
executor command, but complete readiness failed. The native supervisor used
`/usr/lib/ssh/sshd`, which is absent in the pinned OmniOS root; its configuration
check returned 127 after roster and host-certificate requests succeeded.
All three SMF services were online and the base listeners had PID markers, but
SSH and its refresh/ready markers were absent. Correcting the executable path
requires a new kit and fresh native assembly; these partial diagnostics do not
establish terminal/SSH acceptance or the complete service/growth/recovery matrix.

A live stock administration boot confirmed `/usr/sbin/sshd`, root-owned mode
0755, and the stock `/lib/svc/method/sshd` executes that exact path; the evidence
is `/tmp/overalls-omnios-native-probe/admin-ssh-path-confirmation.log`. The
[supervisor](../../../nix/domains/artifacts/guest/native-agents.nix) now uses
`/usr/sbin/sshd` on both native targets. OmniOS
[assembly and booted verification](../../../nix/domains/artifacts/guest/native-kernels/illumos/native_image.py)
also require that path to be a bounded, root-owned regular executable ELF and
refuse links, missing files, unsafe modes or invalid bytes. The new
`native_ssh_executable_checked` receipt records this file check only; it cannot
establish valid SSH configuration, a running daemon or readiness.

The native executable then exposed an OmniOS parser incompatibility: explicit
`UsePAM yes` returns 255 because this downstream always enables PAM and rejects
the remaining option argument. The generated config now emits that directive
only for FreeBSD. Removing only that directive from the `sis8` config passed
both native `sshd -t` and `sshd -T`, each exit 0, with temporary synthetic
volatile host-key/certificate prerequisites. Effective configuration retained
`usepam yes`, disabled password and keyboard-interactive authentication,
required public-key authentication and certified Ed25519 host keys, and kept
the original authorization helper, account and forced command. The synthetic
keys/certificate were removed. Evidence is
`/tmp/overalls-omnios-native-probe/admin-ssh-synthetic-config-test.log` and
`/tmp/overalls-omnios-native-probe/public/probe_native_sshd_config.py`.
This native configuration check starts no daemon and grants no SSH-session or
complete readiness claim.

The shared native command path also bypassed the executor's existing lease
callback while running a command. The corrected
[native runner](../../../lyra/src/agent/native_command.rs) now invokes that
callback before spawn and on each polling turn, kills its process group and
reaps the child on refusal, and returns no retained output. A scoped collector
enforces the child deadline independently of a blocking lease RPC. The callback
checks stop state immediately and renews at five-second intervals. This preserves
[ADR-0100](../decisions/0100-pulled-agent-work-over-ziggy-control.md)'s existing
fencing requirement. It changes current userland bytes; neither the `sis8`
assembly nor the sealed admitted FreeBSD closure proves this new native
lease-withdrawal path. Fresh kit/image replay remains required.

The corrected scoped collector passed all six local real-process command tests:
bounded simultaneous output, deadline kill, inherited pipes after shell exit,
pre-spawn refusal, running cancellation/reaping without returned output, and a
blocked lease callback that cannot extend the child deadline. The complete
pinned Lyra test, Linux/native Clippy, Windows/native type and native executable
link gates passed together in 193 seconds at
`/tmp/overalls-native-command-lease-final-gates.log`; exact test results are
`/tmp/overalls-native-command-lease-test-results.log`, with test output
`/nix/store/zs30gbkpjhj2cci7pbb50ds0pi609dx4-lyra-tests-0.1.0`.
This validates local process cancellation and typed packaging, not native
lease withdrawal. That kit predates the separate SSH-path correction.

The final replacement kit
`/nix/store/wz4rkmvzima04zdgql3z6x90ha09l260-overalls-omnios-native-image-candidate-kit`
includes the collector, corrected native SSH path and OmniOS PAM config. Its
build passed in 26 seconds at
`/tmp/overalls-native-omnios-ssh-path-kit-final.log`. Fresh native assembly
passed with nine linked modules, 764 exact payload records, all three actual
SMF validations, the safe SSH executable check, five stock service disables
and four stock network removals. GUID-only read-only receipt extraction and
export passed. Only administration pool `9985174500187493668` remained imported,
both private workspaces were absent, filesystem synchronization completed and
QEMU exited 0 after `init 5`.

| Final OmniOS assembly identity | Value |
| --- | --- |
| Read-only test artifact | `/tmp/overalls-omnios-native-ssh-config-final-artifact` |
| Raw bytes / SHA256 | 8,589,934,592 / `e7fc0c04bccb4b443dd4bea2edcdabfa2d1481fee6b683891f4338b399625a41` |
| Assembly receipt bytes / SHA256 | 158,319 / `512a112f910a3ce65c5f3f791a91aecbdcc20c8e428af6f9f9702ee904320180` |
| Kit manifest SHA256 | `6db105276ba24eebc5fe87b3e961ee9dc01e18243db2c1c493bbe897420a2d73` |
| Test-only manifest SHA256 | `4cf5828573cdc1d77d4ff2ab8136217ba616e935287ddf81c759aae8c2231fd2` |
| Installed SSH config SHA256 | `276c98c072f6907ce3d669306969422c44ccc3cc3a16e0dbcccfe77bbd7d2904` |
| Transport build ID | `76b8c1ad4ba2e25f87768bbf8a1c55ed0f8d1b9fb973f776799c0b68eda98809` |

The disk and receipts are read-only; runtime checks must clone the baseline.
Assembly, extraction, export-state and shutdown logs are respectively
`admin-ssh-config-final-assembly.log`, `admin-ssh-config-final-receipt.log`,
`admin-ssh-config-final-export-state.log` and
`admin-ssh-config-final-shutdown.log` under
`/tmp/overalls-omnios-native-probe/`. The assembly receipt retains
`runtime_validated=false` and `native_admission=false`; the test-only manifest
also retains `native_services_validated=false`. Complete native boot/service,
lease withdrawal, growth, transport/reset, isolation and recovery replay remain
pending for this disk. Its successful assembly and the separate synthetic SSH
config proof grant no runtime capability or production v6 manifest authority.

The trunk integration also adds `protocol/priv` to the application release
[source allowlist](../../../nix/domains/artifacts/applications/source.nix),
so the compile-time exact native registry input ships alongside Protocol's
library and Mix files. This fixes release input closure under the existing
ADR-0190 decision; a fresh application release build remains pending.

## Validation and remaining gaps

The [native kernel review](2026-10-17-native-kernel-attestation.md) records all
five passing exact-image native scenarios. Their scope remains the same after
promotion: complete native service oracles, mounted-root growth, the packaged
IPv4/router/TAP policy against a Linux sibling sink, same-boot daemon recovery
and same-disk process-SIGKILL recovery. Ordinary transport and reset test images
have different disk hashes and retain their separate evidence. Wrong-CID
injection, reset/DMA stress, direct native peer-VM/TAP isolation, physical host
or power loss, relocation and fleet acceptance remain gaps.

The final focused Marshall suite passed 33 checks (5 properties and 28 tests),
recorded at `/tmp/overalls-native-admission-marshall-focused-final.log`. It
executed all eight sourced/unsourced unapproved-native refusals with unchanged
allocation inventory, exact reviewed admission through ordinary capacity and
readiness accounting, and row-bound capability projection with altered or
corrupt manifest refusal. The source review confirmed the native identity gate
precedes source-version checking and host/address allocation.

The focused Lilly source/launch suite passed 18 checks. At clean revision
`589ff7fe5`, complete Marshall `mix precommit` passed 1,690 checks (244 properties
and 1,446 tests), four exclusions, all 24 Covenant obligations, terminal and
workspace JavaScript/TypeScript, Monospace and forced Dialyzer with zero errors
or skips. Complete Lilly passed 610 checks (115 properties and 495 tests),
Covenant and forced Dialyzer with zero errors or skips. Their records are
`/tmp/overalls-native-integration-marshall-precommit-589ff7fe5-final.log` and
`/tmp/overalls-native-lilly-589ff7fe5-precommit.log`. Later production or test
changes retain their own pending checks. Protocol Hegel/native engine execution
retains a separate result. A host
verifier or SQL fixture can establish exact-identity refusal and
absence of allocation effects; it cannot establish native isolation or a
Marshall-driven guest journey. The scenario ledger keeps this activation
partial until the missing preferred machine/property coverage is recorded.

The final production FreeBSD package, `native-image-promotion` 12-test gate and
`native-os-guest-unit` gate passed together in 18 seconds at
`/tmp/overalls-native-promoted-freebsd-build.log`. Isolated verifier Dialyzer
passed without warnings at `/tmp/overalls-native-promotion-dialyzer-final.log`.
The publication check verified the public remote NAR and trusted signature,
then substituted into a fresh store and verified its complete NAR contents and
signature. This establishes immutable signed publication and host-side artifact
verification, not a new guest or fleet runtime result. The final local boot-log
browser fixture also passed desktop/mobile, both themes, grid, contrast,
origin-only resources and polling/disconnect/hide/destroy lifecycle, recorded in
the [host diagnostic review](2026-10-17-host-boot-log-authorization.md). It does
not establish a complete pending/failed native guest journey.

The source review must inspect every native capability consumer and each fresh
launch boundary. Code-contract syntax and discovery checks remain separate from
that semantic review. Final governance receipts are recorded after the source
and handbook freeze; generated inventories establish no new domain or deployed
role from this change.
