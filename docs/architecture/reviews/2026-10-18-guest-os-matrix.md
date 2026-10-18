# Guest OS matrix evidence review (2026-10-18)

## Scope and architecture impact

This review reconciles the seven declared guest OS families with the evaluated
fleet catalog, current image evidence and opt-in Porsche acceptance tooling.
It also corrects foreign-Linux ext4 construction, adds evaluation assertions for
the native SSH supervisor's temporary PID cleanup and reconciles the Windows
evaluation's shared VMM patch inventory.
The next checkpoint repairs Windows profile/bootstrap ordering, foreign-root
LSM and temporary-directory construction, and the exact OmniOS release probe;
it preserves diagnostic failures and separate source/build/native/live scopes.
The following checkpoint restores Arch's boot-time root policy, normalizes
actual Hegel lock identities and refreshes all eight dependency snapshots. It
records completed OmniOS and fresh NixOS lifecycles without upgrading failed
foreign-Linux or unrun repaired-Windows acceptance.

There is no new Ash domain/resource, deployment host/service, persistence shape,
authorization grant, wire protocol or guest capability kind. Exact-image
qualification enables only the previously reviewed native subset. The work preserves
[ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md),
[ADR-0171](../decisions/0171-windows-guest-agents.md) and
[ADR-0173](../decisions/0173-windows-images-winget-desktop-experience.md).
The new Hegel frontend checkpoint preserves
[ADR-0191](../decisions/0191-elixir-hegel-property-verification.md), including
its incomplete compatibility and separate execution evidence.
Their recorded decision and implementation statuses remain unchanged.
The existing domain and deployment views require no inventory change.
Windows publication enforces ADR-0171's existing built-once distribution through
the signed cache of ADR-0188. The illumos accept fix preserves ADR-0190's existing
host-only transport while making successful accept wait for RESPONSE publication.

## Findings

The [shared image list](../../../fleet/guest-images.nix) declares NixOS, Ubuntu,
Arch Linux, AlmaLinux, FreeBSD, OmniOS and Windows. Native entries are filtered
by the selected package's `nativeAdmission` flag. Both exact promoted FreeBSD
and OmniOS packages now pass that filter. `omniosGuest` and `illumosGuest`
select the same reviewed OmniOS promotion; stock constructors and candidate
kits retain false admission/runtime flags. The
[current matrix](../../guests/os-matrix.md) separates these seven source-selected entries
from recorded native machine and live fleet execution.

FreeBSD admission remains bound to image
`sha256:d141e4266c29da00a1378157b1d39369b1d48e577bca4ce7375e8ff6d399557b`
and its complete validated manifest or portable descriptor. The compiled
registry, immutable promotion and ordinary current-boot attestation remain the
authority. Changed candidates, stock native identities and an OS name alone
remain refused; editor and Inception remain false. The existing
[admission review](2026-10-17-native-image-admission.md) records the approved
five native scenarios and their limits.

The promotion verifier now compares the exact named service-oracle set, rather
than its length. The immutable FreeBSD approval retains its 22 reviewed checks.
OmniOS requires 25: the shared set plus workspace Git ownership/unrelated-root
refusal, executor current-heartbeat withdrawal and whole-process-group
cancellation with fresh-fence completion. Missing, extra, renamed or incorrect
clean/crash-ending checks refuse, including equal-length substitutions and an
OmniOS receipt using FreeBSD's narrower set. The current promotion unit gate and
actual sealed FreeBSD package build passed; this strengthens evidence validation
without itself admitting an OmniOS image or executing a new native scenario.

Earlier source-qualified OmniOS receipts cover complete services over two clean
boots, three boots with two root expansions and separate process-SIGKILL
same-disk recovery. Those receipts retain `native_admission=false`. No claim of
supervised daemon recovery, formal policy gates, current wrong-CID/reset/DMA safety, direct
native peer-VM or physical-host isolation, interrupted growth, physical
durability, relocation or live fleet acceptance follows. Historical failed
assemblies and service attempts remain in the
[native kernel review](2026-10-17-native-kernel-attestation.md).

The current illumos socket repair makes `sd_accept` wait until the connection
RESPONSE has been submitted, preventing an immediate application close from
overtaking that handshake. Reset, listener closure and an interrupted wait
refuse instead of returning an unestablished child. The extracted production
downcall passed 256 forced pthread schedules under ASan/UBSan; a forced old-code
mutant failed. Strict cross-compilation, native helper/shim checks and 24 image
helper tests passed for kit
`ir4bn13n5yhfs143jh94rv1kpp0355h4`, transport build identity
`cc5b0bd0d40375a5364cbd7a5650fbf14f8fd02c8e3ab8652f1e690e13e7b2d4`.
This host regression verifies ordering, not native interrupt or DMA safety.

The new exact test-only image SHA-256
`aa669e51a6b68b623d432c317c9527367697455fac1e53612cc1b8f3f66c3bbb`
retains kernel SHA-256
`c56dc5c19523ef29511e2bfe4b98a6544b786a089b55b654c30ea32e821bdd21`.
Direct host-KVM execution of maintained scenario runners passed ordinary
transport over two clean boots, the API pause/full-snapshot/resume reset
fixture and two-boot Lilly-policy isolation. The latter service receipt names
all 25 current service checks plus five policy checks per boot. These are
manual direct-host fixtures with unique netns/TAPs, exact sealed disk clones,
pinned Firecracker and synthetic authority; they are not the formal NixOS
nested-KVM gates. Supervised daemon recovery still fails its first
readiness-withheld connection after daemon replacement. Separate current-image
service, growth and process-crash runners passed. Services records 25 checks
across clean boots `29757d82-d279-48be-8459-3d265df77ed0` and
`7089b0e6-5df1-4dfd-9697-d8e841af55a2`; growth records all 25 service checks
across three clean boots `638d6d06-5d6e-4a7a-8e9e-76114ef79ca0`,
`58f92a5d-c269-40d7-ab31-4ab3c1a2af03` and
`cfbf73bb-194d-4fb3-ba42-ad26c8a3ca2c`, with two expansions; crash records 25 service and eight
recovery checks with endings `sigkill,clean` across boots
`1fbe9a12-3c50-41db-bba1-5530a4b7f1dc` and
`68f89a41-217e-4c25-aa97-dc0e7bb4b771`. Earlier image results are not
transferred to these bytes. Admission remains false. No peer-native,
jail/physical-host, multi-host or power-loss guarantee is established.

The follow-up source correction keeps the native agent SMF service's contract
duration and sets `ignore_error` to `signal` only. This lets the shell supervisor
replace an individually killed child without SMF killing the other listeners;
core dumps, hardware errors and an empty contract still use the outer restart
boundary. Assembly and boot verification reject missing, duplicate, broader or
instance-overriding policies. The 25-test native-image suite passed, including
ten refusal mutations for the new semantic gate; Ruff formatting/lint, ty and
contract checks passed. Listener close additionally publishes its closed state
and wakes same-port pending-handshake children under the socket lock, so accept
can refuse without another interrupt or completed connection callback. The
extracted production close/accept regression passed ASan/UBSan and caught a
missing-wake mutant. A killed shell supervisor with surviving children remains
an explicit unverified recovery case.

