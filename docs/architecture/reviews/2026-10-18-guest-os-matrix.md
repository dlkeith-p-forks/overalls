# Guest OS matrix evidence review (2026-10-18)

## Scope and architecture impact

This review reconciles the seven declared guest OS families with the evaluated
fleet catalog, current image evidence and opt-in Porsche acceptance tooling.
It also corrects foreign-Linux ext4 construction, adds evaluation assertions for
the native SSH supervisor's temporary PID cleanup and reconciles the Windows
evaluation's shared VMM patch inventory.

There is no new Ash domain/resource, deployment host/service, persistence shape,
authorization grant, wire protocol or guest capability. The work preserves
[ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md),
[ADR-0171](../decisions/0171-windows-guest-agents.md) and
[ADR-0173](../decisions/0173-windows-images-winget-desktop-experience.md).
Their recorded decision and implementation statuses remain unchanged.
The existing domain and deployment views require no inventory change.
Windows publication enforces ADR-0171's existing built-once distribution through
the signed cache of ADR-0188. The illumos accept fix preserves ADR-0190's existing
host-only transport while making successful accept wait for RESPONSE publication.

## Findings

The [shared image list](../../../fleet/guest-images.nix) declares NixOS, Ubuntu,
Arch Linux, AlmaLinux, FreeBSD, OmniOS and Windows. Native entries are filtered
by the selected package's `nativeAdmission` flag. Only the exact promoted
FreeBSD image passes that filter; OmniOS contributes no evaluated catalog row.
The [current matrix](../../guests/os-matrix.md) separates these six entries
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
without admitting an OmniOS image or executing a new native scenario.

Current source-qualified OmniOS receipts cover complete services over two clean
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
Current-image recovery, growth and isolation executions remain pending; no older
runtime receipt transfers to these bytes and admission stays false.

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
This comparison covers the final fleet-context construction inputs, including
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

## Consumer verification prerequisites

Initial consumer repairs used Hegel frontend `9b13af8`; the merged consumers now
select ref `02cd8bd`, resolved as `02cd8bd5bf07a7ca1bfaf7d599456fff5badbfa2`.
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

The scenario validator additionally recognizes exact qualified Elixir
`Hegel.check(...)`/`Hegel.run(...)` calls, alongside existing property markers.
Negative-prefix and tag-only fixtures retain refusal; path containment, inspected
assertions and recorded-execution requirements remain unchanged. This prevents
real explicit-runner properties from losing their existing evidence category;
lexical recognition alone remains no proof of execution or native behavior.

## Verification boundary

The native and Windows evaluation assertions inspect generated artifact/service
configuration; they do not start a guest. The pinned Python 3.13 runner suite
passed all 23 tests with
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
