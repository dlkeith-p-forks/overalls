# HTTPS egress production acceptance, 2026-10-02

## Scope and architecture impact

The source review traced Lilly's TAP/source guards, TPROXY rules and policy route,
Brady's original-destination sockets, HTTPS authority and verified upstream TLS,
public cache admission, boot-delivered platform roots and flow attribution.
Brady was implemented and enabled on Overalls, rather than absent. The existing
`04392b0c` fix already admits HTTPS across differing guest/proxy DNS views while
retaining original-IP pinning and upstream certificate verification.

The campaign used an isolated worktree based on `5f5225f3391cf6e3dbba85788c789913e280b32d`.
Before guest acceptance, Overalls activated that revision and reported it as
healthy. Both transparent listeners and live namespace interception rules were
present. Service activity alone was not treated as request evidence.

Architecture impact: verification and operations evidence only. No proxy,
trust, protocol, authorization, storage ownership, placement or deployment policy
changes are needed for the passing paths. ADR-0069 remains accepted/implemented;
ADR-0113 remains accepted/partial, including its outstanding trust-exhaustion
and independent-host boundaries. ADR-0124's SSH trust and ADR-0046's management
authority are consumed unchanged. No new ADR is required.
Cleanup later exposed an inventory omission under ADR-0112: descriptor-pinned
mount namespaces without inhabitants. Its repair expands discovery, preserving
GUID custody, the deleting fence, exact-root checks and ordinary unmount only.
It changes no guest, capacity-release or privilege authority.

## Production results

**Production NixOS and Ubuntu verified HTTPS, redirect, shallow clone, shared
public cache and protected-address refusal passed before and after guest restart.**
The Customer fixture's pinned-public-IP HTTPS request was denied in both stages.
No shared production service was deliberately interrupted.

| Fixture | VM UUID | Baseline generation | After stop/start |
| --- | --- | --- | --- |
| NixOS OSS | fba6a056-15fb-411f-868b-18a741c8e91d | 1 | 3 |
| Ubuntu OSS | 903dc050-598e-4b1c-835c-a7d4dc5b003d | 2 | 4 |
| NixOS Customer | 113b815c-91e9-457d-a3c5-f7e5240192f3 | 1 | 3 |

Both OSS guests used ordinary system trust without `--cacert` or disabled
verification. Curl reported verification result zero and the `Overalls Brady
overalls Signer 2026` / `Overalls Brady Fleet Root 2026` chain. The version-pinned
jsDelivr artifact matched the independent reference SHA-256
`04255e482e181687823a95b207802ddd32e746c65dce4c95a5176fc192735960`.
The GitHub shallow clone resolved to
`7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`.

Scoped closed events contained eight successful HTTPS requests per OSS guest
per stage. Baseline cache hits were two for NixOS and three for Ubuntu; after
restart both had three. The events bound the actual VM, placement, owning account,
execution epoch and generation. Cache reuse did not infer identity from an IP's
previous occupant. Protected requests to `10.90.0.1`, `169.254.169.254` and
`OVERALLS_PRIMARY_IPV4` timed out. The Customer test used a public address resolved outside
the guest, so denied guest DNS alone could not pass it.

A second campaign, `egress-20261002-151600`, exercised the completed runner's
sequential create path. All three fresh fixtures reached running, including
Ubuntu, and its full current-generation HTTPS/cache/refusal probe passed. This
does not turn the earlier failed create into successful evidence.

Private append-only evidence, original create receipts, lifecycle receipts and
bounded host snapshots reside outside Git under the operator's
`https-egress-20261002` state directory. The
[acceptance runner](../../../scripts/egress_acceptance.py) makes the scenario
repeatable; its [guide](../../acceptance/egress-acceptance.md) specifies ownership checks,
request replay and cleanup. Public evidence excludes account credentials, raw
terminal data and private keys.

## Findings and limits

- No proxy integration failure was reproduced on the tested revision. The
  existing DNS-disagreement repair is retained, not replaced with TLS bypass.
- Ubuntu's first create request failed before networking with
  `vm.dataset_preparation_failed: incoherent_zfs_observation`, then
  `disk_prepare_failed` / `execution_failed`. This remains failed evidence.
  A separate explicit start of the same VM recovered its retained disk and
  completed the live matrix. A later stop/start also completed. This campaign
  does not establish the transient ZFS observation's cause or universal
  provisioning recovery; it is not attributed to Brady.
- The initial probe assumed an OpenSSL executable in NixOS. That executable
  is absent although curl uses OpenSSL. The runner now reads curl's verified
  certificate metadata, avoiding package installation or a trust override.
- Production faults remain isolated: proxy outage, real quota/headroom pressure,
  credential/privacy combinations and stale address-reuse schedules use native
  fixtures. Single-host production acceptance does not prove independent-host
  relocation, every HTTP input, application-specific certificate pinning/mTLS,
  large-download backpressure or fleet capacity.

