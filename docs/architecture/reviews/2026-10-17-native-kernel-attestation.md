# Native kernel provenance and attestation review (2026-10-17)

## Scope

This review covers ADR-0190, the replacement for ADR-0180 that adds native FreeBSD and
illumos kernel provenance, a jail-local kernel probe, native agent daemon
packaging and Lilly's pre-credential kernel-attestation check. It inspects the
current `native-kernels` Nix inputs, version-6 manifests and version-3 bundles,
the Protocol and Lilly validators, Lyra's native daemons, and the focused tests.
The review uses the existing multi-OS image review for the earlier catalog and
firmware decisions; it does not convert structural evidence into boot evidence.

## Architecture impact

The change is architectural. Kernel bytes are now part of the native image
identity and a guest response is required before credentials or readiness. This
replaces ADR-0180's advertised native capabilities with unavailable rows and
kernel-provenance gates, while preserving ADR-0113's
boot-bound trust model. The native daemons remain guest-local processes; they do
not create a new host service or Ash domain. No deployment topology or domain
ownership changes.

[ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md) is accepted
under the custom native-kernel plan. It preserves the foreign Linux and native
metadata choices; [ADR-0180](../decisions/0180-multi-os-guest-image-contract.md)
retains the superseded rationale and historical evidence.

## Findings

### 1. Provenance is explicit and admission remains fail-closed — resolved with an implementation gap

Version-6 manifests and version-3 bundles carry a positive kernel byte count,
SHA-256 digest, full source revision, patch hash, configuration hash and
compiler identity. Protocol validation rejects incomplete or malformed
descriptors. `native-kernels/default.nix` pins FreeBSD, illumos and OmniOS
source inputs and emits a reviewable source receipt, but marks
`artifact.available = false` and uses a placeholder digest. The FreeBSD and
OmniOS image builders test the receipt before unpacking their disks, so a stock
kernel cannot be silently advertised as native support.

Evidence: `nix/domains/artifacts/guest/native-kernels/default.nix`,
`nix/domains/artifacts/guest/native.nix`,
`protocol/lib/overalls_protocol/image_manifest.ex`,
`protocol/lib/overalls_protocol/workload_bundle.ex` and their focused tests.

### 2. Kernel attestation is bound to the current execution — scoped FreeBSD evidence, final acceptance pending

Lilly's driver reads the validated native bundle and opens a bounded exchange over
the jail-local `/v.sock` to the fixed probe port. It compares OS, placement,
execution epoch, boot challenge and kernel digest before credentials and the
ordinary readiness exchange. Lyra's probe now binds its listener and reads the
read-only AF_VSOCK/VSOCK_SO_BUILD_ID option: exactly 64 hex build-input bytes plus
NUL. It compares that executing transport token to a bounded, root-owned,
non-symlink `/etc/overalls/kernel-build-id`, and separately checks the configured
kernel file digest before answering. FreeBSD compiles the token into its static
kernel; illumos requires the socket and transport modules to carry matching
tokens. Short buffers, writes, mismatches, fenced sockets and unavailable
transport refuse. The token identifies compiled inputs, while the file hash
identifies bytes; neither substitutes for native evidence that the intended
kernel/module set booted. Host response framing remains unchanged.
Malformed, stale, absent and oversized responses remain refusal/retry evidence.
Lilly also requires the subsequent readiness response to use the kernel
response's boot ID, preventing the two exchanges from naming different boots.
The tests exercise framing and mismatch handling through local sockets only.
The getter and root-owned expected-token checks have source/type/unit evidence;
the separate scoped FreeBSD candidate service record below also exercises the
current-boot kernel path. No final complete native-service acceptance record
exists for both OS families. A later scoped OmniOS diagnostic Firecracker run
passed the loaded token, complete installed-file verification and host-CID
transport below; final reproducible-image and complete-service acceptance
remain separate.

Evidence: `protocol/lib/overalls_protocol/kernel_attestation.ex`,
`lilly/lib/lilly/vm/kernel_attestation.ex`,
`lilly/lib/lilly/vm/driver.ex`, `lyra/src/guest/kernel_probe.rs`,
`protocol/test/kernel_attestation_test.exs` and
`lilly/test/vm/kernel_attestation_test.exs`.

### 3. Native userland linkage exists; complete runtime closure remains open

The recorded native Lyra package built nine production binaries for each target,
eighteen in all, including root-only MMDS/network bootstrap. That complete
Linux/Windows/native test and native Clippy build passed in 297 seconds at
`/nix/store/qkd598npifssp6sl47b705hwx049nhhs-lyra-native-0.1.0` and
`/nix/store/zwbw4iwdsv0fpmm1ig4ppmwqqaw5ihw0-lyra-tests-0.1.0`.
Two transport probes are separate test outputs, outside the production closure.
ELF checks identify AMD64 FreeBSD and Solaris binaries, their native interpreters
(`/libexec/ld-elf.so.1`, `/usr/lib/amd64/ld.so.1`), non-executable stacks and no
Nix runtime references, Linux shared libraries or RPATHs. The machine-readable
manifest binds lockfile/toolchain/sysroot inputs and each binary's bytes/digest.

The [official SDK](../../../nix/domains/artifacts/guest/illumos_sdk/README.md)
uses seven exact r151050 IPS package manifests, verifies compressed/plain
payload hashes and bounds, and records the assembled sysroot hash. The pinned
Clang 21.1.8 Solaris linker-path patch and GNU binutils 2.46 support userland
linkage; they do not replace Solaris `ld -ztype=kmod`. Four bounded extractor
checks, a real C link/interpreter check and invalid-linker refusal passed.
The credential-free fixed-output acquisition disables TLS verification only for
the archived official endpoint whose certificate chain failed; recorded content
hashes preserve exact byte integrity separately from transport authentication.
This exception changes no runtime TLS policy.

The [native Git runtimes](../../../nix/domains/artifacts/guest/native_git/README.md)
pin FreeBSD Git-lite 2.49.0's complete retained `release_3` dependency graph and
OmniOS Git 2.44.3's exact IPS manifests, native HTTPS helpers, templates, trust
and 64-bit library closure. Sixteen extraction/IPS/ELF-path refusal checks
passed. Optional OmniOS Perl and shell frontends are excluded. Static ELF
resolution follows declared runpaths rather than basename matches. Both payloads
retain `runtime_verified:false`; FreeBSD's separate candidate boot executes Git
and verifies installed bytes/trust, while DNS/TLS and an actual HTTPS clone
remain native integration requirements.

FreeBSD rc.d and illumos SMF supervision remain distinct guest-local services.
The actual account adapter uses FreeBSD `pw`, `/usr/local/bin/bash` and managed
sudoers, while illumos uses native `useradd`/`usermod`, `/bin/bash`, `passwd -N`
and `/export/home`. Each native SSH helper invocation validates fresh MMDS.
Host keys, locks, sshd PID and the SSH-ready marker live in volatile
`/var/run/overalls`. A separate `/etc/overalls/sshd_config` refuses root/password
login and forces the current-authorization session helper. Stock sshd is disabled.
The supervisor refreshes roster/certificates every two seconds and removes
readiness on failure; all nine supervised PID markers plus a fresh SSH-ready
marker are required. The native package build checks these paths and dialects
statically. A disposable OmniOS QEMU clone then exercised the production
`ssh_platform` module and matching safe home-parent preparation. Probe v7
(SHA-256 `ef88642d340a7c023972eef3ee9f3c51cd9a7510b6573c95766a90844de37fb2`)
passed create, retire and reactivate for synthetic UID/GID995007: exact identity,
home ownership and Bash, unusable password authentication, clear active expiry,
the local account lock/noninteractive retired shell, and retained home bytes.
Native execution exposed two actual utility differences: stock `/export/home`
was absent, and illumos password locking deliberately skips an existing
non-password account. The adapter prepares the safe parent, prohibits implicit
per-user ZFS datasets, uses local `passmgmt` for atomic lock/shell retirement,
and explicitly selects the files repository for non-password activation.
The transcript is
`/tmp/overalls-omnios-native-probe/native-account-probe-v7.log`. This is account
dialect evidence; the complete MMDS-bound helper, SSH authentication and canonical
image remain separate.
The supervisor starts the six listeners before bounded SSH bootstrap retries,
and withholds the live sshd PID marker until trust/roster/certificate bootstrap
succeeds. The native readiness contract now separates listener binding from
authority: every request requires current boot identity, while ready responses
add network, writable storage and the complete live service set. Host-only trust
may precede SSH HTTPS dependencies; a bound listener grants no readiness or user
authority. This reconciles the earlier overly broad process-start wording with
the reviewed dependency order without permitting stale authority. Linked binaries and supervision files do not prove target filesystem,
trust roots, SSH/service ordering or a runnable native image. Both native terminal daemons now cross-link at
`/nix/store/5g1qqj9qjmgglhvq5yrpyym184z59kdq-lilly-terminald-native-0.1.0`.
They retain the shared boot-bound terminal/session engine, MMDS client and
native Unix PTY adapters. Their exact interpreters, shared libraries, hashes and
non-executable stacks are checked. The stock OmniOS native PTY probe passed
controlling-terminal verification, shell execution, resize to 101 columns by
41 rows and inherited descriptor closure after the illumos adapter stopped
issuing unsupported TIOCSCTTY and verified `tcgetsid` after opening the STREAMS
slave. Its SHA-256 is
`c6116128aed81c246e5efee04135373347497abdf1403303f7f86c3fa72c77fc`.
This establishes the isolated native PTY adapter scope; the complete terminal
protocol and boot-bound terminal journey remain unverified. All capability rows
are false.
The terminal Linux gate passed Clippy and all 55 tests at
`/nix/store/fdakfav1fdyzy8x8yf56dq3s9dmdp4xd-lilly-terminald-native-checks-0.1.0`
in 47 seconds. Its earlier parallel generated-history run failed a 30-second
generator-health limit under competing finite PTY/process workloads. Top-level
histories now run serially while each history retains its internal concurrent
sessions/workers. This is Linux terminal-core evidence; both native links and
Windows/FreeBSD/illumos production checks remain distinct from native PTY/session
execution and host-CID transport.

