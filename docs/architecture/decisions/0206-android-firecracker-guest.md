# ADR-0206: Software-rendered Android in the Firecracker guest

- ID: ADR-0206
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Lilly, Marshall, protocol, Nix artifacts
- Supersedes: none
- Superseded by: none

## Context

Android support must use the existing NixOS Firecracker guest boundary. Firecracker
provides no display device and the guest host cannot provide nested KVM.

## Decision

Use an additive `linux-android-v1` profile. Run one persistent API 36 AVD inside
the guest with TCG software rendering (`-no-accel`, `swiftshader_indirect`) and
SDK/platform and x86_64 Google APIs images for API 34, 35 and 36. Keep ADB and
display private to the machine transport; eventual display access uses an
authenticated relay with one controller and read-only viewers.

## Alternatives

A separate host KVM Android VM and direct Android boot in Firecracker were rejected
for this requested guest model. Public ADB/RFB listeners were rejected for security.

## Consequences

The profile has higher boot and frame latency and needs persistent writable AVD
storage. Existing Linux image identities remain unchanged. Initial sizing is eight
vCPUs, 8 GiB RAM and 32 GiB disk with a 600-second readiness budget.

## Invariants and verification

The emulator must not require `/dev/kvm`; stale generations cannot retain display
or input authority; AVD state survives restart; and viewers cannot send input.
Protocol tests, Hegel properties and the Android NixOS machine fixture cover the
current partial implementation. The guest now provides a typed host-CID-validated
display relay; native transport and browser rendering remain unverified.

## Implementation evidence

[Android guest module](../../../nix/domains/artifacts/guest/android.nix), [protocol capability](../../../protocol/lib/overalls_protocol/guest_agents.ex), [Hegel property](../../../protocol/test/android_emulator_state_machine_property_test.exs), and [machine fixture](../../../nix/verification/tests/machines/android-emulator/default.nix) provide partial evidence.

The [host-stream sequence-gap regression](../../../marshall/test/marshall/terminal/host_stream_android_test.exs)
and [reviewed focused execution](../reviews/2026-10-18-android-firecracker.md)
record channel closure, close-control output and generation-bound owner notice
in the BEAM. This does not establish authenticated native display transport.

## Open questions

Native Firecracker transport, controller lease integration, browser rendering and
the `/machines/:id` viewer still need end-to-end acceptance.

## Related decisions

[ADR-0161](0161-monospace-web-presentation.md) governs Marshall presentation.