## Native and component evidence

**Native HTTPS cache recovery passed: full and range bytes survived proxy restart
with the origin stopped.** The added
[native storage scenario](../../../nix/verification/tests/machines/brady-network/storage.py)
warms HTTP and HTTPS separately, requires another published object for HTTPS,
stops the origin, restarts Brady, verifies exact full and range bytes, and checks
fresh hit counters. It uses production TLS/ZFS helpers with veth guest peers;
it does not establish Firecracker boot trust or authoritative owner attribution.

The complete extended `brady-native-storage` check passed in 125.42 seconds at
`/nix/store/16ppakkxm397xa1l74lwjm0h9pgzmz71-vm-test-run-overalls-brady-native-storage`.
The storage driver SHA-256 was
`6199eb7442953dbc94f02ecc20d80a5139c4a71aba63fc1e93fc9b93e79b8129`.
Existing real quota, parent headroom and physical 15%/20% pressure cases passed
alongside the HTTPS extension.

The unmodified `brady-network` check passed in 47.08 seconds at
`/nix/store/pdj8ywi47fhh8ihpx18g3gm0i1asjjbs-vm-test-run-overalls-brady-network`:
transparent HTTP/TLS, upstream name rejection, exact tunnel exception,
DNS-disagreement Git clone, Customer/protected refusal, fail-closed outage,
HTTP/3 fallback and closed journal diagnostics.

Brady `mix precommit` passed: 66 checks (17 properties, 49 tests), compilation,
runtime/contracts/logging/ADR gates and forced Dialyzer with zero errors.
The runner's seven safety tests passed; ruff and ty passed. Those tests establish
fixture-mutation fencing, request reconciliation, timeout termination of local
SSH/proxy descendants and evidence handling only.
They are not native isolation evidence.

Marshall `mix precommit` passed: 1,394 checks (201 properties, 1,193 tests),
two excluded, with frontend/shared validator checks and forced Dialyzer reporting
zero errors. The full Python hooks, contract format/discovery/coverage, ADR,
generated HLDD options/scenarios/views and evaluated Nix `hldd` gates passed.
These structural gates support documentation consistency, not native isolation.

## Publication and post-deployment evidence

The normal fast-forward push published `ca739afa441e991690de04e6dbdd0a75346e25bb`
to `origin/main`, including the reviewed merge of the Galileo/fleet repairs.
Overalls reported that exact revision as candidate, activated and last healthy
at 2026-10-02 15:57:58 UTC, with active system
`/nix/store/lf7s8r5jjxhys9pfxiww52piqpxb2aqd-nixos-system-overalls-26.05.20260914.c3eea5b`.
The normal updater was started without bypassing its build or health gates.

**Both three-guest campaigns completed the post-deployment HTTPS/cache/refusal
matrix on ca739afa.** The first passed under `after-deploy-confirm`; the second
passed under `after-deploy-stable`. Private snapshots retained healthy activation
and fresh successful owner/VM/generation-bound HTTPS cache events. Customer
refusal now accepts only connection failure or timeout, excluding TLS/receive
errors; the independently reachable pinned-IP control passed.

These successful stages do not conceal failed attempts. Initial post-deployment
SSH streams closed with exit 255 on the first campaign's NixOS and Ubuntu guests,
and later on the second campaign's Ubuntu guest after verified HTTPS and clone
output but before the protected-address loop completed. Independent fixed SSH
checks subsequently passed on all six guests. A 12-second SSH renewal diagnosis
passed on the first campaign's NixOS and Ubuntu guests but again closed on the
second Ubuntu guest. Audi recorded admitted streams and the VMs remained running
at their original generations; this does not establish the closure's cause.
SSH transport stability remains an explicit unresolved dependency gap, not a
repaired Brady defect or a successful network refusal. No lease, execution or
TLS guard was weakened to obtain acceptance.

The merged Marshall full gate passed: **1,403 checks (208 properties, 1,195 tests),
two excluded**, with forced Dialyzer reporting zero errors. Protocol's full gate
passed **222 checks (83 properties, 139 tests)** and Lilly's full gate passed
**468 checks (78 properties, 390 tests)**, both with Dialyzer success. Python
hooks and the evaluated HLDD gate passed on the merged tree.

The merged native network check passed in 47.09 seconds at
`/nix/store/485jdhjh9500cmxkdwy6mc0pwqw11ymv-vm-test-run-overalls-brady-network`.
The final storage assertions compare the complete full and range strings,
including length, rather than matching one output line.
**The final `brady-native-storage` check passed in 130.19 seconds** at
`/nix/store/ccbir5cq8sn3l0lllcpsb79pyn6f0pm6-vm-test-run-overalls-brady-native-storage`,
with driver SHA-256
`49d8994f200980218331219d9557f1768803b019d3abb8153769c464f9b5cc20`.
Earlier runs above retain their original revision and driver scope.

