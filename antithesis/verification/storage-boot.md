# Storage-router TCG boot, 2026-10-13

**Passed:** The source-built NixOS router ran under one-vCPU QEMU TCG with a
real Linux ZFS mirror, Lilly-generated nftables policy, and production Brady.
The fresh first boot created the mirror and applied Brady's fixture quota.
The bounded smoke then intercepted HTTP and HTTPS, observed two complete cache
bodies and independent origin effects, replayed both bodies with the origin
stopped without increasing its effect count, fsynced a marker, and received an
acknowledged QMP `system_reset`. A new boot imported the same pool and parent
GUIDs, read the marker's exact 41 bytes, and reapplied the 64 MiB cache quota
and refquota. The router VM was stopped after evidence collection; its sparse
disks and logs remain at `/var/tmp/overalls-routervm-20261013/state`.

The passing build is
`/nix/store/40c1lak39q5xyxg6q296jasczlrgd3zg-overalls-antithesis-router-vmm-context`.
Its root image is
`/nix/store/7cki4d3kxzfw7d5a30jj3xmlaqna4ysa-overalls-antithesis-router-image`
with root SHA-256
`be49c4a2420d0231038989cb38e19611ee4e2c99f5e1ba7bc22f4df55cfb073f`.
The context's runner and smoke hashes match the invoked repository files. The
exact manifest, source hashes, store closure, retained-disk hashes and log
hashes are in [storage-boot.json](storage-boot.json). The source HEAD was
`c835eb1017d24a001215c319373fa4204d64269b`; the worktree was dirty, so
the recorded file hashes identify the tested sources more precisely than HEAD.

Observed boot IDs were `299888b1-e940-4863-95b7-e1a5a917775c` before reset
and `9507f3ad-11d3-49d5-bb0f-b18f8579b7aa` afterward. Pool GUID
`6018209262888840004` and parent GUID `16570712071147543403` remained
equal across the reset. The retained marker SHA-256 was
`5178eba5eb28f198a83074363a4d02651ad1e4c5ad4ba9d4afc4a93de9e29b44`.
Before reset, the nft interception counter reached 118 packets. After reset,
the independent origin journal held one `http:public` and one `https:public`
effect, and both complete cached body hashes matched the 22-byte fixture
response. The post-reset pool was `ONLINE`, with parent quota 256 MiB and
Brady quota and refquota each 64 MiB.

The passing command was
`python3.13 antithesis/emulation/storage/smoke.py --config /var/tmp/overalls-routervm-20261013/config.json`.
It exited 0; its staged proof and final values are in
`/var/tmp/overalls-routervm-20261013/smoke-final2.log`. The independent
post-reset oracle reply is in
`/var/tmp/overalls-routervm-20261013/post-observe.json`. The serial log is
`/var/tmp/overalls-routervm-20261013/state/serial.log`; the Nix build log is
`/home/ghuntley/.local/state/nix/build-logs/1791895487326-3737713-0.jsonl`.
Ruff format/check, `ty` with the pinned Python 3.13 cryptography environment,
code-contract formatting, both staged and unstaged `git diff --check`, and a
bounded cookie/private-key scan of the recorded logs passed.

Earlier retained diagnostic attempts exposed and resolved a missing `rw`
direct-boot flag, a missing Lilly release cookie, missing `sysctl` in the
bootstrap path, a first-boot udev serial-read race, and a CA lacking Brady's
required `keyCertSign` usage. The release cookie is now randomly generated
in a root-only volatile environment file each boot. These attempts are not
counted as passing evidence. Their disks and serial logs remain under
`/var/tmp/overalls-routervm-20261013/state-attempt1`,
`state-diagnostic-cookie`, and `state-diagnostic-final1`.

Architecture impact is limited to an emulated verification harness for the
existing storage, router, crash and isolation decisions (ADR-0069, ADR-0135,
ADR-0140 and ADR-0149). No production decision or API contract changed. This
result is software-emulated kernel integration and guest/process-crash evidence;
it does not establish physical power-loss durability, KVM/Firecracker behavior,
strict production reverse-path validation, or real guest attribution. The
router-vmm context was built and the VM was launched directly from its exact
Nix image and QEMU. The container entrypoint and hosted Antithesis run were
not exercised.