The combined kit subsequently passed fresh native assembly, including nine
modules, 764 payload records, native SMF validation, clean export, read-only
receipt extraction and administration shutdown. Its 8,589,934,592-byte disk
SHA-256 is `45983bb74f9064f7aeea7d4f934094bd8c4c0efb4e8a2ad7f4bf0a8ee6390554`;
the 158,362-byte assembly receipt SHA-256 is
`aaf9aeeee25b73c6454a395b69b78eb4a207b59dcbcd363b088e8839592edb04`.
Its test-only manifest SHA-256 is
`aac2c4d67684f9e77d1fc7b6b2207b6ae4fc4a3800cfd32170608c9d607d6be8`.
Those assembly records alone granted no admission; the exact-image runtime and
immutable promotion records below were collected separately.

The unchanged `45983bb7` disk subsequently passed all five maintained direct
host-KVM scenario runners: complete services, three-boot/two-expansion growth,
two-boot Lilly router/TAP policy, same-boot supervised daemon replacement and
same-disk process-SIGKILL recovery. Ordinary transport and the API
pause/full-snapshot/resume reset fixture also passed independently. Every
service-bearing receipt records the exact 25-check OmniOS oracle. The final
services receipt SHA-256 is
`b8fc867e0d1e5484c05da231bb5012ae00411937320ae91e0764be296efb30de`,
with clean boots `eba79645-1cd5-479d-a035-9b2aa24bcd4f` and
`8620cb2b-a7ac-4aed-9f9a-547458f740f4`. Recovery observed real daemon death,
three withheld-readiness probes, an exact supervised replacement and restored
current-boot flush without changing the guest boot identity. Growth preserved
the pinned pool/vdev and foreign-disk identities. The crash receipt records
`sigkill,clean`, fresh authority/boot identity, exact retained bytes and native
ZFS integrity checks. All candidate execution receipts retain
`native_admission=false`; qualification is the separate immutable review step.

The final reset receipt SHA-256 is
`02f0ed8e2c0a7146d16a93a5e0f5f7fe9887174c784df1b603d0d4a62a64fb1d`,
boot `c3e2cf85-4e50-4e2e-ac48-5037628e052f`. All three API operations returned
204; pending read, accept and idle operations refused with 131 and the blocked
write with 32 after 262,144 bytes. The current CID was revalidated. This is one
transport-reset event, without service-restoration or DMA-safety evidence.

The reviewed version-6 manifest is
[`protocol/priv/native/omnios-r151050.json`](../../../protocol/priv/native/omnios-r151050.json),
image ID
`sha256:98b23b7931bc52d55b3c5b38cc20c97c1c967be96cf301940f88b01c715530d8`.
The manually assembled input is sealed at
`/nix/store/9r92hvbj5zch8r0xdv4wsw7rhhwg6as7-overalls-native-omnios-r151050-45983bb7`,
recursive NAR hash `sha256-JrTq1siY+meAVhpqYBdddLVgs+eagD79taqn+wZivsU=`,
with no references. Local exact-NAR comparison, public signed-cache import and
independent Dungarees substitution/content/signature verification passed. The
[OmniOS promotion constructor](../../../nix/domains/artifacts/guest/native-promotion/omnios.nix)
passed its exact artifact/evidence verifier and produced
`/nix/store/8lckqimfchbk5p21n3qb3s09byx4dr1q-lilly-omnios-r151050-x86_64-promoted`,
containing only `disk.raw`, `firmware` and `manifest.json`. The compiled registry
now qualifies that complete immutable identity and its normalized descriptor;
changed identities, cross-family descriptors and stock agent names still refuse.
The unqualified native capability rows, editor and Inception remain false.
The later source activation points both fleet aliases at that exact promotion;
it does not admit unrelated candidates or establish a deployed live guest.
The catalog evaluation, 15-check promotion gate and actual exact promoted
package build passed for that source activation. Evaluation binds image
`98b23b79` and true promotion flags, identical OmniOS/illumos aliases and false
candidate-kit flags. The existing promoted output is unchanged. The record is
`/tmp/overalls-osmatrix-omnios-catalog-gates.log`; selected-release host builds,
deployment and live CLI acceptance retain independent records.
These records satisfy the existing per-image promotion requirements without
claiming reproducible native assembly, formal nested-NixOS execution, a direct
native peer VM, jail/physical isolation, interrupted growth, shell-supervisor
death with surviving children, physical power loss, relocation or live OmniOS
fleet acceptance.
The promoted output has recursive NAR hash
`sha256-qKv00aAEuM+ObUg2GpzEvepykgDpn3EE9aoG3EKWAhs=` and no references.
The published candidate contains no test probes, synthetic keys, logs or runtime
clones; probes were installed only in owned disposable clones. Its declared
minimum is 2 GiB memory and 16 GiB disk. Recorded growth is the deterministic
8-to-10-to-12 GiB expansion history, separate from a live 16 GiB launch. The
kernel digest identifies the kernel executable; the assembled disk digest binds
the nine installed modules.

The final runner uses an explicit owned Firecracker `--log-path`: the default
logger writes stdout even when stderr is redirected, so splitting only stderr
could mix VMM text into the guest JSON stream. Startup stderr and serial stdout
now have separate files. The reset parser waits for a newline before accepting
even a valid final JSON fragment; malformed or duplicate complete events still
refuse. Four focused reset regressions and an old-parser mutant established the
boundary. Native terminal verification now closes the completed initial control
before PTY work and gives resize/retire fresh authenticated 15-second controls;
the data channel keeps its own 15-second limit. A controlled-clock healthy
18-second history passed, a 16-second data timeout still refused and the actual
old-helper mutant failed. Retirement failures fail otherwise successful probes;
secondary cleanup failures preserve the original failure without payloads.
These fixture fixes change no guest bytes and do not classify the preserved
earlier PTY failure. The final native-fixture gate passed 87 checks, 31 additional
focused checks passed, promotion tests passed 15 checks, and pinned Ruff
format/lint plus ty passed on all Python files. Six focused protocol checks,
including the 64-case identity-substitution property, passed; full exact-source
protocol and consumer gates retain separate records.
The exact-source protocol full precommit is recorded below; the five-scenario
native execution scope remains separate from that BEAM validation.

The follow-up mounted-root helper also removes dependence on an early-boot
persisted ZFS userland cache. Read-only label discovery uses
`zdb -C -e -U /dev/null -p /dev/dsk` for the fixed root pool. Assembly pool GUID,
the exact single whole-disk vdev, canonical device path, raw-device custody,
capacity and both GPT copies remain prerequisites before mutation. Three natural
failures stopped at the old `zdb` child exit before mutation. A controlled
missing-cache diagnostic on a disposable clone removed only its root-owned
regular cache: the old query failed with the missing-file class and no pool
configuration; the revised helper passed preflight, native expansion, post-GPT
preservation and the volatile success receipt. This is one same-boot diagnostic
fault case, separate from fresh-image three-boot growth, interrupted expansion,
physical recovery and admission. The full Lyra Nix gate also passed in 224
seconds; its host tests, lint and target checks do not establish native growth.