## Fixture cleanup

The six original fixture deletions completed, including the previously blocked
Ubuntu deletion, after normal activation of `99f13b26059086f1348f94db60e2d31d5abb20e1`.
Overalls reported candidate, activated and last healthy as that exact revision,
with active system
`/nix/store/lb2d2s19h529cgvl3zrmapnpnqb04dvn-nixos-system-overalls-26.05.20260914.c3eea5b`
and zero updater failures. The original request
`egress-20261002-151600-ubuntu-cleanup-rm` completed through normal reconciliation;
no replacement deletion, force/lazy unmount or unrelated process termination was
used. A bounded independent SQL/ZFS/systemd check confirmed all six VM rows
were deleted, compute/disk reservations released, exact datasets absent and
exact units inactive. Private evidence retains this physical proof.

The fresh post-repair campaign `egress-20261002-171000` created all three guests
sequentially on healthy `99f13b26`. Its `after-cleanup-fix` stage passed the complete
HTTPS/cache/refusal matrix, including ordinary system trust, independent artifact
digest, redirects, shallow GitHub clone and current-generation owner-bound cache
hits on both OSS distributions, and the Customer pinned-public-IP refusal.

| Fresh fixture | VM UUID |
| --- | --- |
| NixOS OSS | 5cea6261-87e8-469c-aeb8-928449178e62 |
| Ubuntu OSS | 6594b652-a3b0-41e8-88ec-1bf1ef605248 |
| NixOS Customer | dc6e6cb7-328b-4752-95c5-f7c4aba942f6 |

**All nine campaign fixtures are deleted.** Fresh campaign cleanup completed
using the three recorded deletion requests. A new bounded independent proof
covered all nine exact VM UUIDs: deleted rows, released compute/disk reservations,
absent placement datasets and inactive units. The append-only private evidence
includes `physical-nine-fixtures-after-cleanup.json`; no fixtures were replaced
to obtain these results.

The latest combined Marshall full gate passed **1,408 checks (210 properties,
1,198 tests), two excluded**, with forced Dialyzer reporting zero errors. The
subsequent test-only host-takeover merge passed its focused check, forced Dialyzer,
all-file hooks and evaluated Nix HLDD gate. These results retain the earlier
failed provisioning and SSH attempts and do not establish their causes.

## Descriptor-pinned namespace cleanup repair

The second campaign's Ubuntu VM stopped, but its fenced deletion retained disk
capacity with `zfs_dataset_cleanup_unconfirmed`. The helper repeatedly detached
13 inhabited namespace copies; nonforced ZFS destruction still reported busy.
Read-only inspection found a Nix daemon-held mount-namespace descriptor with no
process inhabiting that namespace. Entering it for inspection showed the exact
owned dataset at its canonical placement path. The previous helper scans only
`/proc/PID/ns/mnt` and therefore cannot discover this namespace.

The [native helper](../../../lilly/native/zfs-namespace-unmount/src/lib.rs) now
also inventories process-held `mnt:` descriptors before unmounting anything.
It pins each candidate, enters it to classify the mount inventory, restores the
host namespace, deduplicates by native namespace identity and applies the same
exact-root/alias/busy/race refusal rules. The additional scan is bounded at
131,072 descriptors; failures and overflow retain the deletion fence. No force,
lazy detach, unrelated process termination or service restart is introduced.

The [machine regression](../../../nix/verification/tests/machines/zfs-guest/namespace-cleanup.py)
holds a late namespace descriptor after reaping its last child. It requires
fenced Firecracker/disk deletion while the holder and neighboring guest survive.
The existing live-file-holder case still requires busy refusal followed by safe
cleanup after release.

**The extended `zfs-namespace-cleanup` native check passed in 420.83 seconds**
on `5c623418`, including the descriptor-only subtest in 91.24 seconds, at
`/nix/store/xxdwajdk3b54yg0fn27agc9b3k1vvvsy-vm-test-run-overalls-zfs-namespace-cleanup`.
The initial fixture attempt failed because its transient service could not
resolve `sh`; that run was cancelled and retained. Absolute NixOS tool paths
corrected the fixture before the recorded passing runs. Rust tests, format and
Clippy passed; descriptor opens are nonblocking so a reused FD cannot block on
a FIFO before namespace-type rejection. Lilly's full gate again passed 468
checks (78 properties, 390 tests) and zero Dialyzer errors. Focused Marshall
handbook/governance checks passed 47 checks (nine properties, 38 tests).
The evaluated Nix handbook gate and full Python hooks passed. The original
blocked production deletion subsequently completed on healthy
`99f13b26`; its independent physical proof is recorded above, separately from
this native result.
