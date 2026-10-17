# Dungarees worker provisioning

Date: 2026-09-18

## Scope and architecture impact

Install the authorized new Hetzner machine at `136.243.69.35` as `dungarees`,
using the reviewed [declaration](../../../fleet/hosts/dungarees/host.json).
Preserve ADR-0048's inherited provisioning and storage policy and ADR-0045's
separate worker enrollment. The worker joins the existing Overalls control
plane; it does not replicate the database or establish control-plane HA.
ADR-0060 monitoring and ADR-0063 private services apply to the enrolled worker.
Explicit provider selection preserves ADR-0063 authority and secret custody;
it adds a backward-compatible runtime option, not a readiness bypass.

Overalls' [declaration](../../../fleet/hosts/overalls/host.json) adds specific
routes to both worker addresses through the existing Hetzner gateway. Both
machines need routed peer traffic despite sharing the public IPv4 prefix.
No Overalls disk, installation identity or application authority is replaced.

## Discovery and pre-installation evidence

The supplied rescue Ed25519 fingerprint was authenticated over IPv6. Discovery
confirmed UEFI, physical UUID `1e47fcf0-ac62-11f1-8420-5cffb9e15600`, both stable
Samsung 1.92 TB NVMe identities, MAC-matched networking, and actual KVM VM
creation. The reviewed declaration mirrors both drives and retains Overalls'
current explicit resource budgets. DNS and both gateways match rescue state.

Host-planning and storage-configuration checks passed. Physical installation,
worker enrollment, guest execution and automatic-update health checks succeeded.
Public receipts are retained outside Git under the operator's private
`~/.local/state/overalls/provisioning/dungarees` directory. Private keys and
plaintext credentials must not appear in this report or the repository.

## Installation and enrollment progress

The base installation completed from revision
`1efb7c04ce231b058a8ea41a9afb7bad5fdd36ef` with erasure digest
`d290588a10356e9f9c9adb42e033d99b3da9ddbd39744c4f7accc8edcbd9cfd0`.
The installed host booted, authenticated named-user SSH/sudo succeeded, storage
verification passed, both mirror members are healthy, and no failed systemd
units were reported. The supplied additional address `136.243.69.32/26` is
included in the enrolled configuration, with a corresponding Overalls peer route.

The real OpenAI key supplied through private operator custody passed model-list
HTTP authentication and was encrypted separately for both hosts. Anthropic is
explicitly disabled; its placeholder is retained in ciphertext. Runtime and Nix
validation reject an empty, duplicate or unknown provider selection. Inference
requests to disabled providers fail before authority admission or provider calls.

Lilly registration is separate from service authority. The current Ziggy issuer
requires an enabled, execution-ready compute host, so initial activation uses an
unissued host-specific bootstrap token and must fail Ziggy readiness. Polling
stays gated. After Lilly reported execution readiness, the worker was enabled and its real
Ziggy credential was issued and encrypted. Repeated enrollment passed the final
authenticated health check, persisted the receipt and enabled automatic updates.
The initial bootstrap failure was not treated as deployment acceptance.

## Enrollment resource-policy finding

**High, fixed in source:** explicit first enrollment incorrectly reused the
ordinary resource-transition path, which requires an existing enrollment receipt.
It rejected the new worker before activation. Explicit enrollment now validates
candidate resource policy against installed CPU/RAM/ARC/quota budgets and verified
native GUIDs, rejects changes to an existing policy, and lets activation apply
those unchanged declared limits without manufacturing a receipt. Ordinary updater
transition rules are unchanged. Host-planning regressions cover initial/retry
enrollment, changed budgets/GUIDs, policy changes and removal. Physical retry
passed on revision `1728e11b03e7a9c10b9c3a954d0d61d30f00b2c7`: the enrollment
receipt was persisted and automatic polling enabled. Both hosts subsequently
reported that revision healthy.

## IPv4-only networking

At the operator's request, both host configurations disable IPv6 through
`networking.enableIPv6 = false`, remove IPv6 addresses, DNS servers and default
routes from their active declarations, and disable link-local addressing.
Overalls' unused IPv6 PostgreSQL authentication rule is removed. Discovery
snapshots retain historical rescue observations; they do not configure networking.
Both IPv4-only system closures build successfully. On both running hosts,
`net.ipv6.conf.all.disable_ipv6` and `net.ipv6.conf.default.disable_ipv6` are 1,
and `ip -6 address show` is empty. These host-local settings
preserve existing domain and authority boundaries; no accepted ADR changes.

## Native guest acceptance

The disposable Standard guest was scheduled specifically on Dungarees and
reached the control plane's running state. Its serial console, public internet
egress, private DNS and verified private TLS worked. Both hosts report fresh
execution readiness and independent monitoring. Primary and additional IPv4
SSH access were verified against the installed host key.

The guest catalog request exposed an existing private-forwarding defect:
Finch's Unix-socket pool uses a default Host that differs from the request URL.
Native comparison returned 403 without an explicit Host and 200 with the fixed
`llm.internal` Host, using the same placement binding and socket. The Audi fix
preserves ADR-0063's canonical host and transport-derived identity checks; it
never forwards a guest-controlled Host. After activation, the guest successfully retrieved the catalog through normal
private DNS and verified HTTPS. Console and public HTTPS egress checks also
passed again. The disposable guest was deleted through the control plane; its
runtime directory and ZFS dataset are absent, and its retained reservation has
released compute, disk and temporary capacity. This is single-guest acceptance,
not fleet-load or HA validation.

## Final validation

Both hosts accepted revision `2ffa5b78be905ff0cc3618a9d1a1c6a6ba298918` through
their updater. Native storage/identity receipt verification passed; mirrored ZFS
is healthy. SSH remains available over IPv4, including Dungarees' additional
`136.243.69.32` address. No failed systemd units were found on Dungarees.

Ziggy's precommit gate passed with 24 tests/properties and forced Dialyzer.
Audi's first full run had one short-TTL property expire before its worker started;
the complete rerun passed all 140 tests/properties, and forced Dialyzer reported
zero errors. Both final NixOS closures built, host-planning/storage/provider
configuration checks passed, and ADR and contract structural checks passed.
These checks do not establish concurrency/load or multi-host control-plane HA.
Anthropic remains disabled until a real provider key is supplied.
