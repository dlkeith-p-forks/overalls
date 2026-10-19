{ pkgs, terminald, lyraLinux, codingClis ? import ../coding-clis.nix { inherit pkgs; }, androidSdk }:
args:
import ../default.nix ({
  inherit pkgs terminald lyraLinux codingClis;
  guestAgents = "linux-android-v1";
  minimumMemoryBytes = 8589934592;
  minimumDiskBytes = 34359738368;
  extraModules = [ (import ./../android.nix { inherit pkgs androidSdk; }) ];
} // args)