The earlier sixteen-binary linkage, 201-second eighteen-binary build and Rust type-check results remain historical;
the recorded eighteen-binary build includes the network bootstrap changes. That
bootstrap validates MMDSv2 identity, actual MAC/profile/slot/gateway, interface
bound routes and IPv6 refusal before publishing volatile root-only identity.
Its refusal tests and native compilation do not establish actual service startup.

The [FreeBSD candidate assembler](../../../nix/domains/artifacts/guest/freebsd/candidate.nix)
completed a separate 94-second two-boot QEMU build at
`/nix/store/996qyplkcwq0rcpi79yyn6jy3cpvadf0-overalls-freebsd-native-image-candidate`.
That recorded candidate predates the final accepted-child/SSH payload changes.
It installs the recipe-bound kernel, full FHS service/bootstrap/Git roots and
checks exact installed bytes, trust, actual Git version, sysctl token and kernel
digest before clean shutdown. A later scoped nested-KVM service run used that
historical image and production VMM
`f91yr04h84d7xsaxxbmhlj5vg4ymw6wv` and passed in 197 seconds. Its eight checks
cover MMDSv2 bootstrap/current-boot kernel identity, assigned-address reachability,
withheld readiness without SSH authority, trust installation/stale refusal,
flush/refusals, workspace refusals, terminal HELLO/PING/refusals and a final
current-boot kernel recheck. The recorded receipt is
`/nix/store/q7bjpk90fcib8x0031ikvsm11jcd765l-vm-test-run-overalls-freebsd-native-services/service-receipt.json`;
the execution log is `/tmp/overalls-native-services-debug-v4.log`.
This predates the final kernel/account payload and establishes no checkout,
SSH, agent execution, PTY, isolation or recovery acceptance.
The later exact twenty-binary build passed in 217 seconds at
`/nix/store/z830h6dmm5zfy0szs9lzcj9mn7px4s2v-lyra-native-0.1.0`, together with
Linux tests/Clippy, Windows checks, both native checks/Clippy and terminal
properties/Clippy. Its SSH original-command path uses Bash `-c` after current
login authority; interactive sessions retain the login shell. The actual final
FreeBSD candidate at
`/nix/store/f3babakkd86pfbzb7kcmh258x62qnbqm-overalls-freebsd-native-image-candidate`
then passed first-boot kernel/readiness, managed SSH identity/sudo, foreign
authority and login-receipt refusals/restoration, private HTTPS workspace
checkout with actual commit bytes, managed PTY input/resize/replay and fenced
execution. It subsequently reached clean shutdown, emitted filesystem sync,
and remained running because pinned CloudHv firmware's poweroff write to 0x600
was unhandled by the VMM. Record:
`/tmp/overalls-native-aligned-ssh-services.log`. This is scoped actual first-boot
evidence; no final two-boot complete-service receipt exists. Later execution
with the repaired VMM observed the first clean exit 0, then the second boot
exposed cumulative trust roots: the adapter had reused the managed destination
as its vendor base. The correction installs a separate recipe-pinned regular
vendor snapshot at `/etc/overalls/system-ca.pem` for both OS families, while
preserving each standard effective trust path. Current-boot validation precedes
writes; exact staged bytes and durable link publication preserve idempotent
replacement. Real-filesystem regressions cover new-boot reinstallation,
addition/removal/rollback, conflicting staged bytes, missing bases and stale
authority. The later vendor-base and final reviewed runs below passed the
corrected two-boot boundary. This restores
ADR-0113's existing replacement semantics; it does not authorize accumulated
platform roots or native admission.

The corrected vendor-base candidate then passed the complete FreeBSD services
and daemon-recovery machine variants through two clean boots each. Both bind
image SHA256 `1e4f21f48098418588df0d6c4cded1af05f5c788f856637c8a660d86dd9b5ed0`,
kernel SHA256 `5d6ea5f9ba4caa0c30dc048eac56af2c6cfa4d9121fde6a859113373e736784f`,
firmware SHA256 `261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2`
and VMM SHA256 `5dc9a44417e758c94fd70cb78113bd55f04f3d9170307215a9ff2e88aabd6c90`.
Services checked actual certified SSH/account/sudo/refusals, current-boot trust,
native private-HTTPS checkout and exact bytes, managed PTY input/resize/replay,
fenced execution, rotated host keys, retained home bytes and old-boot refusal.
Both boot IDs differed and both endings were clean. Receipts are
`/nix/store/mxsw76xfznpp0nsbipprjafv0945lbsq-vm-test-run-overalls-freebsd-native-services/service-receipt.json`
and
`/nix/store/5cp6ai62glx5sfcdvy7a493gd3l0mm2x-vm-test-run-overalls-freebsd-native-recovery/service-receipt.json`.
These exact inputs predate the final canonical trust-root ordering and `UseDNS no`
changes. Their scoped results do not establish later-image acceptance, OmniOS
services, growth, policy isolation, abrupt-crash recovery or native admission.

The final reviewed FreeBSD image subsequently passed all five native machine
variants with image SHA256
`5022d714b94032253bc44b706b37426f8a247debd155fbe223fde28000228f55`.
It includes canonical trust-root ordering, `UseDNS no` and the blocking UFS
suspend/resume flush correction. Kernel, firmware and VMM hashes remain the
exact values above. Services, growth, isolation and daemon recovery completed
together in 290 seconds; the separate abrupt-crash variant completed in 224
seconds. Each variant records all 22 service checks, distinct boot identities
and `native_admission=false`. Exact immutable outputs are:

| Variant | Output and additional receipts |
| --- | --- |
| Services | `/nix/store/vwdvnlvvi7n8zdhmicsck1r8nr6plc0k-vm-test-run-overalls-freebsd-native-services/service-receipt.json` |
| Growth | `/nix/store/s0wbhmjgz0yjk94k2avdra5d4k9gxlg5-vm-test-run-overalls-freebsd-native-growth/`, service and growth receipts |
| Isolation | `/nix/store/h8s2v8snyz3xazq3kiv57ga6hghhb4hb-vm-test-run-overalls-freebsd-native-isolation/`, service and two policy receipts |
| Daemon recovery | `/nix/store/6kcdh1f3c87ksrcab54i5dadyrgxf1sa-vm-test-run-overalls-freebsd-native-recovery/`, service and two recovery receipts |
| Abrupt crash | `/nix/store/fl83dba7laz1m7swcybxj2n13adjwwwp-vm-test-run-overalls-freebsd-native-crash-recovery/`, service and crash-recovery receipts |

Logs are `/tmp/overalls-native-reviewed-final-suite.log` and
`/tmp/overalls-native-final-reviewed-crash.log`. The growth receipt records
three clean boots and the same two physical/root-capacity increases detailed
below. Both policy receipts retain the exact packaged policy hash and actual
sink controls, foreign-source guard drops and assigned-source recovery. Both
daemon receipts record real kill/reap, three live readiness refusals and a new
supervised PID with exact bytes/mode in the same boot. The crash receipt records
observed SIGKILL, a new boot of the same disk, exact retained home/marker bytes,
old-authority refusals, UFS snapshot background fsck and final clean exit.
These close the five stated FreeBSD candidate boundaries for these exact inputs.
They do not establish OmniOS services, physical stable-media/power-loss
durability, direct native peer-VM/jail/host isolation, reset/DMA safety, signed
production artifacts or Marshall-driven fleet acceptance.

The [OmniOS kit](../../../nix/domains/artifacts/guest/omnios/candidate.nix) builds at
`/nix/store/91xwy6bfj14rivv7qdfammlw4gq99yaa-overalls-omnios-native-image-candidate-kit`.
Its compiled input token is
`4b1627f10dca4964bd29eaff1d12904cc65a83d9edae6cd79a10eeebdaa807fd`;
the kit manifest digest is
`1fa04ac0c8301ad52d96ec7bbaf68a9870f187db603795b5f2b7f40c8dc058b6`.
It binds the exact 8-GiB base GPT, native Python interpreter, 819 kit files/links
and 758 installed payload entries. All nine helper safety tests, Ruff and ty
pass. The helper enforces symlink confinement and exact installed sudoers
ownership/mode checks. The immutable kit retains sudoers mode0444 while
the guest target and installed payload receipt require root:root mode0440.
Stock OmniOS Bash and sudo retain their vendor bytes and modes, including
sudo's mode04511. The root-only native helper requires a separately
identified unimported pool, preserves the base BE and fails closed when pool
export refuses. Native execution on the matching OmniOS image imported the
separately identified pool GUID6088636317398311714, cloned its root, linked and
installed all nine modules and full payload, rebuilt the boot archive, selected
the candidate bootfs and cleanly exported the pool. Assembly exited 0; the
assembly/export records are `/tmp/overalls-omnios-native-probe/native-kit-assembly.log`
and `/tmp/overalls-omnios-native-probe/native-kit-export-status.log`. A separate
QEMU boot reached the installed candidate root and hostname. Actual fresh-boot
verification then refused `/etc/resolv.conf`: stock cloud-init changed its
installed mode0444 to0644 and its bytes. The unix digest, all nine module
digests and other 757 payload entries matched. This exposes a conflict between
the immutable payload receipt and vendor runtime network configuration;
neither the receipt nor the verifier was bypassed. The failure record is
`/tmp/overalls-omnios-native-probe/candidate-payload-exact-diff.log`.
The fix installs a site profile disabling
`svc:/system/cloud-init:{initlocal,init,modules,final}` and
`svc:/network/ssh:default`. The helper applies the profile to the clone's offline
SMF repository with the supported `repository FILE`/`apply PROFILE` command
file; it never modifies the administration VM's live repository. It verifies
five false enabled properties, and fresh-boot verification additionally requires
the instances' actual disabled states. The exact profile SHA256
`eb4a0990932706de4a7f40d3bf1432cccad99b118490e30fe2cd980ab40d28de`
passed native `svccfg` against a root-only scratch copy of stock
`/etc/svc/repository.db`: exactly five `general/enabled boolean false` rows,
exit0 and empty stderr. The scratch directory was removed; the live repository
was untouched. Record:
`/tmp/overalls-omnios-native-probe/admin-svccfg-exact-profile-test.log`.
The fresh pinned image's seed repository did not yet contain cloud-init
instances, unlike the already booted administration image. The initial complete
assembly therefore refused the absent instance. Explicit offline manifest import
then hung in `lscf_instance_verify` while waiting for restarter properties. Native
`pstack` and the pinned `svccfg_libscf.c` source identified the missing offline
`SVCCFG_REPOSITORY` environment. The corrected fixed command binds that variable
to the validated clone repository, imports the clone's exact stock cloud-init
and SSH manifests, then applies and verifies the profile. Native replay exited 0
with exactly five false rows and empty stderr; the administration repository
was untouched. Records are
`/tmp/overalls-omnios-native-probe/admin-scf-import-process-stack.log` and
`/tmp/overalls-omnios-native-probe/admin-clone-svccfg-bound-env-replay.log`.

