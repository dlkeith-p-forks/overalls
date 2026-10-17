{ nixpkgs, modules, disko }:
let
  make = platform: firmware: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ modules.default (import ../../../../platform/hosts/profile.nix {
      host = import ./. { inherit platform firmware; }; diskoModule = disko.nixosModules.disko;
    }) ({ config, lib, ... }: {
      disko.memSize = 2048;
      disko.imageBuilder.imageFormat = "qcow2";

      # Disk-image building has no physical serial discovery. The fixture maps
      # declared identities onto the image builder's private virtual devices.

      disko.devices.disk = lib.mkMerge [
        (lib.genAttrs (if platform == "hetzner" then [ "system0" "system1" ] else [ "system0" "local1" "local2" ]) (_: { imageSize = "12G"; }))
        { system0.device = lib.mkForce "/dev/vda"; }
        (lib.optionalAttrs (platform == "hetzner") { system1.device = lib.mkForce "/dev/vdb"; })
        (lib.optionalAttrs (platform == "ec2") { local1.device = lib.mkForce "/dev/vdb"; local2.device = lib.mkForce "/dev/vdc"; })
      ];
      system.build.overallsTestImages = lib.overrideDerivation config.system.build.diskoImages (previous: {
        buildCommand = previous.buildCommand + ''
          ${config.boot.zfs.package}/bin/zpool export ${if platform == "hetzner" then "zroot" else "guests"}
        '';
      });
    }) ];
  };
in {
  hetzner-uefi = make "hetzner" "uefi";
  hetzner-bios = make "hetzner" "bios";
  ec2-uefi = make "ec2" "uefi";
  ec2-bios = make "ec2" "bios";
}
