{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  key = builtins.head (import ../../../users.nix).ghuntley.sshKeys;
  machine = name: {
    address = name;
    port = if name == "beta" then 2222 else 22;
    systems = [ "x86_64-linux" ];
    logicalCpus = 2;
    clientPublicKeys = [ key ];
    hostPublicKey = key;
    encryptedFile = "/run/fixture/keys.enc.json";
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-remote-builders";
  globalTimeout = 600;
  defaults = { config, ... }: {
    imports = [ module ];
    system.stateVersion = "26.05";
    virtualisation = { memorySize = 1536; cores = 2; qemu.forceAccel = lib.mkForce true; };
    overalls.access.enable = true;
    overalls.remoteBuilders = {
      enable = true;
      localName = config.networking.hostName;
      machines = { alpha = machine "alpha"; beta = machine "beta"; };
    };
    services.openssh.ports = [ (if config.networking.hostName == "beta" then 2222 else 22) ];
    nix.settings = {
      substituters = lib.mkForce [ "ssh-ng://nix-ssh@overalls-builder-${if config.networking.hostName == "alpha" then "beta" else "alpha"}?trusted=true&ssh-key=/run/overalls-secrets/remote-builders/id_ed25519" ];
      sandbox = true;
      sandbox-paths = [ "/builder-id" ];
      experimental-features = [ "nix-command" "flakes" ];
    };
    environment.systemPackages = [ pkgs.openssh pkgs.python3 pkgs.busybox packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."seal.py".source = ./seal.py;
    environment.etc."jobs.nix".text = ''
      { batch, count ? 6 }:
      builtins.genList (i: builtins.derivation {
        name = "remote-builder-" + batch + "-" + toString i;
        system = "x86_64-linux";
        builder = (builtins.storePath "${pkgs.busybox}") + "/bin/sh";
        args = [ "-c" '' + "''" + ''
          set -eu
          export PATH=${pkgs.busybox}/bin
          mkdir "$out"
          cat /builder-id > "$out/host"
          date +%s > "$out/start"
          sleep 6
          date +%s > "$out/end"
        '' + "''" + '' ];
      }) count
    '';
  };
  nodes = { alpha = {}; beta = {}; };
  testScript = builtins.readFile ./driver.py;
}
