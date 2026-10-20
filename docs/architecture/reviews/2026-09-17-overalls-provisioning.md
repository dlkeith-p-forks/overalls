# Overalls physical Hetzner provisioning

Date: 2026-09-17

## Scope and architecture impact

Provision the operator-authorized Hetzner machine `overalls` at `OVERALLS_PRIMARY_IPV4`
using ADR-0043. The existing fleet access and recovery policy is preserved;
`ghuntley` remains the administrator and recovery recipient. No new architectural
decision is introduced. ADR-0043 remains accepted and partial.

The [host declaration](../../../fleet/hosts/overalls/host.json) binds the discovered
UEFI machine, complete stable disk inventory, MAC-matched IPv4/IPv6 network,
ZFS host ID and explicit budgets. The two 1.92 TB Samsung NVMe drives form a
ZFS root mirror with independent EFI boot partitions. Guest quota and logical
budget are 1,400 GiB, guest CPU budget is 14 cores, guest RAM budget is 112 GiB,
and the ARC cap is 8 GiB. No application role is enabled.

## Executed verification

- The operator authenticated the rescue Ed25519 fingerprint before connection.
- Discovery verified the physical machine UUID, serial/by-id disk identities,
  firmware, addresses, gateways and DNS. Actual KVM VM creation passed.
- Host planning and storage-configuration Nix checks passed. Contract structural
  checks passed before the checkpoint publication; that checkpoint includes
  explicitly requested unrelated work in progress, not a claim of application
  suite completion.
- The base and installer built from published revision
  `da58528addf8cf8cd4a00132427f4b105c9004d2` before erasure. The plan digest was
  `94e814ddf8955ed2020c3f8304538698337223b412166d00a80b1895dd6309fb`.
- The real Hetzner rescue environment entered the pinned kexec image; installer
  hardware, inactive-device and KVM guards passed before formatting.
- Installation generated the host key privately on the target and retrieved
  its public key and storage GUID receipt over the authenticated connection.
- The installed host booted successfully as `overalls`; pinned-key SSH login as
  `ghuntley` and passwordless sudo succeeded. `overalls-host-check` verified storage,
  identity, actual KVM creation and the installed SSH policy. No failed systemd
  units were reported. Both mirror members were ONLINE with no ZFS data errors.
- Installed IPv4/IPv6 routes and the exact ZFS quota, LZ4 compression and zero
  reservations matched the declaration. Four SOPS documents passed recipient
  checks after preparing the encrypted host Git credential.

## Findings and remaining work

**High, fixed and deployed:** the profile converted repository ciphertext paths to
strings without retaining a Nix dependency. After copying the enrollment closure,
its source checkout was absent on the physical host and secret staging failed
before reading ciphertext. Explicit per-document store paths now retain the
ciphertext in both Git and Lilly deployment closures. The enrollment evaluation
regression requires dependency context for both documents. The host remained
accessible and polling stayed gated during this failure.

Initial SSH attempts during the physical reboot timed out; subsequent
authenticated access succeeded after boot completed.

**Medium, fixed and deployed:** the SSH-delivered `host verify` probe needs Git on
the administrative command path. Git was present only in the wrapped host-check
and updater environments, so the installed checker succeeded while the CLI
failed. The profile now installs Git explicitly. The storage evaluation checks
that requirement, and the enrollment machine fixture no longer supplies Git on
behalf of the production profile.

Git enrollment activated revision `1e82301ec97f7082e0ea90142ce71e8bb11e9157`,
persisted the receipt and enabled polling after its health checks. The installed
`overalls-host-check --receipt` passed, and automatic updating recorded that
revision and its actual system closure as healthy with zero failures. The normal
updater then applied revision `e37f6877ba660a4bb857f75c6578d5dff64ff90d` and
recorded its actual system closure as healthy. The documented `host verify`
command passed against the installed receipt, including live pinned Git access,
SSH policy, native storage identity and actual KVM creation. No failed systemd
units were reported. Physical
single-disk failure boots, EC2 acceptance, independent multi-host failures,
application deployment, Lilly enrollment and scheduling are outside this result.
This one-host installation does not complete the full ADR-0043 acceptance matrix.

Public installation receipts are retained in the operator's private state
location `~/.local/state/overalls/provisioning/overalls`; the target retains its
storage receipt in `/var/lib/overalls-host`. No private keys or plaintext
credentials belong in this review or the repository.
