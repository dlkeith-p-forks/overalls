# ADR-0098: Expanded image artifact admission limits

- ID: ADR-0098
- Date: 2026-09-23
- Status: accepted
- Implementation: implemented
- Components: shared protocol, Marshall Compute, Lilly Host, NixOS guest
- Supersedes: ADR-0014
- Superseded by: none

## Context

ADR-0014 bounded immutable root image artifacts at 32 GiB and kernel/initrd
artifacts at 512 MiB each. Those numbers had no documented quantitative rationale.
The complete Inception image can exceed the former root bound while remaining
below the 64 GiB writable root disk declared by that image. The user explicitly
authorized increasing the root protocol limit to
128 GiB and increasing the kernel and initrd limits by a large amount.
The separate manifest rule that the artifact fit the declared minimum disk
continues to prevent an oversized image from being admitted to a smaller VM.

## Decision

The manifest v2 validator accepts rootfs artifacts of 1 through 128 GiB,
inclusive, and kernel and initrd artifacts of 1 through 8 GiB each, inclusive.
It rejects larger artifacts. Minimum disk fit, content identity, descriptor
hashes, address admission and image handling remain as specified by ADR-0014
and its successors. These figures use binary GiB: 137,438,953,472 bytes for
rootfs and 8,589,934,592 bytes for each boot artifact. This replaces only
ADR-0014's artifact ceilings.

## Alternatives

Keeping the 32 GiB cap would reject a valid complete Inception image and force
build-output pruning solely to fit an unsupported numeric limit. Removing the
cap entirely would admit unbounded descriptors and invalidate bounded peer-input
handling. A 64 GiB cap would fit the current image but leave no room for larger
future VM shapes. The chosen 128 GiB bound remains finite and is still subject
to the manifest's minimum disk constraint. An 8 GiB kernel/initrd bound gives
16 times the prior headroom while retaining finite peer-input limits.

## Consequences

Valid root manifests between 32 and 128 GiB and boot artifacts between 512 MiB
and 8 GiB can now be registered and advertised.
The manifest identity continues to include exact artifact sizes, so relaxing
validation does not change IDs for existing images. Hosts still hash actual
artifact bytes before advertising and copying them; admitting a larger artifact
can increase storage, transfer and verification time. The protocol change is
additive for validators but requires coordinated consumer deployment before
newly admitted large images are selected. Existing smaller images remain valid.

## Invariants and verification

- Accept exactly 128 GiB when minimum disk is at least that large; reject one
  byte more even if disk is large enough.
- Accept exactly 8 GiB for each of kernel and initrd; reject one byte more.
- Reject an artifact that exceeds its declared minimum disk at any size.
- Keep image identity encoding unchanged.
- Run the shared protocol, Marshall and Lilly precommit gates. Validate the
  actual Inception image manifest and native image execution separately.

## Implementation evidence

The shared [manifest validator](../../../protocol/lib/overalls_protocol/image_manifest.ex)
applies the new bound and retains disk fit. Its
[boundary tests](../../../protocol/test/image_manifest_test.exs) exercise the
inclusive caps, one-byte overflows and insufficient disk. Marshall and Lilly
both consume this shared validator. The complete native Inception run remains
separate acceptance work under ADR-0085.

## Open questions

None for the artifact bound. Runtime capacity and Inception public acceptance
are tracked under their respective decisions.

## Related decisions

[ADR-0014](0014-image-and-address-admission.md) defines the historical artifact
limits and remaining image admission rules. [ADR-0016](0016-executable-generations-and-lifecycle.md)
carried those rules forward. [ADR-0085](0085-inception-public-ingress.md) defines
the Inception runtime acceptance obligations.
