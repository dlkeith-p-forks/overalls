{ nixpkgs, nixCompact ? import ./source.nix }:
let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ (import ../../modules/nix-compact.nix { inherit nixCompact; }) extra ];
  }).config;
  enabled = evaluate {};
  disabled = evaluate { programs.nix-compact.enable = false; };
  override = evaluate { nix.package = pkgs.nix; };
  patched = nixCompact.lib.mkPackage { inherit pkgs; };
  checks = {
    nativePackageSelected = enabled.nix.package.outPath == patched.outPath;
    cliActuallyPatched = patched.nix-cli.outPath != pkgs.nix.nix-cli.outPath;
    daemonLibrariesUnchanged = patched.libs.nix-store.outPath == pkgs.nix.libs.nix-store.outPath;
    canDisable = disabled.nix.package.outPath == pkgs.nix.outPath;
    explicitPackageWins = override.nix.package.outPath == pkgs.nix.outPath;
    enabledByDefault = enabled.programs.nix-compact.enable;
  };
in
assert builtins.all (result: result) (builtins.attrValues checks);
pkgs.runCommand "nix-compact-configuration-check" {
  result = builtins.toJSON checks;
} ''
  printf '%s\n' "$result" > $out
''