Eleven image-helper regressions and pinned Ruff/ty checks passed. The final
seed-fixed kit built at
`/nix/store/ix9zsw1f3099bw6rkm0s9i8rj6vi688i-overalls-omnios-native-image-candidate-kit`,
kit manifest SHA256
`815808167de55c83f31c6ac19684464b92f0390a58be7b0ba0f54950f17c3452`.
Its independently hashed transfer and fresh 8-GiB pinned target assembled
natively, exited 0, exported the pool and removed its workspace. The preserved
assembled disk SHA256 is
`94f6da255a3f750ca94cd438df71ee45e107d80733718e49f8a3fd9360fd109d`.
Record: `/tmp/overalls-omnios-native-probe/native-seed-fixed-kit-assembly.log`.
A separate QEMU single-user boot mounted the exact candidate dataset and passed
the verifier's unix, nine module, complete payload, five disabled-service,
Git-runtime and trust checks. Resolver bytes and mode0444 survived. Verification
then refused with AF40 ENXIO because this QEMU fixture has no vsock hardware;
it emitted no complete verification receipt. Record:
`/tmp/overalls-omnios-native-probe/seed-fixed-native-verify-growth.log`.
Firecracker's executing socket token/transport and complete services remain
pending; installation and boot progress cannot open native admission.

The later frozen source kit
`/nix/store/hjyvwhfqrn1nnglf31xhf21y4zrb14yf-overalls-omnios-native-image-candidate-kit`
passed fresh native assembly, clean export, read-only receipt extraction/export
and clean admin shutdown. It includes persistent console settings, the immutable
vendor CA, narrow managed-trust verifier, canonical roots and `UseDNS no`.
Kit manifest SHA256 is
`3102ab05141c0bea1a09bd367b2ec425388c7a7b8e5a393ad823878328589c8c`;
the exact fresh 8-GiB assembled disk SHA256 is
`e0c0176090edbd499dd37522bbf9f54e82bbdf75c7e826af4c87e031804934e3`.
Assembly receipt SHA256 is
`8fb508371ec5319729c58dfd5fdc7a91f786fb3c33864fafd60eee137f4e3d8c`,
binding 765 payload entries, nine modules and unix SHA256
`c56dc5c19523ef29511e2bfe4b98a6544b786a089b55b654c30ea32e821bdd21`.
The growth helper SHA256 is
`a77d51987c2b66f4d33575fef648bfc5f2397342d0a4a5260115376b6aabca4c`.
Records are `/tmp/overalls-omnios-native-probe/native-frozen-hjyv-kit-assembly.log`,
`native-frozen-hjyv-readonly-receipt.log` and
`admin-frozen-hjyv-clean-shutdown.log` in that directory. The read-only test-only
artifact is `/tmp/overalls-omnios-native-final-artifact-hjyv`; it is not a production
version-6 manifest. Runtime/services, managed trust after actual delivery and
growth remain separate acceptance boundaries.

The first formal normal-boot replay of that `hjyv` image confirmed persistent
serial output and reached the ordinary login prompt without a debugger. It
then failed the current-boot service gate after 495 seconds: stock
`network/physical:default` returned 96 and entered maintenance, withholding
Overalls bootstrap through its required dependency. The native service log
showed that the remaining plumb-only `/etc/hostname.vioif0` conflicted with
stock physical interface initialization. All three Overalls manifests also
failed import because `Uncommitted` is outside the pinned SMF stability enum.
Record:
`/tmp/overalls-omnios-formal-services-full.log`. Those symptoms require separate
service corrections and disk-I/O investigation. Decoded native FMD records show
ZFS EIO at 16:28:08 before the later unsupported VMM reset attempts, so resets
cannot explain the initial errors. No lower transport cause is established by
the FMD records alone. Decoded evidence is
`/tmp/overalls-omnios-native-probe/admin-formal-fmd-errlog-decoded.log` and
`admin-formal-fmd-fltlog-decoded.log` in that directory. No service or complete
image-verification receipt was published by that attempt.

The correction removes only the four fixed stock vioif0 address/DHCP files
from the scratch clone, preflights all destinations before removal, preserves
unrelated interfaces and binds the removed inventory into the assembly receipt.
Every booted verification refuses restoration. This preserves the accepted
growth-gated, MMDS-only network authority. The generated growth/bootstrap/agents
manifests now use `Unstable`, and assembly plus booted verification invoke the
real native `svccfg validate` on their exact installed bytes before receipts.
Twenty-one image-helper boundary tests and pinned Python format/lint/typing
passed, including refusal of each stock vioif0 file even in a correctly repacked
kit before pool access. Record: `/tmp/overalls-native-image-handoff-final-static.log`.
Actual native validation passed all three frozen manifests from
`/nix/store/9l6vvcf7dd29681qibmq5bvf4ix5c51j-overalls-illumos-guest-agents`;
agents/bootstrap/growth SHA256 values are respectively
`6fb99095d1d1702a122869accfc08206b51563524356d26ec35913dd4e99e871`,
`6e4a00fd857779dc3863529273de111b534f5a773b7c86eef429232a3413a853` and
`a4c7f34c2a802e233dbae30996813cc3743e3bc43eaf69549101558716b68f3d`.
A deliberate `Uncommitted` mutant failed native validation with exit 1 and
the expected enumeration error. Record:
`/tmp/overalls-omnios-native-probe/admin-frozen-smf-native-validation.log`.
These are schema checks; actual import, ordering and method execution still
require the corrected image replay. No new service or network authority is added.

The Marshall distributed recovery fixtures now stop replacement peers before
transactional cleanup of their captured VM, host, users and context/planning/
skill/activity graph. Exact public-table row inventories before and after each
case detect retained rows, while an unrelated retained machine/history fixture
checks cleanup scope. Fixture construction is transactional as well. The final
focused suite passed ten checks (one property, nine tests), the distributed-only
suite passed 171 checks (13 properties, 158 tests), and forced test-environment
Dialyzer reported zero errors in 44.26 seconds. These repair test isolation and
add database-state verification; they change no production API or accepted
architecture and establish no native physical recovery behavior.

Evidence: [lyra-native.nix](../../../nix/domains/artifacts/infrastructure/lyra-native.nix),
[native_manifest.py](../../../nix/domains/artifacts/infrastructure/native_manifest.py),
[native-agents.nix](../../../nix/domains/artifacts/guest/native-agents.nix),
[SDK](../../../nix/domains/artifacts/guest/native-kernels/illumos/sdk.nix),
and [fs2 provenance](../../../lyra/vendor/fs2/OVERALLS.md).

### 4. Kernel candidates implement the host-only ABI; native transport acceptance remains open

The [FreeBSD candidate](../../../nix/domains/artifacts/guest/native-kernels/freebsd/default.nix)
cross-links a complete amd64 GENERIC kernel with pinned Clang 19.1.7 and static
socket/virtio-vsock registration. The Linux bootstrap executes the bmake tests,
retains kernel warnings-as-errors and fixes the build timestamp. Build provenance
binds complete source revision, ABI patch, driver/core, configuration and compiler,
with exact output bytes/digest. It remains outside the closed image constructor.

The later FreeBSD revision also refuses generic send/receive buffer and
low-watermark setters, preserving the immutable 64-KiB per-stream budget.
It built in 192 seconds at
`/nix/store/s5m8yz0gpj6nq1jjwd4hj9l7dasmgiwv-overalls-freebsd-kernel-candidate-833d39bd2e38421a14ea489a956261a0fa993fbc`:
29,195,032 kernel bytes, SHA-256
`5d6ea5f9ba4caa0c30dc048eac56af2c6cfa4d9121fde6a859113373e736784f`,
build token `5e1fd7cfa5aaa0e8e99097904b3fc79f12001841f5df321e3cf68e5d0be283b9`.
The actual accepted-child helper/core regression passed with lifetime mocks and
sanitizers at `/nix/store/8pkw17xpdrqacm2in45nzj5snqgh6z9m-freebsd-vsock-accept-lifetime`.
The separate native probe now asserts option refusals, exact buffer size,
socket-129 refusal and full 128-slot capacity reuse; final-candidate native
execution of those expanded assertions remains pending.

The public socket ABIs use family 45 on FreeBSD (`AF_VENDOR03`; family 40 is
already SDP), and currently unused family 40 on illumos. Both export
`sys/vsock.h`/`sockaddr_vm`; BSD length/family bytes and illumos family16 differ,
while size 16 and port/CID offsets 4/8 match the native Rust adapters. Wrappers
require root or global-zone system-configuration authority, permit only passive
host-CID-2 streams to guest CID 3, cap sockets at 128 and windows at 64 KiB, and
reserve queue capacity for controls. Outgoing connects remain unsupported.

The [illumos modern backport](../../../nix/domains/artifacts/guest/native-kernels/illumos/0002-modern-virtio.patch)
applies to exact stock-image revision `6f87d0b5d63b957991dc9d4a01a7e6c95483282c`.
It includes modern/transitional virtio and subsequent queue-address, BAR-cache,
mutex, notification-order and DMA-length fixes, preserving upstream licenses.
All nine framework/consumer objects compiled for Solaris AMD64; framework ABI
changes require rebuilding all five consumers. The transport/socket wrappers
and shared core also compile with `-Wall -Wextra -Werror`, allowing only pinned
source unknown pragmas and aggregate initializer conventions. These are objects,
not native linked kernel modules. `nix build .#illumos-kernel-candidate-objects`
passed at
`/nix/store/4q9z5wkcr8bmlgg3212pvhc4xkr021id-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`
in 122 seconds while the FreeBSD build ran. It compiles all 26 objects, including
the complete 14-object sockfs set, checks the public C ABI, executes the extracted
listener harness and records exact object sizes/digests plus source/patch/config
and build-token inputs. The output explicitly says linked=false and native
admission=false.