Arch/Alma evaluation checks establish their separate pinned root sources,
version-4 identity and installed offline agent/service closure. They do not
establish either distribution's Firecracker boot or runtime behavior. An audit
found differing foreign-Linux ext4 bytes at the same declared Nix paths on the
two hosts. The construction now derives sizing from regular-file/symlink content
instead of host-dependent directory sizes and fixes source times, filesystem
hash seed and filesystem mutation clocks. Image construction and
`foreign-linux-guest-unit` evaluation passed. Actual rootfs
`nix-store --realise --check` rebuilds also passed for both outputs, separately
from an image-wrapper-only rebuild:

| Rootfs | Bytes | SHA-256 |
|--------|-------|---------|
| `/nix/store/1w979vhp7ql5bdlbfawggaw9rqvixycd-ext4-fs.img` (Arch) | 2,289,811,456 | `f5ea8703eb558211b65939e0121e84699edc5a4f85995ce2db2be0a6d54b3376` |
| `/nix/store/abvfphcmdf8wsl7kzf7zv9hhkf1hgy12-ext4-fs.img` (AlmaLinux) | 2,555,826,176 | `8811a0a08ea2a9a9c181310fd9df7cef78f2284160b659532c4af8c99a846eb2` |

These historical comparisons precede the final copy and SSH-policy changes.
A later cross-host Arch comparison failed: store optimisation had changed
incidental hardlink topology, which changed ext4 inode allocation despite the
same source paths. Both base-root and closure copying now explicitly discard
hardlink topology. The final fleet-context cross-host comparison passed on
Dungarees after signed Overalls Cachix substitution and actual local rebuilds:

| Family | Rootfs derivation | Compared output |
|--------|-------------------|-----------------|
| Arch | `/nix/store/b95hz1ikv93rc4nlfv0s3yz43vk8s9r3-ext4-fs.img.drv` | `/nix/store/galrn1ln1arp3c539dvkr535flfp2q6w-ext4-fs.img` |
| AlmaLinux | `/nix/store/6a376plmpddg8mhh02q1w2cim46iad9k-ext4-fs.img.drv` | `/nix/store/nxmyvyg5s43r7nicbz69rzdnvqnnh40y-ext4-fs.img` |

`nix-store --realise --check` returned exit 0 for both actual rootfs outputs.
Arch measures 2,325,372,928 bytes, SHA-256
`750e1bcbb607e0d96aeb270c27172713d44ec29b53d2ce01a8d72c9c06aa6662`;
AlmaLinux measures 2,684,354,560 bytes, SHA-256
`21e62216428509310cefd13f2d992a5fba926c83e9eed8c88c380f5eb5b77682`.
This historical comparison covers those fleet-context construction inputs, including
the copy and SSH-policy corrections below. Native guest execution remains a
separate requirement.

The foreign-Linux audit also replaces vendor-dependent SSH includes and PAM
stacks with a complete owned key-only policy and pinned absolute PAM modules.
Opening an SSH session requires the private current login receipt. Dedicated
locked `sshd` and `overalls-ssh` identities are allocated without UID/GID
collisions; NSS account lookup uses local files. Reconciliation has explicit
pinned account tools and PATH. Sudo is a root-owned regular mode-4755 image copy,
with per-user policy supplied only by the existing roster reconciler; a
non-setuid Nix-store symlink cannot provide that behavior. Vendor sshd service
enablement resolves to the same readiness-gated listener. Account-allocator unit
coverage, evaluation and inspection of both actual ext4 outputs passed. The
filesystem inspection verified regular root-owned mode-4755 sudo, distinct locked
service identities, pinned executable tools, SSH/PAM policy, private login
receipt requirement and unit PATH; its digest/outcome record is
`/tmp/foreign-linux-final-filesystem-audit-20261018.json`. These checks do not
establish a successful Arch/Alma boot, PAM session or sudo invocation.

A subsequent six-image artifact audit checked every manifest, native admission
result and actual file length/SHA-256, including the 64 GiB Windows disk. The
then-current Arch and Alma roots also passed independent Dungarees rebuilds with
Nix 2.34.8, empty builders/substituters and `nix-store --realise --check`:

| Family | Compared rootfs output | Bytes | SHA-256 |
|--------|------------------------|-------|---------|
| Arch | `/nix/store/g8ll63iw4fqhvwbiak0z0pp92wv19xfp-ext4-fs.img` | 2,325,372,928 | `424736943bee56855eddc242b24ccdb56b35bd3ec548b6f0dda678bdcfc50539` |
| AlmaLinux | `/nix/store/03l6nbi3ni4dqbfc7q615slj3nc09ifb-ext4-fs.img` | 2,684,354,560 | `46c98944ee61cd042e02f61ca1eff46c13b3c9f97da1629822f6513bdb89e1ce` |

The receipt is
`/tmp/overalls-final-fleet-images-20261018/cross-host-reproducibility-receipt.json`.
These exact-byte comparisons did not establish a bootable distribution root:
live creation of both images subsequently reached `/sbin/init: Permission denied`.
The shared upstream-root copy discarded source modes, leaving systemd, its ELF
loader and bash at 0644. The original failed VM identities and diagnostic
receipts remain retained. A narrow correction preserves upstream executable
modes and grants staging write access only to the build owner. The actual
private-fleet filesystem gate passed in 58 seconds, inspecting both
init/bash/loaders at 0755, release data at 0644, sudo at 04755, shadow/gshadow
at 0600 and root ownership. Both original images separately failed this gate at
bash mode 0644. The corrected Arch image ID is
`sha256:fc437aea09e700c617afa6d45a7c76c94fbf071b60c5a7d9d44477847ed68778`,
root SHA-256 `4a12184a5c207ea8d1fa003f7b8e39e7bb236de50ddb0e3e16837a19831a000a`,
2,325,372,928 bytes. Alma's image ID is
`sha256:f91eaf37e427c28e3529ef9f26ec0e3bb4b4134d1bd2268add1f31fb4d6cac7b`,
root SHA-256 `8cc93fb7ace0889cfeb6518590aa2248e80494941a61fc8368b35ff6709b7b05`,
2,684,354,560 bytes. Evaluation and contract checks passed. Corrected-image
cross-host rebuild and runtime acceptance remain separate; prior rebuild
results do not transfer to these corrected roots. The corrected images then
passed fresh actual file SHA-256/length and complete offline policy audits,
plus forced Dungarees `--check` rebuilds with independently matching remote
hashes. Records are under `/tmp/overalls-corrected-fleet-images-20261018/`.
Their later failed live creates are recorded below and do not inherit offline
success. The next source repair explicitly selects `lsm=landlock,yama,bpf`,
matching the evaluated NixOS manifest (the Ubuntu manifest does not currently
declare an LSM parameter). The assembled foreign roots lack the distribution's
SELinux labels, so the distro policy must not activate against that root.
This selects the guest stack without changing host jailer, network, protocol
or capacity authority. After general write-mode normalization, the builder
also restores real root-owned `/tmp` and `/var/tmp` directories to 01777;
accounts can create temporary files while the sticky bit protects other
accounts' entries.
The actual private Arch/Alma artifact gate passed in 57 seconds, inspecting
the final manifest and ext4 directory/file modes and ownership. A manifest
without the selection failed the LSM check; substituting the previous Arch
ext4 while preserving a valid new manifest failed the `/tmp` directory-mode
check. The evaluation and contract/format checks passed; logs are
`/tmp/overalls-foreign-linux-boot-{check,contracts,old-alma-negative,old-arch-tmp-negative}.log`.
These are offline artifact checks, without a repaired-image boot or readiness
claim. The exact Arch readiness sandbox diagnosis remains in progress.
The combined final source, including the Windows repair and current Hegel
pin, then passed both actual private Linux filesystem/manifest and evaluation
gates in 167 seconds; log
`/tmp/overalls-osmatrix-final-foreign-linux-artifact-checks.log`. That combined
artifact result remains separate from repaired-image runtime acceptance.

