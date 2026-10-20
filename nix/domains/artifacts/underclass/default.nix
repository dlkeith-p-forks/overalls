{ lib, rustPlatform, fetchFromGitHub, makeWrapper }:
rustPlatform.buildRustPackage rec {
  pname = "underclass";
  version = "0.1.0-dbaf7b8";

  src = fetchFromGitHub {
    owner = "ghuntley";
    repo = "underclass";
    rev = "dbaf7b8fc62fdb447c00f4b8746a66ff51db3c1c";
    hash = "sha256-reqW7b1WT1D6whTnC2sYpZijWwBW3ErbWq5pywKF0Y0=";
  };

  cargoHash = "sha256-trXMnTioYNjr74HjFcDjMvJ8GYUG0UTiPVi68PNBzEk=";
  # @cc [owner:ghuntley,label:durability;build] underclass-fixed-slo-journal
  # The pinned proxy MUST compile the reviewed Rust journal and admission/body
  # patch from this source tree without adding dependencies or provider replay.
  patches = [ ./instrumentation.patch ];
  postPatch = ''
    cp ${./slo.rs} src/slo.rs
  '';
  nativeBuildInputs = [ makeWrapper ];
  # @cc [owner:ghuntley,label:cli] underclass-utop-wrapper
  # The package MUST expose utop as underclass top, preserving user arguments.
  postInstall = ''
    makeWrapper "$out/bin/underclass" "$out/bin/utop" --add-flags top
  '';
  # Hegel's build script launches a nested Cargo build that cannot use the
  # outer vendored registry. Upstream Rust tests run before revising this pin;
  # the fleet derivation and NixOS check remain fully offline.
  doCheck = false;

  meta = {
    description = "Pooled ChatGPT Codex and GitHub Copilot subscription proxy";
    homepage = "https://github.com/ghuntley/underclass";
    license = lib.licenses.mit;
    mainProgram = "underclass";
    platforms = [ "x86_64-linux" ];
  };
}
