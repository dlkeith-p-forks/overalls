{ pkgs, nixpkgs, hostFixture, secretsModule, imageSource, platform ? "hetzner", firmwareMode ? "uefi" }:
let
  instrumented = { lib, modulesPath, ... }: {
    imports = [ (modulesPath + "/testing/test-instrumentation.nix") ];
    documentation.enable = false;
    users.users.root.hashedPasswordFile = lib.mkForce null;
    boot.kernelParams = [ "console=ttyS0" ];
    boot.loader.grub.extraConfig = "serial; terminal_output serial";
  };
  testKey = imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519";
  target = hostFixture.extendModules { modules = [ instrumented ({ lib, ... }: {
    overalls.access.users = lib.mkForce {
      ghuntley = { login = true; admin = true; sshKeys = [
        (lib.removeSuffix "\n" (builtins.readFile (imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519.pub")))
      ]; };
    };
  }) ]; };
  installer = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ../../../modules/access.nix instrumented ({ config, lib, pkgs, modulesPath, ... }: {
      imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
      system.stateVersion = "26.05";
      overalls.access.enable = true;
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      environment.systemPackages = [ config.boot.zfs.package (pkgs.writeShellScriptBin "host-test-install" ''
        set -eu
        test "$#" = 1
        test "$1" = --erase-fixture-disks
        ${lib.getExe target.config.system.build.destroyFormatMount} --yes-wipe-all-disks
        ${config.system.build.nixos-install}/bin/nixos-install --root /mnt \
          --system ${target.config.system.build.toplevel} --no-channel-copy --no-root-password
        sync
      '') ];
      isoImage.storeContents = [ target.config.system.build.toplevel target.config.system.build.destroyFormatMount ];
    }) ];
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-${platform}-${firmwareMode}-installation";
  nodes = {};
  requiredFeatures.kvm = true;
  globalTimeout = 1800;
  testScript = ''
    test_key = "${testKey}"
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    firmware = "${pkgs.OVMF.firmware}"
    variables = "${pkgs.OVMF.variables}"
    platform = "${platform}"
    firmware_mode = "${firmwareMode}"
    installer_iso = "${installer.config.system.build.isoImage}/iso/${installer.config.image.fileName}"
  '' + builtins.readFile ./driver.py;
}
