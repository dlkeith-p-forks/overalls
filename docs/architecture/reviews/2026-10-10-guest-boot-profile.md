# Guest boot profile and measured reductions (2026-10-10)

## Scope and authority

The user approved: (A) permanent guest boot timing visibility in NixOS and
Ubuntu images, then (B) speedups ranked by measured gain, keeping ADR-0113 trust
ordering. A follow-up instruction narrowed (B): read the implementation, measure
each candidate first, change only what evidence shows is slow and keep
correctness. In particular, `update-ca-certificates` must stay the Ubuntu store
writer. This review covers
[ADR-0154](../decisions/0154-guest-boot-profile.md) and its interaction with
[ADR-0113](../decisions/0113-guest-trust-at-boot.md).

## Architecture assessment

No Ash resource, protocol, listener, credential or authorization action changes.

- **Writer.** The boot-log writer changes the retained console bytes only by
  adding host offsets at line starts. The cap, custody, refusal and
  signal-propagation contracts are unchanged.
- **Boot report.** The report unit is observation only: it is ordered after
  readiness, required by nothing and never fails the boot. It prints unit names,
  times and the trust receiver's fixed events, never payloads.
- **NixOS image.** Build-time Nix registration moves existing work from boot
  into the reproducible image build and reuses the Ubuntu canonicalizer.
- **Ubuntu trust.** The verified-current path keeps `update-ca-certificates` as
  the only store writer. It skips the rebuild only when the marker,
  managed-file bytes, bundle PEM blocks and per-root links all prove the store
  already reflects the delivered set. The marker is withdrawn before any
  mutation and written only after a verified rebuild. Trust still completes
  before networking, private DNS, roster sync and sshd on every boot.

## Method

All numbers come from the `guest-boot-profile` and `ubuntu-guest-boot-profile`
NixOS checks: nested KVM, a 1-vCPU 512 MiB guest, three boots per run. Each run
boots the image roots, then an added root, then that root retired. Values are
seconds since guest kernel start, from the boot report's manager and unit
timeline lines. The NixOS image enables private services with the fixture root,
as fleet images do. Run-to-run noise is about ±0.4 s, so changes below that were
not accepted on single runs. The fixture has no Audi authority, so its roster
sync keeps the boot transaction unfinished and `systemd-analyze time` is
unavailable. Manager instants replace it.

## Results

| Run | Change | NixOS trust start | NixOS readiness | Ubuntu trust done (boot 1) | Ubuntu readiness (boots 1/2/3) |
| --- | --- | --- | --- | --- | --- |
| c | baseline (A only) | 10.46, 10.46 | 11.36, 11.43 | 9.04 (install 3.04 s) | 9.28, 9.51 |
| d | build-time Nix DB; Ubuntu verified-current trust | 9.65, 9.51, 11.42 | 10.82, 10.56, 12.97 | 6.11 (`current`, 26 ms) | 7.07, 8.94, 9.47 |
| e | Ubuntu `lilly-network` waits for `eth0`, not udev-settle | 10.26, 10.69, 9.80 | 11.55, 11.68, 11.03 | 6.42 | 7.57, 11.01, 9.78 |
| f | e reverted; trust `DefaultDependencies=no`; lean initrd; no vconsole | 8.57, 8.37, 8.10 | 11.08, 10.90, 10.93 | 4.93 | 7.53, 9.87, 9.63 |
| g | f trust ordering and `noCheck` reverted; quiet console | 8.56, 8.09, 9.35 | 9.63, 9.02, 10.59 | 4.64 | 5.54, 8.19, 7.81 |
| final | committed source | 8.22, 8.34, 8.61 | 9.17, 9.34, 9.64 | 4.62 | 5.56, 8.22, 7.83 |

Run c predates the rotation journey: it booted the same set twice, and both
Ubuntu boots paid the full rebuild.

Ubuntu boots 2 and 3 deliver changed sets and so pay the full
`update-ca-certificates --fresh` rebuild: 3.2–3.5 s in runs d, f and g, against
3.0–3.5 s in run c. After every boot, `trust-verify` passed. The bundle held
exactly the delivered roots, Ubuntu `openssl verify -CApath` accepted present
roots and refused the retired one, and the managed file count matched.