Windows
has a current 64 GiB Desktop Experience catalog image and 96 GiB template
budget; its latest recorded stop attempt hung, so a complete current-image
stop/restart/delete pass remains open. The Windows guide now distinguishes
that image from the historical agentless spike.

The audit also observed different Windows bytes at the same input-addressed
source-derivation path on the two hosts. The fleet selector now uses
`windowsGuestPublished`, a recursive-hash fixed-output directory sealed from the
existing registered `windows-v1` image. The source installer stays available for
development. The selected directory has exactly dereferenced regular `disk.raw`,
`firmware` and unchanged `manifest.json`, with no references. The fixed-output
fallback only prints publication guidance and exits 1; it cannot reinstall,
read a host-local image or weaken signature checks. The
[Windows guide](../../guests/windows-guests.md) records the exact path, NAR/root
hashes and update procedure. Package resolution, artifact/file custody,
declaration and fallback refusals passed. The public Overalls Cachix narinfo is present for the
exact `nh6wfp35zm8wpdjgkvms7dlwkr1pwbgr` path, signed by the reviewed cache key;
its compressed NAR is 17,099,050,377 bytes. Both hosts now hold the exact sealed
path with the same recursive NAR hash, NAR size 68,723,672,224 bytes and no
references. Both imported the public cache signature and passed
`nix store verify --no-contents --sigs-needed 1`. This establishes signed cache
publication and cross-host custody, separately from runtime acceptance.
This is an artifact-identity correction and grants no new
Windows runtime guarantee.

The [Porsche acceptance guide](../../acceptance/porsche-acceptance.md) describes
the explicit-image matrix workflow. The runner retains private resumable
evidence and exact fixture ownership. Its implementation and host-side tests
cannot substitute for a live guest execution record. No live seven-OS pass is
recorded, and the runner must not bypass unavailable OmniOS admission to obtain
one. Inception is known broken and outside this work.

The first NixOS, Ubuntu and FreeBSD matrix creates in the private
`/tmp/porsche-20261018-071500` run failed with `template_quarantined` before guest
execution. The NixOS failure exposed a runner-ledger gap: accepted creation identity now persists
before polling, and failed/superseded terminal receipts remain available for
owned reconciliation and cleanup. Read-only reconciliation retained the original
VM/request rather than issuing another creation. A failed retry-start was
superseded by successful `failed-create-cleanup` receipts for all three original
fixtures. This failed creation run establishes no guest execution.

The separate private `/tmp/porsche-20261018-072900` run created NixOS
`b4e446ac-d45e-4a82-8a83-4b043da5e305`, Ubuntu
`79d8e4c5-ad65-4838-8ec8-0b740adec9b9` and FreeBSD
`7f99f396-dd70-4b57-a8e4-4446c7ab3d57`. Each passed `matrix-ssh --stage initial`
through the installed Overalls CLI with the exact OS oracle, then passed
`matrix-stop --stage orderly-stop`; durable state confirmed stopped generation
2. `matrix-start --stage restart` and `matrix-ssh --stage after-restart` then
passed for all three. `matrix-cleanup --stage final-cleanup` then returned deleted
receipts for all three owned fixtures.
An unrelated existing VM received a read-only SSH probe only. No complete
seven-OS lifecycle, all-capability, revocation or independent physical cleanup
claim follows from these subset results.

The later `/tmp/porsche-20261018-075200` six-image run used deployed revision
`f5ce1e6c67593040d0523ecc81b8b84c8977cdcb`; its 09:11:49 UTC structured
snapshot is `acceptance-ledger-snapshot-091149.json` in that private directory.
NixOS `226555b3-1fb5-47cf-b9d2-cd238135a36d` and Ubuntu
`45f93d2c-b354-4696-8b84-0a795761974e` passed create, initial exact-OS CLI
SSH, orderly stop with stopped-state checkpoint, restart, repeated exact-OS SSH
and terminal deleted cleanup receipts. The NixOS restart reconciled the original
request after a transport failure. Original Arch
`cfb76a7d-e67b-4a0f-aa4e-2b2f700d4c72` and Alma
`f1196e0a-c3c6-4531-a5f2-5f72a338dc4a` failed before init on the mode-stripped
images; their later stages were not run, and their original identities and
failed receipts are retained.

That run's FreeBSD `cbf81155-470c-407e-a0f0-5132f2a03daa` passed through
restart and repeated exact-OS CLI SSH. Its original cleanup request first
remained unsettled: desired state was deleted, observed state unknown and the
failure was `cleanup_failed` while the maintained ZFS destroy namespace sweep
could not confirm absence. The reconciliation poll ended with a management
`transport_error`, rather than a successful deleted receipt or deadline
exhaustion. Investigation found the exact dataset retained in a rootless
Podman mount namespace. Retirement was initially refused while unrelated
containers were active. After fresh proof of zero active work, normal idle
context retirement released the namespace; `SendSIGKILL=no` prevented forced
termination and the pause process exited naturally. The external storage
container remained intact. The unchanged cleanup helper then reconciled the
original request to `succeeded`/`deleted`; the VM was archived at 09:38:41 UTC
with no failure reason. The private `matrix-final-six-cleanup-freebsd.json`
receipt records that terminal outcome. No forced unmount, migration, database
repair or replacement intent was used. This closes the recorded fixture's
lifecycle after operational recovery, without establishing independent
physical cleanup or automatic recovery for other namespace holders.
The inspected transient context started at 08:55:11 UTC; it explains the
later observed blocker, not necessarily the earliest 07:52 cleanup failures.
Its private manual operational audit is
`/tmp/overalls-osmatrix-freebsd-cleanup-recovery-audit.json`, SHA-256
`fbec957e7ca328cd39423e48d30d935ecc98d281b7f294fda7a2db07b8841084`.
The audit records zero active runtime processes/API clients, nine mounted
storage paths with zero process users/errors, preserved storage records,
normal service retirement and an exact post-retirement namespace inventory
with zero matches/errors and confirmed dataset absence. It is not a native
machine-test receipt. Existing recursive-private propagation does not remove
already copied mounts; preventive pool-free rootless namespace creation
remains unimplemented.
The terminal receipt SHA-256 is
`1996c8eaca49b2053f625cf722c94f365cd58065d0c35a84547d7f23815506ba`.

