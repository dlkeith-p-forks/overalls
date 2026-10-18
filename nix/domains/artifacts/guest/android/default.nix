{ pkgs, terminald, lyraLinux, codingClis ? import ../coding-clis.nix { inherit pkgs; }, androidSdk }:
args:
import ../default.nix ({
  inherit pkgs terminald lyraLinux codingClis;
  extraModules = [ (import ./../android.nix { inherit pkgs androidSdk; }) ];
} // args)
