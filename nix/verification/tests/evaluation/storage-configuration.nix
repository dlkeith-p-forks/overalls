{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  checks = lib.mapAttrs (name: machine:
    let c = machine.config; mirror = lib.hasPrefix "hetzner" name; cloud = lib.hasPrefix "hcloud" name;
      moduleLines = lib.splitString "\n" c.boot.extraModprobeConfig;
      pool = c.disko.devices.zpool.${if mirror || cloud then "zroot" else "guests"};
    in lib.all (a: a.assertion) c.assertions
      && c.boot.loader.grub.devices == []
      && builtins.length c.boot.loader.grub.mirroredBoots == (if mirror then 2 else 1)
      && c.services.overallsAutoUpdate.installationBinding.effective.filesystems."/".device == c.fileSystems."/".device
      && c.boot.loader.grub.efiSupport == lib.hasSuffix "uefi" name
      && pool.rootFsOptions.compression == "lz4"
      && pool.rootFsOptions.reservation == "none"
      && pool.rootFsOptions.refreservation == "none"
      && (if mirror then pool.mode == "mirror" && pool.datasets.lilly.options.quota == "536870912"
          # hcloud-single-zfs-root: one disk, a ZFS root and no guest dataset.
          else if cloud then pool.mode == "" && pool.datasets ? root && !(pool.datasets ? lilly)
            && c.fileSystems."/".fsType == "zfs" && c.fileSystems."/".device == "zroot/root"
            && !(c.fileSystems ? "/var/lib/lilly/pool") && !(builtins.elem "ena" c.boot.kernelModules)
          else pool.mode == "" && !(pool.datasets.lilly.options ? quota) && c.fileSystems."/".fsType == "ext4")
      && !c.services.marshall.enable && !c.services.lilly.enable && !c.services.overallsAutoUpdate.enable
      && !c.services.cloud-init.enable && !c.services.amazon-ssm-agent.enable
      && builtins.elem "nested-kvm" c.nix.settings.extra-system-features
      && builtins.elem "kvm-intel" c.boot.kernelModules
      && builtins.elem "kvm-amd" c.boot.kernelModules
      && builtins.elem "options kvm-intel nested=Y" moduleLines
      && builtins.elem "options kvm-amd nested=1" moduleLines
      && builtins.elem "options zfs zfs_arc_max=536870912 zfs_arc_dnode_limit=134217728" moduleLines
      && c.programs.nix-ld.enable
      && lib.any (package: lib.getName package == "git") c.environment.systemPackages
      && lib.any (package: lib.getName package == "jq") c.environment.systemPackages
      && lib.any (package: lib.getName package == "direnv") c.environment.systemPackages
      && c.programs.direnv.enable
      && lib.hasInfix "direnv hook bash" c.programs.bash.interactiveShellInit
      && lib.any (package: lib.getName package == "devenv") c.environment.systemPackages
      && (cloud || builtins.elem "nofail" c.fileSystems."/var/lib/lilly/pool".options)
      && !(c.systemd.services ? disko)
  ) fixtures;
in
assert lib.assertMsg (lib.all (v: v) (lib.attrValues checks)) "Host profile evaluation failed";
pkgs.writeText "host-profile-checks.json" (builtins.toJSON checks)