Windows `c8149dc5-eff4-4bed-8ab0-2f6965edb025`, image
`sha256:e9ed22f19485315066bc5527ebd207fce8cd7d7fa4c0854a963c58ffa5361d73`,
created and reported running with `guest_ready=true`, but its initial CLI SSH
attempt exited 255 before a remote banner. Read-only diagnosis found sshd
stopped with no TCP/22 listener and SSH-sync reporting `pass_failed`, despite
an existing roster account and enabled inbound TCP/22 rule. The owned fixture
was retained for diagnosis; later lifecycle stages were unrun. That ready flag
does not establish SSH access. A later owned-fixture native diagnostic isolated
`CreateProfile`: the original 4,096-unit output buffer returned HRESULT
`0x800706f7` (Win32 1783) without registering a profile; the `MAX_PATH`-sized
260-unit call returned `S_OK` and created the SID-bound profile. The existing
agent then enabled the account, installed one key file, started sshd and
retired the bootstrap Administrator. The private
`windows-profile-diagnostic-receipt.json` marks `fixture_mutated=true` and
`unchanged_image_lifecycle_acceptance=false`. This is a manual API diagnosis,
not an unchanged-image SSH or lifecycle pass; a rebuilt, sealed image still
requires its own acceptance.
The diagnostic receipt SHA-256 is
`e0a1225693a09e5a1a9d4eca1e52bf5b89f07205f480dd3d25cb98c821ab3239`.
The integrated Windows repair uses the bounded profile call and verifies the
SID-bound registered directory before activation. Its shared
[`ssh_bootstrap`](../../../lyra/src/guest/ssh_bootstrap.rs) coordinator clears
prior keys before first listener startup, requires a verified current-boot
host-certificate receipt and publishes bootstrap readiness before ordinary key
delivery. Every readiness response also requires the two current receipts and
live sshd. Same-boot retries preserve current keys. The four-field running-VM
and completed provision/start key-delivery authority is unchanged; neither
the roster nor host-certificate bootstrap route acquires key authority.
This implements ADR-0171's existing boundaries without a replacement decision.
The frozen source patch SHA-256 is
`8946bd954ca2b3a716cb46dfe1d13707a5cd3a7b04ef41c7591e9d74d0661455`.
Its sandboxed Lyra gate passed in 197 seconds with 223 portable tests,
Linux Clippy, Windows all-binary type checks and FreeBSD/illumos checks and
Clippy; log `/tmp/overalls-windows-profile-bootstrap-frozen-lyra-check.log`.
The portable cases cover actual readiness answers, pre-completed-start key
refusal followed by successful retrieval, stale-key cleanup refusals and
same-boot preservation. They do not execute Windows SCM/profile APIs or a
fresh sealed image. The new Windows installation and its full live lifecycle
retain separate evidence.
A separate 64-second sandbox mutation gate caught both retaining prior keys
and allowing a readiness answer without the current marker, log
`/tmp/overalls-windows-bootstrap-negative-check.log`. The mutation build did
not change frozen production or image inputs.
The combined final source's multi-target production Lyra release also built
successfully in 318 seconds, log
`/tmp/overalls-osmatrix-final-lyra-release-build.log`. A linked release does
not establish execution of the new Windows installation.
The subsequent actual installation passed in 1,834.2 seconds with QEMU/result
zero and all required markers. Readback of the three repaired executables from
immutable NTFS matched the reviewed payloads. The sealed exact image is
`sha256:8ca0a11fd0063dc3f3bb7e4eb928dcb7083da08be4e72ba8ef9e56de911c5d5c`,
with recursive NAR hash
`sha256-MTpVti0Mc+c3FzqjUJLfBAfEIW+plgP+HheZnVdPlUo=`,
68,723,672,224 bytes and no references. Private installer, installed-custody,
manifest and seal receipts are under
`/tmp/overalls-windows-profile-bootstrap-*`. Scoped signed publication then
passed in 418.446 seconds, followed by public narinfo retrieval and actual
Ed25519 verification of the exact NAR fingerprint, including store path, hash,
size and empty references. Receipt
`/tmp/overalls-windows-profile-bootstrap-publication-receipt.json` has SHA-256
`eed8f20592a39abc7a99c77e8ef3bc70ae3a515fa9f0582aa8c529e2be65f442`.
The first urllib fetch returned a client-specific 403; bounded TLS curl fetch
passed with the same signature checks. Independent full-content Dungarees
substitution, selected-image deployment and clean physical lifecycle acceptance
remain pending; the old mutated fixture does not verify these new bytes.
The separate corrected Arch/Alma qualification
ledger `/tmp/porsche-20261018-085815` later created Arch
`10ce2f77-7be8-4dea-9f8c-3171dac34b0c` from image `fc437aea` and Alma
`746ad956-f800-4e32-80bc-cf98af6c57c4` from image `f91eaf37`. Both original
create requests ended `failed`/`execution_failed`. Arch reached running units
and an SSH listener, then failed the readiness budget; Alma encountered
SELinux policy and `/run` mount-context denials. Their corrected mode and
artifact-custody checks do not establish readiness or any later lifecycle
stage. Further source/image repairs require separate runtime results.
OmniOS is outside the six-image ledger. No complete six- or seven-OS pass
follows.
The separate `/tmp/porsche-20261018-091638` OmniOS ledger completed its original
create request for `b04f2400-fc7a-4fe5-8a92-dd7c441e98f2` after both consumers
converged healthy to `b17d6beec`, using exact promoted image `98b23b79`.
The original `matrix-ssh-omnios-promoted-initial-omnios.json` recorded actual
CLI transport exit zero but failed the OS oracle: the probe omitted the real
`OmniOS v11 r151050` label and produced only `SunOS`. That failed attempt is
retained. A narrow probe correction normalizes the pinned `v11` label to the
existing canonical `OmniOS r151050`, preserving exact revision refusal.
Its executable shell regression refuses the wrong revision, version and
vendor. The updated suite passed 24 checks; narrowed Ruff/ty/contracts and
all-files pinned Ruff, Ruff format and ty passed. Logs are
`omnios-oracle-source-checks.log` and `python-all-files-static.log` in that
private ledger.
The same VM's explicit `initial-v11` stage then passed the exact OS oracle
through actual CLI SSH, exit zero, 21 output bytes and SHA-256
`2c45e839af8de414f3acdb6b514c9902ec09ef927545bd82f6146a6dd5a1fece`.
Its orderly stop, original restart, repeated strict CLI OS identity and owned
cleanup then all succeeded, ending with a terminal deleted receipt. Stop is
proved by its terminal stopped receipt; no separate pre-restart show-state or
physical checkpoint was recorded. The immutable private summary is
`qualification-summary-100056.json`, SHA-256
`4bd27971eee5547ccedff2ba77d50aa2972f00d000e7cb05bdc0cddaaecd3132`.
This establishes one ordinary 16 GiB exact-image live lifecycle at `b17d6beec`,
separately from the native growth/policy/recovery scenarios and physical
isolation or reset stress.
Its promoted-artifact proof passed the shared schema/admission validator and
fresh full 8 GiB disk/4 MiB firmware hashes against the reviewed manifest.
Artifact custody, creation/readiness, exact CLI identity and later lifecycle
stages retain separate evidence scopes.

Both actual-host toplevel builds for the combined repair checkpoint
`870eecef53c5627b517974e5367069a068cd4b8a` passed in 357 seconds, log
`/tmp/overalls-osmatrix-870-hosts-build.log`; both auto-updaters confirmed
healthy exact-release convergence with zero failures at 10:10 UTC.
The combined Arch/Alma actual ext4s and image wrappers also passed forced
independent Dungarees `--check` rebuilds with builders and substituters disabled.
Remote rootfs and manifest hashes matched local outputs; manifest-file hashes
are distinct from canonical protocol image IDs. The receipt is
`/tmp/overalls-combined-linux-images-20261018/cross-host-reproducibility-receipt.json`,
SHA-256 `1c0ee9ab412c06c33555e18a9ebf445f1cbf80a2efb4db0f1e7e55c2b10989f2`.
These build/custody results did not establish guest readiness.

