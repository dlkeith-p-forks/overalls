# ADR-0154: Guest boot profile and measured boot reductions

- ID: ADR-0154
- Date: 2026-10-10
- Status: accepted
- Implementation: partial
- Components: Lilly boot-log writer, NixOS guest image, Ubuntu guest image, Lyra guest trust receiver
- Supersedes: none
- Superseded by: none

## Context

A NixOS create spent about 6.4 s in Lilly's `awaiting_trust` phase and an
Ubuntu create about 5 s. The trust install itself is short; most of the wait is
guest boot. The 2026-09-26 provisioning review measured kernel, initrd and
userspace phases once. There was no permanent way to see where a given boot
spent its time: console logs had no timestamps and nothing summarized the
systemd boot.

The user approved this plan: (A) permanent boot timing visibility in both
images, then (B) boot and trust speedups ranked by measured gain. The user then
narrowed (B): read the implementation, measure each candidate first, change only
what the evidence shows is slow, and keep correctness. In particular,
`update-ca-certificates` must keep running whenever the Ubuntu store changes,
because it also maintains the per-certificate and OpenSSL hash links and runs
the `update.d` hooks.

## Decision

**Visibility.** The host `lilly-boot-log` writer prefixes every retained console
line with a `[+S.mmm] ` offset from writer start. A line-start state machine
treats CR and LF as line ends, leaves empty lines bare and is independent of
pipe chunking. The 1 MiB cap applies to the stamped stream. Both images boot
with `printk.time=1`. A `lilly-boot-report` unit in both images starts after
`lilly-readiness` and writes a bounded, marker-prefixed profile to the serial
console:
- `systemd-analyze time` and the manager phase instants;
- the critical chain for trust and readiness;
- a fixed unit start/active timeline;
- the trust receiver's catalogued events;
- top service blame.

The unit is `Type=exec`, required by nothing, and reports even when the boot
transaction never finishes. It is observation only.

**Reductions kept because they measured faster** (nested-KVM fixture, 1 vCPU):
1. NixOS registers its closure in the guest Nix database at image build time,
   using the guest's own Nix and the existing canonicalization (fixed
   `registrationTime`, no WAL/SHM). The boot-time `register-nix-paths` unit and
   `/nix-path-registration` are deleted. The unit took 1.7–1.85 s before
   `sysinit.target`, so it blocked trust.
2. Ubuntu images built with private-service roots stage them exactly as
   `overalls-trustd` does: `overalls-platform/overalls-I.crt`, then
   `update-ca-certificates`, then the installed digest marker. The receiver
   skips `update-ca-certificates` only when the store is verifiably current:
   - the marker equals the delivered digest;
   - the managed files are byte-equal to the delivered roots, in order;
   - every root is a PEM block in the system bundle;
   - every `overalls-I.pem` link resolves to its managed file.

   Otherwise it withdraws the marker, replaces the roots and runs
   `update-ca-certificates --fresh` as before. It writes the marker only after
   a verified rebuild. The full rebuild measured 3.0–3.5 s on 1 vCPU.
3. The NixOS initrd drops the default PC storage/USB module set, LVM, TPM2 and
   virtual-console setup (29.2 MB to 23.1 MB). `console.enable = false`.
4. Both images keep the serial console quiet (`quiet`, `loglevel=3`,
   `systemd.show_status=error`). The console carries errors, the boot-complete
   line and the boot report. Before the report, console bytes fell from about
   20 KB (NixOS) and 42 KB (Ubuntu) to under 1 KB.

ADR-0113's ordering is unchanged. Trust still completes before guest networking,
private DNS, roster sync and sshd, and every boot still receives and verifies
the host's current root set.

## Alternatives

Measured and rejected (changes reverted):
- **Start `overalls-trustd` with `DefaultDependencies=no`.** Trust then finished
  before `basic.target`, but `lilly-network` still waits for `basic.target`.
  On a 1-vCPU guest the work only moved; readiness did not improve.
- **Replace `systemd-udev-settle` with an `eth0` device dependency in Ubuntu
  `lilly-network`.** The settle job left the critical path, but other sysinit
  work then gated `sysinit.target` at about the same time. There was no
  measurable gain.
- **Root `noCheck`.** fsck never reached the top blame entries. Its effect was
  inside run-to-run noise.

Investigated and not changed:
- **Merging Lilly's `pending` and `delivering` trust journal writes.** Each
  locked, durable write costs about 6 ms, which is below 0.1% of the trust
  wait. `Lilly.Lifecycle.GuestTrust` is already an Ash state machine with
  explicit edges and property tests.
- **Dropping `--fresh`, or writing the Ubuntu bundle by hand.** Both would leave
  hash links and hooks stale. The verified no-op keeps `update-ca-certificates`
  as the only writer of the store.
- **A no-initrd NixOS boot.** It needs a custom kernel with virtio-blk and ext4
  built in, plus a new artifact. The initrd phase (about 3.3–3.6 s, including a
  2 s `initrd-switch-root`) is still the largest NixOS block. This remains open.

## Consequences

Measured boot times, in seconds since guest kernel start. All runs are the
`guest-boot-profile` and `ubuntu-guest-boot-profile` fixtures (nested KVM,
1 vCPU, 512 MiB):