The [native assembly helper](../../../nix/domains/artifacts/guest/native-kernels/illumos/native_candidate.py)
then verified that exact26 bundle and linked all nine modules using Solaris
`ld -ztype=kmod` inside the matching scratch OmniOS guest. It staged verified
input bytes, used the fixed complete dependency sets, and recorded actual
module sizes/hashes plus native Link Editors 5.11-1.1790. An earlier linked
candidate failed native sockfs loading with `fs/sockfs:bind() not defined properly`:
Clang's Solaris target defines `_XOPEN_SOURCE=600`, which renamed kernel
definitions to userland `__xnet_*` symbols. The corrected build undefines that
macro and checks six ordinary syscall exports in the actual `socksyscalls.o`,
refusing renamed exports. Its compiled token binds both configuration-file and
Nix build-recipe hashes. The corrected 26-object derivation passed in 28 seconds at
`/nix/store/h0flfgn6dh34ihahzp415kqyw5hmkbmf-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`.
Build ID `26af66ac9f0729d965918816f5132bf161a8d8a5af3bc68a7aed1f6b815e72a8`
produced native linked-receipt SHA-256
`5b2323d51e3ea44b76043ebfc7949d9d96cc0786be0b6320594cf90489f6bdba`.

The same helper installed the verified modules, public header, root-owned
expected token, modern PCI aliases and family40 stream mapping into the separate
ZFS dataset `rpool/ROOT/overalls-native-candidate`, then successfully ran native
`bootadm update-archive -v -R`. It refuses the running root, its dataset,
non-ZFS roots and symlink destinations. The original boot environment was
preserved; the clone was selected separately and the guest performed a clean
init5 shutdown with filesystem synchronization. The native run used the pinned
stock image's Python 3.12.3. The candidate kit binds that interpreter's actual
ELF digest instead of assuming host Python. The helper uses nonblocking file
opens before regular-file
validation, root-owned/non-group-or-other-writable destination ancestors, and
conflicting family40 mapping refusal. Seven input/path-boundary tests, Ruff
formatting/lint and the repository's Python 3.13 ty target passed. The hardened
helper linked/installed the corrected objects natively and all seven tests
passed under the stock image's Python. The corrected clone booted under QEMU
without the sockfs loader error and a native TCP bind succeeded. The transcript
is `/tmp/overalls-omnios-native-probe/native-helper-tests-fixed.log`.
These scoped runs do not prove virtio-vsock execution, reset safety or
reproducible full-image assembly. Both receipts leave runtime validation and
native admission false.

The opt-in sockfs listener reset patch is necessary: stock sockfs assumes
listeners never disconnect, so a disconnected upcall cannot wake a blocked
accept. The patch uses unused mode/state bits without changing sonode layout,
which preserves stock SCTP's embedded sonode. It records a sticky reset under
both locks, wakes/refuses accepts and refuses later new connections. The lower
wrapper rechecks parent/child fences on accept. A pthread harness executed the
actual extracted patched dequeue/disconnect functions: 256 blocked accepts woke
with ECONNRESET; queued/nonblocking reset, sticky failure after SO_ERROR clear
and unchanged opt-out behavior passed with address/undefined-behavior sanitizers.
This harness does not execute sockfs inside a native kernel.

Review corrected an untrusted REQUEST credit transition that could panic, an
unlocked send copy that could publish after shutdown/credit shrink, reader/writer
ownership during close, read shutdown while copying, callback-subscription
replacement during drain and configuration-only CID changes. Old sockets,
including idle sockets/listeners, are fenced and cannot bind/listen again.
FreeBSD retains static interrupt-visible resources and requires VM replacement
after reset; runtime detach/unload are refused. The initial illumos teardown
drained interrupts and workers before queue evacuation/free, but a later source
review found that this did not establish backend DMA termination when
Firecracker refuses device reset. Native concurrent/reset and malformed-DMA
acceptance remain separate from source reasoning.
Independent final source/contract reviews of the common core and each native
wrapper found no additional concrete violation. This source review adds no
native DMA, interrupt, callback-race or reset evidence.

The corrected illumos transport now has static lifetime after `DRIVER_OK`.
Fallible taskq, slot, chain and DMA allocation precede activation. The pinned
framework initializes queue mutexes at queue allocation and only reinitializes
their interrupt priority in `virtio_init_complete`; its sole failure branch
precedes `DRIVER_OK`, and interrupt enabling remains separate. Thus allocation
and unflushed private-chain preparation are legal before activation without
publishing buffers to the backend. Activated state is recorded immediately
after successful completion. A preactivation failure may still reclaim resources.

Runtime detach refuses once attached, preventing module unloading and retaining
all interrupt-visible objects and DMA until VM disposal. An unavoidable
postactivation failure clears this device's global readiness, disables interrupts,
stops/drains workers and fences sockets while retaining a bounded unavailable
attachment; it never calls the reclaiming destructor. Independent control-flow
review found no remaining lifetime violation in this correction. This enforces
the existing `illumos-transport-lifetime` contract and ADR-0190's fail-closed
boundary, without adding a new deployment or authority. The final cross-build
passed all 26 objects and all three host-test gates at
`/nix/store/8r2lwnsi1qql51q3b23d7f5ajfpq1v5y-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`,
with compiled token
`985301b455d2a656b4664381b38374fec4aebfa57e2dc8185a072723092efa41`
and aggregate patch hash
`b92c2e3c7803db22ad11c9c71a3ecd8ead0d4e3187ca35eb3c32c26079155df1`.
Native linkage and replay of those exact inputs remain required. The correction
does not explain the earlier initial ZFS EIO:
decoded FMD records place those errors before the reset attempts.

The source-extracted lifetime harness passed strict Clang plus address/undefined
sanitizers across 236 preactivation fault sites, both late activated failures
(interrupt-enable and duplicate-singleton), successful attach and runtime detach
refusals. Each late failure retained all 65 DMA/chain pairs, worker storage and
driver-private ownership while withholding this device's availability. Three
deliberate mutants were rejected: early `DRIVER_OK`, freeing after activation
and successful runtime detach. Record:
`/tmp/overalls-viosock-lifetime-mutants.log`. These are host-mocked control-flow
and sanitizer checks; native interrupt/DMA/physical recovery remains open.

The separate [direct block descriptor correction](../../../nix/domains/artifacts/guest/native-kernels/illumos/0004-block-direct-budget.patch)
addresses a source-level capacity defect: a non-indirect ring previously allowed
one request per ring descriptor even though each request needs data descriptors
plus a header and status. The helper bounds concurrent requests by
`ring_size / (data_segments + 2)`, clamps data scatter to `ring_size - 2` before
publishing DMA attributes, and refuses a ring unable to hold one request.
Indirect requests retain one ring descriptor each and the fixed pool bound.
For the pinned 256-descriptor/128-data-segment case the safe direct depth is one.
The early preflight changes only the local scatter limit; request capacity is
still assigned at the original allocation stage, preserving failure cleanup.
Independent source review found no violation in the corrected ordering/budget.

The host harness extracts the actual patched helper and fixed request bound,
then passes 265,596 generated/boundary vectors under strict Clang and
address/undefined-behavior sanitizers. It checks the independent aggregate ring
bound with widened arithmetic, undersized-ring refusals and indirect behavior.
This is arithmetic/source evidence, not native disk/ZFS acceptance. No traced
descriptor-append ENOMEM or native A/B result establishes this as the cause of
the earlier EIO; a diagnostic 256-MiB zero-write workload passed, and an attempted
raw-read clone history was invalidated by host mount cleanup. The corrected
exact image requires native service/storage replay. This changes internal
kernel queue accounting, preserving Lilly's physical capacity/admission policy.

The depth-one direct pool exposed a separate completion-order defect in the
pinned driver: `vioblk_complete` notified blkdev before releasing its request.
Actual `bd_xfer_done` can immediately submit the next DMA window, and
`bd_runq_exit` synchronously schedules queued work; a still-occupied one-request
pool then returns `ENOMEM`. The correction caches the original transfer/error,
releases the request and descriptors under `vib_mutex`, and only then notifies
blkdev. Neither completion nor its poll/polled callers touch the recycled request
after the callback can begin. Completed blkdev transfers return submission
success while delivering the original error exactly once through the callback;
internal transfers without a callback return their original error directly.
This also closes the pre-existing polled-error double-completion risk: the
framework otherwise treats a nonzero submission return as another completion
after `bd_xfer_done` has freed that transfer. Independent review of the actual
driver/framework control flow found no remaining violation in the correction.
It enforces the existing internal request-ownership contract without changing
Lilly capacity or authority. The host regression below passed; corrected native
replay remains separate evidence. Neither this source reasoning nor the QEMU diagnostic proves
the original ZFS EIO's precise cause.

The later source review also found two lifetime hazards. FreeBSD's old failed
accept path could abort a child still owned by the listener queue. The corrected
path validates before allocating, creates an unqueued child, detaches/deallocates
it on response-resource exhaustion and publishes only a successful child.
Illumos interrupt work previously depended on fallible `TQ_NOSLEEP` dispatch;
failure could strand a completion or configuration fence. A preallocated taskq
entry removes that allocation/failure branch while the existing queued guard
serializes worker ownership. These are source fixes with scoped host regressions
and compilation; native memory-pressure, callback-race and reset stress remain
required.

