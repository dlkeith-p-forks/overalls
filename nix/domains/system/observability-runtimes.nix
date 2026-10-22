{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "overalls-observability-runtimes";
  version = "0.1.0";
  src = ./observability-runtimes;
  cargoLock.lockFile = ./observability-runtimes/Cargo.lock;
}