| | Baseline | Final |
| --- | --- | --- |
| NixOS trust start | 10.46 | 8.09–9.35 |
| NixOS readiness | 11.36–11.43 | 9.02–10.59 |
| Ubuntu trust installed (matching set) | 9.04–9.28 | 4.64 |
| Ubuntu readiness (matching set) | 9.28–9.51 | 5.54 |
| Ubuntu readiness (rotated sets, full rebuild) | 8.94–9.47 | 7.81–8.19 |

The NixOS image without private services can finish booting in the `zfs-guest`
fixture. Its `systemd-analyze time` went from 1.761 + 3.367 + 6.121 = 11.250 s
to 1.582 + 3.183 + 4.933 = 9.698 s (kernel + initrd + userspace). The
[review](../reviews/2026-10-10-guest-boot-profile.md) has per-run numbers.
Fleet hardware has cheaper VM exits, so absolute numbers and the quiet-console
gain will differ there.

The console no longer shows routine `Starting`/`Started` lines. The boot report
timeline and fleet readiness diagnostics replace them. A failing unit still
prints `[FAILED]`.

The Ubuntu fast path applies only when the host delivers exactly the image's
roots. Any other set still pays the full rebuild. Image rebuilds change the
manifest digests. Existing writable disks keep their old layout and take the
full path on their first boot.

## Invariants and verification

- Stamped output is independent of chunking, and stripping it recovers the
  input. Retention is the exact capped prefix. Covered by Hegel properties in
  [boot-log tests](../../../lilly/native/boot-log/src/tests.rs) and the process
  fixture in [boot_log.rs](../../../lilly/native/boot-log/tests/boot_log.rs).
- Report lines are marked, printable and bounded. The report waits for at most
  30 s and handles an unfinished boot. Covered by
  [Python unit/property tests](../../../nix/tests/evaluation/ubuntu-guest.py).
- Rotation still takes the full path:
  - a present marker always means a completed rebuild;
  - an identical delivery is a no-op;
  - drift in the checked marker, managed roots, bundle or direct PEM links,
    rotation or failed rebuild takes the full path.

  Covered by the
  [Rust receiver tests](../../../lyra/src/bin/overalls-trustd.rs). The image digest
  equals Lilly's `GuestTrust.digest/1`, checked against a fixed vector.
- NixOS boots with a registered store and no registration file. The rootfs
  rebuilds byte-identically (`nix build --rebuild`). The native check runs
  `nix-store -q --hash /run/current-system`.
- [Native boot-profile journey](../../../nix/tests/machines/zfs-guest/boot-profile.py):
  each image boots three times through Lilly's real trust delivery:
  1. image roots;
  2. an added root;
  3. that root retired.

  After every boot the guest bundle must hold exactly the delivered roots. On
  Ubuntu, `openssl verify -CApath /etc/ssl/certs` must pass for each present
  root and fail for the retired one, and the managed file count must match.

## Implementation evidence

- Writer: [lib.rs](../../../lilly/native/boot-log/src/lib.rs) (`Stamper`, `Retention`).
- Report: [boot_report.py](../../../nix/packages/guest/boot_report.py), wired in
  [configuration.nix](../../../nix/packages/guest/configuration.nix) and
  [lilly-boot-report.service](../../../nix/packages/guest/ubuntu/units/lilly-boot-report.service).
- NixOS registration at build time: [guest builder](../../../nix/packages/guest/default.nix).
- Ubuntu prebuilt trust: [Ubuntu builder](../../../nix/packages/guest/ubuntu/default.nix),
  [platform_digest.py](../../../nix/packages/guest/ubuntu/platform_digest.py) and
  [overalls-trustd.rs](../../../lyra/src/bin/overalls-trustd.rs).
- Native checks: [zfs-guest fixture](../../../nix/tests/machines/zfs-guest/default.nix)
  (`guest-boot-profile`, `ubuntu-guest-boot-profile`; `zfs-guest` and
  `ubuntu-guest` assert the profile on first boot).

The review lists the recorded runs. Fleet-hardware measurement after deployment
is still to be done.
Merge review found an implementation discrepancy against the at-most-30-second
completion wait above. `boot_report.py` checks its polling deadline between
calls, while an in-flight completion probe keeps its 20 s tool timeout. A
controlled runner consuming 20 s per probe waited 40.25 s. Later report queries
also retain individual 20 s timeouts. The accepted wait requirement is preserved
and remains unimplemented; a timeout-budget correction and scoped regression
are still required. This observation-only report never grants readiness or
changes trust ordering. Implementation is partial for this explicit gap.
The verified-current predicate does not inspect subject-hash links or update.d
outputs independently. Native rotation covers CApath after real rebuilds, while
isolated drift of uninspected outputs remains outside that no-op evidence scope.
Changed delivered sets still run the full updater to maintain links and hooks.

## Open questions

- Enforce the accepted at-most-30-second completion wait across in-flight tools;
  the current polling deadline alone does not satisfy it.
- Is a no-initrd NixOS boot (built-in virtio/ext4 kernel) worth a custom kernel
  artifact? Measure it after fleet numbers exist.
- On multi-vCPU fleet guests, does starting trust early help? Re-measure there.
  It did not help on 1 vCPU.

## Related decisions

[ADR-0113](0113-guest-trust-at-boot.md) owns boot-bound trust delivery and
ordering. [ADR-0011](0011-nixos-guest-and-console.md) and
[ADR-0068](0068-nix-built-ubuntu-guests.md) own image artifacts and the locked Ubuntu
builder. The
[2026-09-26 provisioning review](../reviews/2026-09-26-porsche-provisioning-performance.md)
recommended this profiling.
