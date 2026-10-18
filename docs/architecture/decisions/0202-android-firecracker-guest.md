# ADR-0202: Software-rendered Android in the Firecracker guest

- ID: ADR-0202
- Status: accepted
- Date: 2026-10-18
- Implementation: partial
- Components: Lilly, Marshall, protocol, Nix artifacts

## Decision

Android is an additive `linux-android-v1` guest profile based on the NixOS
Firecracker guest. The Android emulator runs inside that guest with TCG/software
rendering (`-no-accel`, `-gpu swiftshader_indirect`) and no `/dev/kvm`, GPU,
USB or framebuffer device. The image carries SDK/platform and x86_64 Google APIs
system images for API 34, 35 and 36, with API 36 as the persistent AVD default.

The image currently provides only a loopback-bound diagnostic RFB bridge; it
does not claim authenticated display access or expose public ADB/RFB listeners.
An authenticated vsock display relay, controller lease and read-only viewers
remain a follow-up integration. Emulator userdata is persistent across restarts.
The profile starts at 4 vCPUs, 8 GiB RAM and 32 GiB disk with a 600-second
readiness budget.

## Consequences and verification

Software rendering increases boot and frame latency. Protocol capability and
manifest identity are additive and preserve existing Linux identities. Hegel
state-machine properties cover lease and generation fencing; NixOS machine tests
cover SDK inventory, software flags, ADB boot, APK/screenshot behavior and the
absence of `/dev/kvm`. Production display bridge and Firecracker execution remain
partial until the corresponding native machine evidence is recorded.
