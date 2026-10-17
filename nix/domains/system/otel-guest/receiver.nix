{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "overalls-otel-guest-receiver";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./receiver;
    filter = path: _: builtins.baseNameOf path != "target";
  };
  cargoLock.lockFile = ./receiver/Cargo.lock;
}
