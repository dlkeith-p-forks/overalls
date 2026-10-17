{ pkgs, debug ? false }:
let
  # @cc [owner:ghuntley,label:build] cloudhv-firmware-from-pinned-edk2
  # The firmware MUST be built from the pinned nixpkgs edk2 source with the
  # CloudHv platform description and only the patch listed here. It MUST NOT
  # download anything or depend on a prebuilt firmware blob (ADR-0169).
  base = pkgs.OVMF.override {
    projectDscPath = "OvmfPkg/CloudHv/CloudHvX64.dsc";
    fwPrefix = "CLOUDHV";
    secureBoot = false;
    tpmSupport = false;
    httpSupport = false;
    tlsSupport = false;
    inherit debug;
  };
in
# @cc [owner:ghuntley,label:isolation] cloudhv-firmware-pvh-payload
# The result MUST be a single PVH-bootable ELF (`XEN_ELFNOTE_PHYS32_ENTRY`
# note present) at `$fd/FV/CLOUDHV.fd` whose 32-bit PCI aperture ends at
# Firecracker's PCI MMCONFIG base, so Firecracker can load it through
# `boot-source.kernel_image_path` without any firmware-specific loader.
base.overrideAttrs (previous: {
  pname = "cloudhv-firecracker-firmware";
  patches = (previous.patches or [ ]) ++ [
    # 32-bit PCI aperture ends at Firecracker's MMCONFIG window (CloudHv.h hole
    # size and the PlatformInitLib window computed from it), so the firmware's
    # normal bus enumeration never assigns a BAR over MMCONFIG. Firecracker
    # follows BAR moves (firecracker-pci-bar-relocation.patch).
    ../../../../platform/patches/edk2-cloudhv-firecracker-mmio-hole.patch
  ];
  nativeBuildInputs = (previous.nativeBuildInputs or [ ]) ++ [ pkgs.binutils ];
  postInstall = (previous.postInstall or "") + ''
    firmware="$fd/FV/CLOUDHV.fd"
    test -s "$firmware"
    # The PVH entry note (owner "Xen", type XEN_ELFNOTE_PHYS32_ENTRY = 0x12) is
    # what lets Firecracker's ELF loader boot the firmware.
    readelf --file-header "$firmware" > firmware-header.txt
    if ! grep -q "Class:.*ELF" firmware-header.txt; then
      echo "CLOUDHV.fd is not an ELF image" >&2
      cat firmware-header.txt >&2
      exit 1
    fi
    readelf --notes "$firmware" > firmware-notes.txt
    if ! grep -q -i "xen" firmware-notes.txt; then
      echo "CLOUDHV.fd carries no Xen PVH note" >&2
      cat firmware-notes.txt >&2
      exit 1
    fi
    cp firmware-notes.txt "$fd/FV/CLOUDHV.notes.txt"
    grep -q "0x1ec00000" OvmfPkg/Include/IndustryStandard/CloudHv.h
  '';
  # Consumers use "${firmware.fd}/FV/CLOUDHV.fd".
  passthru = (previous.passthru or { }) // { firmwareFile = "FV/CLOUDHV.fd"; };
  meta = (previous.meta or { }) // {
    description = "edk2 CloudHv UEFI firmware adjusted for Firecracker's PCI layout";
  };
})