The preallocated-taskq revision then built all 26 illumos objects at
`/nix/store/wgwr1cqcw1y45alv9icf4lhxw9x03rmm-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`.
Its build token is
`4b1627f10dca4964bd29eaff1d12904cc65a83d9edae6cd79a10eeebdaa807fd`.
The same reviewed helper linked all nine modules natively, recording linked
receipt SHA-256 `f743593e7479e0e2145b58008a838d196012ed1d9b630214a8c528cd61de8f05`,
then installed into the separate `rpool/ROOT/overalls-native-taskq` clone of the
preserved stock BE, rebuilt its archive and shut down cleanly. This new clone
contains no scratch polling module or forced-MSI setting. Its native transport
execution remains pending; earlier QEMU bind evidence belongs to token `26af66ac`.

Both wrappers link the [common C core](../../../nix/domains/artifacts/guest/native-kernels/common).
Generated malformed frame/state/credit/counter-wrap and directional-shutdown
suites passed with address/undefined-behavior sanitizers in the actual core.
The independently selected common-core/Firecracker patch check run passed in
171 seconds (2026-10-17); it does not execute either native wrapper.

Exploratory QEMU modern-only OmniOS reaches `Hostname: omnios` with the backported
virtio/block/network modules. The corresponding Firecracker scratch disk initially
stalled at ZFS scan. Bounded stage/PCI/queue/IRQ diagnostics showed its first
GET_ID reached the used ring while MSI-X remained globally masked. Firecracker
initialized the guest capability as already enabled while internal state was
disabled/masked; stock illumos therefore skipped its conditional enable write.
The production fix initializes both views disabled/unmasked, preserves masked
individual entries and refuses interrupt delivery until enabled. Scratch
stage/polling/tracing variants remain outside accepted sources and are removed
from the clean clone. The production MSI-X/network-reset checks passed in
204 seconds at `/tmp/overalls-native-vmm-reset-gates-v5.log`. The clean taskq
clone subsequently reached a real virtio-block device and mounted its ZFS root
under production VMM `f91yr04h84d7xsaxxbmhlj5vg4ymw6wv`. Both one- and two-vCPU
attempts then stopped producing boot progress before the maintenance prompt;
the last device messages do not identify the waiting kernel stack. The logs
`/tmp/overalls-omnios-native-probe/production-msix-serial.log` and
`/tmp/overalls-omnios-native-probe/production-onecpu-serial.log` record the bounded
attempts. Complete native boot and vsock execution remain pending.
The complete FreeBSD service candidate separately stopped serial output at
`Setting hostuuid` after the first16FIFO bytes. The actual FreeBSD ordering
writes its FIFO before enabling ETXRDY; pinned vm-superio0.8.1 did not signal
THRE when enabled on an empty THR. The production UART repair signals only on
the disabled-to-enabled transition, preserves pending re-enable and DLAB
semantics, and has a regression through the actual dependency API that fails
before the repair. Production VMM, identity and selected patch gates passed
in173seconds (`/tmp/overalls-native-uart-vmm-gates.log`) at
`/nix/store/54rsidap3qqlnc6g5fyxbf20z4rs35xd-firecracker-static-x86_64-unknown-linux-musl-1.16.1`;
the VMM SHA256 is
`6dc973624d906ac02ed41d99c2f43f41033a56fbc318751f96b845a2842caa54`.
Actual guest replays remain separate from these build/unit results.
The integrated production VMM then added the pinned CloudHv firmware's exact
shutdown byte: one byte 0x34 at port 0x600 signals the existing VMM exit event.
Other lengths and values refuse. All 52 patched VMM tests, actual PIO bus
registration, static VMM and Windows dependency gates passed in 214 seconds at
`/nix/store/a6281qwrnsj4yrnkwpj514vjvii6wc9q-firecracker-static-x86_64-unknown-linux-musl-1.16.1`.
Record: `/tmp/overalls-native-integrated-cloudhv-gates.log`. Actual native clean
exit remains distinct from this build/unit result.

The later OmniOS diagnostic used the preserved seed-fixed kit clone and the
54rs production VMM. Explicit loader `console=ttya`, `os_console=ttya` and
`ttya-mode=115200,8,n,1,-` exposed verbose progress. Native kmdb breakpoints
proved `strplumb`, `consconfig`, other-CPU startup and `start_init` all completed;
the old final message did not identify a kernel wait. Actual device inventory
had no ISA/asy node. Setting the stock `pseudo_isa` global to 1 in debugger
memory before kernel initialization created `/isa/asy@1,3f8` and reached real
SMF/single-user root. The complete image verifier then exited 0, checking actual
AF40 compiled token, candidate root, unix, nine modules, every payload entry,
Git/trust and five disabled stock services. Records are
`/tmp/overalls-omnios-native-probe/seed-fixed-kmdb-pseudo-isa-entry.log` and
`/tmp/overalls-omnios-native-probe/seed-fixed-fc-native-verify.log`.

That same boot ran the separately packaged native Rust transport probe
(321,712 bytes, SHA256
`79154ce0d114a1f0faa96583325d8a1d74ee73d3e479155f2a5716e5d2293e45`).
Its pre-listen native CID/bind/connect/token/privilege/buffer/capacity refusals
passed, followed by actual host `native_transport.exercise`: exact executing
token 4b1627f10dca4964bd29eaff1d12904cc65a83d9edae6cd79a10eeebdaa807fd,
CID 3/2, malformed-length/disconnect recovery and all nine exact echo sizes
from 0 through 1 MiB. The recorded result is
`/tmp/overalls-omnios-native-probe/seed-fixed-omnios-transport-results.json`.
The initially timed-out transfer connection preceded listener readiness;
after readiness the same native path transferred and independently hashed the
probe. This is scoped diagnostic execution, with a debugger memory override
and disposable loader changes. The new assembler preserves stock files while
appending `set pseudo_isa=1` to `/etc/system` and the three serial settings to
`/boot/loader.conf.local`; it binds both complete files/modes in assembly and
second-boot verification. Fifteen boundary tests passed. Final fresh persistent
image replay, complete services, wrong-CID injection and reset stress remain
required; this diagnostic result grants no admission.

The runtime verifier now reconciles the deliberate effective-CA transition:
the exact immutable regular vendor snapshot stays bound to the kit, while only
`/etc/ssl/cacert.pem` may become a root-owned link into the fixed managed bundle
directory. Its regular mode0644 target must retain the exact vendor prefix and
one to 32 bounded public PEM roots. Every other installed payload check remains
exact. All eighteen image boundary tests passed, including foreign/traversal
links, writable or nested-link targets, substituted vendor bytes, unrelated
payload mutation and empty/oversized/private-key/malformed root sets. Test root
ownership is modeled; actual native ownership remains a separate execution
boundary. Structural file verification does not replace the current-boot trust
protocol receipt. Final native assembly/replay of these inputs remains pending.
An earlier custom FreeBSD Firecracker boot
encountered MSI-X setup failures; a later exploratory candidate reached a real
host UDS echo. The latest credit-fix candidate then passed the actual host
`native_transport.exercise`: the executing token matched, guest/peer CID 3/2
matched, oversized-length and partial-disconnect histories refused/recovered,
and all nine exact echo sizes from zero through 1 MiB crossed the credit window.
The exploratory result is recorded at
`/tmp/overalls-freebsd-kernel-boot/fc5-transport-results.json`; its executing
build ID was `0cd7d4c63614584e97f85e2b29680db0471aa2ecbf4df76e501244ed6886bc2f`.
The [nested-KVM machine gate](../../../nix/verification/tests/machines/native-transport/default.nix)
and [test-only listener](../../../lyra/src/bin/overalls-native-transport-probe.rs)
are now present. The listener remains outside the production native binary set.
The historical gate passed in 208 seconds, including native ABI refusals, with execution
log `/tmp/overalls-native-freebsd-machine-gate-v5.log` and full build record
`/home/ghuntley/.local/state/nix/build-logs/1792244016953-2728962-0.jsonl`.
This is the captured v5 input set. The newer gate passed in 139 seconds with
build token `5e1fd7cfa5aaa0e8e99097904b3fc79f12001841f5df321e3cf68e5d0be283b9`
and receipt
`/nix/store/biy88s3mwklkbg4h2hi57qy20fyj9nw3-vm-test-run-overalls-freebsd-native-transport/transport-receipt.json`.
It records image SHA256
`ee545402d0c4aa4787d94663cc6f52474fb4d53403d4b74a138235fe4e52f1a3`,
firmware SHA256
`261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2`
and production VMM SHA256
`6dc973624d906ac02ed41d99c2f43f41033a56fbc318751f96b845a2842caa54`.
It checks the executing token/CID2/3, immutable buffer/capacity and native ABI
refusals, malformed-length/disconnected/reconnect histories and the same nine
exact payload sizes through 1 MiB. Later input changes require their own recorded
execution and exact disk/firmware/VMM receipts. Integrated native service,
malformed-input, reset, isolation and recovery evidence remain separate. These
disposable experiments cannot open catalog admission.

Evidence: [native-kernels README](../../../nix/domains/artifacts/guest/native-kernels/README.md),
[FreeBSD wrapper](../../../nix/domains/artifacts/guest/native-kernels/freebsd/virtio_vsock.c),
[illumos transport](../../../nix/domains/artifacts/guest/native-kernels/illumos/viosock.c),
[socket wrapper](../../../nix/domains/artifacts/guest/native-kernels/illumos/sockvsock.c),
and [core check](../../../nix/domains/artifacts/guest/native-kernels/common/default.nix).

### 5. Shared Lilly boundaries are preserved — resolved

The new check runs inside existing placement locking and boot-generation
fences. It uses the existing jailer, per-tap network guard, ZFS ownership and
readiness transaction. Native guests retain guest CID 3, host CID 2 and the
jail-local `/v.sock`; no listener or host placement is added. Credentials are
not delivered when kernel attestation fails.

### 6. Root growth is fenced before identity and network — scoped FreeBSD execution, integrated acceptance pending

The new no-argument root helper runs as root after writable local filesystems
and before MMDS identity/network bootstrap on every boot. A current success
receipt is required even if rcorder continues after a failed service. FreeBSD
clears the volatile directory before growth and disables vendor firstboot
growfs; OmniOS uses volatile `/var/run` and an SMF dependency. Receipt publication
follows successful native commands and postflight, under an exclusive root-owned
lock; failures retain opaque errors and do not publish success.

