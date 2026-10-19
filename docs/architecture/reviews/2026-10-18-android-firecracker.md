# Android Firecracker guest review

The Android profile preserves the existing NixOS/Firecracker guest boundary and
adds an explicit protocol identity, SDK closure and software-rendered emulator.
No host KVM or public display socket is introduced. The loopback RFB bridge is
diagnostic only and does not establish authenticated display authority. The implementation is partial:
current evidence is protocol tests, a Hegel lifecycle property and a passing
NixOS software-emulator machine fixture. The fixture was executed through
`nix build .#checks.x86_64-linux.android-emulator-software --no-link`; it built
the fixture APK against API 36 and booted an API 34 AVD with software rendering
and acceleration disabled. The NixOS test VM has 8 vCPUs and 8 GiB memory; the
AVD is configured for 4 Android cores and 4 GiB. The fixture authenticated ADB,
installed/launched the APK, captured a PNG screencap, and verified marker
persistence across an emulator restart. This records the standalone software
emulator, not the production API 36 guest image, TAP firewall enforcement,
Lilly ticket authority or browser control. Authenticated vsock display and
production Firecracker execution remain open validation work.
