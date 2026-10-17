{ pkgs, nixpkgs, module, fixtures }:
let
  inherit (pkgs) lib;
  cache = import ../../../platform/nix-cache.nix;
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  host = evaluate {};
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [ ../../../domains/artifacts/guest/configuration.nix ];
  };
  configured = cfg: builtins.elem cache.substituter cfg.nix.settings.substituters
    && builtins.elem cache.publicKey cfg.nix.settings.trusted-public-keys
    && builtins.elem "https://cache.nixos.org/" cfg.nix.settings.substituters
    && cfg.nix.settings.require-sigs;
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  disabledSignatures = builtins.tryEval (builtins.deepSeq
    (evaluate { nix.settings.require-sigs = lib.mkForce false; }).system.build.toplevel.drvPath true);
  fleet = lib.all (name: configured fixtures.${name}.config) (builtins.attrNames fixtures);
  cases = {
    host = configured host;
    guest = configured guest.config;
    fleet = fleet;
    signature-policy = valid host && !disabledSignatures.success;
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == [])
  "Nix cache configuration checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-nix-cache-configuration.json" (builtins.toJSON cases)