Read-only preflight derives the actual mounted root and checks physical capacity,
both GPT headers and arrays, CRCs, pinned disk/partition GUIDs, starts and layout.
FreeBSD uses `gpart recover`, root partition5 resize and `growfs`, preserving the
root UUID/start and every nonroot entry. OmniOS requires the assembly dataset and
pool GUID plus exactly one whole-disk vdev, then uses `zpool online -e` while
preserving loader and reserved-tail identity. Commands have120-second and64-KiB
bounds. Typed numeric receipt fields retain `native_admission=false`.

Twelve pure parser/authority/GPT tests and cross-target Clippy passed. The updated
cross-built package passed at
`/nix/store/z830h6dmm5zfy0szs9lzcj9mn7px4s2v-lyra-native-0.1.0`;
its manifest contains exactly twenty production executables, ten per OS,
including both native growth helpers. The earlier eighteen-binary package is
historical. Three clean offline QEMU boots passed using
`/nix/store/7ibv5b2677rngqsakmrm9kxxv2sv11dw-overalls-freebsd-native-image-candidate`:
one unchanged boot followed by two host-side2-GiB enlargements. Native UFS
capacity rose5,061,628 →7,098,392 →9,135,160KiB. Root start/UUID and every
nonroot GPT entry remained unchanged; home bytes survived each boot and a
separate32-MiB foreign disk retained digest
`ac1b6f8aeddd7114877f0b47115ebb9733edb5708beb7ca28b89cfd168dc9a35`.
Caller-selected disk arguments and nonroot invocation refused on every boot.
The receipt is `/tmp/overalls-freebsd-growth-oracle/run-aligned/receipt.json`;
the typed native oracle is `/tmp/overalls-freebsd-growth-oracle/run.py`.
This is native GPT/UFS service-order evidence on a disposable image predating
the final SSH command correction; Firecracker service composition, OmniOS
growth, abrupt crash and interrupted expansion remain separate requirements.
The actual OmniOS no-op probe then refused before mutation: raw-device reads
accepted 512-byte MBR/header transfers but rejected the 1152-byte logical GPT
array with EINVAL. The corrected reader rounds its bounded physical transfer
to 512-byte sectors and truncates to the logical entry bytes before CRC and
identity checks. A reader regression rejects unaligned transfers, allows
different sector padding and refuses logical corruption. Native replay on the
new exact helper remains pending; no failed probe publishes a receipt.
Record: `/tmp/overalls-omnios-native-probe/seed-fixed-native-growth-truss.log`.
The separate OmniOS three-boot oracle is now present with ten passing host
boundary checks, Ruff/ty and read-only parsing of the actual pinned 8-GiB GPT.
It requires two root and pool-capacity increases, dual GPT/identity checks,
loader and relocated reserved-tail bytes, assembly/kernel/helper/pool/vdev
binding, foreign-disk preservation, caller refusals, disabled stock automation,
current volatile growth receipts and retained home bytes through the service
runner. This fixture presence adds no native expansion acceptance.

An actual first FreeBSD CloudHv boot created root ESP `/NvVars` (1,559 bytes),
while all GPT IDs/geometry and other boot/configuration bytes stayed exact.
The shared FAT oracle now compares every directory path and each regular file's
exact path, size and SHA256, allowing only the fixed root regular `NvVars` file
of at most 1 MiB to differ. Unrelated/new paths, changed boot files and an
`NvVars` directory refuse. Non-EFI protected partitions retain whole-partition
digests. The actual retained ESP comparison passed with three directories and
three files (`EFI/BOOT/bootx64.efi`, `overalls/install-status`,
`overalls/verify-status`); 21 combined FAT/FreeBSD/OmniOS host boundary tests passed.
Record: `/tmp/overalls-native-growth-debug/diagnostic-v2.log`. This corrects
firmware-variable accounting without granting native growth acceptance.

The later FreeBSD Firecracker growth variant passed in 334 seconds on exact
image SHA256 `46c41ca94a956f5ebc2a69cab2058a6035d36e89902d348a22bd56d5045b4540`.
Three distinct boots ended cleanly, with full service oracles on each boot and
two host-side 2-GiB increases. Physical bytes were 6,477,687,296 →8,625,170,944
→10,772,654,592; native root bytes were 5,183,107,072 →7,268,753,408 →9,354,403,840.
The oracle checked exact GPT IDs/nonroot geometry, protected partition bytes,
strict EFI inventory with only bounded root `NvVars` mutable, foreign-disk
preservation, nonroot/argument refusals, disabled stock firstboot, current
growth receipts and retained home data. Service and growth receipts are
`/nix/store/sz9bjnhiyr0d7wy3fg5lfifi6gqprqpn-vm-test-run-overalls-freebsd-native-growth/service-receipt.json`
and `growth-receipt.json` in that output. The log is
`/tmp/overalls-native-growth-firmware-fixed.log`. This closes the stated
FreeBSD three-boot growth boundary for those exact inputs; it does not establish
interrupted growth, OmniOS growth or admission. The final blocking-flush image
subsequently passed the same complete growth boundary in the five-variant
matrix above, with the same capacity series and three distinct clean boots.

The persistent host fixture gate `native-fixture-unit` passed 59 tests with
pinned Python 3.13/Git/OpenSSH/OpenSSL/FAT/block tools in a four-second Nix build:
`/nix/store/j8xrgphjfqsk7k21akkgb1c3qqr1m576-overalls-native-fixture-tests`.
Its actual unittest log records 59 checks in 1.051 seconds. Parser/refusal/cleanup,
synthetic Git authority and EFI inventory evidence stay host-scoped. The shared
service machine now accepts a closed FreeBSD/illumos OS selection and explicit
test-only image input for the same five scenario variants; this does not create
a production manifest or grant native admission.

Separate actual FreeBSD service execution exposed an early supervisor exit:
unconditional `chmod 0755 /var/empty` returned EPERM on the vendor's safe
root-owned0555 immutable directory. The supervisor now preserves an existing
root-owned real directory without group/other write permission, including its
native immutable flags, and initializes permissions only when missing.
The failed native record is
`/tmp/overalls-native-uart-failed-state/single-user-v2.log`. Later complete
first-boot execution passed the service paths above, then encountered the
separate firmware shutdown boundary. The later complete three-boot growth result
above supersedes that incomplete scoped attempt for its exact inputs.

Evidence: [mounted-root helper](../../../lyra/src/native_growth.rs),
[GPT validation](../../../lyra/src/native_growth/gpt.rs),
[service order and ABI checks](../../../nix/domains/artifacts/guest/native-growth.nix),
[OmniOS growth oracle](../../../nix/verification/tests/support/native_omnios_growth_oracle.py)
and its [boundary tests](../../../nix/verification/tests/support/native_omnios_growth_oracle_test.py).

### 7. Native network policy uses real rules — scoped FreeBSD execution, remaining isolation gaps

The NixOS fixture generates router and TAP source guards from packaged
`Lilly.Network.Policy` with validated synthetic operator/guest identities. Real
fixed TCP sinks prove public, sibling, protected-uplink, private, gateway and
unregistered-service targets reachable before policy installation. After
installation the native guest must retain public access and private SSH authority
while each forbidden target refuses. A foreign source must work before rules,
then increment the real TAP guard's drop counter; the assigned source must
recover. Two clean boots require distinct boot IDs and independent receipts.

The composed driver built at
`/nix/store/fw15439w13ixy88442hinpihh4pgnkcq-nixos-test-driver-overalls-freebsd-native-isolation`.
Real packaged rules installed in an isolated Linux namespace and the exact
five-drop guard inventory/counter parser passed. Logs:
`/tmp/overalls-native-isolation-driver.log` and
`/tmp/overalls-native-isolation-policy-smoke.log`. Ruff/ty and three boundary
tests also passed. These remain driver, Linux nft and source evidence.
The later native FreeBSD policy run passed in 280 seconds over two clean boots,
with separate policy receipts for each boot. Actual positive controls proved
all fixed sinks reachable, public access remained allowed under policy,
forbidden sinks refused, the foreign source incremented real guard drops and
the assigned source recovered. This required the native SSH `UseDNS no` fix;
the packaged policy was not weakened. Image SHA256 is
`46c41ca94a956f5ebc2a69cab2058a6035d36e89902d348a22bd56d5045b4540`,
with the same kernel/firmware/VMM hashes recorded above. Service and per-boot
isolation receipts are under
`/nix/store/0dncac323lf14xb6ff67wbw6vdgxz34j-vm-test-run-overalls-freebsd-native-isolation/`.
Policy SHA256 is
`c8af8eea9cd422d155fe11abce85ef980517beea7d1c6eaeb7f703f649d05b74`.
These results establish the stated native IPv4/router/TAP scope; jail,
physical-host and multi-host isolation remain unestablished.
The sibling address is a reachable Linux TCP sink behind the test peer uplink,
not another native VM/TAP; direct native-VM peer isolation remains a separate gap.

Evidence: [machine driver](../../../nix/verification/tests/machines/native-isolation/driver.py),
[packaged policy preparation](../../../nix/verification/tests/machines/native-isolation/prepare.exs),
[native network probe](../../../nix/verification/tests/support/native_isolation.py).

### 8. Daemon recovery requires observed failure and restored authority — scoped FreeBSD execution

The optional recovery fixture uses actual managed SSH to inspect the running
flush daemon's root-owned marker, exact executable mode/hash and live PID. It
temporarily removes execute permission, kills that process and confirms it is
reaped, then requires three refusals over the still-live readiness channel. A
finally block restores the exact saved mode. Recovery requires a different
supervised PID with the same bytes/mode and boot identity, followed by real
flush framing/refusals and current readiness. Only the complete sequence emits
the closed per-boot receipt, retaining admissionfalse.

