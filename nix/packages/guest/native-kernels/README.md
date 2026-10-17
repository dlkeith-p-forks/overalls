# Native guest kernel inputs

This directory is the immutable input boundary for native FreeBSD and OmniOS
guests. `default.nix` pins the source commits named by the native guest plan and
publishes patch/configuration hashes used by the v6 image manifest. The patch
files are intentionally small reviewable units: they establish the vendored
virtio-vsock contract and configuration surface while the OS-specific transport
implementation is built by the cross toolchain.

The derivations produce a build receipt even on the Linux release builder. They
do not claim that receipt is a bootable kernel: `artifact.available` is false and
the placeholder descriptor is rejected by runtime admission until a FreeBSD or
illumos cross build supplies the kernel bytes. This keeps image identities stable
and prevents stock kernels from being silently advertised as native support.
