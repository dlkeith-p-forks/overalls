# Android Firecracker guest review

The Android profile preserves the existing NixOS/Firecracker guest boundary and
adds an explicit protocol identity, SDK closure and software-rendered emulator.
No host KVM or public display socket is introduced. The loopback RFB bridge is
diagnostic only and does not establish authenticated display authority. The implementation is partial:
current evidence is protocol tests, a Hegel lifecycle property and a passing
NixOS software-emulator machine fixture. The fixture was executed through
`nix build .#checks.x86_64-linux.android-emulator-software --no-link`; it built
the API 36 fixture APK, booted the 8-vCPU/8-GiB software emulator with TCG,
authenticated ADB, installed/launched the fixture, captured a PNG screencap,
and verified marker persistence across an emulator restart. Authenticated
vsock display and production Firecracker execution remain open validation work.
