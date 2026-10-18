{ pkgs, terminald, lyraLinux, codingClis ? import ../coding-clis.nix { inherit pkgs; }, androidSdk,
  privateServiceRoots ? [ ], imageName ? "lilly-android-x86_64", minimumMemoryBytes ? 4294967296 }:

import ../default.nix {
  inherit pkgs terminald lyraLinux codingClis privateServiceRoots imageName minimumMemoryBytes;
  extraModules = [ (import ./../android.nix { inherit pkgs androidSdk; }) ];
}