The final `/tmp/porsche-20261018-101111` custody audit independently validated
the actual selected artifacts and canonical identities. Ubuntu retained its
previous exact `8d468c67` image despite a wrapper-path change, so its recorded
`075200` full lifecycle is retained with fresh custody evidence. The changed
NixOS `92114604` image's VM `40e03d8b-b369-43e7-9f1e-faf72dfabfc2` passed
create, strict initial CLI identity, terminal stopped plus a separate current
owner stopped-state checkpoint, restart, repeated strict CLI identity and
terminal deleted cleanup. Final Arch `e2f67fe5` VM
`05406661-2b26-4d91-97fc-29d1cf87cd48` and Alma `43b08259` VM
`abe3258e-86a0-4956-adeb-2629720d5c37` both returned terminal `execution_failed` creates; no foreign SSH or
privilege smoke passed. The private `qualification-snapshot-102335.json`
retains the actual receipts, unchanged-Ubuntu proof and failed creates.

The exact Arch same-boot diagnostic found root mode 0555 and a capability-free
root process receiving `mkstemp` EACCES, despite immutable root mode 0755.
The preserved vendor `/usr/lib/tmpfiles.d/root.conf` contains `z / 555 - - -`.
An Arch-only higher-priority `/etc/tmpfiles.d/root.conf` now applies
`z / 0755 root root -`; it leaves the vendor file, capabilities, recursive
ownership, readiness checks and host authority unchanged. Actual private
artifact/evaluation gates passed in 63 seconds; the original exact image fails
the new gate for its missing override. A guarded scratch execution using the
pinned systemd-tmpfiles and exact extracted policies reproduces old root 0555
with capability-free `mkstemp` errno 13, then proves root 0755 and successful
write/flush/fsync/unlink with the override. Receipt
`arch-root-policy-runtime.json` in the combined Linux ledger has SHA-256
`64bfc6cd57b03b6a968664c90fab89d54a80f4f72524ad94336e866197c733f8`.
The final exact-artifact audit confirms the combined evaluation selects
`sha256:8ab89c2d0e0f679ef2f43fdd849b1d750d1ca24948ca5413c05913e17493801c`;
it checks the actual filesystem, manifest hashes and copied native executable
custody. Receipt `arch-root-policy-artifact-audit.json` has SHA-256
`8a4ace58fc62d81cbbb5231015eb40696c96dc2c5c21aab9b43c1f5652cef5a7`.
This is actual artifact and isolated policy execution evidence; a fresh
repaired-image production boot and lifecycle remain pending.
The exact Alma fixture separately passed capability-free root write/fsync,
network and growth predicates, but `systemd-resolved.service` was absent.
Dependent private DNS/readiness/SSH units therefore remained inactive. The
closed `alma-final-{readiness,units}-diagnostic.json` receipts preserve that
cause without changing its original failed create or proving guest SSH.

The private Alma-only repair now installs the existing pinned resolver service,
both sockets, D-Bus policy/activation and exact sysusers configuration. A
dedicated `overalls-resolved-identity.service` invokes only that configuration
after remount/vendor sysusers and before sysinit, D-Bus and resolver startup;
the resolver requires and follows this bootstrap. Vendor sysusers conditions
and unrelated account configurations remain intact. Eight regular files and
five activation links are checked byte-for-byte with root ownership and modes
in the actual immutable ext4; the old image is rejected specifically for its
missing resolver runtime. Final private filesystem/evaluation gates passed in
44 seconds. The Arch derivation is unchanged, and there is no new host service,
domain/resource, wire contract, capability or authority grant.

The repaired Alma candidate is
`sha256:bed87c331fae5fbd3669646765f21af7c9631498e3c8cef5d19952f55714dc33`.
Its actual-artifact audit checks the manifest, copied native executables and
exact pinned resolver/sysusers/nologin ELF bytes, including root-owned 0555
executables inside the copied Nix store. Private receipt
`alma-resolver-artifact-audit.json` in the combined Linux ledger has SHA-256
`e22bab6bda53887a9650c4e9f4e67f40b0227f2a68f3c130c749589bc175f98e`.
Independent Dungarees forced root and wrapper rebuilds with empty builders and
substituters passed, and remote root/manifest hashes match local immutable
outputs. The combined source selects those exact Alma outputs and preserves
the Arch derivation. Receipt `alma-resolver-cross-host-receipt.json` has SHA-256
`48495dc6264e4d05f6ec0e95b9990fe6b8b898e26751b94c4222cb53cfcee488`.
Isolated pinned sysusers execution using copied Alma account databases creates
only a locked nonroot resolver UID/GID 992, preserves every unrelated account
row and reruns byte-idempotently. Receipt `alma-resolver-sysusers-proof.json`
has SHA-256
`16086d0b7f231a2b17c0b41ed4a9ab316ec32cdfd80bbe77aaeca414c6f4afe2`.

The native Alma systemd 257 parser also accepts the exact pinned systemd 261
resolver service/two sockets and the actual built identity unit/drop-in with
zero unknown/invalid settings, ordering cycles or shared-library failures.
The isolated extracted scratch still reports eight missing executables; this
is parser compatibility evidence without daemon execution. The v2 receipt
`/tmp/alma-systemd-parser-20261018-1053/native-parser-receipt-v2.json` has
SHA-256 `9bd222f8a940488a1a8121013716cf5d8ca4ef3fc38d94d0e7fa0f1aea276973`,
and retains the original narrower v1 receipt identity. Artifact/build, sysusers
policy execution and parser results do not establish a fresh production guest
boot, resolver/D-Bus activation, strict CLI SSH or the repaired-image lifecycle.

The same ledger's later strict idle-namespace recovery preserved the original
cleanup intents. Both the user Podman service and exact pause scope received
normal SIGTERM under temporary `SendSIGKILL=no` guards only after fresh zero
ordinary containers, runtimes, API clients and storage users/errors. Namespace holders
then reached zero without forced signals, unmounts, migration, storage removal
or database writes; the external storage record remained intact. All 15 known
historical fixtures subsequently reached terminal deleted receipts with no
visible historical fixtures or missing cleanup. The durable manual audit is
`/tmp/overalls-osmatrix-idle-namespace-cleanup-recovery-audit.json`, SHA-256
`df26f04459beaecbbe2c9fab54606b8ba695f97b483d0b4aabb4d7ff7cfe995c`.
The two current failed foreign fixtures remain separately authorized for
causal diagnosis. Original failed creates, SSH attempts and transport failures
remain failures; this manual recovery is not an automatic or independent
physical cleanup guarantee.

## Consumer verification prerequisites

