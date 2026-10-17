{ pkgs, antithesisObserver ? false, toolchain ? (import ./lyra.nix { inherit pkgs; }).toolchain }:
pkgs.pkgsStatic.rustPlatform.buildRustPackage {
  pname = "lilly-terminald";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../terminald;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "target" && name != ".hegel" &&
        (type == "directory" || pkgs.lib.hasSuffix ".rs" name ||
          builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" ]);
  };
  cargoLock.lockFile = ../terminald/Cargo.lock;
  cargoBuildFlags = pkgs.lib.optionals antithesisObserver [ "--features" "antithesis-observer" ];
  doCheck = false;
  strictDeps = true;
  meta = {
    description = "Overalls guest terminal multiplexer over AF_VSOCK";
    platforms = [ "x86_64-linux" ];
  };
  passthru.native = import ./terminald-native.nix { inherit pkgs toolchain; };
}
