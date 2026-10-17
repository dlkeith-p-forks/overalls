{ pkgs, packages, image ? packages.windowsGuest }:
# @cc [owner:ghuntley,label:verification] windows-guest-reaches-sac
# This machine test MUST boot the Windows image through the patched Firecracker
# with the CloudHv firmware on nested KVM and pass only when the Windows
# Special Administration Console prompt appears on the serial console and,
# when the image carries the transport probe, the host receives the probe's
# JSON answer through Firecracker's vsock Unix socket (`CONNECT 1099`) and
# reads its published log from the EFI system partition. It proves firmware
# PVH entry, ACPI delivery, the PM timer, virtio-blk-pci boot, EMS and the
# viosock transport. It does not prove networking, readiness or any Lilly
# launch path.
pkgs.testers.runNixOSTest {
  name = "overalls-windows-guest";
  requiredFeatures.nested-kvm = true;
  # Windows under nested KVM is slow; the image build itself happens before the
  # test starts because the image is an ordinary derivation input.
  globalTimeout = 3600;
  nodes.host = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 8192;
    virtualisation.cores = 4;
    virtualisation.diskSize = 4096;
    virtualisation.emptyDiskImages = [ 40960 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.kernelModules = [ "kvm" "kvm-intel" "kvm-amd" ];
    environment.systemPackages = [ packages.windowsBoot pkgs.e2fsprogs pkgs.socat pkgs.mtools pkgs.util-linux pkgs.jq ];
    environment.etc."overalls-windows-image".source = image;
  };
  testScript = ''
    image = "/etc/overalls-windows-image"
    probe = ${if image.passthru.agents or null != null then "True" else "False"}
  '' + builtins.readFile ./driver.py;
}