Initial consumer repairs used Hegel frontend `9b13af8`; the repaired consumer
checkpoint selected ref `02cd8bd`, resolved as
`02cd8bd5bf07a7ca1bfaf7d599456fff5badbfa2`.
The source locks were normalized to that full resolved commit while retaining
the requested ref. Source/fixed-output lock snapshot comparison and hash refresh
retain separate verification records. All eight actual Mix dependency outputs
now match their current source lock snapshots and configured recursive NAR
hashes. Six rebuilt outputs passed; Brady and Galileo retained their matching
outputs, and the Cargo hash is unchanged. This corrects source/artifact custody
without selecting new dependency bytes. The
historical protocol pass at `2c9f7a4` verifies neither pin. The first Marshall full test attempt (seed
836760) was killed with exit 137 during compilation. The pinned context-pattern
`property/3` macro recursively rewrites identifiers without reaching a fixed
point. Twenty-nine affected declarations across twenty Marshall test files now
use ordinary ExUnit declarations tagged `:hegel`, retaining their one existing
generated check, all generators, fixtures and oracles. These consumer repairs
change no production behavior, transport or authorization interface.

Both actual-host NixOS toplevel source builds subsequently passed in 691
seconds with the canonical dependency locks and native-growth correction. This
establishes release/build closure for those source inputs, separate from later
handbook-only rebuilds, deployment, live readiness and guest runtime acceptance.
A later pair of actual-host source builds at `d388cf91a` passed in 264 seconds.
That result likewise establishes build closure, separately from later merged
source, deployment and guest acceptance.
The frozen registry/foreign-mode source on merged `21831915e` then passed both
actual-host toplevel builds in 247 seconds, recorded in
`/tmp/overalls-osmatrix-registry-hosts-build.log`. The merged presentation checks
also passed, including nine JavaScript tests. Later handbook compilation and
deployment retain separate records.
The merged first batch `c420650b2` subsequently passed both actual-host
toplevel builds in 233 seconds, log
`/tmp/overalls-osmatrix-merged-registry-hosts.log`, and both consumers converged
healthy to that exact release before catalog activation. That release still
selected six entries. The later OmniOS alias activation is a distinct source
change requiring its own build, deployment and live records; no guest outcome
is inferred from the consumer convergence.
Both actual-host builds for the selected seven-entry catalog at `008a02331`
then passed in 291 seconds. After merging the caption and crawler policy,
both actual-host builds at `b17d6beec` passed in 263 seconds, recorded in
`/tmp/overalls-osmatrix-omnios-merged-hosts.log`; both consumers converged
healthy to that exact release. This establishes the selected-release build
and deployment scope, separately from live OmniOS or other guest acceptance.

The handbook unknown-ID property separately corrects a discarded compatibility
filter: a bounded UTF-8 generator actually excludes listed chapter IDs, draws
silently through the native test-case boundary and checks direct/traversal
refusal in 100 cases at seed 20261018. Fixed observability tests remove unused
Hegel imports. A capped focused execution passed all eight handbook/observability
tests (ExUnit seed 465575). Compile-only discovery then exposed unsupported
tuple-destructuring and single-line `gen all` forms in the distributed capacity
generator; explicit tuple/map/bind composition preserves its operation variants,
weights, key ranges and four-to-seven batches of two-to-four operations. Full
current consumer outcomes remain separate records. These are BEAM verification
repairs and establish no native guest or deployment guarantee.

After merging frontend `02cd8bd`, the view-inventory suffix generator was made
explicitly uppercase, and enrollment GUIDs compose two 32-bit halves to retain
all nonzero unsigned 64-bit values. Unknown enrollment keys use a real filter.
The three-case TLS histories use the native `test_cases` option; each actual
fifteen-second silence history runs separately so expected runtime does not trip
the cumulative slow-input health check. No deadline or assertion was relaxed.
The three-file focused rerun passed all 17 tests in 97.7 seconds, ExUnit seed
43955, with warnings as errors on the full resolved frontend commit above.
This covers the maintained view inventory, enrollment parser and real loopback
TLS peer fixtures; it does not establish a full consumer gate or native guest.

The subsequent count audit replaced 158 ignored `max_runs` option names in 107
Marshall test files with native `test_cases`, retaining each literal value.
Ninety-seven plain outer properties also receive the identical count so their
existing per-case fixture and replay boundaries remain intact. Normalized AST
comparison preserved every other body, generator, assertion and option value.
Compiler, contract and logging checks passed; a temporary native counter probe
observed exactly three executions from an outer `test_cases: 3` property.
Full current-source execution remains separate. One pre-existing distributed
admission `max_shrinking_steps: 0` option remains unsupported by this engine;
the repair does not claim that shrinking is disabled there.

Lilly's analogous audit restores 55 intended counts in 37 files and moves 14
plain outer wrappers to tagged ordinary tests so their native checks own those
counts. Protocol restores three counts in two files; its two View histories
create a fresh View and retire real writer processes for every case and replay.
The focused protocol run passed eight tests in 3.6 seconds, seed 427219.
Lilly's full canonical-pin precommit previously passed 610 tests in 150.4
seconds, seed 947632, Covenant 15/15 and forced Dialyzer with zero errors.
That pass preceded these intended-count repairs; the final repaired-source
protocol, Lilly and Marshall full gates remain separate pending records.
Lilly's final repaired-count full precommit subsequently passed all 610 tests
in 66.8 seconds, seed 991989, Covenant 15/15, contract regression/format checks
and forced Dialyzer with zero errors or skips in 12.46 seconds. It exercises the
55 corrected counts on the frozen dual-family registry source, separately from
the earlier canonical-pin baseline or native host behavior.

The later protocol merge serializes the control-client fixture and selects the
CI profile directly on the standalone workspace-source native check. The
reviewed count stays 500: the incoming two-case outer wrapper and ignored inner
`max_runs: 50` would reduce exploration from the already passing native count.
The merged workspace-source profile passed all five focused tests in 0.1
seconds, seed 926594. Control-client serialization retains its separate focused
and full verification record;
the prior 299-test full repaired-count gate passed in 417.3 seconds, seed
953483, Covenant 14/14 and Dialyzer with zero errors or skips.

The first complete repaired-count Marshall scan ran 1,694 tests with seed
634032: 1,682 passed, 12 failed and four were excluded, in 1,342.4 seconds.
Covenant passed 24/24, presentation JavaScript passed 9/9 and the Monospace
check passed; forced Dialyzer passed with zero errors/skips in 61.36 seconds
after a 4-minute-50.9-second PLT refresh. Six failures were the
native TooSlow input-health heuristic including real database, distributed,
passkey and ten-second SMTP histories. Scoped `profile: :ci` selections retain
all intended case counts and the actual clocks/assertions. A strict typed C
diagnostic against the actual linked NIF and its exact setter sequence compared
the effective settings: only the TooSlow suppression bit differs; seed,
randomness, database, phases, backend and counts are equal. The remaining
repairs give each ingress/key history unique fixture ownership, use the intended
lowercase list alphabet instead of a Range that the generator treated as
printable ASCII, use `integer(0..2)` for peer selection and retain the existing
`image_name` projection in SSH's exact field list. These repairs change no
production behavior and require fresh focused and complete execution; the
failed full scan is preserved as a failure record.
The fresh ten-file focused scan passed 59/60 tests in 407.4 seconds, seed
393478, clearing all twelve original failures. A sibling four-case retry-window
history then hit the same TooSlow heuristic after three valid cases in 34.55
seconds; it receives the same scoped profile while retaining all four cases,
proof mixtures and assertions. Its fresh focused run then passed in 46.4
seconds, seed 525114 (one selected test, three excluded). Complete final
Marshall precommit then passed completely: 1,694 tests, four excluded,
1,540.6 seconds, seed 156566, Covenant 24/24, terminal JavaScript 36/36,
presentation JavaScript 9/9, Monospace and forced Dialyzer with zero errors,
skips or unnecessary skips in 59.03 seconds after its PLT refresh. The process
exited zero; log `/tmp/overalls-os-matrix-marshall-confirmation2.log`.
It began at 09:11:27 UTC from `21831915e` plus final repairs committed as
`b84ac6277` at 09:13:28. Later caption/handbook merges add no test fixture
change. This is the `02cd8bd` checkpoint, separate from the focused records
and the later frontend update.

