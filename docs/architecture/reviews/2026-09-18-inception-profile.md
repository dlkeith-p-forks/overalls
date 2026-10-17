# Inception development profile implementation review

## Scope and decision

This review covers the isolated `feat/inception-profile` implementation of
[ADR-0054](../decisions/0054-inception-development-profile.md), superseding the
exhaustive three-profile list in ADR-0052. The user authorized merge to main and
push after validation. The original main checkout's unrelated work is outside
this change.

The accepted target is PostgreSQL, Marshall and Lilly in a Firecracker guest,
with real inner Firecracker execution. All VM creators may select it. Only SMTP
credentials are shared. The default/minimum shape is 16 vCPUs, 32 GiB RAM, 64 GiB
ext4 root and a separate sparse 256 GiB disk. Fixed embedded service budgets
explain the minimum shape. Inner Audi/Porsche browser ingress is out of scope.

## Architecture assessment

- **Admission and authorization:** the existing Ash creation authorization applies;
  no new privilege or allowlist is introduced. The configured image is bound to
  the profile in the domain, browser and SSH paths. Ordinary profiles cannot
  select the configured Inception image. Missing configuration or native host
  eligibility refuses admission before reservations or addresses are allocated.
- **Capacity and storage:** `disk_bytes` remains root capacity. The shared profile
  layout adds the data disk once for reservation, startup and resize completion.
  Native ZFS ownership includes both confined drives. Ready storage missing a
  drive is refused instead of silently recreated. Deletion validates ownership
  and reclaims both. The inner pool has a native GUID and per-instance binding;
  imports validate read-only before writable use. Unexpected storage is preserved.
- **Isolation:** profile 40 extends existing UID/MAC/address and nftables rules.
  User VMs retain the normal jail and supervision boundary. The trusted startup
  probe is a separate root service running fixed source-built artifacts, with
  no external interface, SMTP or production disks. Its systemd unit limits memory,
  CPU, devices and address families and terminates the entire probe cgroup.
  Receipt validation binds the host boot, image, probe artifact and exact VMM;
  CPU flags alone are insufficient. A failed probe withholds Inception eligibility
  while ordinary host operation remains available.
- **Credentials:** immutable source and images exclude production secrets. Guest
  identity, database password, signing/encryption keys, TLS and enrollment persist
  independently per deployment. SMTP travels over a bounded private vsock channel
  tied to the owned placement's epoch and random boot challenge. Refresh preserves
  internal identity and retries without killing a running guest. Guest root can
  read the shared SMTP account, as explicitly authorized by the requested model.
- **Recovery:** first running evidence waits for the full guest stack. Restart
  preserves source edits, database, native pool identity and enrollment. An
  interrupted enrollment re-exports the same credential using its durable operation
  ID. Lilly runs outside the inner VM slice. Inception relocation is refused.
- **Compatibility:** older consumers reject the new profile. Upgrade compatible
  consumers before enabling it. The current single configured image ID is also
  a restart/credential-delivery constraint; multi-version rolling image upgrades
  are not claimed. Preflight artifact changes require an explicit maintenance
  refresh because its service does not automatically restart on configuration change.

## Executed evidence

- All application precommit gates passed: protocol 98 cases (32 properties),
  Lilly 279 (30 properties), Marshall 542 (50 properties), plus runtime, compiler,
  contract syntax/discovery, ADR and Dialyzer checks. Marshall retains one existing
  Dialyzer ignore; it was not introduced or broadened by this change.
- Browser/domain tests cover profile visibility, bound image selection, default
  resource values, two ordinary users, address separation, reservation accounting,
  missing/wrong native proof, minimum budgets, root growth and relocation refusal.
- Runtime/receiver preparation tests passed 16 cases, including real local crypto,
  independent persistent identities, private-file checks, workspace retention and
  interrupted SMTP refresh. Host sender tests exercise bounded boot-bound exchange.
  These isolated tests do not establish physical nesting or live mail delivery.
- The basic native Inception stack check passed full bootstrap, enabled inner
  Lilly, native ZFS, persistent credentials and workspace edits over stop/start,
  and both-disk deletion. A native failure exposed public CA directory permissions
  under UMask 0077; explicit validated directory permissions fixed it, with a real
  filesystem regression test.
- The new host preflight passed a real Firecracker-in-Firecracker boot on AMD.
  Its native fixture rejected altered boot/image/probe/VMM receipts before disk
  creation. Its first run correctly failed on insufficient fixture root space;
  the fixture now reserves 32 GiB for the probe and outer services.
- The native ZFS suite previously passed its sparse two-disk scenario, restart,
  missing-disk refusal and cleanup in 947 seconds. The updated SMTP-bound fixture
  is being rerun. This suite uses an ordinary image to isolate storage behavior.

## Remaining acceptance

The expanded native suite is running real outer Marshall admission and dispatch,
inner VM create/stop/start/delete, network egress and private-range denial, SMTP
refresh and inner storage-binding refusal. No successful expanded run is claimed
until its physical assertions complete. Native evidence remains single-host AMD
acceptance rather than Intel or multi-host fleet qualification.

A selected operational SMTP secret reference and explicit test recipient are
still needed for live delivery acceptance. Fixture SMTP never establishes inbox
delivery. No production credentials were read or messages sent.

The test environment now honors `PGPORT`; checks used a private PostgreSQL on
55440 with an isolated test partition. Pinned OpenSSL was added to the development
shell for the existing SMTP certificate test. These preserve production behavior.

Reconcile this review with the final native outcomes and final diff before merging.
See the [operator/developer guide](../../guests/inception.md) for configuration and limits.
