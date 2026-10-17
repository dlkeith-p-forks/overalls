{ nixCompact ? import ../artifacts/nix-compact/source.nix }:
{ lib, pkgs, ... }:
let
  standalone = nixCompact;
in {
  imports = [ standalone.nixosModules.default ];
  # @cc [owner:ghuntley,label:build] compact-native-nix-selection
  # Hosts MUST enable the public `programs.nix-compact` module by default and,
  # without an explicit nix.package override, MUST select the source-patched
  # package from the supplied stable input. Disabling `programs.nix-compact`
  # or explicitly choosing a package MUST retain ordinary NixOS precedence.
  config = {
    programs.nix-compact.enable = lib.mkDefault true;
    programs.nix-compact.package = lib.mkDefault (standalone.lib.mkPackage { inherit pkgs; });
  };
}