The frozen dual-family registry's full protocol precommit then passed 302 tests
in 413.6 seconds, Covenant 14/14, compiler/format/contracts/ADR checks and
Dialyzer with zero errors or skips in 3.38 seconds. That exact-source protocol
gate does not establish the pending consumer or native fleet execution.

Upstream `0ed3c8151` subsequently selected frontend ref `f1ad336`, resolved as
`f1ad336e4be1f0b3e18e429f8bc826d538b40601`, and refreshed all eight Mix
dependency hashes. Its upstream delta changes only map-context/keyword-options
macro handling and a regression test; the native engine/settings sources are
unchanged. Both freshly resolved Marshall and protocol NIFs hash to
`6ed2a45ede213661e8231523bcdc8315e96bcd81b4e1b29085686a436665d38a`.
The new context/options branch still recursively wraps its inserted variable:
an actual macro-compilation probe in an isolated 512 MiB/10-second scope
exited 137, while the plain-property/options control exited zero. Probe files
and logs are `/tmp/overalls-hegel-f1ad-{context,plain}-probe.{exs,log}`.
Existing tagged ordinary ExUnit workarounds remain in place. Focused new-pin
execution passed two protocol capability tests (seed 21863), six native
admission tests (seed 395668), and fourteen Marshall handbook/observability
tests in 4.7 seconds (seed 365394). The complete `f1ad336` Marshall run then
exited 2: 1,693 of 1,694 tests passed, four were excluded, in 1,526.1 seconds,
seed 770435. Its only failure was the opposite-source relocation/clone
host-lock property's native TooSlow heuristic after two valid inputs in
34.511763231 seconds. Covenant passed 24/24, terminal JavaScript 36/36,
presentation JavaScript 9/9, Monospace and forced Dialyzer with zero errors,
skips or unnecessary skips in 54.36 seconds. Log
`/tmp/overalls-os-matrix-marshall-f1ad-full.log` has SHA-256
`191055fe6498cadf7e922480a1b99518fa18eafc2893bafb54108b61a0334e09`.
It ran `0ed3c8151` plus the frozen sources committed as `870eecef5`.
This remains a failed full gate, separate from the passing prior-pin record.

Incoming `fb956a2c4` selects frontend `08cd428`, actually resolved as
`08cd4289b8b268ae14176e3391c791647e8affae`. Its delta from `f1ad336` touches
only the Elixir macro and regression tests: postwalk replaces recursive
prewalk, inserted variable metadata is corrected and context/options expansion
uses the ExUnit context pattern directly. Native engine/settings source is
unchanged. An isolated 512 MiB/10-second actual compilation/runtime probe passed
three forms: map context with options, named ExUnit context with options and
map context without options, seed 454122. Its log is
`/tmp/overalls-hegel-08cd-context-confirmation.log`; the initial diagnostic's
overly strict equality against a named full ExUnit context was corrected to a
submap pattern, preserving the original diagnostic log. This does not establish
the upstream suite or every compatibility form.

The scoped host-lock property repair adds only its outer `profile: :ci`,
retaining two generated cases and all three rotations per case, the real
three-peer startup, lock barriers, clocks, allocation/SQL assertions and cleanup.
Its selected actual `08cd428` run passed one test with two exclusions in 26.9
seconds at seed 770435, log
`/tmp/overalls-os-matrix-marshall-08cd-lock-focused.log`.

The incoming release failed the existing source-lock snapshot comparison.
Actual Mix resolution normalizes all eleven locks to the full upstream commit;
ten source locks required correction because Ziggy was already normalized.
All eight configured dependency outputs retained stale snapshots: seven used
the short ref and Ziggy used a different full revision. The private audit
`/tmp/overalls-os-matrix-08cd-stale-dependency-snapshots.json` preserves those
identities. All eight hashes were then discovered from actual normalized-source
fetches and refreshed; normal fixed-output builds passed. Independently computed
recursive NAR hashes equal the configured values, and every actual
`.overalls-mix.lock` is byte-equal to its source lock. Receipt
`/tmp/overalls-os-matrix-08cd-dependency-custody.json` has SHA-256
`574fe280ab34fd1d3d01996402cf8d120edf92d61484df606a1b393f0f729136`.
The Cedar Cargo hash is unchanged. Upstream `cdbc76086` then supplied
byte-identical resolved locks and hashes. The post-fast-forward source
comparison is `/tmp/overalls-os-matrix-08cd-cdbc-custody-confirmation.json`;
it independently confirms the same eight proven identities at that revision.
Both hosts subsequently converged healthy to exact `cdbc76086` at 10:43 UTC,
with zero failures. Complete current-pin consumer gates and the later Arch
repair's host builds retain separate records. No prior-pin pass is transferred.

The subsequent incoming `f7f3c8c7e` bounds Porsche's invalid-boot property to
one generated CI history. Each history still visits every configured refusal
mutation and retains startup, fixture-custody and diagnostic-secrecy assertions;
randomized history exploration is reduced, and no new execution is inferred.
Its unrelated temporary fake Porsche dependency hash is replaced with the
previously proven `sha256-Hp2h0NYvDKZDiVJEztDpL8/YVGF1r9vD/lNC51MlI30=`.
Source locks and dependency contents are unchanged, so the existing independent
fixed-output and byte-equal lock custody proof still applies. This merge
changes no production authority, domain, protocol or deployment placement.

The scenario validator additionally recognizes exact qualified Elixir
`Hegel.check(...)`/`Hegel.run(...)` calls, alongside existing property markers.
Negative-prefix and tag-only fixtures retain refusal; path containment, inspected
assertions and recorded-execution requirements remain unchanged. This prevents
real explicit-runner properties from losing their existing evidence category;
lexical recognition alone remains no proof of execution or native behavior.

## Verification boundary

The native and Windows evaluation assertions inspect generated artifact/service
configuration; they do not start a guest. The pinned Python 3.13 runner suite
passed all 24 tests with
`python3 -m unittest discover -s scripts/test -p test_porsche_acceptance.py` in
`devenv shell`. These tests exercise runner refusal, receipt recovery, timeout
cleanup, strict SSH configuration, output privacy and OS-oracle behavior with
controlled responses, including accepted UUID retention after failed or uncertain
creation. Ruff and ty passed separately for the runner and tests.
The handbook scenario ledger distinguishes these checks from live acceptance.
ADR, handbook, generated-reference, coverage and topology gates check
documentation consistency only. Remaining gate results are recorded at
completion; the open runtime requirements above remain open regardless of
those results.