Four host parser/failure-cleanup tests passed with Ruff/ty. The native FreeBSD
fixture then completed the first boot's real-daemon failure, three readiness
refusals, mode restoration, new supervised PID and real protocol callback before
reaching the same unresolved clean-shutdown boundary. Record:
`/tmp/overalls-native-aligned-recovery.log`. The later vendor-base image completed
both clean boots with actual daemon kill/reap, three live-channel readiness
refusals, exact mode/bytes restored to a new supervised PID, same-boot identity
and current-boot flush/refusals restored. Its two per-boot receipts are in
`/nix/store/5cp6ai62glx5sfcdvy7a493gd3l0mm2x-vm-test-run-overalls-freebsd-native-recovery/recovery-receipts/`.
The final canonical-root-order/SSH/blocking-flush image subsequently passed the
same two-boot boundary in the five-variant matrix above. OmniOS still requires
its own replay.
This does not establish guest-crash durability, disk recovery, relocation,
host failure or fleet availability.

Evidence: [native recovery oracle](../../../nix/verification/tests/support/native_recovery.py),
[snapshot boundary tests](../../../nix/verification/tests/support/native_recovery_test.py),
[optional machine variant](../../../nix/verification/tests/machines/native-services/default.nix).

### 9. Abrupt guest crash recovery — scoped final FreeBSD execution, OmniOS pending

The optional crash variant flushes and reads back exact retained home bytes,
then requires the actual Firecracker process to exit by SIGKILL. A new MMDS
identity boots the same disk. The second boot requires a distinct boot ID,
retained bytes, native filesystem verification, and refusal of old flush,
workspace and terminal authority. FreeBSD runs snapshot `fsck -B -f`; OmniOS
requires a completed zero-error scrub. Final clean shutdown remains required.
Seven host boundary checks passed. The actual FreeBSD crash run then exposed a
durability defect: `libc::sync` schedules UFS writes with `MNT_NOWAIT`, so an
acknowledged flush could precede durable managed-home/marker creation. After
actual SIGKILL, fsck discarded those bytes and SSH home lookup failed. This
refused crash acceptance rather than permitting a partial receipt. The correction
uses stock `/dev/ufssuspend` with `UFSSUSPEND` on the mounted UFS fsid, waits for
filesystem suspension and soft-dependency drains, then immediately resumes with
`UFSRESUME`. Acknowledgement follows successful resume; closing the descriptor
also resumes after errors. The final reviewed image then passed all eight crash
checks and both complete service oracles, as bound by the five-variant matrix
above. Pinned OmniOS ZFS sync already uses blocking `spa_sync_allpools`; its
native crash scenario remains unexecuted. Original failure records remain
`/tmp/overalls-freebsd-crash-full.log` (fsck clears the managed-home directory
and retained files) and `/tmp/overalls-native-crash-debug/diagnostic-v2.log`
(bounded diagnostics confirm home lookup/account activation/roster refusal
while host certificate and control authority remain healthy). Kernel review
supports waiting UFS suspension and soft-dependency drains; physical stable-media
`BIO_FLUSH` is outside this process-SIGKILL scope. Separately, the exact native command
`/sbin/fsck_ufs -B -f /dev/gpt/rootfs` exited 0 in six seconds on a mounted QEMU
candidate with soft updates enabled and SUJ/gjournal disabled. The fixture's
mounted-root parser accepted that actual body. Records are
`/tmp/overalls-freebsd-fsck-oracle/evidence/` and its `serial.log`; this checks
the native snapshot utility dialect rather than a crash history.
This tests an abrupt guest/VMM process failure, not physical host
power loss, interrupted expansion or fleet recovery; admission remains false.

Evidence: [crash oracle](../../../nix/verification/tests/support/native_crash_recovery.py)
and [boundary tests](../../../nix/verification/tests/support/native_crash_recovery_test.py).

### 10. Actual transport event fences live sockets — scoped FreeBSD execution

A separate test-only FreeBSD probe passed one real Firecracker pause,
full-snapshot and resume sequence, with all three API responses 204. Before the
event it verified live kernel identity on a socket without a peer and observed
pending accept, read and write calls. After the transport event the idle socket's
identity getter refused with `ECONNRESET` (54), accept/read woke with 54 and write
woke with `EPIPE` (32), after `send` had accepted 327,680 bytes. A new socket
refused with `ENXIO`, preserving the static driver's new-VM requirement. The idle
identity assertion distinguishes transport fencing from ordinary peer disconnect.

This result binds test-only image SHA256
`222329d8919b0afa0ac00a272d77d6c111b414662ab3c3b6652dc54b006e0c53`,
transport input token
`5e1fd7cfa5aaa0e8e99097904b3fc79f12001841f5df321e3cf68e5d0be283b9`,
firmware SHA256
`261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2`
and VMM SHA256
`5dc9a44417e758c94fd70cb78113bd55f04f3d9170307215a9ff2e88aabd6c90`.
The test-only source is [native_reset_probe.c](../../../nix/verification/tests/support/native_reset_probe.c),
with [host oracle](../../../nix/verification/tests/support/native_reset.py) and
[nested-KVM gate](../../../nix/verification/tests/machines/native-reset/default.nix).
The receipt and full serial log are
`/tmp/overalls-freebsd-live-reset-proof2/reset-receipt.json` and `serial.log`
in that directory. This image is distinct from the final five-variant service
image. `native_admission=false` remains explicit. This is one actual
transport-event/blocked-operation result; it does not establish malformed DMA,
reset-race stress, DMA reclamation, physical safety, OmniOS behavior, service
recovery or fleet acceptance.

The persisted `native-freebsd-reset` nested-KVM gate subsequently passed in
232 seconds. Its immutable receipt and serial log are under
`/nix/store/c7c9r96lvm05wm2k2vjlb2al5hj64vg4-vm-test-run-overalls-freebsd-native-reset/`.
It records test image SHA256
`69144fa6ef9597c872347484a3afb614479d0df070f69a4e645794d1ed599296`,
kernel SHA256
`5d6ea5f9ba4caa0c30dc048eac56af2c6cfa4d9121fde6a859113373e736784f`
and test probe SHA256
`a67b8973357f4e1944e1f408f4a6624e1b17cbb8b22041042541772d841b0e0f`,
with the same exact transport token/firmware/VMM and socket outcomes above.
The cross-build gate compiles isolated probes for both OS families; actual
OmniOS reset execution remains pending. The private fixture Unix API and
disposable snapshot/memory are test-only authority. No ordinary guest TCP port,
production control surface or native capability is added.

## 11. Final ADR-0190 artifact reconciliation

After reserving decision numbers 0188 and 0189 for upstream Cachix, all
native references use ADR-0190. The frozen Rust gates passed at
`/tmp/overalls-native-adr0190-frozen-rust-gates.log`. The final FreeBSD agent
output `/nix/store/hf1wv2fpmivcblyl4ikx82n6s0xbp7a2-overalls-freebsd-guest-agents`
has the same 37 file/link entries and identical bytes/targets as the reviewed
`br0v2ivx1vwm4zfkc4vyvk5bqngnbn27` baseline. The inspected comparison is
`/tmp/overalls-native-adr0190-freebsd-payload-comparison.json`; the comment-only
renumbering therefore preserves the recorded five-variant payload evidence.

The final ordinary FreeBSD transport catalog gate passed in 246 seconds at
`/nix/store/v15hqd1rb3dbb532zkviq2amrgbhjkjf-vm-test-run-overalls-freebsd-native-transport/`.
Its `transport-receipt.json` records image SHA256
`19658a4a2a013e910256916fa6e47cd48db76de51ca6cbf5c4dd02bf2a2fa841`,
token `5e1fd7cfa5aaa0e8e99097904b3fc79f12001841f5df321e3cf68e5d0be283b9`,
guest/peer CIDs 3/2, malformed-length refusal, disconnected-history recovery
and all nine exact echo sizes from zero through 1 MiB. Firmware and VMM hashes
remain `261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2`
and `5dc9a44417e758c94fd70cb78113bd55f04f3d9170307215a9ff2e88aabd6c90`.
This ordinary probe image is distinct from the reset and complete-service images;
its receipt explicitly retains `native_admission=false`.

The corrected OmniOS kit is
`/nix/store/8m1r196pilwy9mc7zvbfcsdifrf08d7x-overalls-omnios-native-image-candidate-kit`,
with manifest SHA256
`8c3231b0faebeb02b61cd2d109f9bfa2cfc20b031ea22315139210073fb66dbc`.
Its authenticated transfer archive SHA256 is
`a993104a3d37a3e26ecde54f7dac401305ae7aaada86d3de19aea2823a22ffaf`.
Native assembly of the pristine pinned disk passed with final token
`985301b455d2a656b4664381b38374fec4aebfa57e2dc8185a072723092efa41`:
all nine modules linked/installed, 764 payload entries verified, all three exact
SMF manifests passed native validation, four fixed stock network files were
removed, boot archive/bootfs were updated and the pool exported cleanly.
The 158,278-byte assembly receipt SHA256 is
`a6a2e89e99370494e86abd544e5cb5cf5b2e20735c3423eb52da3092e4c27b06`.
It binds pool GUID `6088636317398311714`, the candidate dataset, five disabled
stock services and exact network-removal list while retaining
`runtime_validated=false` and `native_admission=false`.

A private-device/GUID-only read-only import extracted and independently hashed
the receipt, then unmounted/exported and removed its workspace. Only the
administration pool remained imported; both assembly/evidence workspaces were
absent. Native `init 5` completed filesystem synchronization and QEMU exited
cleanly. The sealed 8,589,934,592-byte disk SHA256 is
`24318238ff18723fe3c984eac04475ede0d6ceb9d802aecaddd092ead70efa61`.
Its read-only baseline, firmware link, receipt and explicitly test-only metadata
are `/tmp/overalls-omnios-native-final-artifact-adr0190/`; runtime tests must
clone it. Assembly/receipt/shutdown records are the corresponding
`admin-adr0190-final-assembly-root-owned.log`,
`admin-adr0190-final-readonly-receipt.log` and
`admin-adr0190-final-shutdown.log` under
`/tmp/overalls-omnios-native-probe/`.
The unix SHA256 remains
`c56dc5c19523ef29511e2bfe4b98a6544b786a089b55b654c30ea32e821bdd21`;
native module hashes are separately bound by the receipt. This is a recorded
target-native assembly, not a reproducibly Nix-built disk or production v6
manifest. Normal persistent boot, services, storage, isolation and recovery for
this exact disk remain separate machine gates.

