# Guest platform trust bootstrap review

## Scope and architecture impact

This change replaces the image-baked platform roots in ADR-0109 with
[ADR-0113](../decisions/0113-guest-trust-at-boot.md)'s host-to-guest boot
delivery. It changes the Lilly execution outcome gate, adds an AF_VSOCK
protocol, and adds a host-local Ash lifecycle journal whose audit events are
ingested through the existing authenticated lifecycle channel. Brady's signer
and recovery-key custody remain as recorded in ADR-0109. ADR-0074 supplies the
durable audit model; ADR-0110's SSH roster still determines SSH authorization.

## Findings and implementation

- The previous immutable NixOS `security.pki.caBundle` and Ubuntu image-build
  `update-ca-certificates` step could not replace platform roots on a retained
  disk. The [NixOS trust unit](../../../nix/domains/artifacts/guest/private-services.nix)
  now atomically points `/etc/ssl/certs` at the writable installed bundle. The
  [Ubuntu receiver](../../../lyra/src/bin/overalls-trustd.rs) replaces a managed
  certificate directory and rebuilds the system bundle before notifying
  systemd. Ordinary public OS roots remain.
- The [Lilly driver](../../../lilly/lib/lilly/vm/driver.ex) checks the exact
  confined boot before and after the bounded [vsock exchange](../../../lilly/lib/lilly/vm/guest_trust.ex).
  The durable receipt binds placement, epoch, generation, boot challenge, guest
  boot ID and exact CA digest. Existing-boot receipts can be reused; a new boot
  enters `pending` again. Three attempts at most precede a fenced terminal
  failure. The [executor](../../../lilly/lib/lilly/vm/executor.ex) withholds
  `running` until this receipt is committed.
- The [lifecycle resource](../../../lilly/lib/lilly/lifecycle/guest_trust.ex),
  closed protocol state list (`protocol/lib/overalls_protocol/lifecycle_audit.ex` at overalls revision `a99f74f0`, repository deleted),
  outbox (`lilly/lib/lilly/lifecycle/outbox.ex` at overalls revision `a99f74f0`, repository deleted) and
  [Marshall projection](../../../marshall/lib/marshall/compute/lifecycle_log.ex)
  provide durable, authenticated audit and catalogued diagnostics without
  certificate contents, command arguments or terminal bytes.
- Native NixOS fleet runs reached `vm.trust_installed` and then found
  that the unprivileged SSH callback could not traverse the installed bundle.
  `tempfile` created its directory with mode `0700`; the guest agent also owns
  `/var/lib/overalls` with mode `0700`, so public trust cannot live below it.
  The receiver now uses an independent `/var/lib/overalls-trust` state directory,
  publishes the public directory and PEM with modes `0755` and `0644`, and
  repairs old modes on retry. A Rust regression test checks those modes. The
  fleet machine fixture checks readability as the SSH callback user.
- The isolated [Ubuntu storage fixture](../../../nix/verification/tests/machines/zfs-guest/probe.exs)
  has no Audi authority to issue an SSH roster. It now verifies installed
  trust, networking and storage while asserting SSH stays closed, without
  calling that VM fully ready. The Ubuntu relocation fleet test supplies the
  separate real-authority readiness and SSH acceptance. The isolated fixture
  omits its NixOS-only full-readiness and cancelled-source restoration cases,
  which require a roster-authorized ready boot.
- The Ubuntu storage fixture's clone path resumed a stopped source through
  `Driver.start` without delivering trust for the new boot. Its terminal never
  became available because guest networking waits for trust. The clone fixture
  now waits for the restarted VMM's confined observation, then calls
  `Driver.trust` before testing continued operation. The first rerun of this
  repair showed that trust cannot precede that observation.
- A later native rerun found the storage fixture's CPU pressure assertion
  intermittently sampled idle headroom. Supervised load units then produced
  variable absolute headroom, and a bounded recovery sample never rose enough
  after those units stopped. This is an unrelated host CPU accounting probe in
  a nested Ubuntu storage fixture. That fixture still checks two live guests,
  real memory and sparse disk usage, but runs the CPU pressure subcheck only
  in its NixOS variant. Ubuntu CPU headroom acceptance remains unverified here.

## Verification

The merged branch passes the Rust receiver's five tests, format and clippy;
Protocol, Lilly and Marshall `mix precommit` including Dialyzer; and all
`prek run --all-files` hooks. The full Audi NixOS fleet test and the native
NixOS and Ubuntu relocation fleet tests passed. Those relocation tests checked
the unprivileged CA bundle, installation before networking and SSH, and the
addition and removal of a destination-only root in the effective guest bundle
across two moves. A separate Ubuntu fleet run failed in its existing browser
identity HTTP fixture; its rerun passed that stage but failed the native SSH
assertion with roster-fetch and authorization diagnostics. The Ubuntu
relocation run passed both stages and continued through both moves. The base
fleet failure is not attributed to the trust bootstrap without further evidence.
The initial NixOS fleet runs found the permissions defects above; the full
rerun passed. The relocation runs preceded the later independent Lyra SSH
merge; the merged Lyra package build, Rust tests, format and Clippy passed.
The first isolated Ubuntu storage rerun failed in a full-readiness case that
requires Audi roster authority; after scoping those cases to NixOS, its next
run passed trust, storage, headroom, resize and data-drive cases, then found
the clone restart trust omission described above.
The final `ubuntu-guest` native storage check passed with trust delivery on
both clone source restarts, terminal access, data-drive independence and
cleanup. After merging the independent ZFS namespace deletion work, Lilly's
`mix precommit` passed with 403 tests, including 48 properties, and zero
Dialyzer errors. The full `ubuntu-guest` native storage check passed again on
that merged source. It retains the Ubuntu CPU headroom limitation recorded
above.

## Remaining gaps

Native terminal trust failure acceptance remains unverified. The separate
Ubuntu base fleet check has intermittent browser and SSH fixture failures;
the successful relocation variant covers the trust and SSH behavior for this
change. Existing running VMs intentionally keep their last installed bundle
until restart or replacement. The design does not claim live CA rotation.