`systemd-analyze time` is only available on the NixOS image without private
services, whose boot can finish in the isolated `zfs-guest` fixture. Its first
boot went from "1.761s (kernel) + 3.367s (initrd) + 6.121s (userspace) =
11.250s" (readiness at 5.374 s of userspace) before the changes to "1.582s
(kernel) + 3.183s (initrd) + 4.933s (userspace) = 9.698s" (readiness at
4.190 s of userspace) on the final source.

Other measured facts:
- **NixOS `register-nix-paths`** took 1.71–1.85 s before `sysinit.target`
  (blame, critical chain). It no longer exists.
- **NixOS initrd** shrank from 29,199,190 to 23,080,372 bytes. The kernel phase
  (to initrd start) fell from 1.82–2.18 s to 1.51–1.82 s.
- **Console bytes** before the report fell from 19.7–20.4 KB to 0.7 KB (NixOS)
  and from 41.8–43.4 KB to 0.6–0.7 KB (Ubuntu). Every byte is a VMM exit.
- **Early trust start (run f).** Trust finished before `basic.target`, but
  `lilly-network` still waits for it and ran slower under contention. On 1 vCPU
  the boot is CPU-bound and readiness did not improve, so it was reverted.
- **udev-settle (run e).** Other sysinit work gated `sysinit.target` at about
  the same time, so there was no gain. Reverted.
- **Lilly trust journal writes.** A locked durable `Journal.write` median was
  about 5.9–6.3 ms (local ext4 microbenchmark, 50 iterations). Merging
  `pending` and `delivering` was not worth the change.

## Native evidence

- Run g of both boot-profile checks
  passed with all subtests, on the final source apart from documentation and
  comment edits.
- `cargo test` in `lilly/native/boot-log`: 7 unit/property tests and 6 process
  tests passed (lilly-boot-log: 13 passed).
- `cargo test --bin overalls-trustd`: overalls-trustd receiver tests 8 passed,
  including the three verified-current, rotation/drift and failed-rebuild cases.
  Clippy for all Lyra targets was clean.
- The `guest-readiness`, `private-services-guest`, `guest-ssh` and
  `ubuntu-guest-unit` evaluation checks passed. The last runs the boot report,
  manager, blame and platform-digest unit/property tests.
- On the committed source, the full `ubuntu-guest` check passed (test script
  finished in 1726.38s). It includes the first-boot profile assertion without
  requiring Startup finished.
- The first full `zfs-guest` execution passed the first-boot profile assertion
  (Startup finished, 9.698 s) and the storage subtests through resize. It then
  failed in the Inception subtest with `KeyError: 'allocations'`. The fixture's
  `snapshot` read the transient busy pool entry that Lilly reports while pool
  usage is moving (`pool.snapshot_withheld`, stage `usage_moving`, ADR-0031)
  right after the guest's data write. The race exists whenever a snapshot
  coincides with guest writes; faster boots can only shift when it happens.
  The fixture now retries until it reads a settled observation, within 60 s.
- The `zfs-guest` rerun with that fixture correction passed every subtest
  (test script finished in 3179.64s). Its first boot reported "Startup finished
  in 1.649s (kernel) + 3.189s (initrd) + 5.024s (userspace) = 9.863s".

## Remaining gaps

The later editor integration review found a discrepancy against ADR-0154's
accepted at-most-30-second completion wait. `boot_report.py` checks its 30 s
polling deadline between calls; an already running completion probe retains its
20 s timeout. A controlled runner consuming 20 s per completion probe waited
40.25 s. Subsequent report queries each retain a 20 s timeout. The accepted
requirement is preserved, implementation is partial and a timeout-budget
correction plus scoped regression remains required. Observation-only/non-gating
behavior and ADR-0113 ordering remain unchanged. This read-only timing-bound
check does not replace the recorded native measurements above.

- No fleet-hardware measurement after deployment yet. Nested-KVM exit costs
  inflate the quiet-console gain.
- No-initrd NixOS boot is not attempted. The initrd phase of about 3.3–3.6 s,
  including a 2 s `initrd-switch-root`, remains the largest NixOS block.
- Early trust start was not re-measured on multi-vCPU guests.
- The isolated fixtures cannot finish booting without Audi, so
  `systemd-analyze` time and critical-chain lines were only observed in the
  NixOS image without private services.
