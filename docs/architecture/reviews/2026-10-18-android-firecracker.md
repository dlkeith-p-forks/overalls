# Android Firecracker guest review

The Android profile preserves the existing NixOS/Firecracker guest boundary and
adds an explicit protocol identity, SDK closure and software-rendered emulator.
No host KVM or public display socket is introduced. The implementation is partial:
current evidence is protocol tests, a Hegel lifecycle property and a NixOS
software-emulator machine fixture; authenticated vsock display and production
Firecracker execution remain open validation work.