The first corrected-disk service, ordinary-transport and reset attempts all
failed during early boot, before current-boot fixtures, native probes or reset
API calls. About 13 seconds after the inner Firecracker started, it reported an
unsupported device-reset attempt followed by vCPU `Shutdown`,
`Shutdown(GenericError)` and exit 1; serial contained blank lines without a
native diagnosis. The service build failed after 125 seconds overall. Records
are `/tmp/overalls-native-omnios-9853-services.log`,
`/tmp/overalls-native-ordinary-9853.log` and
`/tmp/overalls-native-omnios-9853-reset.log`; the complete service build log is
`/home/ghuntley/.local/state/nix/build-logs/1792257495316-1534918-0.jsonl`.
These are failed normal-boot attempts, not service, transport or reset evidence.
The initial boot failure has no established cause. Investigation uses disposable
clones and preserves the sealed baseline and scoped successful assembly receipt.

Disposable QEMU BIOS clones subsequently isolated the early failure to the
direct-descriptor block path without requiring vsock. Modern virtio-blk with a
256-entry queue and `indirect=on` mounted root and reached SMF; the same setup
with `indirect=off` produced `zfs_parse_bootfs` error 6, failed to mount root and
panicked/rebooted. Records are `qemu-modern-indirect-serial.log` and
`qemu-direct-serial.log` under `/tmp/overalls-omnios-9853-boot-triage/`.
This diagnostic supports block-path involvement; it does not identify the precise
causal source line or establish corrected native A/B or service acceptance.
Its inspected `diagnostic-receipt.json` in that directory binds the three
QEMU cases, exact serial hashes and an independently rechecked unchanged sealed
baseline. Both modern cases use the same 256-entry queue and omit vsock; toggling
only indirect descriptors changes root-mount panic to ordinary console login.

## 12. Corrected block-completion build and native assembly

The host regression extracts the actual `vioblk_req_alloc`, `vioblk_req_free`,
`vioblk_complete`, `vioblk_common_submit` and `vioblk_poll` functions, plus the
pinned request layout/flags. Strict C11 warnings and address/undefined-behavior
sanitizers passed 161 histories: 32 direct completions, 128 submit/poll paths and
one append failure. The one-request fixture checks descriptor recycling before
callback reentry, an intact replacement request, original callback errors,
four device statuses, flush/nonflush, external/internal, polled/nonpolled and
panic/condition-variable paths. Four actual-source mutants were rejected with
`SIGABRT`: callback-before-release, poll double-free, externally consumed result
twice and internal error read after release. The inspected mutation log is
`/tmp/overalls-native-block-completion-mutants.log`; structural contracts passed
at `/tmp/overalls-native-block-completion-contracts.log`. These are source/mock
ownership checks, not native DMA, scheduling, storage or boot acceptance.

The corrected pinned object and kit build passed in 24 seconds. The 26-object
output is
`/nix/store/hqc4qqs55zv5byzsjbl71qx7xm8qw5aq-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`,
with token
`76b8c1ad4ba2e25f87768bbf8a1c55ed0f8d1b9fb973f776799c0b68eda98809`,
aggregate patch SHA256
`26aea847a4c288bb17970324c488d1624f011d02a1f67ed61b47d94b589f352b`
and configuration SHA256
`12377dbec7b8020be63120d6804f1d26d664c3b225b5a973a59c81ad6182e7aa`.
Its receipt binds pinned Clang 21.1.8, the public ABI, ordinary syscall symbols
and all four host gates: listener reset, direct descriptor budget, activated
lifetime fault injection and completion reentrancy. Native loadability/runtime/
admission remain false in that object receipt. Build records are
`/tmp/overalls-native-omnios-completion-kernel-kit.log` and
`/home/ghuntley/.local/state/nix/build-logs/1792258383026-1591227-0.jsonl`.

The matching kit is
`/nix/store/wvz857pax3pgcqm4i4x2q2cfkc6irk9y-overalls-omnios-native-image-candidate-kit`.
Its manifest SHA256 is
`b92a0d85a9d65e0f37538adbb5a5d233361b496b6566664ec3c8c2ad1154ef28`;
the independently verified transfer archive SHA256 is
`847df918a52c02674978f64b832c8531b3b161c33c1994b001a37cc68cf5ac52`.
A separate pristine disk passed native nine-module linkage, 764 exact payload
checks, validation of all three installed SMF manifests, removal of the exact
four stock-network files, boot-archive/bootfs update and clean export.
Read-only private-device/GUID-only receipt extraction also passed and exported.
The 158,278-byte assembly receipt SHA256 is
`30c85e38813eef79db8b153ebe48ba48d9d42182954cb13ce19f711c6fffa43c`.
It retains `runtime_validated=false` and `native_admission=false`, binds pool
GUID `6088636317398311714` and preserves the exact payload/disabled-service
boundaries. The unix SHA256 remains
`c56dc5c19523ef29511e2bfe4b98a6544b786a089b55b654c30ea32e821bdd21`.

Only the administration pool remained imported and both helper workspaces were
absent before native `init 5`. Shutdown completed filesystem synchronization at
17:39:44 UTC; QEMU exited 0 and detached the target. The sealed read-only disk
has 8,589,934,592 bytes and SHA256
`a49255bd16732be7b499ad36caab09f96df5de10fae58eedf7bae90aaffb5fc2`.
The artifact directory `/tmp/overalls-omnios-native-76b8-artifact/` contains its
read-only baseline, firmware link, assembly receipt and explicitly test-only
metadata. Runtime tests clone that baseline. Logs are
`admin-block-reentrant-assembly-result.log`,
`admin-block-reentrant-readonly-receipt.log`,
`admin-block-reentrant-export-preflight.log` and
`admin-block-reentrant-shutdown.log` under `/tmp/overalls-omnios-native-probe/`.
The failed `9853` image and evidence remain preserved separately. This is
recorded target-native assembly, not a reproducibly Nix-built disk or production
v6 manifest. Firecracker service/transport/reset execution remains separate
machine evidence; original ZFS EIO causality and production admission are
unestablished.

The paired direct-only QEMU diagnostic subsequently reached console login on
the corrected `76b8` disk, where the preceding `9853` disk panicked mounting
root. Both cases use QEMU 10.2.4 default BIOS, KVM, host CPU, 2,048 MiB, two
vCPUs and `virtio-blk-pci,drive=root,disable-legacy=on,indirect_desc=off,queue-size=256`,
without a vsock device. The inspected receipt is
`/tmp/overalls-omnios-76b8-boot-triage/diagnostic-receipt.json`.
It binds the sealed disks and exact serial logs: the old
`/tmp/overalls-omnios-9853-boot-triage/qemu-direct-serial.log` has SHA256
`15db146a0b8a70d6e8d42219afd16f7d553b8b4be327b99e8bd922181d7e8e29`,
and the corrected
`/tmp/overalls-omnios-76b8-boot-triage/qemu-direct-serial.log` has SHA256
`983962d896eb788b91489147436e84688b6451051a8c629889c45a463177f0f4`.
The corrected disposable clone completed ACPI shutdown with QEMU exit 0; the
sealed `a49255bd` baseline hash was independently rechecked unchanged.
This supports the source-grounded completion/recycling correction for the
direct-root-mount failure. The growth service entered maintenance in this
diagnostic configuration, so no growth or service success is claimed. This
does not establish the precise cause of the original earlier ZFS EIO,
Firecracker services, transport/reset/DMA safety, isolation or admission.

The first corrected-image Firecracker service attempt failed at its 240-second
first-boot deadline; the complete build failed in 353 seconds. The VMM remained
alive through that deadline, unlike the earlier `9853` early shutdown. Native
serial contained only newlines, and Firecracker reported the network device
not yet activated at 17:43:56 and 17:45:00 UTC. No kernel or service response was
obtained. The observed failure stage is boot; the next driver/bootstrap failure
has not been located. Records are `/tmp/overalls-native-omnios-76b8-services.log`
and `/home/ghuntley/.local/state/nix/build-logs/1792258871620-1627105-0.jsonl`;
the failed derivation is
`/nix/store/w12jz771m913l4lc4dmbkdr0jr31hw4f-vm-test-run-overalls-illumos-native-services.drv`.
This attempt grants no service, transport, reset or storage acceptance.

## Verification boundary and follow-up

Protocol, Lilly and Rust unit tests plus Nix evaluation provide typed, bounded
source evidence. The exact FreeBSD candidates have separately recorded native
service, growth, policy, daemon-recovery, process-crash, ordinary-transport and
transport-event results above. Their receipts retain distinct image identities
and establish only those nested-KVM histories. OmniOS has target-native
assembly, scoped diagnostic transport and paired direct-only QEMU boot evidence;
the corrected-image normal Firecracker service attempt still fails at boot.
Neither family's record establishes wrong-CID injection, DMA/race stress,
direct native peer-VM isolation, physical power-loss durability, relocation or
fleet availability.

Before either family is admitted, finish the missing native and reproducible
image gates, then run Marshall-driven capability and recovery journeys. Keep
the current unavailable production receipts and all capability rows fail-closed
until the required source-qualified evidence exists for both families.

Checks for this review are `elixir scripts/check_adrs.exs`,
`elixir scripts/check_hldd.exs`, `elixir scripts/hldd_coverage.exs --check`,
`elixir scripts/hldd_views.exs --check`, the Protocol/Lilly focused tests and
the Lyra formatter/type/test gates. These checks do not add native runtime
evidence.

The CI metadata selector now obtains enabled requirements from a NixOS tester's
lazy `config.requiredFeatures` when its wrapper lacks `requiredSystemFeatures`.
This preserves the actual nested-KVM requirement without forcing the driver,
derivation or guest image merely to schedule a check. Explicit metadata remains
authoritative. Synthetic throw-on-driver/drvPath evaluation passed, and actual
service/transport/reset metadata reports enabled machine/nested-KVM while the
host fixture remains a nonmachine check. The command was
`nix eval --impure --json --file /tmp/overalls-native-ci-lazy-feature-regression.nix`,
with result `/tmp/overalls-native-ci-lazy-feature-regression.json`;
source [ci.nix](../../../nix/verification/tests/ci.nix). This corrects verification
scheduling under the existing architecture and adds no runtime acceptance.
